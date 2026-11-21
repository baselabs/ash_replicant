"""Exercise the real declaration reader against disposable configuration files."""

import copy
import json
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
            ".github/dependency-lanes.json",
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
        dependencies = json.loads((self.root / ".github/dependency-lanes.json").read_text())
        for row, dependency in zip(data["compatibility"][:len(dependencies)], dependencies):
            self.assertEqual(row, dict(dependency, pg_major=data["engine_major"], pg_image=""))
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
        lane = dict(self.lanes[0], major=engine)
        lane["image"] = "postgres:" + engine + "@" + lane["image"].split("@", 1)[1]
        self.write_lanes(self.lanes + [lane])
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

    def test_dependency_policy_needs_all_cells_and_known_fields(self):
        path = self.root / ".github/dependency-lanes.json"
        original = json.loads(path.read_text())
        for rows in (original[:1], original[::-1], [dict(original[0], unknown=True)] + original[1:]):
            with self.subTest(rows=rows):
                path.write_text(json.dumps(rows))
                self.refused()


if __name__ == "__main__":
    unittest.main()
