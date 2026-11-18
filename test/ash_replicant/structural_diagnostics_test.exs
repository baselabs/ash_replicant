defmodule AshReplicant.StructuralDiagnosticsTest do
  use ExUnit.Case, async: true

  setup do
    capture =
      Path.join(System.tmp_dir!(), "ash-replicant-diagnostics-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(capture) end)
    {:ok, capture: capture}
  end

  test "connection receipts distinguish library templates without printing their values", %{
    capture: capture
  } do
    messages = [
      {"client #PID<1.2.3> exited", "client_exited"},
      {"client #PID<1.2.3> exited: sensitive-value", "client_exited"},
      {"owner #PID<1.2.3> exited: sensitive-value", "owner_exited"},
      {"client #PID<1.2.3> timed out because it checked out the connection for longer than 123ms",
       "checkout_timeout"},
      {"client #PID<1.2.3> timed out because it queued and checked out the connection for longer than 123ms",
       "queue_checkout_timeout"},
      {"owner #PID<1.2.3> timed out because it owned the connection for longer than 123ms",
       "ownership_timeout"},
      {"connection not available and request was dropped from queue after 123ms", "queue_drop"},
      {"connection not available and queuing is disabled", "queue_disabled"},
      {"#PID<1.2.3> checked in the connection owned by #PID<4.5.6>", "checked_in"},
      {"tcp recv (idle): closed", "tcp_closed"},
      {"ssl recv (idle): closed", "ssl_closed"},
      {"sensitive-value", "unknown"}
    ]

    Enum.each(messages, fn {message, template} ->
      output =
        diagnose(
          capture,
          "12:00:00.000 [error] Postgrex.Protocol (#PID<7.8.9>) disconnected: " <>
            "** (DBConnection.ConnectionError) #{message}\n"
        )

      assert output == "CONNECTION-ERROR: template=#{template} emitter=postgrex_protocol\n"
    end)
  end

  test "unknown emitters and embedded templates never become diagnostic values", %{capture: capture} do
    output =
      diagnose(
        capture,
        "sensitive-value ** (DBConnection.ConnectionError) sensitive-value client #PID<1.2.3> exited\n"
      )

    assert output == "CONNECTION-ERROR: template=unknown emitter=other\n"
  end

  defp diagnose(capture, content) do
    File.write!(capture, content)

    [_, python] =
      "scripts/run-structural-tests.sh"
      |> File.read!()
      |> String.split("<<'PYTHON'\n", parts: 2)

    [python | _] = String.split(python, "\nPYTHON", parts: 2)

    {output, 0} =
      System.cmd("python3", ["-B", "-c", python, capture], stderr_to_stdout: true)

    output
  end
end
