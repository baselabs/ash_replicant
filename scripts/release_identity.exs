# Anonymous pre-build and inspected-archive checks. No project or key is loaded.
defmodule AshReplicant.ReleaseIdentity do
  @moduledoc false

  def main(args, runner \\ &run/2) do
    {version, package_digest, docs_digest} =
      case args do
        [version] -> {version, nil, nil}
        [version, package, docs] -> {version, digest(package), digest(docs)}
        _ -> raise "usage: release_identity.exs VERSION [PACKAGE DOCS]"
      end

    case check_archive(version, package_digest, docs_digest, runner) do
      {:ok, _state} -> IO.puts("Hex release identity: accepted")
      {:error, message} -> raise message
    end
  end

  defp digest(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  # A nil digest is only the pre-build identity check. Publication always repeats
  # this decision with both inspected SHA256s, before exposing a key.
  def check_archive(version, digest, docs_digest, runner \\ &run/2) do
    args = [
      "--silent",
      "--show-error",
      "--connect-timeout",
      "10",
      "--max-time",
      "30",
      "--write-out",
      "\n%{http_code}",
      "https://hex.pm/api/packages/ash_replicant/releases/" <> version
    ]

    case runner.("curl", args) do
      {response, 0} ->
        case String.split(response, "\n") |> Enum.reverse() do
          ["404" | _body] ->
            matching_docs(version, :fresh, docs_digest, runner)

          ["200" | body] ->
            with {:ok, state} <- held_release(Enum.reverse(body), version, digest) do
              matching_docs(version, state, docs_digest, runner)
            end

          _other ->
            {:error, "Hex release lookup failed; publication refused"}
        end

      _other ->
        {:error, "Hex release lookup failed; publication refused"}
    end
  end

  defp matching_docs(_version, state, nil, _runner), do: {:ok, state}

  defp matching_docs(version, state, digest, runner) do
    args = [
      "--silent",
      "--show-error",
      "--connect-timeout",
      "10",
      "--max-time",
      "30",
      "--write-out",
      "\n%{http_code}",
      "https://repo.hex.pm/docs/ash_replicant-" <> version <> ".tar.gz"
    ]

    with :ok <- docs_match(runner.("curl", args), digest, state == {:held, true}) do
      {:ok, state}
    end
  end

  # Split the HTTP status by byte offset: the archive is binary, not UTF-8 text.
  def docs_match({response, 0}, digest, required?) when byte_size(response) >= 4 do
    size = byte_size(response) - 4

    <<bytes::binary-size(size), status::binary>> = response

    case {status, bytes} do
      {"\n200", <<0x1F, 0x8B, _rest::binary>>} ->
        if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest,
          do: :ok,
          else: {:error, "Hex docs checksum differs from the built archive; publication refused"}

      {"\n404", _body} when not required? ->
        :ok

      _other ->
        {:error, "Hex docs archive is unavailable; publication refused"}
    end
  end

  def docs_match(_response, _digest, _required?),
    do: {:error, "Hex docs archive lookup failed; publication refused"}

  defp held_release(body, version, digest) do
    # OTP's JSON decoder uses :null; Hex's Erlang API uses nil in the uploader.
    with {:ok, metadata} <- decode_json(Enum.join(body, "\n"), "Hex release") do
      case metadata do
        %{
          "version" => ^version,
          "checksum" => checksum,
          "retirement" => :null,
          "has_docs" => docs?
        }
        when is_binary(checksum) and is_boolean(docs?) ->
          cond do
            not Regex.match?(~r/\A[0-9a-f]{64}\z/, checksum) ->
              {:error, "Hex release checksum is invalid"}

            digest != nil and checksum != digest ->
              {:error, "Hex release checksum differs from the built package; publication refused"}

            true ->
              {:ok, {:held, docs?}}
          end

        %{"retirement" => retirement} when retirement != :null ->
          {:error, "Hex release is retired; publication refused"}

        _other ->
          {:error, "Hex release metadata is invalid; publication refused"}
      end
    end
  end

  defp decode_json(body, label) do
    case :json.decode(body) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _other -> {:error, "#{label} returned an invalid metadata shape"}
    end
  rescue
    _error -> {:error, "#{label} returned invalid JSON"}
  catch
    _kind, _reason -> {:error, "#{label} returned invalid JSON"}
  end

  defp run(command, args), do: System.cmd(command, args, stderr_to_stdout: true)
end

AshReplicant.ReleaseIdentity.main(System.argv())
