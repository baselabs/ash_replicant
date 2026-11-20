# Anonymous pre-build and inspected-archive checks. No project or key is loaded.
defmodule AshReplicant.ReleaseIdentity do
  @moduledoc false

  def main(args, runner \\ &run/2) do
    {version, package_digest, inspect_docs?} =
      case args do
        [version] ->
          {version, nil, false}

        [version, package, docs] ->
          unless docs_archive?(File.read!(docs)), do: raise("Built docs archive is invalid")
          {version, digest(package), true}

        _ ->
          raise "usage: release_identity.exs VERSION [PACKAGE DOCS]"
      end

    case check_archive(version, package_digest, inspect_docs?, runner) do
      {:ok, _state} -> IO.puts("Hex release identity: accepted")
      {:error, message} -> raise message
    end
  end

  defp digest(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  # A nil digest is only the pre-build identity check. Publication always repeats
  # this decision with the inspected package checksum and docs presence, before exposing a key.
  def check_archive(version, digest, inspect_docs?, runner \\ &run/2) do
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
            present_docs(version, :fresh, inspect_docs?, runner)

          ["200" | body] ->
            with {:ok, state} <- held_release(Enum.reverse(body), version, digest) do
              present_docs(version, state, inspect_docs?, runner)
            end

          _other ->
            {:error, "Hex release lookup failed; publication refused"}
        end

      _other ->
        {:error, "Hex release lookup failed; publication refused"}
    end
  end

  defp present_docs(_version, state, false, _runner), do: {:ok, state}

  defp present_docs(version, state, true, runner) do
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

    with :ok <- docs_present(runner.("curl", args), state == {:held, true}) do
      {:ok, state}
    end
  end

  # Split the HTTP status by byte offset: the archive is binary, not UTF-8 text.
  def docs_present({response, 0}, required?)
      when is_binary(response) and byte_size(response) >= 4 do
    size = byte_size(response) - 4
    <<bytes::binary-size(size), status::binary>> = response

    case status do
      "\n200" ->
        if docs_archive?(bytes),
          do: :ok,
          else: {:error, "Hex docs archive is malformed; publication refused"}

      "\n404" when not required? ->
        :ok

      "\n404" ->
        {:error,
         "Hex docs metadata and repository disagree; inspect public state before retrying"}

      _other ->
        {:error, "Hex docs archive is unavailable; publication refused"}
    end
  end

  def docs_present(_response, _required?),
    do: {:error, "Hex docs archive lookup failed; publication refused"}

  def docs_archive?(<<0x1F, 0x8B, _rest::binary>> = bytes) do
    case :erl_tar.extract({:binary, bytes}, [:compressed, :memory]) do
      {:ok, entries} -> Enum.any?(entries, &match?({~c"index.html", _bytes}, &1))
      _other -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def docs_archive?(_bytes), do: false

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
