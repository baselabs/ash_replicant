defmodule AshReplicant.Doctor.Report do
  @moduledoc """
  The ordered set of `AshReplicant.Doctor.Check` results, the verdict derived
  from them, and the process exit code that verdict maps to.

  Both output formats are TOTAL functions of the same checks — `to_map/1` for a
  machine reader and `to_text/1` for an operator — so a rendering cannot report
  something the canonical result does not say.

  ## Exit codes

    * `0` — every check passed (or was not applicable).
    * `1` — at least one check failed.
    * `2` — no failure, but at least one warning.
    * `3` — the command could not build a diagnosis at all: an unusable
      invocation, an unloadable sink, an unconfigured pipeline. Separate from
      `1` so a monitoring caller can tell "your deployment is unhealthy" from
      "you invoked me wrong".
  """

  alias AshReplicant.Doctor.Check

  @type mode :: :preflight | :doctor

  @type status :: :pass | :warn | :fail | :invalid

  @type t :: %__MODULE__{
          mode: mode() | nil,
          checks: [Check.t()],
          status: status(),
          exit_code: 0..3
        }

  @enforce_keys [:checks, :status, :exit_code]
  defstruct [:mode, :checks, :status, :exit_code]

  @doc "Build a report from the checks a run produced, deriving verdict and exit code."
  @spec new(mode(), [Check.t()]) :: t()
  def new(mode, checks) when is_list(checks) do
    status = verdict(checks)

    %__MODULE__{mode: mode, checks: checks, status: status, exit_code: exit_code(status)}
  end

  @doc """
  The report for an invocation that could not be diagnosed at all. Carries the
  structural refusal reason as a single `:invocation` check so machine readers
  parse one shape, never two.
  """
  @spec invalid(atom()) :: t()
  def invalid(reason) when is_atom(reason) do
    check = %Check{name: :invocation, domain: :runtime, status: :fail, reason: reason}

    %__MODULE__{mode: nil, checks: [check], status: :invalid, exit_code: 3}
  end

  defp verdict(checks) do
    cond do
      Enum.any?(checks, &(&1.status == :fail)) -> :fail
      Enum.any?(checks, &(&1.status == :warn)) -> :warn
      true -> :pass
    end
  end

  # `:invalid` never reaches here — `invalid/1` builds its report directly,
  # because an undiagnosable invocation has no checks to derive a verdict from.
  defp exit_code(:fail), do: 1
  defp exit_code(:warn), do: 2
  defp exit_code(:pass), do: 0

  @doc "The machine rendering: plain maps, JSON-encodable, one entry per check."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    %{
      mode: report.mode,
      status: report.status,
      exit_code: report.exit_code,
      checks: Enum.map(report.checks, &check_map/1)
    }
  end

  defp check_map(%Check{} = check) do
    %{
      name: check.name,
      domain: check.domain,
      status: check.status,
      reason: check.reason,
      detail: check.detail
    }
  end

  @doc """
  The operator rendering. Derived from the same checks as `to_map/1`, and
  deliberately free-text-free: each line is the check's own name, status, and
  reason, plus its structural detail when the allowlist admitted one.
  """
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{} = report) do
    lines =
      [header(report)] ++
        Enum.map(report.checks, &check_line/1) ++
        ["", "status=#{report.status} exit_code=#{report.exit_code}"]

    Enum.join(lines, "\n") <> "\n"
  end

  defp header(%__MODULE__{mode: nil}), do: "ash_replicant diagnosis"
  defp header(%__MODULE__{mode: mode}), do: "ash_replicant #{mode}"

  defp check_line(%Check{} = check) do
    "  [#{marker(check.status)}] #{check.domain}/#{check.name} " <>
      "status=#{check.status} reason=#{check.reason}" <>
      if(check.detail, do: " detail=#{check.detail}", else: "")
  end

  defp marker(:pass), do: "ok"
  defp marker(:warn), do: "!!"
  defp marker(:fail), do: "XX"
  defp marker(:skipped), do: "--"
end
