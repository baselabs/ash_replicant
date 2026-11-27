"""Exercise the real declaration reader against disposable configuration files."""

import copy
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
READER = ROOT / "scripts/ci/postgres-lanes.sh"


class PostgresLanesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ash-replicant-lanes-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in (
            ".github/postgres.ref",
            ".github/postgres-lanes.json",
            "mix.exs",
            "scripts/qualification-jobs.json",
        ):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        self.lanes = json.loads((self.root / ".github/postgres-lanes.json").read_text())

    def read(self):
        return subprocess.run(
            [str(READER), "--json", str(self.root)],
            check=False, capture_output=True, text=True, timeout=30,
        )

    def write_lanes(self, lanes):
        (self.root / ".github/postgres-lanes.json").write_text(json.dumps(lanes))

    def refused(self):
        result = self.read()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), "PostgreSQL declarations are invalid")

    def test_matrices_and_inventory_cover_every_declared_role(self):
        result = self.read()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        dependencies = data["compatibility"][:3]
        self.assertEqual([row["label"] for row in dependencies],
                         ["exact-floors", "current-lock", "latest-compatible"])
        self.assertEqual([row["ash_selector"] for row in dependencies[1:]], ["", "latest"])
        for row in dependencies:
            self.assertEqual(row["pg_major"], data["engine_major"])
            self.assertEqual(row["pg_image"], "")
        for prefix in ("ash", "replicant", "onetime"):
            self.assertEqual(dependencies[0][prefix + "_requirement"],
                             "== " + dependencies[0][prefix + "_selector"])
            self.assertEqual(dependencies[1][prefix + "_requirement"],
                             dependencies[2][prefix + "_requirement"])
        compatibility = [lane for lane in self.lanes if "compatibility" in lane["roles"]]
        self.assertEqual(
            [(row["pg_major"], row["pg_image"]) for row in data["compatibility"][len(dependencies):]],
            [(lane["major"], lane["image"]) for lane in compatibility],
        )
        self.assertEqual(
            data["decoder"],
            [dict(pg_major=lane["major"], base=lane["image"])
             for lane in self.lanes if "decoder-source" in lane["roles"]],
        )
        self.assertEqual(data["checks"], sorted(set(data["checks"])))
        for row in data["compatibility"]:
            self.assertIn(
                "qualification / Dependencies " + row["label"] + " / PostgreSQL " + row["pg_major"],
                data["checks"],
            )

    def test_currently_supported_sources_are_qualified(self):
        result = self.read()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)

        self.assertEqual(
            {row["pg_major"] for row in data["compatibility"]},
            {"15", "16", "17", "18"},
        )
        self.assertEqual(
            {row["pg_major"] for row in data["decoder"]},
            {"15", "16", "17", "18", "19"},
        )
        for row in data["decoder"]:
            self.assertIn(
                "qualification / Plugin decoders / PostgreSQL " + row["pg_major"],
                data["checks"],
            )

    def test_github_outputs_include_the_same_inventory_and_matrices(self):
        result = self.read()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = json.loads(result.stdout)
        output = self.root / "github-output"
        result = subprocess.run(
            [str(READER), "", str(self.root)],
            env=dict(os.environ, GITHUB_OUTPUT=str(output)),
            check=False, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        records = [line.split("=", 1) for line in output.read_text().splitlines()]
        self.assertEqual([key for key, _value in records],
                         ["engine_major", "compatibility", "decoder", "checks"])
        for key, value in records:
            if key == "engine_major":
                self.assertEqual(value, expected[key])
            else:
                self.assertEqual(value, json.dumps(expected[key], separators=(",", ":")))

    def test_invalid_shapes_and_unknown_fields(self):
        for invalid in (None, {}, [], [None], [dict(self.lanes[0], unknown=True)]):
            with self.subTest(invalid=invalid):
                self.write_lanes(invalid)
                self.refused()

    def test_duplicate_major(self):
        self.write_lanes(self.lanes + [self.lanes[0]])
        self.refused()

    def test_engine_major_cannot_be_a_compatibility_lane(self):
        engine = json.loads(self.read().stdout)["engine_major"]
        lanes = copy.deepcopy(self.lanes)
        lane = next(lane for lane in lanes if lane["major"] == engine)
        lane["roles"].append("compatibility")
        self.write_lanes(lanes)
        self.refused()

    def test_source_major_below_the_floor_is_refused(self):
        lanes = copy.deepcopy(self.lanes)
        lanes[0]["major"] = "14"
        lanes[0]["image"] = lanes[0]["image"].replace("postgres:15", "postgres:14")
        lanes[0]["roles"] = ["decoder-source"]
        self.write_lanes(lanes)
        self.refused()

    def test_image_must_be_upstream_with_matching_tag_and_digest(self):
        original = self.lanes[0]["image"]
        for image in (
            original.split("@")[0],
            original.replace("postgres:", "other:"),
            original.replace("postgres:", "postgres:0", 1),
            original[:-1],
            original.upper(),
            original + "\n",
        ):
            with self.subTest(image=image):
                lanes = copy.deepcopy(self.lanes)
                lanes[0]["image"] = image
                self.write_lanes(lanes)
                self.refused()

    def test_roles_are_closed_nonempty_and_unique(self):
        for roles in (None, "compatibility", [], ["unknown"], ["compatibility"] * 2, [{}]):
            with self.subTest(roles=roles):
                lanes = copy.deepcopy(self.lanes)
                lanes[0]["roles"] = roles
                self.write_lanes(lanes)
                self.refused()

    def test_engine_reference_is_exactly_one_canonical_line(self):
        path = self.root / ".github/postgres.ref"
        original = path.read_text()
        for value in ("", original.rstrip(), original + "\n", original.replace("@", "")):
            with self.subTest(value=value):
                path.write_text(value)
                self.refused()

    def test_duplicate_json_keys_are_refused(self):
        path = self.root / ".github/postgres-lanes.json"
        path.write_text(path.read_text().replace('"major":', '"major": "invalid", "major":', 1))
        self.refused()

    def test_dependency_floors_and_ranges_follow_mix_declarations(self):
        path = self.root / "mix.exs"
        source = path.read_text()
        requirement = ">= 1.7.2 and < 2.0.0-0"
        path.write_text(re.sub(r'@replicant_requirement "[^"]+"',
                               '@replicant_requirement "' + requirement + '"', source, count=1))
        result = self.read()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)["compatibility"]
        self.assertEqual(rows[0]["replicant_selector"], "1.7.2")
        self.assertEqual(rows[0]["replicant_requirement"], "== 1.7.2")
        for row in rows[1:]:
            self.assertEqual(row["replicant_requirement"], requirement)

    def test_floor_policy_accepts_exact_and_pessimistic_lower_bounds(self):
        path = self.root / "mix.exs"
        original = path.read_text()
        for requirement, floor in (("~> 7.8", "7.8.0"), ("== 7.8.9", "7.8.9")):
            with self.subTest(requirement=requirement):
                path.write_text(re.sub(r'@replicant_requirement "[^"]+"',
                                       '@replicant_requirement "' + requirement + '"', original, count=1))
                result = self.read()
                self.assertEqual(result.returncode, 0, result.stderr)
                row = json.loads(result.stdout)["compatibility"][0]
                self.assertEqual(row["replicant_selector"], floor)
                self.assertEqual(row["replicant_requirement"], "== " + floor)

    def test_duplicate_missing_and_nonliteral_declarations_are_refused(self):
        path = self.root / "mix.exs"
        original = path.read_text()
        for replacement in ('@replicant_requirement "bad"',
                            '@replicant_requirement "> 7.8.9"',
                            '@replicant_requirement System.get_env("UNTRUSTED")',
                            '@replicant_requirement "~> 1.0"\n  @replicant_requirement "~> 1.0"'):
            with self.subTest(replacement=replacement):
                path.write_text(re.sub(r'@replicant_requirement "[^"]+"',
                                       lambda _: replacement, original, count=1))
                self.refused()


if __name__ == "__main__":
    unittest.main()
