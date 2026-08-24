#!/usr/bin/env python3
"""Data-boundary guard-mutation gates (roadmap D7, ADR-0003).

Proves the fail-closed data-boundary guards are OBSERVED by the no-database
focused tests: each matrix cell removes exactly ONE production guard (or one
sibling call site of a shared guard), or moves one notifier guard after its
first effect, in an ISOLATED temporary copy of the project and requires the
named focused selector to fail for the cell's property-specific reason. A
guard whose removal keeps every test green is a
vacuous guard; this runner is the repeatable evidence that none of the
covered guards is.

Contract (SEC01 / the reconciled T2 design):

- The matrix is per independent guard and per sibling path across ten
  families: tenant absence, tenant reassignment, replica identity, sensitive
  type shape, sink-action multitenancy bypass, dynamic destination
  participants, notifier load drift, snapshot fingerprint collisions,
  append identity, and value-free telemetry typing (O03: one mutant family
  per typed metadata key, per measurement key, and per shared type clause,
  so no telemetry gate can survive unobserved).
- Mutants run SERIALLY in one `mktemp` project copy built from `git
  ls-files` working-tree bytes plus copied (never symlinked) `deps/` and the
  test build; the copied dependency tree loses write permission. The live
  checkout's tracked-byte manifest and `deps/` manifest must be identical
  before and after the run.
- Build identity: every mutation/restoration is stamped with a strictly
  increasing mtime and recompiled; a compiled mutant's BEAM digest must
  differ from its pristine digest and the restored target BEAM must return
  to it exactly. The digest covers every BEAM chunk except the
  compiler-nondeterministic ExCk type-inference chunk. Cells observed
  through `File.read!` source pins declare `"mode": "source"` and claim no
  BEAM identity.
- A mutant counts as RED only when the anchor matched exactly once, the
  baseline selector was green, the selected run exits nonzero, and the
  captured output carries every property-specific fingerprint (an assertion
  marker or the exact structural reason/path — never merely a test name)
  while every declared green control stays absent. Compile failures,
  timeouts, and unrelated failures are runner failures, not reds.
- Every child process gets an environment with `ASH_REPLICANT_TEST_URL` and
  Mix's build/dependency path redirections DELETED (the test Repo start
  sentinel is active without the URL) and each green baseline must report
  `TestRepo start attempts: 0`. No database or server is ever started.
- Runner output is structural and value-free: cell ids, verdict classes and
  counts only. Raw child output is captured into the scratch tree and
  deleted on exit, after the child's whole process group has stopped. Each
  child owns a new session; a timeout kills the entire group and waits for
  it before cleanup, and cleanup only ever removes the runner-created temp
  root.

Modes:

    run-mutation-gates.py                 self-test, then the full matrix
    run-mutation-gates.py --self-test     sentinel/fixture self-test only
    run-mutation-gates.py --matrix        full matrix only
    run-mutation-gates.py --cells A,B     matrix subset (development aid)
    run-mutation-gates.py --diff-base REF run only the cells REF..HEAD makes
                                         relevant (guard file or named test
                                         changed; harness/build surfaces and
                                         an unusable REF fall back to the
                                         FULL matrix — the push evidence
                                         scope, never a local gate)

`--fixture-config PATH` drives the engine from a JSON config; it exists for
the self-test's fixture scenarios and is not a supported entry point.
"""

import argparse
import contextlib
import hashlib
import io
import json
import os
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time

# --------------------------------------------------------------------------
# Structural failure classes. These strings are the ONLY diagnosis the
# runner ever emits for a failing cell; child output never surfaces here.
# --------------------------------------------------------------------------

CONFIG_INVALID = "config_invalid"
ANCHOR_MISSING = "anchor_missing"
ANCHOR_AMBIGUOUS = "anchor_ambiguous"
BASELINE_COMPILE_FAILED = "baseline_compile_failed"
BASELINE_TEST_FAILED = "baseline_test_failed"
BASELINE_MARKER_MISSING = "baseline_marker_missing"
MUTANT_COMPILE_FAILED = "mutant_compile_failed"
MUTANT_BUILD_IDENTITY = "mutant_build_identity"
MUTANT_STAYED_GREEN = "mutant_stayed_green"
WRONG_RED = "wrong_red"
CONTROL_REGRESSED = "control_regressed"
RESTORE_COMPILE_FAILED = "restore_compile_failed"
RESTORE_IDENTITY = "restore_identity"
TIMEOUT = "timeout"
DESCENDANT_LEAK = "descendant_leak"
PROCESS_CLEANUP_FAILED = "process_cleanup_failed"
LIVE_TREE_MUTATED = "live_tree_mutated"
INTERNAL_ERROR = "internal_error"


class StructuralFailure(Exception):
    """A classified runner failure: (scope, failure class). Value-free."""

    def __init__(self, scope, cls):
        super().__init__(f"{scope} {cls}")
        self.scope = scope
        self.cls = cls


# --------------------------------------------------------------------------
# The matrix. One cell per independent guard / sibling path. `red` entries
# are property-specific fingerprints that must ALL appear in the failing
# selector's captured output; `absent` entries are green controls that must
# NOT appear (a control test name only appears in ExUnit output when that
# test fails). `mode: "source"` cells are observed by File.read! source
# pins and claim no BEAM identity.
# --------------------------------------------------------------------------

RESOLVER = "lib/ash_replicant/resolver.ex"
APPLY = "lib/ash_replicant/apply.ex"
SCD2 = "lib/ash_replicant/apply/scd2.ex"
COVERAGE = "lib/ash_replicant/coverage.ex"
V_SENSITIVE = "lib/ash_replicant/resource/verifiers/validate_sensitive.ex"
V_ACTION_MT = "lib/ash_replicant/resource/verifiers/validate_action_multitenancy.ex"
V_APPEND = "lib/ash_replicant/resource/verifiers/validate_append_log.ex"
DESTINATION = "lib/ash_replicant/destination.ex"
NOTIFIER_LOADS = "lib/ash_replicant/destination/notifier_loads.ex"
APPEND = "lib/ash_replicant/append.ex"
MESSAGES = "lib/ash_replicant/messages.ex"
IMPL = "lib/ash_replicant/sink/impl.ex"
ROWS = "lib/ash_replicant/snapshot/rows.ex"
RETIREMENT = "lib/ash_replicant/snapshot/retirement.ex"
PROVENANCE = "lib/ash_replicant/snapshot/provenance.ex"
TELEMETRY = "lib/ash_replicant/telemetry.ex"

T_RESOLVER = "test/ash_replicant/resolver_test.exs"
T_COVERAGE = "test/ash_replicant/coverage_test.exs"
T_SENSITIVE = "test/ash_replicant/validate_sensitive_test.exs"
T_ACTION_MT = "test/ash_replicant/validate_action_multitenancy_test.exs"
T_SNAP_PROV_V = "test/ash_replicant/validate_snapshot_provenance_test.exs"
T_START_LINK = "test/ash_replicant/start_link_test.exs"
T_DESTINATION = "test/ash_replicant/destination_test.exs"
T_NOTIFIER = "test/ash_replicant/notifier_load_binding_test.exs"
T_PROVENANCE = "test/ash_replicant/snapshot_provenance_test.exs"
T_APPEND_V = "test/ash_replicant/validate_append_log_test.exs"
T_TELEMETRY = "test/ash_replicant/telemetry_test.exs"

B_RESOLVER = "Elixir.AshReplicant.Resolver.beam"
B_COVERAGE = "Elixir.AshReplicant.Coverage.beam"
B_SENSITIVE = "Elixir.AshReplicant.Resource.Verifiers.ValidateSensitive.beam"
B_ACTION_MT = "Elixir.AshReplicant.Resource.Verifiers.ValidateActionMultitenancy.beam"
B_APPEND_V = "Elixir.AshReplicant.Resource.Verifiers.ValidateAppendLog.beam"
B_DESTINATION = "Elixir.AshReplicant.Destination.beam"
B_NOTIFIER_LOADS = "Elixir.AshReplicant.Destination.NotifierLoads.beam"
B_PROVENANCE = "Elixir.AshReplicant.Snapshot.Provenance.beam"
B_TELEMETRY = "Elixir.AshReplicant.Telemetry.beam"

NO_RAISE = "but nothing was raised"

# --------------------------------------------------------------------------
# Path scoping (--diff-base): per-push evidence without the full-matrix cost.
#
# A cell is RELEVANT to a diff exactly when the diff touches the production
# file the cell mutates OR one of the named focused test files that observe
# it. Anything else — docs, README, CHANGELOG, notebooks — selects nothing.
# The surfaces that could change HOW guards are observed (this runner, the
# structural harness, fixtures, build identity, CI wiring) force the FULL
# matrix: scoping may never silently weaken the evidence machinery itself.
# --------------------------------------------------------------------------

FULL_MATRIX_PREFIXES = (
    "scripts/",
    "config/",
    "test/support/",
    ".github/",
    "priv/",
)
FULL_MATRIX_FILES = {"mix.exs", "mix.lock", ".tool-versions"}
FULL_MATRIX_TEST_FILES = {"test/test_helper.exs"}
SCOPED_PREFIXES = ("lib/", "test/")


def select_matrix_cells(changed_files):
    """Select the cells a diff makes relevant.

    Returns a list of MATRIX cells (possibly empty), or None when the diff
    must run the FULL matrix. Pure: no git, no filesystem.
    """
    selected = {}
    for raw in changed_files:
        path = raw.strip()
        if not path:
            continue
        if path in FULL_MATRIX_FILES or path.startswith(FULL_MATRIX_PREFIXES):
            return None
        if path in FULL_MATRIX_TEST_FILES:
            return None
        if not path.startswith(SCOPED_PREFIXES):
            continue
        for cell in MATRIX:
            if cell["file"] == path or any(
                run.get("file") == path for run in cell["runs"]
            ):
                selected[cell["id"]] = cell
    return list(selected.values())


def changed_files_for_base(ref, cwd=None):
    """Changed paths between `ref` and HEAD, or None when ref is unusable
    (unreachable, absent, a bad sha) — the caller then runs the FULL matrix
    (evidence availability outranks scoping).

    `--no-renames` is load-bearing: git's default rename detection lists
    ONLY the new path for a pure rename, so a renamed guard file would
    select zero cells and pass silently — while the full run would fail
    loudly on the stale anchor. With both paths listed, the OLD path
    selects its cell and the run fails loudly at anchor-missing."""
    result = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", ref, "HEAD"],
        capture_output=True,
        text=True,
        cwd=cwd or repo_root(),
    )
    if result.returncode != 0:
        return None
    return [line for line in result.stdout.splitlines() if line.strip()]

MATRIX = [
    # ---------------------------------------------------------- tenant absence
    {
        "id": "tenant_absence.nil_guard",
        "file": RESOLVER,
        "beams": [B_RESOLVER],
        "replacements": [
            [
                "  defp present_or_required(nil), do: {:error, :tenant_required}\n",
                "  defp present_or_required(nil), do: {:ok, nil}\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    # ExUnit reports only the FIRST failing assertion of a
                    # test, so each fingerprint is the first assertion this
                    # mutation fails in its own test: the attribute path (nil
                    # column) and the MFA path (missing key resolves nil).
                    'Resolver.resolve_tenant(Account, %{"org_id" => nil})',
                    "Resolver.resolve_tenant(MfaOrder, %{})",
                ],
                "absent": ["reads the tenant attribute from the record"],
            }
        ],
    },
    {
        "id": "tenant_absence.false_guard",
        "file": RESOLVER,
        "beams": [B_RESOLVER],
        "replacements": [
            [
                "  defp present_or_required(false), do: {:error, :tenant_required}\n",
                "  defp present_or_required(false), do: {:ok, false}\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    'Resolver.resolve_tenant(Account, %{"org_id" => false})',
                    'Resolver.resolve_tenant(MfaOrder, %{"tenant_key" => false})',
                ],
                "absent": ["reads the tenant attribute from the record"],
            }
        ],
    },
    {
        "id": "tenant_absence.blank_guard",
        "file": RESOLVER,
        "beams": [B_RESOLVER],
        "replacements": [
            [
                "  defp present_or_required(v) when is_binary(v),\n"
                '    do: if(String.trim(v) == "", do: {:error, :tenant_required}, else: {:ok, v})\n',
                "  defp present_or_required(v) when is_binary(v), do: {:ok, v}\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    'Resolver.resolve_tenant(Account, %{"org_id" => ""})',
                    'Resolver.resolve_tenant(MfaOrder, %{"tenant_key" => "  "})',
                ],
                "absent": ["reads the tenant attribute from the record"],
            }
        ],
    },
    # ----------------------------------------------------- tenant reassignment
    {
        "id": "tenant_reassignment.missing_old_tuple",
        "file": RESOLVER,
        "beams": [B_RESOLVER],
        "replacements": [
            [
                "    if tenant_scoped?(resource) do\n",
                "    if tenant_scoped?(resource) and false do\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    "an update with NO old tuple on a tenant-scoped resource halts"
                    " :tenant_required side=old (tripwire)",
                    NO_RAISE,
                ],
                "absent": ["a non-tenant resource always resolves :same with nil tenants"],
            }
        ],
    },
    {
        "id": "tenant_reassignment.old_side_required",
        "file": RESOLVER,
        "beams": [B_RESOLVER],
        "replacements": [
            [
                "      {:error, :tenant_required} ->\n"
                "        raise Error.exception(\n"
                "                reason: :tenant_required,\n"
                "                resource: resource,\n"
                "                op: op,\n"
                '                shape: "side=#{side}"\n'
                "              )\n",
                "      {:error, :tenant_required} ->\n        {:ok, nil}\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    "missing old tenant halts :tenant_required side=old BEFORE any write",
                    "blank/false old tenant halts :tenant_required side=old",
                    NO_RAISE,
                ],
                "absent": [":same update keeps the upsert path"],
            }
        ],
    },
    {
        "id": "tenant_reassignment.raising_mfa",
        "file": RESOLVER,
        "beams": [B_RESOLVER],
        "replacements": [
            [
                "    other ->\n      tenant_resolution_failed(other, resource, side, op)\n",
                "    other ->\n      reraise other, __STACKTRACE__\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    "a raising tenant_mfa on the old side halts :tenant_resolution_failed",
                    "but got ArgumentError",
                ],
                "absent": ["missing old tenant halts :tenant_required side=old"],
            }
        ],
    },
    {
        "id": "tenant_reassignment.apply_call_site",
        "file": APPLY,
        "mode": "source",
        "replacements": [
            [
                "    {:ok, transition, _old_tenant, _new_tenant} =\n"
                "      Resolver.require_tenant_pair!(resource, change, op)\n",
                "    {:ok, transition, _old_tenant, _new_tenant} = {:ok, :same, nil, nil}\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    "lib/ash_replicant/apply.ex carries 0 tenant-pair preludes, expected 1"
                ],
                "absent": ["Apply.Scd2 enters require_tenant_pair!/3"],
            }
        ],
    },
    {
        "id": "tenant_reassignment.scd2_call_site",
        "file": SCD2,
        "mode": "source",
        "replacements": [
            [
                "    {:ok, transition, prelude_old_tenant, prelude_new_tenant} =\n"
                "      Resolver.require_tenant_pair!(resource, change, op)\n",
                "    {:ok, transition, prelude_old_tenant, prelude_new_tenant} ="
                " {:ok, :same, nil, nil}\n",
            ]
        ],
        "runs": [
            {
                "file": T_RESOLVER,
                "red": [
                    "lib/ash_replicant/apply/scd2.ex carries 0 tenant-pair preludes, expected 1"
                ],
                "absent": ["Apply enters require_tenant_pair!/3 before the mirror upsert"],
            }
        ],
    },
    # ------------------------------------------------------- replica identity
    {
        "id": "replica_identity.tenant_arm",
        "file": COVERAGE,
        "beams": [B_COVERAGE],
        "replacements": [
            [
                "        fact.append? or fact.tenant? or\n",
                "        fact.append? or false or\n",
            ]
        ],
        "runs": [
            {
                "file": T_COVERAGE,
                "red": [
                    "rule 10: a tenant-scoped table without FULL identity halts"
                    " :source_replica_identity",
                    ":source_replica_identity",
                ],
                "absent": [
                    "rule 10: every append source requires FULL identity for delete payloads"
                ],
            }
        ],
    },
    {
        "id": "replica_identity.append_arm",
        "file": COVERAGE,
        "beams": [B_COVERAGE],
        "replacements": [
            [
                "        fact.append? or fact.tenant? or\n",
                "        false or fact.tenant? or\n",
            ]
        ],
        "runs": [
            {
                "file": T_COVERAGE,
                "red": [
                    "rule 10: every append source requires FULL identity for delete payloads",
                    ":source_replica_identity",
                ],
                "absent": [
                    "rule 10: a tenant-scoped table without FULL identity halts"
                ],
            }
        ],
    },
    {
        "id": "replica_identity.scd2_business_key_arm",
        "file": COVERAGE,
        "beams": [B_COVERAGE],
        "replacements": [
            [
                "          (fact.scd2? and not business_key_is_pk?(fact, live.pk))\n",
                "          (fact.scd2? and false)\n",
            ]
        ],
        "runs": [
            {
                "file": T_COVERAGE,
                "red": [
                    "rule 10: an SCD2 table whose business key is NOT the source PK"
                    " requires FULL",
                    ":source_replica_identity",
                ],
                "absent": [
                    "rule 10: an SCD2 table whose business key IS the source PK needs no FULL"
                ],
            }
        ],
    },
    # --------------------------------------------------------- sensitive type
    {
        "id": "sensitive_type.plaintext_protected",
        "file": V_SENSITIVE,
        "beams": [B_SENSITIVE],
        "replacements": [
            [
                "  defp binary_attr?(attr),\n"
                "    do: Ash.Type.storage_type(attr.type, attr.constraints) == :binary\n",
                "  defp binary_attr?(_attr), do: true\n",
            ]
        ],
        "runs": [
            {
                "file": T_SENSITIVE,
                "red": [
                    "a plaintext :string sensitive column, not skipped, fails closed (tripwire)",
                    "path: [:replicant, :sensitive]",
                ],
                "absent": [
                    "a skipped sensitive column compiles clean (green control)",
                    "a :binary-storage sensitive attribute compiles clean (clause b)",
                    "a sensitive column backed by an AshCloak-cloaked attribute compiles"
                    " clean (clause a)",
                ],
            }
        ],
    },
    # ----------------------------------------------------------- action bypass
    {
        "id": "action_bypass.bypass_predicate",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            [
                "  defp bypasses?(action), do: action.multitenancy in @bypass_modes\n",
                "  defp bypasses?(_action), do: false\n",
            ]
        ],
        "runs": [
            {
                "file": T_ACTION_MT,
                "red": [
                    "a :bypass primary create action on a multitenant resource fails closed",
                    "a :bypass_all primary destroy action on a multitenant resource fails closed",
                    "a :bypass primary READ action on a multitenant resource fails closed",
                    "a :bypass SCD2 close action on a multitenant resource fails closed",
                ],
                "absent": [
                    "default (:enforce) sink actions on a multitenant resource compile clean"
                ],
            },
            {
                "file": T_SNAP_PROV_V,
                "red": [
                    "TRIPWIRE: a mark action declaring `multitenancy :bypass` fails closed",
                    "TRIPWIRE: a retire action declaring `multitenancy :bypass_all`"
                    " fails closed",
                ],
                "absent": [],
            },
        ],
    },
    {
        "id": "action_bypass.primary_read",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            ["      AshInfo.primary_action(dsl_state, :read),\n", "      nil,\n"]
        ],
        "runs": [
            {
                "file": T_ACTION_MT,
                "red": [
                    "a :bypass primary READ action on a multitenant resource fails closed",
                    "path: [:actions, :read]",
                ],
                "absent": [
                    "a :bypass primary create action on a multitenant resource fails closed",
                    "a :bypass_all primary destroy action on a multitenant resource fails closed",
                ],
            }
        ],
    },
    {
        "id": "action_bypass.primary_create",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            ["      AshInfo.primary_action(dsl_state, :create),\n", "      nil,\n"]
        ],
        "runs": [
            {
                "file": T_ACTION_MT,
                "red": [
                    "a :bypass primary create action on a multitenant resource fails closed",
                    "path: [:actions, :create]",
                ],
                "absent": [
                    "a :bypass primary READ action on a multitenant resource fails closed"
                ],
            }
        ],
    },
    {
        "id": "action_bypass.primary_destroy",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            ["      AshInfo.primary_action(dsl_state, :destroy)\n", "      nil\n"]
        ],
        "runs": [
            {
                "file": T_ACTION_MT,
                "red": [
                    "a :bypass_all primary destroy action on a multitenant resource"
                    " fails closed",
                    "path: [:actions, :destroy]",
                ],
                "absent": [
                    "a :bypass primary create action on a multitenant resource fails closed"
                ],
            }
        ],
    },
    {
        "id": "action_bypass.scd2_close",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            [
                "      [close && AshInfo.action(dsl_state, close) | actions]\n",
                "      actions\n",
            ]
        ],
        "runs": [
            {
                "file": T_ACTION_MT,
                "red": [
                    "a :bypass SCD2 close action on a multitenant resource fails closed",
                    "path: [:actions, :close_version]",
                ],
                "absent": [
                    "a :bypass primary create action on a multitenant resource fails closed"
                ],
            }
        ],
    },
    {
        "id": "action_bypass.snapshot_mark",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            [
                "      [:snapshot_mark_action, :snapshot_retire_action]\n",
                "      [:snapshot_retire_action]\n",
            ]
        ],
        "runs": [
            {
                "file": T_SNAP_PROV_V,
                "red": [
                    "TRIPWIRE: a mark action declaring `multitenancy :bypass` fails closed",
                    "path: [:actions, :replicant_mark_seen]",
                ],
                "absent": [
                    "TRIPWIRE: a retire action declaring `multitenancy :bypass_all`"
                    " fails closed"
                ],
            }
        ],
    },
    {
        "id": "action_bypass.snapshot_retire",
        "file": V_ACTION_MT,
        "beams": [B_ACTION_MT],
        "replacements": [
            [
                "      [:snapshot_mark_action, :snapshot_retire_action]\n",
                "      [:snapshot_mark_action]\n",
            ]
        ],
        "runs": [
            {
                "file": T_SNAP_PROV_V,
                "red": [
                    "TRIPWIRE: a retire action declaring `multitenancy :bypass_all`"
                    " fails closed",
                    "path: [:actions, :replicant_retire_unseen]",
                ],
                "absent": [
                    "TRIPWIRE: a mark action declaring `multitenancy :bypass` fails closed"
                ],
            }
        ],
    },
    # ----------------------------------------------------- dynamic participant
    {
        "id": "dynamic_participant.effective_repo",
        "file": DESTINATION,
        "beams": [B_DESTINATION],
        "replacements": [
            [
                "    if dynamic_repo_owned_by?(repo, identity) do\n"
                "      {:ok, identity}\n"
                "    else\n"
                "      {:error, {:invalid_destination_config, :effective_repo}}\n"
                "    end\n",
                "    {:ok, identity}\n",
            ]
        ],
        "runs": [
            {
                "file": T_START_LINK,
                "red": [
                    "a foreign effective dynamic Repo is rejected before activation state",
                    ":effective_repo",
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "dynamic_participant.set_context_change",
        "file": DESTINATION,
        "beams": [B_DESTINATION],
        "replacements": [
            [
                "       when module in [Ash.Resource.Change.SetContext,"
                " Ash.Resource.Preparation.SetContext] do\n",
                "       when module in [Ash.Resource.Preparation.SetContext] do\n",
            ]
        ],
        "runs": [
            {
                "file": T_DESTINATION,
                "red": [
                    "mapped create, destroy, and SCD2-close actions cannot redirect the"
                    " data-layer target",
                    ":destination_participant_invalid",
                ],
                "absent": ["a Preparation.SetContext that replaces :data_layer is rejected"],
            }
        ],
    },
    {
        "id": "dynamic_participant.set_context_preparation",
        "file": DESTINATION,
        "beams": [B_DESTINATION],
        "replacements": [
            [
                "       when module in [Ash.Resource.Change.SetContext,"
                " Ash.Resource.Preparation.SetContext] do\n",
                "       when module in [Ash.Resource.Change.SetContext] do\n",
            ]
        ],
        "runs": [
            {
                "file": T_DESTINATION,
                "red": [
                    "a Preparation.SetContext that replaces :data_layer is rejected",
                    ":destination_participant_invalid",
                ],
                "absent": [
                    "mapped create, destroy, and SCD2-close actions cannot redirect the"
                    " data-layer target"
                ],
            }
        ],
    },
    # --------------------------------------------------------- notifier drift
    {
        "id": "notifier_drift.out_of_band_verdict",
        "file": NOTIFIER_LOADS,
        "beams": [B_NOTIFIER_LOADS],
        "replacements": [
            [
                "      {:ok, _drifted} ->\n"
                "        {:error, {:invalid_destination_config, :notifier_load_drift}}\n",
                "      {:ok, _drifted} ->\n        :ok\n",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "a changed STATEMENT is drift",
                    "a changed CLOSURE is drift",
                    ":notifier_load_drift",
                ],
                "absent": ["an unchanged statement verifies"],
            }
        ],
    },
    {
        "id": "notifier_drift.in_band_verdict",
        "file": NOTIFIER_LOADS,
        "beams": [B_NOTIFIER_LOADS],
        "replacements": [
            [
                "      if current == admitted,\n"
                "        do: :ok,\n"
                "        else: {:error, {:invalid_destination_config, :notifier_load_drift}}\n",
                "      _ = {current, admitted}\n      :ok\n",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    # The observer is a single assert_raise; the bypassed
                    # verdict means NOTHING raises, which is the marker.
                    "a widened DECLARED ACTION CLOSURE halts inside the delivery",
                    NO_RAISE,
                ],
                "absent": ["outside a sink delivery it is an ORDINARY Ash notifier"],
            }
        ],
    },
    {
        "id": "notifier_drift.site_mirror_upsert",
        "file": APPLY,
        "mode": "source",
        "replacements": [
            ["    Context.verify_notifier_loads!(config, resource, action, :upsert)\n", ""]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/apply.ex carries 1 notifier-load guards, expected 2"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_mirror_destroy",
        "file": APPLY,
        "mode": "source",
        "replacements": [
            ["    Context.verify_notifier_loads!(config, resource, action, :destroy)\n", ""]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/apply.ex carries 1 notifier-load guards, expected 2"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_scd2_close",
        "file": SCD2,
        "mode": "source",
        "replacements": [
            [
                "    action = Info.replicant_history_close_action!(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n",
                "    action = Info.replicant_history_close_action!(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/apply/scd2.ex carries 1 notifier-load guards,"
                    " expected 2"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_scd2_open",
        "file": SCD2,
        "mode": "source",
        "replacements": [
            [
                "    action = Resolver.upsert_action(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n",
                "    action = Resolver.upsert_action(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/apply/scd2.ex carries 1 notifier-load guards,"
                    " expected 2"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_append",
        "file": APPEND,
        "mode": "source",
        "replacements": [
            [
                "      Context.verify_notifier_loads!(config, resource, action, :append)\n",
                "",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/append.ex carries 0 notifier-load guards, expected 1"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_message",
        "file": MESSAGES,
        "mode": "source",
        "replacements": [
            [
                "    DeliveryContext.verify_notifier_loads!(\n"
                "      config,\n"
                "      route.resource,\n"
                "      route.action,\n"
                "      :message\n"
                "    )\n",
                "",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/messages.ex carries 0 notifier-load guards,"
                    " expected 1"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_snapshot_bulk",
        "file": IMPL,
        "mode": "source",
        "replacements": [
            [
                "      Apply.Context.verify_notifier_loads!(\n"
                "        config,\n"
                "        resource,\n"
                "        Resolver.upsert_action(resource),\n"
                "        :snapshot\n"
                "      )\n",
                "",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/sink/impl.ex carries 0 notifier-load guards,"
                    " expected 1"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_snapshot_mark",
        "file": ROWS,
        "mode": "source",
        "replacements": [
            [
                "    Context.verify_notifier_loads!(config, resource, action,"
                " :snapshot_mark)\n",
                "",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/snapshot/rows.ex carries 0 notifier-load guards,"
                    " expected 1"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_drift.site_snapshot_retire",
        "file": RETIREMENT,
        "mode": "source",
        "replacements": [
            [
                "    Context.verify_notifier_loads!(config, resource, action,"
                " :snapshot_retire)\n",
                "",
            ]
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "lib/ash_replicant/snapshot/retirement.ex carries 0 notifier-load"
                    " guards, expected 1"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.mirror_upsert",
        "file": APPLY,
        "mode": "source",
        "replacements": [
            ["    Context.verify_notifier_loads!(config, resource, action, :upsert)\n", ""],
            [
                "      return_notifications?: true\n"
                "    )\n\n"
                "    :ok\n"
                "  rescue\n"
                "    e -> reraise Error.scrub(e, resource, :upsert), __STACKTRACE__\n",
                "      return_notifications?: true\n"
                "    )\n\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n"
                "    :ok\n"
                "  rescue\n"
                "    e -> reraise Error.scrub(e, resource, :upsert), __STACKTRACE__\n",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "mirror_upsert: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.mirror_destroy",
        "file": APPLY,
        "mode": "source",
        "replacements": [
            ["    Context.verify_notifier_loads!(config, resource, action, :destroy)\n", ""],
            [
                "      return_errors?: true\n"
                "    )\n\n"
                "    :ok\n"
                "  rescue\n"
                "    e -> reraise Error.scrub(e, resource, :destroy), __STACKTRACE__\n",
                "      return_errors?: true\n"
                "    )\n\n"
                "    Context.verify_notifier_loads!(config, resource, action, :destroy)\n"
                "    :ok\n"
                "  rescue\n"
                "    e -> reraise Error.scrub(e, resource, :destroy), __STACKTRACE__\n",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "mirror_destroy: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.scd2_close",
        "file": SCD2,
        "mode": "source",
        "replacements": [
            [
                "    action = Info.replicant_history_close_action!(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n",
                "    action = Info.replicant_history_close_action!(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n",
            ],
            [
                "      return_errors?: true\n"
                "    )\n\n"
                "    :ok\n"
                "  end\n\n"
                "  defp open_version",
                "      return_errors?: true\n"
                "    )\n\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n"
                "    :ok\n"
                "  end\n\n"
                "  defp open_version",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "scd2_close: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.scd2_open",
        "file": SCD2,
        "mode": "source",
        "replacements": [
            [
                "    action = Resolver.upsert_action(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n",
                "    action = Resolver.upsert_action(resource)\n"
                "    Context.preflight_onetime!(config, tenant, resource, action, :upsert)\n",
            ],
            [
                "      return_notifications?: true\n"
                "    )\n\n"
                "    :ok\n"
                "  end\n\n"
                "  @doc \"\"\"\n"
                "  The window-column input",
                "      return_notifications?: true\n"
                "    )\n\n"
                "    Context.verify_notifier_loads!(config, resource, action, :upsert)\n"
                "    :ok\n"
                "  end\n\n"
                "  @doc \"\"\"\n"
                "  The window-column input",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "scd2_open: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.append",
        "file": APPEND,
        "mode": "source",
        "replacements": [
            ["      Context.verify_notifier_loads!(config, resource, action, :append)\n", ""],
            [
                "        return_notifications?: true\n"
                "      )\n"
                "    end)\n\n"
                "    :ok\n",
                "        return_notifications?: true\n"
                "      )\n"
                "      Context.verify_notifier_loads!(config, resource, action, :append)\n"
                "    end)\n\n"
                "    :ok\n",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": ["append: notifier guard must run before its first destination effect"],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.message",
        "file": MESSAGES,
        "mode": "source",
        "replacements": [
            [
                "    DeliveryContext.verify_notifier_loads!(\n"
                "      config,\n"
                "      route.resource,\n"
                "      route.action,\n"
                "      :message\n"
                "    )\n\n",
                "",
            ],
            [
                "        context: action_context(config, operation)\n"
                "      )\n"
                "    end)\n\n"
                "    :ok\n",
                "        context: action_context(config, operation)\n"
                "      )\n"
                "    end)\n\n"
                "    DeliveryContext.verify_notifier_loads!(\n"
                "      config,\n"
                "      route.resource,\n"
                "      route.action,\n"
                "      :message\n"
                "    )\n"
                "    :ok\n",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": ["message: notifier guard must run before its first destination effect"],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.snapshot_bulk",
        "file": IMPL,
        "mode": "source",
        "replacements": [
            [
                "      Apply.Context.verify_notifier_loads!(\n"
                "        config,\n"
                "        resource,\n"
                "        Resolver.upsert_action(resource),\n"
                "        :snapshot\n"
                "      )\n\n",
                "",
            ],
            [
                "          )\n"
                "        end)\n\n"
                "      guard_generation!(config)\n",
                "          )\n"
                "        end)\n\n"
                "      Apply.Context.verify_notifier_loads!(\n"
                "        config,\n"
                "        resource,\n"
                "        Resolver.upsert_action(resource),\n"
                "        :snapshot\n"
                "      )\n\n"
                "      guard_generation!(config)\n",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "snapshot_bulk: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.snapshot_mark",
        "file": ROWS,
        "mode": "source",
        "replacements": [
            [
                "    Context.verify_notifier_loads!(config, resource, action, :snapshot_mark)\n",
                "",
            ],
            [
                "        return_notifications?: true\n"
                "      )\n\n"
                "    # A mark that stamped no row",
                "        return_notifications?: true\n"
                "      )\n\n"
                "    Context.verify_notifier_loads!(config, resource, action, :snapshot_mark)\n\n"
                "    # A mark that stamped no row",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "snapshot_mark: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    {
        "id": "notifier_order.snapshot_retire",
        "file": RETIREMENT,
        "mode": "source",
        "replacements": [
            [
                "    Context.verify_notifier_loads!(config, resource, action, :snapshot_retire)\n",
                "",
            ],
            [
                "    end\n\n"
                "    :ok\n"
                "  rescue\n"
                "    e in AshReplicant.Error -> reraise e, __STACKTRACE__\n",
                "    end\n\n"
                "    Context.verify_notifier_loads!(config, resource, action, :snapshot_retire)\n"
                "    :ok\n"
                "  rescue\n"
                "    e in AshReplicant.Error -> reraise e, __STACKTRACE__\n",
            ],
        ],
        "runs": [
            {
                "file": T_NOTIFIER,
                "red": [
                    "snapshot_retire: notifier guard must run before its first destination effect"
                ],
                "absent": [],
            }
        ],
    },
    # ---------------------------------------------------- provenance collision
    {
        "id": "provenance_collision.length_prefix",
        "file": PROVENANCE,
        "beams": [B_PROVENANCE],
        "replacements": [
            [
                "  defp prefixed(binary) when is_binary(binary),"
                " do: <<byte_size(binary)::64>> <> binary\n",
                "  defp prefixed(binary) when is_binary(binary), do: binary\n",
            ]
        ],
        "runs": [
            {
                "file": T_PROVENANCE,
                "red": [
                    "field boundaries are explicit — a shifted key/value boundary does"
                    " not collide",
                    "Refute with == failed",
                ],
                "absent": ["is stable across calls and independent of map insertion order"],
            }
        ],
    },
    {
        "id": "provenance_collision.type_tag",
        "file": PROVENANCE,
        "beams": [B_PROVENANCE],
        "replacements": [
            [
                '  defp encode(value) when is_binary(value), do: {:ok, "b" <> prefixed(value)}\n',
                "  defp encode(value) when is_binary(value), do: {:ok, prefixed(value)}\n",
            ],
            [
                '    do: {:ok, "i" <> prefixed(Integer.to_string(value))}\n',
                "    do: {:ok, prefixed(Integer.to_string(value))}\n",
            ],
        ],
        "runs": [
            {
                "file": T_PROVENANCE,
                "red": [
                    'types are tagged — integer 1 and binary "1" do not collide',
                    "Refute with == failed",
                ],
                "absent": ["is stable across calls and independent of map insertion order"],
            }
        ],
    },
    {
        "id": "provenance_collision.list_count",
        "file": PROVENANCE,
        "beams": [B_PROVENANCE],
        "replacements": [
            [
                '      {:ok, "l" <> <<count::64>> <> payload}\n',
                '      {:ok, "l" <> <<0 * count::64>> <> payload}\n',
            ]
        ],
        "runs": [
            {
                "file": T_PROVENANCE,
                "red": [
                    "container ELEMENT COUNTS are explicit — differently-shaped nestings"
                    " do not collide",
                    "Refute with == failed",
                ],
                "absent": ["is stable across calls and independent of map insertion order"],
            }
        ],
    },
    {
        "id": "provenance_collision.tuple_count",
        "file": PROVENANCE,
        "beams": [B_PROVENANCE],
        "replacements": [
            [
                '      {:ok, "u" <> <<count::64>> <> payload}\n',
                '      {:ok, "u" <> <<0 * count::64>> <> payload}\n',
            ]
        ],
        "runs": [
            {
                "file": T_PROVENANCE,
                "red": [
                    "tuple ELEMENT COUNTS are explicit — differently-shaped tuples"
                    " do not collide",
                    "Refute with == failed",
                ],
                "absent": ["is stable across calls and independent of map insertion order"],
            }
        ],
    },
    {
        "id": "provenance_collision.map_count",
        "file": PROVENANCE,
        "beams": [B_PROVENANCE],
        "replacements": [
            [
                '      {:ok, "m" <> <<map_size(map)::64>> <> payload}\n',
                '      {:ok, "m" <> <<0 * map_size(map)::64>> <> payload}\n',
            ]
        ],
        "runs": [
            {
                "file": T_PROVENANCE,
                "red": [
                    "map PAIR COUNTS are explicit — sibling pairs do not collapse"
                    " into nesting",
                    "Refute with == failed",
                ],
                "absent": ["is stable across calls and independent of map insertion order"],
            }
        ],
    },
    # --------------------------------------------------------- append identity
    {
        "id": "append_identity.missing_identity",
        "file": V_APPEND,
        "beams": [B_APPEND_V],
        "replacements": [
            ["    case identity do\n", "    case identity || %{keys: expected} do\n"]
        ],
        "runs": [
            {
                "file": T_APPEND_V,
                "red": [
                    "a missing append identity is rejected",
                    "path: [:replicant, :append_identity]",
                ],
                "absent": ["a fully conforming append target compiles clean"],
            }
        ],
    },
    {
        "id": "append_identity.exact_axes",
        "file": V_APPEND,
        "beams": [B_APPEND_V],
        "replacements": [
            [
                "          Enum.sort(List.wrap(keys)) != Enum.sort(expected) ->\n",
                "          Enum.sort(List.wrap(keys)) != Enum.sort(expected) and false ->\n",
            ]
        ],
        "runs": [
            {
                "file": T_APPEND_V,
                "red": [
                    "a four-key identity is rejected (a narrower key collides distinct"
                    " effects)",
                    "a six-key identity is rejected (a wider key lets a replay append twice)",
                ],
                "absent": ["a fully conforming append target compiles clean"],
            }
        ],
    },
    {
        "id": "append_identity.all_tenants",
        "file": V_APPEND,
        "beams": [B_APPEND_V],
        "replacements": [
            [
                "          attribute_multitenant?(dsl_state) and Map.get(identity,"
                " :all_tenants?) != true ->\n",
                "          attribute_multitenant?(dsl_state) and Map.get(identity,"
                " :all_tenants?) != true and false ->\n",
            ]
        ],
        "runs": [
            {
                "file": T_APPEND_V,
                "red": [
                    "an attribute-multitenant target without `all_tenants? true` is rejected",
                    "path: [:replicant, :append_identity]",
                ],
                "absent": ["a fully conforming append target compiles clean"],
            }
        ],
    },
    {
        "id": "append_identity.nullable_axes",
        "file": V_APPEND,
        "beams": [B_APPEND_V],
        "replacements": [
            [
                "      role != :attempt and Map.get(attribute, :allow_nil?, true)"
                " != false ->\n",
                "      false and role != :attempt and Map.get(attribute, :allow_nil?,"
                " true) != false ->\n",
            ]
        ],
        "runs": [
            {
                "file": T_APPEND_V,
                "red": [
                    "a nullable append identity axis is rejected",
                    "path: [:replicant, :append_commit_lsn_attribute]",
                ],
                "absent": ["a fully conforming append target compiles clean"],
            }
        ],
    },
    {
        "id": "append_identity.local_change_rewrite",
        "file": V_APPEND,
        "beams": [B_APPEND_V],
        "replacements": [
            [
                "      not append_changes_safe?(\n        Map.get(action, :changes, []),\n",
                "      false and not append_changes_safe?(\n"
                "        Map.get(action, :changes, []),\n",
            ]
        ],
        "runs": [
            {
                "file": T_APPEND_V,
                "red": [
                    "an append action change that can rewrite the immutable identity is"
                    " rejected",
                    "path: [:actions, :append, :changes]",
                ],
                "absent": ["a global create change that can rewrite append identity is rejected"],
            }
        ],
    },
    {
        "id": "append_identity.global_change_rewrite",
        "file": V_APPEND,
        "beams": [B_APPEND_V],
        "replacements": [
            [
                "    global_create_changes = AshInfo.changes(dsl_state, :create)\n",
                "    global_create_changes = []\n",
            ]
        ],
        "runs": [
            {
                "file": T_APPEND_V,
                "red": [
                    "a global create change that can rewrite append identity is rejected",
                    "path: [:changes]",
                ],
                "absent": [
                    "an append action change that can rewrite the immutable identity is"
                    " rejected"
                ],
            }
        ],
    },
    # --------------------------------------------- telemetry value-free typing
    # O03: mutation tests cover every key. Three mutant families over
    # lib/ash_replicant/telemetry.ex, all observed in T_TELEMETRY:
    #   telemetry_types.<key>        — the key's @meta_types entry is replaced
    #                                   with an unmatchable type string, so the
    #                                   key's LEGIT shape is rejected; red target
    #                                   is that key's per-key legit-acceptance
    #                                   test (the accept direction).
    #   telemetry_offtype.<key>      — the key's type is laxed to accept the
    #                                   off-type value its rejection test feeds
    #                                   (the value-free reject direction).
    #   telemetry_types.<clause>     — the shared non-negativity guard of a
    #                                   numeric type clause is dropped.
    #   telemetry_measurements.<key> — the measurement key leaves the closed
    #                                   set; its legit shape is now off-set.
    {
        "id": "telemetry_types.commit_lsn",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    commit_lsn: "nil | non_neg_integer",\n',
                '    commit_lsn: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :commit_lsn"],
                "absent": ["legit shape accepted: :resource"],
            }
        ],
    },
    {
        "id": "telemetry_types.resource",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    resource: "nil | atom",\n',
                '    resource: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :resource"],
                "absent": ["legit shape accepted: :commit_lsn"],
            }
        ],
    },
    {
        "id": "telemetry_types.table",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    table: "nil | binary",\n',
                '    table: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :table"],
                "absent": ["legit shape accepted: :slot_name"],
            }
        ],
    },
    {
        "id": "telemetry_types.change_count",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    change_count: "nil | non_neg_integer",\n',
                '    change_count: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :change_count"],
                "absent": ["legit shape accepted: :txn_count"],
            }
        ],
    },
    {
        "id": "telemetry_types.txn_count",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    txn_count: "nil | non_neg_integer",\n',
                '    txn_count: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :txn_count"],
                "absent": ["legit shape accepted: :change_count"],
            }
        ],
    },
    {
        "id": "telemetry_types.tenant?",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    tenant?: "boolean",\n',
                '    tenant?: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :tenant?"],
                "absent": ["legit shape accepted: :transactional"],
            }
        ],
    },
    {
        "id": "telemetry_types.duration",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    duration: "non_neg_integer",\n',
                '    duration: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :duration"],
                "absent": ["legit shape accepted: :change_count"],
            }
        ],
    },
    {
        "id": "telemetry_types.reason",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    reason: "nil | atom | {:invalid_destination_config, atom}",\n',
                '    reason: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :reason"],
                "absent": ["legit shape accepted: :error_class"],
            }
        ],
    },
    {
        "id": "telemetry_types.error_class",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    error_class: "nil | atom",\n',
                '    error_class: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :error_class"],
                "absent": ["legit shape accepted: :kind"],
            }
        ],
    },
    {
        "id": "telemetry_types.kind",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    kind: "nil | atom",\n',
                '    kind: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :kind"],
                "absent": ["legit shape accepted: :error_class"],
            }
        ],
    },
    {
        "id": "telemetry_types.slot_name",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    slot_name: "nil | binary",\n',
                '    slot_name: "mutation_lax",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :slot_name"],
                "absent": ["legit shape accepted: :table"],
            }
        ],
    },
    {
        "id": "telemetry_types.transactional",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    transactional: "boolean"\n',
                '    transactional: "mutation_lax"\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["legit shape accepted: :transactional"],
                "absent": ["legit shape accepted: :tenant?"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.commit_lsn",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    commit_lsn: "nil | non_neg_integer",\n',
                '    commit_lsn: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :commit_lsn = "5" raises'],
                "absent": ["off-type :commit_lsn = -1 raises"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.resource",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    resource: "nil | atom",\n',
                '    resource: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :resource = "Foo" raises'],
                "absent": ["legit shape accepted: :commit_lsn"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.table",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    table: "nil | binary",\n',
                '    table: "nil | atom",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["off-type :table = :orders raises"],
                "absent": ["legit shape accepted: :slot_name"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.change_count",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    change_count: "nil | non_neg_integer",\n',
                '    change_count: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :change_count = "3" raises'],
                "absent": ["off-type :change_count = -1 raises"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.tenant?",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    tenant?: "boolean",\n',
                '    tenant?: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :tenant? = "yes" raises', "off-type :tenant? = nil raises"],
                "absent": ["legit shape accepted: :slot_name"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.duration",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    duration: "non_neg_integer",\n',
                '    duration: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :duration = "1" raises'],
                "absent": ["off-type :duration = -1 raises"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.reason",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    reason: "nil | atom | {:invalid_destination_config, atom}",\n',
                '    reason: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["a binary under the atom-typed reason key raises"],
                "absent": ["off-type :slot_name = 5 raises"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.error_class",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    error_class: "nil | atom",\n',
                '    error_class: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :error_class = "invalid" raises'],
                "absent": ["legit shape accepted: :slot_name"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.kind",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    kind: "nil | atom",\n',
                '    kind: "nil | binary",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ['off-type :kind = "identity" raises'],
                "absent": ["legit shape accepted: :table"],
            }
        ],
    },
    {
        "id": "telemetry_offtype.slot_name",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '    slot_name: "nil | binary",\n',
                '    slot_name: "nil | non_neg_integer",\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["off-type :slot_name = 5 raises"],
                "absent": ["legit shape accepted: :table"],
            }
        ],
    },
    {
        "id": "telemetry_types.nonneg_clause",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '  defp meta_value_ok?("nil | non_neg_integer", v), do: is_integer(v) and v >= 0\n',
                '  defp meta_value_ok?("nil | non_neg_integer", v), do: is_integer(v)\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": [
                    "off-type :commit_lsn = -1 raises",
                    "off-type :change_count = -1 raises",
                ],
                "absent": ['off-type :commit_lsn = "5" raises'],
            }
        ],
    },
    {
        "id": "telemetry_types.duration_nonneg_clause",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                '  defp meta_value_ok?("non_neg_integer", v), do: is_integer(v) and v >= 0\n',
                '  defp meta_value_ok?("non_neg_integer", v), do: is_integer(v)\n',
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["off-type :duration = -1 raises"],
                "absent": ["off-type :commit_lsn = -1 raises"],
            }
        ],
    },
    {
        "id": "telemetry_measurements.count",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                "  @allowed_measurement_keys ~w(count change_count duration byte_size)a\n",
                "  @allowed_measurement_keys ~w(change_count duration byte_size)a\n",
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["measurement accepted: :count"],
                "absent": ["measurement accepted: :change_count"],
            }
        ],
    },
    {
        "id": "telemetry_measurements.change_count",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                "  @allowed_measurement_keys ~w(count change_count duration byte_size)a\n",
                "  @allowed_measurement_keys ~w(count duration byte_size)a\n",
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["measurement accepted: :change_count"],
                "absent": ["measurement accepted: :count"],
            }
        ],
    },
    {
        "id": "telemetry_measurements.duration",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                "  @allowed_measurement_keys ~w(count change_count duration byte_size)a\n",
                "  @allowed_measurement_keys ~w(count change_count byte_size)a\n",
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["measurement accepted: :duration"],
                "absent": ["measurement accepted: :count"],
            }
        ],
    },
    {
        "id": "telemetry_measurements.byte_size",
        "file": TELEMETRY,
        "beams": [B_TELEMETRY],
        "replacements": [
            [
                "  @allowed_measurement_keys ~w(count change_count duration byte_size)a\n",
                "  @allowed_measurement_keys ~w(count change_count duration)a\n",
            ]
        ],
        "runs": [
            {
                "file": T_TELEMETRY,
                "red": ["measurement accepted: :byte_size"],
                "absent": ["measurement accepted: :count"],
            }
        ],
    },
]

# The closed inventory the reconciled design requires. The self-test (and
# every full-matrix run) fails when a required cell id is missing or any id
# is duplicated — the matrix cannot silently shrink.
REQUIRED_CELL_IDS = [
    "tenant_absence.nil_guard",
    "tenant_absence.false_guard",
    "tenant_absence.blank_guard",
    "tenant_reassignment.missing_old_tuple",
    "tenant_reassignment.old_side_required",
    "tenant_reassignment.raising_mfa",
    "tenant_reassignment.apply_call_site",
    "tenant_reassignment.scd2_call_site",
    "replica_identity.tenant_arm",
    "replica_identity.append_arm",
    "replica_identity.scd2_business_key_arm",
    "sensitive_type.plaintext_protected",
    "action_bypass.bypass_predicate",
    "action_bypass.primary_read",
    "action_bypass.primary_create",
    "action_bypass.primary_destroy",
    "action_bypass.scd2_close",
    "action_bypass.snapshot_mark",
    "action_bypass.snapshot_retire",
    "dynamic_participant.effective_repo",
    "dynamic_participant.set_context_change",
    "dynamic_participant.set_context_preparation",
    "notifier_drift.out_of_band_verdict",
    "notifier_drift.in_band_verdict",
    "notifier_drift.site_mirror_upsert",
    "notifier_drift.site_mirror_destroy",
    "notifier_drift.site_scd2_close",
    "notifier_drift.site_scd2_open",
    "notifier_drift.site_append",
    "notifier_drift.site_message",
    "notifier_drift.site_snapshot_bulk",
    "notifier_drift.site_snapshot_mark",
    "notifier_drift.site_snapshot_retire",
    "notifier_order.mirror_upsert",
    "notifier_order.mirror_destroy",
    "notifier_order.scd2_close",
    "notifier_order.scd2_open",
    "notifier_order.append",
    "notifier_order.message",
    "notifier_order.snapshot_bulk",
    "notifier_order.snapshot_mark",
    "notifier_order.snapshot_retire",
    "provenance_collision.length_prefix",
    "provenance_collision.type_tag",
    "provenance_collision.list_count",
    "provenance_collision.tuple_count",
    "provenance_collision.map_count",
    "append_identity.missing_identity",
    "append_identity.exact_axes",
    "append_identity.all_tenants",
    "append_identity.nullable_axes",
    "append_identity.local_change_rewrite",
    "append_identity.global_change_rewrite",
]


# --------------------------------------------------------------------------
# Engine
# --------------------------------------------------------------------------


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# The Elixir compiler's ExCk chunk (type-inference metadata) is NOT
# recompile-deterministic under the parallel compiler — recompiling the
# identical source can flip its bytes while every executable chunk (code,
# atoms, literals, exports, debug info) stays fixed. Build identity therefore
# hashes every chunk EXCEPT ExCk. Verified empirically in this repo: cycling
# an unchanged module produced byte-different beams whose only differing
# chunk was ExCk.
VOLATILE_BEAM_CHUNKS = {b"ExCk"}


def beam_digest(path):
    data = open(path, "rb").read()
    if data[:4] != b"FOR1" or len(data) < 12:
        return hashlib.sha256(data).hexdigest()
    digest = hashlib.sha256()
    offset = 12
    try:
        while offset + 8 <= len(data):
            name = data[offset : offset + 4]
            (size,) = struct.unpack(">I", data[offset + 4 : offset + 8])
            payload = data[offset + 8 : offset + 8 + size]
            if name not in VOLATILE_BEAM_CHUNKS:
                digest.update(name)
                digest.update(struct.pack(">I", size))
                digest.update(payload)
            offset += 8 + size + ((4 - size % 4) % 4)
    except struct.error:
        return hashlib.sha256(data).hexdigest()
    return digest.hexdigest()


def git_tracked_files(root):
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True
    ).stdout
    return [p.decode() for p in out.split(b"\0") if p]


def tree_manifest(root, relpaths):
    manifest = {}
    for rel in relpaths:
        path = os.path.join(root, rel)
        manifest[rel] = sha256_file(path) if os.path.isfile(path) else None
    return manifest


def dir_manifest(root, reldir):
    manifest = {}
    base = os.path.join(root, reldir)
    if not os.path.isdir(base):
        return manifest
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                manifest[os.path.relpath(path, root)] = "link:" + os.readlink(path)
            else:
                manifest[os.path.relpath(path, root)] = sha256_file(path)
    return manifest


def force_writable(path):
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            target = os.path.join(dirpath, name)
            try:
                os.chmod(target, os.stat(target).st_mode | stat.S_IWUSR)
            except OSError:
                pass


def remove_write(path):
    for dirpath, dirnames, filenames in os.walk(path, topdown=False):
        for name in filenames + dirnames:
            target = os.path.join(dirpath, name)
            mode = os.stat(target).st_mode
            os.chmod(target, mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))


class ChildTimeout(Exception):
    pass


class ChildDescendantLeak(Exception):
    pass


class ChildCleanupFailed(Exception):
    pass


class RunnerTermination(BaseException):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def process_group_exists(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def kill_and_confirm_process_group(pgid, reap=None):
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as error:
        raise ChildCleanupFailed() from error
    if reap:
        reap()
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not process_group_exists(pgid):
            return
        time.sleep(0.1)
    raise ChildCleanupFailed()


def run_child(argv, cwd, env, timeout, log_path):
    """Run one child in its own session; capture output to log_path.

    The whole process group must be absent before this function returns or
    raises a classified, cleanup-safe outcome. Child output is never echoed.
    """
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_and_confirm_process_group(proc.pid, reap=proc.wait)
            raise ChildTimeout()
        except BaseException:
            kill_and_confirm_process_group(proc.pid, reap=proc.wait)
            raise
        if process_group_exists(proc.pid):
            kill_and_confirm_process_group(proc.pid)
            raise ChildDescendantLeak()
    with open(log_path, "rb") as handle:
        return code, handle.read()


def validate_relative_path(path):
    """Accept only a normalized relative descendant path from fixture JSON."""
    if not isinstance(path, str) or not path or "\0" in path:
        return False
    normalized = os.path.normpath(path)
    return (
        normalized == path
        and normalized != os.curdir
        and not os.path.isabs(path)
        and normalized != os.pardir
        and not normalized.startswith(os.pardir + os.sep)
    )


def validate_config_paths(config, cells):
    """Reject config-derived filesystem paths before any workspace operation."""
    for key in ("copy_files", "deps_dirs", "build_purge"):
        paths = config.get(key, [])
        if not isinstance(paths, list) or not all(
            validate_relative_path(path) for path in paths
        ):
            raise StructuralFailure("matrix", CONFIG_INVALID)

    for key in ("build_copy", "beam_dir"):
        path = config.get(key)
        if path is not None and not validate_relative_path(path):
            raise StructuralFailure("matrix", CONFIG_INVALID)

    for cell in cells:
        if not isinstance(cell, dict) or not validate_relative_path(cell.get("file")):
            raise StructuralFailure("matrix", CONFIG_INVALID)
        for run in cell.get("runs", []):
            path = run.get("file")
            if path is not None and not validate_relative_path(path):
                raise StructuralFailure(cell.get("id") or "matrix", CONFIG_INVALID)


def validate_cells(cells, require_full_inventory):
    seen = set()
    for cell in cells:
        cell_id = cell.get("id")
        if not cell_id or cell_id in seen:
            raise StructuralFailure(cell_id or "matrix", CONFIG_INVALID)
        seen.add(cell_id)
        replacements = cell.get("replacements") or []
        if not replacements or not cell.get("runs"):
            raise StructuralFailure(cell_id, CONFIG_INVALID)
        for old, new in replacements:
            if not old or old == new:
                raise StructuralFailure(cell_id, CONFIG_INVALID)
        if cell.get("mode", "beam") == "beam" and not cell.get("beams"):
            raise StructuralFailure(cell_id, CONFIG_INVALID)
        for run in cell["runs"]:
            if not run.get("red"):
                raise StructuralFailure(cell_id, CONFIG_INVALID)
    if require_full_inventory:
        missing = [cid for cid in REQUIRED_CELL_IDS if cid not in seen]
        if missing or len(REQUIRED_CELL_IDS) != len(set(REQUIRED_CELL_IDS)):
            raise StructuralFailure("matrix", CONFIG_INVALID)


class Workspace:
    """The isolated scratch copy: build, mutate, restore, destroy."""

    def __init__(self, config):
        self.config = config
        self.base = None
        self.project = None
        self.logs = None
        self.log_count = 0
        self.stamp = int(time.time()) + 120
        self.cleanup_safe = True

    def build(self):
        root = self.config["root"]
        self.base = tempfile.mkdtemp(prefix="ash-replicant-mutation-gates.")
        self.project = os.path.join(self.base, "project")
        self.logs = os.path.join(self.base, "logs")
        os.makedirs(self.project)
        os.makedirs(self.logs)

        for rel in self.config["copy_files"]:
            src = os.path.join(root, rel)
            if not os.path.isfile(src):
                continue
            dst = os.path.join(self.project, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)

        for reldir in self.config.get("deps_dirs", []):
            src = os.path.join(root, reldir)
            if os.path.isdir(src):
                shutil.copytree(src, os.path.join(self.project, reldir), symlinks=False)

        build_copy = self.config.get("build_copy")
        if build_copy and os.path.isdir(os.path.join(root, build_copy)):
            shutil.copytree(
                os.path.join(root, build_copy),
                os.path.join(self.project, build_copy),
                symlinks=False,
            )
        for purge in self.config.get("build_purge", []):
            target = os.path.join(self.project, purge)
            if os.path.isdir(target):
                shutil.rmtree(target)

        for reldir in self.config.get("deps_dirs", []):
            target = os.path.join(self.project, reldir)
            if os.path.isdir(target):
                remove_write(target)

    def child_env(self):
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in self.config.get("env_delete", [])
        }
        env.update(self.config.get("env_set", {}))
        return env

    def next_log(self):
        self.log_count += 1
        return os.path.join(self.logs, f"child-{self.log_count}.log")

    def next_stamp(self):
        self.stamp += 2
        return self.stamp

    def run(self, argv, timeout, scope):
        try:
            return run_child(argv, self.project, self.child_env(), timeout, self.next_log())
        except ChildTimeout:
            raise StructuralFailure(scope, TIMEOUT)
        except ChildDescendantLeak:
            raise StructuralFailure(scope, DESCENDANT_LEAK)
        except ChildCleanupFailed:
            self.cleanup_safe = False
            raise StructuralFailure(scope, PROCESS_CLEANUP_FAILED)
        except OSError:
            raise StructuralFailure(scope, INTERNAL_ERROR)

    def compile(self, scope, failure_class):
        code, _out = self.run(
            self.config["compile"], self.config.get("compile_timeout", 1800), scope
        )
        if code != 0:
            raise StructuralFailure(scope, failure_class)

    def beam_digests(self):
        beam_dir = os.path.join(self.project, self.config["beam_dir"])
        digests = {}
        if os.path.isdir(beam_dir):
            for name in os.listdir(beam_dir):
                if name.endswith(".beam"):
                    digests[name] = beam_digest(os.path.join(beam_dir, name))
        return digests

    def stamp_file(self, rel):
        stamp = self.next_stamp()
        os.utime(os.path.join(self.project, rel), (stamp, stamp))

    def destroy(self):
        if not self.base or not self.cleanup_safe:
            return
        real_base = os.path.realpath(self.base)
        real_tmp = os.path.realpath(tempfile.gettempdir())
        if not (real_base == real_tmp or real_base.startswith(real_tmp + os.sep)):
            # Never delete anything the runner did not create under tmp.
            return
        force_writable(self.base)
        shutil.rmtree(self.base, ignore_errors=True)
        self.base = None


def run_test(workspace, config, run, scope):
    cmd = run.get("cmd") or config["test_command"](run["file"])
    timeout = run.get("timeout") or config.get("test_timeout", 900)
    return workspace.run(cmd, timeout, scope)


def run_gates(config, cells, label="mutation-gates"):
    try:
        validate_config_paths(config, cells)
        validate_cells(cells, config.get("require_full_inventory", False))
    except StructuralFailure as failure:
        print(f"{label}: FAIL {failure.scope} {failure.cls}")
        return 1

    root = config["root"]

    try:
        if config.get("git_tracked", False):
            tracked = git_tracked_files(root)
        else:
            tracked = list(config["copy_files"])
    except (subprocess.CalledProcessError, OSError):
        print(f"{label}: FAIL runner {INTERNAL_ERROR}")
        return 1
    config = dict(config)
    config["copy_files"] = tracked

    try:
        live_before = tree_manifest(root, tracked)
        deps_before = {
            reldir: dir_manifest(root, reldir)
            for reldir in config.get("deps_dirs", [])
        }
    except OSError:
        print(f"{label}: FAIL runner {INTERNAL_ERROR}")
        return 1

    workspace = Workspace(config)
    failures = []
    try:
        workspace.build()
        workspace.compile("baseline", BASELINE_COMPILE_FAILED)
        pristine = workspace.beam_digests()

        marker = config.get("baseline_required_output")
        seen_runs = set()
        for cell in cells:
            for run in cell["runs"]:
                key = tuple(run.get("cmd") or config["test_command"](run["file"]))
                if key in seen_runs:
                    continue
                seen_runs.add(key)
                code, out = run_test(workspace, config, run, "baseline")
                if code != 0:
                    raise StructuralFailure("baseline", BASELINE_TEST_FAILED)
                if marker and marker.encode() not in out:
                    raise StructuralFailure("baseline", BASELINE_MARKER_MISSING)
        print(f"{label}: baseline PASS ({len(seen_runs)} selectors)")

        for cell in cells:
            cell_id = cell["id"]
            rel = cell["file"]
            path = os.path.join(workspace.project, rel)
            try:
                original = open(path, "rb").read()
                mutated = original
                for old, new in cell["replacements"]:
                    old_b, new_b = old.encode(), new.encode()
                    count = mutated.count(old_b)
                    if count == 0:
                        raise StructuralFailure(cell_id, ANCHOR_MISSING)
                    if count > 1:
                        raise StructuralFailure(cell_id, ANCHOR_AMBIGUOUS)
                    mutated = mutated.replace(old_b, new_b)
                if mutated == original:
                    raise StructuralFailure(cell_id, CONFIG_INVALID)

                try:
                    open(path, "wb").write(mutated)
                    workspace.stamp_file(rel)
                    workspace.compile(cell_id, MUTANT_COMPILE_FAILED)

                    if cell.get("mode", "beam") == "beam":
                        after = workspace.beam_digests()
                        for beam in cell["beams"]:
                            if beam not in pristine or beam not in after:
                                raise StructuralFailure(cell_id, INTERNAL_ERROR)
                            if after[beam] == pristine[beam]:
                                raise StructuralFailure(cell_id, MUTANT_BUILD_IDENTITY)

                    for run in cell["runs"]:
                        code, out = run_test(workspace, config, run, cell_id)
                        if code == 0:
                            raise StructuralFailure(cell_id, MUTANT_STAYED_GREEN)
                        for fingerprint in run["red"]:
                            if fingerprint.encode() not in out:
                                raise StructuralFailure(cell_id, WRONG_RED)
                        for control in run.get("absent", []):
                            if control.encode() in out:
                                raise StructuralFailure(cell_id, CONTROL_REGRESSED)
                finally:
                    open(path, "wb").write(original)
                    workspace.stamp_file(rel)

                workspace.compile(cell_id, RESTORE_COMPILE_FAILED)
                if cell.get("mode", "beam") == "beam":
                    # Identity is claimed for the TARGET beams only: a cascade
                    # recompile of a non-target module (e.g. an Ash DSL module
                    # whose bytes are not recompile-deterministic) does not
                    # invalidate the restoration of the mutated guard.
                    restored = workspace.beam_digests()
                    for beam in cell["beams"]:
                        if restored.get(beam) != pristine.get(beam):
                            raise StructuralFailure(cell_id, RESTORE_IDENTITY)

                print(f"{label}: PASS {cell_id}")
            except StructuralFailure as failure:
                failures.append(failure)
                print(f"{label}: FAIL {failure.scope} {failure.cls}")
                if failure.cls in (
                    BASELINE_COMPILE_FAILED,
                    RESTORE_COMPILE_FAILED,
                    RESTORE_IDENTITY,
                    TIMEOUT,
                    DESCENDANT_LEAK,
                    PROCESS_CLEANUP_FAILED,
                    INTERNAL_ERROR,
                ):
                    # The scratch build can no longer be trusted for the
                    # next cell; stop instead of compounding.
                    raise
    except StructuralFailure as failure:
        if failure not in failures:
            failures.append(failure)
            print(f"{label}: FAIL {failure.scope} {failure.cls}")
    except Exception as error:  # noqa: BLE001 - reduce to a structural class
        failures.append(StructuralFailure("runner", INTERNAL_ERROR))
        print(f"{label}: FAIL runner {INTERNAL_ERROR} ({type(error).__name__})")
    finally:
        workspace.destroy()

    try:
        live_after = tree_manifest(root, tracked)
        deps_after = {
            reldir: dir_manifest(root, reldir)
            for reldir in config.get("deps_dirs", [])
        }
        if live_after != live_before or deps_after != deps_before:
            failures.append(StructuralFailure("live-tree", LIVE_TREE_MUTATED))
            print(f"{label}: FAIL live-tree {LIVE_TREE_MUTATED}")
    except OSError:
        failures.append(StructuralFailure("runner", INTERNAL_ERROR))
        print(f"{label}: FAIL runner {INTERNAL_ERROR}")

    if failures:
        print(f"{label}: FAIL ({len(failures)} failure(s))")
        return 1
    print(f"{label}: PASS ({len(cells)} cells RED as required)")
    return 0


# --------------------------------------------------------------------------
# Real-project configuration
# --------------------------------------------------------------------------


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def real_config():
    return {
        "root": repo_root(),
        "git_tracked": True,
        "deps_dirs": ["deps"],
        "build_copy": "_build/test",
        "build_purge": ["_build/test/lib/ash_replicant"],
        "compile": ["mix", "compile"],
        "beam_dir": "_build/test/lib/ash_replicant/ebin",
        "baseline_required_output": "TestRepo start attempts: 0",
        "env_delete": [
            "ASH_REPLICANT_TEST_URL",
            "MIX_BUILD_ROOT",
            "MIX_BUILD_PATH",
            "MIX_DEPS_PATH",
        ],
        "env_set": {"MIX_ENV": "test"},
        "compile_timeout": 1800,
        "test_timeout": 900,
        "require_full_inventory": True,
        "test_command": lambda file: ["mix", "test", file, "--no-compile"],
    }


# --------------------------------------------------------------------------
# Self-test: fixture scenarios driving every runner failure class, plus the
# sentinel proof that no child byte ever reaches the runner's own output.
# --------------------------------------------------------------------------

SENTINEL = "SENTINEL-ROW-VALUE-org-secret-9481"
FIXTURE_MARKER = "FIXTURE-REPO-STARTS-0"
FIXTURE_RED = "FIXTURE-RED tripwire guard removed"
FIXTURE_CONTROL = "FIXTURE-CONTROL-NAME stayed green"

COMPILE_DEFAULT = """
import pathlib
src = pathlib.Path("src.txt").read_bytes()
out = pathlib.Path("build")
out.mkdir(exist_ok=True)
(out / "Elixir.Fixture.beam").write_bytes(b"BEAM:" + src)
"""

COMPILE_STALE = """
import pathlib
out = pathlib.Path("build")
out.mkdir(exist_ok=True)
beam = out / "Elixir.Fixture.beam"
if not beam.exists():
    beam.write_bytes(b"BEAM:" + pathlib.Path("src.txt").read_bytes())
"""

COMPILE_DRIFTING = """
import pathlib
out = pathlib.Path("build")
out.mkdir(exist_ok=True)
counter = pathlib.Path("counter.txt")
n = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(n))
src = pathlib.Path("src.txt").read_bytes()
(out / "Elixir.Fixture.beam").write_bytes(b"BEAM:" + src + str(n).encode())
"""

TEST_DEFAULT = f"""
import pathlib, sys
src = pathlib.Path("src.txt").read_text()
if "GUARD_LINE_A" in src:
    print("{FIXTURE_MARKER}")
    sys.exit(0)
print("{FIXTURE_RED}")
print("{SENTINEL}")
sys.stderr.write("{SENTINEL}\\n")
sys.exit(1)
"""

TEST_BASELINE_FAILS = f"""
import sys
print("{SENTINEL}")
sys.stderr.write("{SENTINEL}\\n")
sys.exit(1)
"""

TEST_NO_MARKER = """
import sys
sys.exit(0)
"""

TEST_ALWAYS_GREEN = f"""
import sys
print("{FIXTURE_MARKER}")
sys.exit(0)
"""

TEST_WRONG_RED = f"""
import pathlib, sys
src = pathlib.Path("src.txt").read_text()
if "GUARD_LINE_A" in src:
    print("{FIXTURE_MARKER}")
    sys.exit(0)
print("an unrelated failure entirely")
print("{SENTINEL}")
sys.exit(1)
"""

TEST_CONTROL_REGRESSED = f"""
import pathlib, sys
src = pathlib.Path("src.txt").read_text()
if "GUARD_LINE_A" in src:
    print("{FIXTURE_MARKER}")
    sys.exit(0)
print("{FIXTURE_RED}")
print("{FIXTURE_CONTROL}")
print("{SENTINEL}")
sys.exit(1)
"""

TEST_TIMEOUT = f"""
import os, pathlib, subprocess, sys, time
src = pathlib.Path("src.txt").read_text()
if "GUARD_LINE_A" in src:
    print("{FIXTURE_MARKER}")
    sys.exit(0)
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
pathlib.Path(os.environ["FIXTURE_PID_FILE"]).write_text(str(child.pid))
print("{SENTINEL}", flush=True)
sys.stderr.write("{SENTINEL}\\n")
sys.stderr.flush()
time.sleep(300)
"""

TEST_BASELINE_DESCENDANT = f"""
import os, pathlib, subprocess, sys
src = pathlib.Path("src.txt").read_text()
if "GUARD_LINE_A" in src:
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
    pathlib.Path(os.environ["FIXTURE_PID_FILE"]).write_text(str(child.pid))
    print("{FIXTURE_MARKER}", flush=True)
    sys.exit(0)
print("{FIXTURE_RED}", flush=True)
sys.exit(1)
"""

TEST_BLOCKING_BASELINE = f"""
import os, pathlib, time
pathlib.Path(os.environ["FIXTURE_PID_FILE"]).write_text(str(os.getpid()))
print("{FIXTURE_MARKER}", flush=True)
time.sleep(300)
"""

TEST_SENTINEL_GREEN = f"""
import sys
print("{FIXTURE_MARKER}")
print("{SENTINEL}")
sys.exit(0)
"""

SRC_DEFAULT = "line-one\nGUARD_LINE_A\nline-three\n"


def fixture_cell(**overrides):
    cell = {
        "id": "fixture.guard",
        "file": "src.txt",
        "beams": ["Elixir.Fixture.beam"],
        "replacements": [["GUARD_LINE_A\n", "guard removed\n"]],
        "runs": [
            {
                "cmd": [sys.executable, "tool/test.py"],
                "file": "src.txt",
                "red": [FIXTURE_RED],
                "absent": [FIXTURE_CONTROL],
            }
        ],
    }
    cell.update(overrides)
    return cell


def build_fixture(base, src, compile_script, test_script, cells, env_set=None):
    root = os.path.join(base, "fixture-root")
    os.makedirs(os.path.join(root, "tool"), exist_ok=True)
    os.makedirs(os.path.join(root, "deps"), exist_ok=True)
    with open(os.path.join(root, "src.txt"), "w") as handle:
        handle.write(src)
    with open(os.path.join(root, "tool", "compile.py"), "w") as handle:
        handle.write(compile_script)
    with open(os.path.join(root, "tool", "test.py"), "w") as handle:
        handle.write(test_script)
    with open(os.path.join(root, "deps", "dep.txt"), "w") as handle:
        handle.write("dependency bytes\n")

    config = {
        "root": root,
        "git_tracked": False,
        "copy_files": ["src.txt", "tool/compile.py", "tool/test.py"],
        "deps_dirs": ["deps"],
        "compile": [sys.executable, "tool/compile.py"],
        "beam_dir": "build",
        "baseline_required_output": FIXTURE_MARKER,
        "env_delete": ["ASH_REPLICANT_TEST_URL"],
        "env_set": env_set or {},
        "compile_timeout": 60,
        "test_timeout": 60,
        "require_full_inventory": False,
        "cells": cells,
    }
    config_path = os.path.join(base, "config.json")
    with open(config_path, "w") as handle:
        json.dump(config, handle)
    return config_path


def run_fixture(config_path):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__), "--fixture-config", config_path],
        capture_output=True,
        text=True,
        timeout=300,
    )
    return proc.returncode, proc.stdout + proc.stderr


def self_test():
    label = "mutation-gates self-test"
    checks = []

    def scenario(name, src, compile_script, test_script, cells, expect_exit, expect_out,
                 forbid_sentinel=True, env_set=None, after=None):
        with tempfile.TemporaryDirectory(prefix="mutation-gates-selftest.") as base:
            config_path = build_fixture(base, src, compile_script, test_script, cells,
                                        env_set=env_set)
            code, out = run_fixture(config_path)
            ok = (code != 0) == (expect_exit != 0)
            for needle in expect_out:
                ok = ok and needle in out
            if forbid_sentinel and SENTINEL in out:
                ok = False
            if ok and after:
                ok = after()
            checks.append((name, ok))
            print(f"{label}: {'PASS' if ok else 'FAIL'} {name}")

    scenario(
        "happy-red",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_DEFAULT, [fixture_cell()],
        0, ["PASS fixture.guard", "PASS (1 cells RED as required)"],
    )
    scenario(
        "anchor-missing",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_DEFAULT,
        [fixture_cell(replacements=[["NO_SUCH_ANCHOR\n", "guard removed\n"]])],
        1, ["FAIL fixture.guard anchor_missing"],
    )
    scenario(
        "anchor-ambiguous",
        "GUARD_LINE_A\nGUARD_LINE_A\n", COMPILE_DEFAULT, TEST_DEFAULT,
        [fixture_cell()],
        1, ["FAIL fixture.guard anchor_ambiguous"],
    )
    scenario(
        "duplicate-cell-id",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_DEFAULT,
        [fixture_cell(), fixture_cell()],
        1, ["config_invalid"],
    )

    with tempfile.TemporaryDirectory(prefix="mutation-gates-selftest-path.") as base:
        outside = os.path.join(base, "outside.txt")
        with open(outside, "w") as handle:
            handle.write(SRC_DEFAULT)

        path_escape_ok = True
        cases = (
            ("copy_files", outside),
            ("deps_dirs", outside),
            ("build_copy", outside),
            ("build_purge", outside),
            ("beam_dir", outside),
            ("cell_file", outside),
            ("run_file", outside),
            ("copy_files", "../outside.txt"),
        )
        for index, (field, value) in enumerate(cases):
            fixture_base = os.path.join(base, str(index))
            config_path = build_fixture(
                fixture_base,
                SRC_DEFAULT,
                COMPILE_DEFAULT,
                TEST_DEFAULT,
                [fixture_cell()],
            )
            with open(config_path) as handle:
                config = json.load(handle)
            if field in ("copy_files", "deps_dirs", "build_purge"):
                config[field] = [value]
            elif field == "cell_file":
                config["cells"][0]["file"] = value
            elif field == "run_file":
                config["cells"][0]["runs"][0]["file"] = value
            else:
                config[field] = value
            with open(config_path, "w") as handle:
                json.dump(config, handle)
            code, out = run_fixture(config_path)
            path_escape_ok = path_escape_ok and code == 1 and "config_invalid" in out
        path_escape_ok = path_escape_ok and open(outside).read() == SRC_DEFAULT
        checks.append(("path-escape", path_escape_ok))
        print(f"{label}: {'PASS' if path_escape_ok else 'FAIL'} path-escape")

    scenario(
        "inert-replacement",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_DEFAULT,
        [fixture_cell(replacements=[["GUARD_LINE_A\n", "GUARD_LINE_A\n"]])],
        1, ["config_invalid"],
    )
    scenario(
        "stale-beam",
        SRC_DEFAULT, COMPILE_STALE, TEST_DEFAULT, [fixture_cell()],
        1, ["FAIL fixture.guard mutant_build_identity"],
    )
    scenario(
        "restore-mismatch",
        SRC_DEFAULT, COMPILE_DRIFTING, TEST_DEFAULT, [fixture_cell()],
        1, ["FAIL fixture.guard restore_identity"],
    )
    scenario(
        "baseline-failure",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_BASELINE_FAILS, [fixture_cell()],
        1, ["FAIL baseline baseline_test_failed"],
    )
    scenario(
        "baseline-marker-missing",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_NO_MARKER, [fixture_cell()],
        1, ["FAIL baseline baseline_marker_missing"],
    )
    scenario(
        "mutant-stays-green",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_ALWAYS_GREEN, [fixture_cell()],
        1, ["FAIL fixture.guard mutant_stayed_green"],
    )
    scenario(
        "wrong-red",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_WRONG_RED, [fixture_cell()],
        1, ["FAIL fixture.guard wrong_red"],
    )
    scenario(
        "control-regressed",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_CONTROL_REGRESSED, [fixture_cell()],
        1, ["FAIL fixture.guard control_regressed"],
    )

    normal_pid_dir = tempfile.mkdtemp(prefix="mutation-gates-selftest-normal-pid.")
    normal_pid_file = os.path.join(normal_pid_dir, "descendant.pid")
    normal_descendant_ok = False
    try:
        with tempfile.TemporaryDirectory(
            prefix="mutation-gates-selftest-normal-descendant."
        ) as base:
            config_path = build_fixture(
                base,
                SRC_DEFAULT,
                COMPILE_DEFAULT,
                TEST_BASELINE_DESCENDANT,
                [fixture_cell()],
                env_set={"FIXTURE_PID_FILE": normal_pid_file},
            )
            code, out = run_fixture(config_path)
            normal_descendant_ok = (
                code == 1
                and "FAIL baseline descendant_leak" in out
                and os.path.isfile(normal_pid_file)
            )
            if normal_descendant_ok:
                pid = int(open(normal_pid_file).read().strip())
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    normal_descendant_ok = False
    finally:
        if os.path.isfile(normal_pid_file):
            pid = int(open(normal_pid_file).read().strip())
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        shutil.rmtree(normal_pid_dir, ignore_errors=True)
    checks.append(("normal-exit-descendant", normal_descendant_ok))
    print(
        f"{label}: {'PASS' if normal_descendant_ok else 'FAIL'} "
        "normal-exit-descendant"
    )

    for signal_name, signal_value in (
        ("sigint", signal.SIGINT),
        ("sigterm", signal.SIGTERM),
    ):
        signal_pid_dir = tempfile.mkdtemp(
            prefix=f"mutation-gates-selftest-{signal_name}-pid."
        )
        signal_pid_file = os.path.join(signal_pid_dir, "child.pid")
        signal_ok = False
        child_pid = None
        runner = None
        try:
            with tempfile.TemporaryDirectory(
                prefix=f"mutation-gates-selftest-{signal_name}."
            ) as base:
                config_path = build_fixture(
                    base,
                    SRC_DEFAULT,
                    COMPILE_DEFAULT,
                    TEST_BLOCKING_BASELINE,
                    [fixture_cell()],
                    env_set={"FIXTURE_PID_FILE": signal_pid_file},
                )
                runner = subprocess.Popen(
                    [
                        sys.executable,
                        os.path.abspath(__file__),
                        "--fixture-config",
                        config_path,
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and not os.path.isfile(
                    signal_pid_file
                ):
                    if runner.poll() is not None:
                        break
                    time.sleep(0.1)
                if os.path.isfile(signal_pid_file):
                    child_pid = int(open(signal_pid_file).read().strip())
                    runner.send_signal(signal_value)
                    out, _ = runner.communicate(timeout=20)
                    deadline = time.monotonic() + 10
                    child_dead = False
                    while time.monotonic() < deadline:
                        try:
                            os.kill(child_pid, 0)
                        except ProcessLookupError:
                            child_dead = True
                            break
                        time.sleep(0.1)
                    signal_ok = (
                        runner.returncode != 0
                        and "mutation-gates: FAIL runner interrupted" in out
                        and child_dead
                    )
        finally:
            if runner is not None and runner.poll() is None:
                runner.kill()
                runner.wait()
            if child_pid is not None:
                try:
                    os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            shutil.rmtree(signal_pid_dir, ignore_errors=True)
        checks.append((f"{signal_name}-cleans-child", signal_ok))
        print(
            f"{label}: {'PASS' if signal_ok else 'FAIL'} "
            f"{signal_name}-cleans-child"
        )

    isolation_vars = {"MIX_BUILD_ROOT", "MIX_BUILD_PATH", "MIX_DEPS_PATH"}
    env_isolation_ok = isolation_vars.issubset(set(real_config()["env_delete"]))
    checks.append(("mix-env-isolation", env_isolation_ok))
    print(
        f"{label}: {'PASS' if env_isolation_ok else 'FAIL'} mix-env-isolation"
    )

    with tempfile.TemporaryDirectory(
        prefix="mutation-gates-selftest-manifest."
    ) as base:
        config_path = build_fixture(
            base,
            SRC_DEFAULT,
            COMPILE_DEFAULT,
            TEST_DEFAULT,
            [fixture_cell()],
        )
        with open(config_path) as handle:
            manifest_config = json.load(handle)
        manifest_cells = manifest_config.pop("cells")
        manifest_config["test_command"] = lambda file: [
            sys.executable,
            "tool/test.py",
        ]
        original_tree_manifest = tree_manifest

        def failing_tree_manifest(_root, _relpaths):
            raise OSError("manifest sentinel path")

        manifest_out = io.StringIO()
        manifest_code = None
        try:
            globals()["tree_manifest"] = failing_tree_manifest
            with contextlib.redirect_stdout(manifest_out):
                try:
                    manifest_code = run_gates(
                        manifest_config,
                        manifest_cells,
                        label="manifest-fixture",
                    )
                except OSError:
                    pass
        finally:
            globals()["tree_manifest"] = original_tree_manifest
        manifest_text = manifest_out.getvalue()
        manifest_ok = (
            manifest_code == 1
            and manifest_text.strip()
            == "manifest-fixture: FAIL runner internal_error"
            and "Traceback" not in manifest_text
            and "sentinel" not in manifest_text
        )
    checks.append(("manifest-error-structural", manifest_ok))
    print(
        f"{label}: {'PASS' if manifest_ok else 'FAIL'} "
        "manifest-error-structural"
    )

    cleanup_workspace = Workspace({"env_delete": [], "env_set": {}})
    cleanup_workspace.base = tempfile.mkdtemp(
        prefix="mutation-gates-selftest-cleanup-failure."
    )
    cleanup_workspace.project = os.path.join(cleanup_workspace.base, "project")
    cleanup_workspace.logs = os.path.join(cleanup_workspace.base, "logs")
    os.makedirs(cleanup_workspace.project)
    os.makedirs(cleanup_workspace.logs)
    cleanup_base = cleanup_workspace.base
    original_group_cleanup = kill_and_confirm_process_group

    def forced_cleanup_failure(pgid, reap=None):
        original_group_cleanup(pgid, reap=reap)
        raise ChildCleanupFailed()

    cleanup_failure_ok = False
    try:
        globals()["kill_and_confirm_process_group"] = forced_cleanup_failure
        try:
            cleanup_workspace.run(
                [sys.executable, "-c", "import time; time.sleep(300)"],
                0.1,
                "cleanup",
            )
        except StructuralFailure as failure:
            cleanup_failure_ok = failure.cls == PROCESS_CLEANUP_FAILED
    finally:
        globals()["kill_and_confirm_process_group"] = original_group_cleanup
    cleanup_workspace.destroy()
    cleanup_failure_ok = cleanup_failure_ok and os.path.isdir(cleanup_base)
    cleanup_workspace.cleanup_safe = True
    cleanup_workspace.destroy()
    cleanup_failure_ok = cleanup_failure_ok and not os.path.exists(cleanup_base)
    checks.append(("cleanup-failure-refused", cleanup_failure_ok))
    print(
        f"{label}: {'PASS' if cleanup_failure_ok else 'FAIL'} "
        "cleanup-failure-refused"
    )

    pid_dir = tempfile.mkdtemp(prefix="mutation-gates-selftest-pid.")
    pid_file = os.path.join(pid_dir, "descendant.pid")

    def descendant_dead():
        if not os.path.isfile(pid_file):
            return False
        pid = int(open(pid_file).read().strip())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.2)
        return False

    scenario(
        "timeout-with-descendant",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_TIMEOUT,
        [fixture_cell(runs=[{
            "cmd": [sys.executable, "tool/test.py"],
            "file": "src.txt",
            "red": [FIXTURE_RED],
            "absent": [],
            "timeout": 5,
        }])],
        1, ["FAIL fixture.guard timeout"],
        env_set={"FIXTURE_PID_FILE": pid_file},
        after=descendant_dead,
    )
    shutil.rmtree(pid_dir, ignore_errors=True)

    scenario(
        "internal-error",
        SRC_DEFAULT, COMPILE_DEFAULT, TEST_SENTINEL_GREEN,
        [fixture_cell(beams=["Elixir.Absent.beam"],
                      runs=[{
                          "cmd": [sys.executable, "tool/test.py"],
                          "file": "src.txt",
                          "red": [FIXTURE_RED],
                          "absent": [],
                      }])],
        1, ["FAIL fixture.guard internal_error"],
    )

    # The REAL matrix inventory: complete, unique, and anchored to the live
    # tree — every cell's anchors occur exactly once and every selector file
    # exists, without compiling anything.
    inventory_ok = True
    try:
        validate_cells(MATRIX, require_full_inventory=True)
        root = repo_root()
        for cell in MATRIX:
            text = open(os.path.join(root, cell["file"]), encoding="utf-8").read()
            for old, _new in cell["replacements"]:
                if text.count(old) != 1:
                    inventory_ok = False
            for run in cell["runs"]:
                if not os.path.isfile(os.path.join(root, run["file"])):
                    inventory_ok = False
    except (StructuralFailure, OSError):
        inventory_ok = False
    checks.append(("real-matrix-inventory", inventory_ok))
    print(f"{label}: {'PASS' if inventory_ok else 'FAIL'} real-matrix-inventory")

    # --diff-base path scoping. The selection is a pure function over the
    # changed-file list; None means the FULL matrix. Each scenario pins one
    # direction of the partition: relevant files select ALL their cells
    # (completeness), irrelevant files select none, and the evidence
    # machinery forces FULL.
    resolver_expected = sorted(
        cell["id"] for cell in MATRIX if cell["file"] == RESOLVER
    )
    telemetry_expected = sorted(
        cell["id"]
        for cell in MATRIX
        if any(run.get("file") == T_TELEMETRY for run in cell["runs"])
    )

    def selection_ids(changed):
        cells = select_matrix_cells(changed)
        return None if cells is None else sorted(cell["id"] for cell in cells)

    def scope_ok(name, changed, expected):
        ids = selection_ids(changed)
        ok = ids == expected
        checks.append((name, ok))
        print(f"{label}: {'PASS' if ok else 'FAIL'} {name}")

    scope_ok("scope-docs-only-zero",
             ["README.md", "docs/RECOVERY.md", "CHANGELOG.md"], [])
    scope_ok("scope-guard-file-complete", [RESOLVER], resolver_expected)
    scope_ok("scope-named-test-complete", [T_TELEMETRY], telemetry_expected)
    scope_ok("scope-uncovered-lib-file-zero", ["lib/ash_replicant/status.ex"], [])
    scope_ok("scope-gate-script-full", ["scripts/run-mutation-gates.py"], None)
    scope_ok("scope-fixture-support-full", ["test/support/marquee.ex"], None)
    scope_ok("scope-test-helper-full", ["test/test_helper.exs"], None)
    scope_ok("scope-build-identity-full", ["mix.lock"], None)
    scope_ok("scope-docs-plus-guard",
             ["README.md", RESOLVER], resolver_expected)

    unreachable_ok = changed_files_for_base("no-such-ref-0deadbeef") is None
    checks.append(("scope-unreachable-base-full", unreachable_ok))
    print(f"{label}: {'PASS' if unreachable_ok else 'FAIL'} scope-unreachable-base-full")

    # A pure rename must list BOTH paths (git's default rename detection
    # collapses to the new path only, which would let a renamed guard file
    # select zero cells and pass silently). Real scratch repo, real git.
    rename_ok = False
    try:
        with tempfile.TemporaryDirectory(prefix="mutation-gates-rename.") as repo:
            def git(*argv):
                return subprocess.run(
                    ["git", "-C", repo] + list(argv),
                    capture_output=True,
                    text=True,
                    check=True,
                )

            git("init", "--quiet")
            git("config", "user.email", "selftest@example.invalid")
            git("config", "user.name", "mutation-gates self-test")
            with open(os.path.join(repo, "lib_guard.ex"), "w", encoding="utf-8") as f:
                f.write("guard\n")
            git("add", "-A")
            git("commit", "--quiet", "-m", "base")
            os.rename(os.path.join(repo, "lib_guard.ex"), os.path.join(repo, "lib_renamed.ex"))
            git("add", "-A")
            git("commit", "--quiet", "-m", "rename")

            changed = changed_files_for_base("HEAD~1", cwd=repo)
            rename_ok = changed is not None and set(changed) == {
                "lib_guard.ex",
                "lib_renamed.ex",
            }
    except (subprocess.CalledProcessError, OSError):
        rename_ok = False
    checks.append(("scope-rename-lists-both-paths", rename_ok))
    print(f"{label}: {'PASS' if rename_ok else 'FAIL'} scope-rename-lists-both-paths")

    # The expected sets are derived from MATRIX; an emptied or re-anchored
    # MATRIX must not let the completeness scenarios pass vacuously.
    anchors_ok = resolver_expected != [] and telemetry_expected != []
    checks.append(("scope-matrix-anchors-nonempty", anchors_ok))
    print(f"{label}: {'PASS' if anchors_ok else 'FAIL'} scope-matrix-anchors-nonempty")

    failed = [name for name, ok in checks if not ok]
    if failed:
        print(f"{label}: FAIL ({len(failed)} scenario(s))")
        return 1
    print(f"{label}: PASS ({len(checks)} scenarios)")
    return 0


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def run_main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--matrix", action="store_true")
    parser.add_argument("--cells", default=None)
    parser.add_argument("--diff-base", default=None, metavar="REF")
    parser.add_argument("--fixture-config", default=None)
    args = parser.parse_args()

    if args.fixture_config:
        with open(args.fixture_config) as handle:
            config = json.load(handle)
        cells = config.pop("cells")
        config["test_command"] = lambda file: [sys.executable, "tool/test.py"]
        return run_gates(config, cells)

    if args.self_test:
        return self_test()

    if args.diff_base:
        # Every --diff-base path keeps the runner's OWN vacuity battery in
        # the per-push evidence — the no-args path always runs it, and a
        # push editing this runner is exactly the push where a vacuous
        # runner would otherwise slip through scoped.
        code = self_test()
        if code != 0:
            return code

        changed = changed_files_for_base(args.diff_base)
        if changed is None:
            print(
                "mutation-gates: diff-base unusable — running FULL matrix "
                f"({args.diff_base})"
            )
            return run_gates(real_config(), MATRIX)

        cells = select_matrix_cells(changed)
        if cells is None:
            print(
                "mutation-gates: diff touches guard-evidence machinery — "
                "running FULL matrix "
                f"({len(changed)} file(s))"
            )
            return run_gates(real_config(), MATRIX)

        if not cells:
            print(
                "mutation-gates: PASS (0 cells selected — no guard file or "
                f"named test changed; {len(changed)} file(s) diffed)"
            )
            return 0

        print(
            f"mutation-gates: scoped {len(cells)}/{len(MATRIX)} cells "
            f"({len(changed)} file(s) diffed)"
        )
        config = real_config()
        config["require_full_inventory"] = False
        return run_gates(config, cells)

    if args.cells:
        wanted = [prefix for prefix in args.cells.split(",") if prefix]
        cells = [
            cell
            for cell in MATRIX
            if any(cell["id"].startswith(prefix) for prefix in wanted)
        ]
        if not cells:
            print("mutation-gates: FAIL matrix config_invalid")
            return 1
        config = real_config()
        config["require_full_inventory"] = False
        return run_gates(config, cells)

    if args.matrix:
        return run_gates(real_config(), MATRIX)

    code = self_test()
    if code != 0:
        return code
    return run_gates(real_config(), MATRIX)


def raise_runner_termination(signum, _frame):
    raise RunnerTermination(signum)


def main():
    previous_sigterm = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, raise_runner_termination)
    try:
        return run_main()
    except KeyboardInterrupt:
        print("mutation-gates: FAIL runner interrupted")
        return 130
    except RunnerTermination as termination:
        print("mutation-gates: FAIL runner interrupted")
        return 128 + termination.signum
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)


if __name__ == "__main__":
    sys.exit(main())
