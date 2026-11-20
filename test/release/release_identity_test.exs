# Exercise the anonymous guard with the same injected-response style as Replicant.
source = File.read!(Path.expand("../../scripts/release_identity.exs", __DIR__))
{:__block__, _, [module, _entrypoint]} = Code.string_to_quoted!(source)
Code.compile_quoted(module)

defmodule AshReplicant.ReleaseIdentityTest do
  use ExUnit.Case, async: true

  alias AshReplicant.ReleaseIdentity

  @version "1.6.4"
  @digest String.duplicate("a", 64)

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "release-docs-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(path, [{~c"index.html", "rendered docs"}], [:compressed])
    bytes = File.read!(path)
    File.rm!(path)
    %{docs: bytes}
  end

  test "pre-build admits only an absent release or valid unretired held metadata" do
    assert {:ok, :fresh} == check({"{}\n404", 0})

    for docs? <- [false, true] do
      assert {:ok, {:held, docs?}} == check(response(metadata(docs?)))
    end

    for body <- [
          Map.put(metadata(false), "checksum", "invalid"),
          Map.put(metadata(false), "version", "1.6.3"),
          Map.put(metadata(false), "retirement", %{"reason" => "other"}),
          Map.put(metadata(false), "retirement", false),
          Map.put(metadata(false), "has_docs", nil),
          Map.delete(metadata(false), "retirement"),
          Map.delete(metadata(false), "checksum"),
          Map.delete(metadata(false), "has_docs"),
          %{},
          nil,
          "private-response-value"
        ] do
      assert {:error, message} = check(response(body))
      refute message =~ "private-response-value"
    end
  end

  test "package checksum matches while readable served docs are kept", %{docs: docs} do
    for docs? <- [false, true] do
      runner = runner(response(metadata(docs?)), {docs <> "\n200", 0})

      assert {:ok, {:held, docs?}} ==
               ReleaseIdentity.check_archive(@version, @digest, true, runner)
    end

    runner = runner(response(metadata(false)), {"{}\n404", 0})

    assert {:ok, {:held, false}} ==
             ReleaseIdentity.check_archive(@version, @digest, true, runner)

    # The docs lookup is authoritative even when release metadata lags.
    runner = runner(response(metadata(true)), {"{}\n404", 0})
    assert {:ok, {:held, true}} == ReleaseIdentity.check_archive(@version, @digest, true, runner)

    mismatch = Map.put(metadata(false), "checksum", String.duplicate("b", 64))
    runner = runner(response(mismatch), {docs <> "\n200", 0})

    assert {:error, message} =
             ReleaseIdentity.check_archive(@version, @digest, true, runner)

    assert message =~ "checksum differs"
  end

  test "post-build preflight hashes the package and checks docs presence", %{docs: docs_bytes} do
    dir =
      Path.join(System.tmp_dir!(), "ash-release-identity-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    package = Path.join(dir, "package.tar")
    docs = Path.join(dir, "docs.tar.gz")
    bytes = "inspected package bytes"
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    File.write!(package, bytes)
    File.write!(docs, docs_bytes)
    metadata = Map.put(metadata(true), "checksum", digest)
    runner = runner(response(metadata), {docs_bytes <> "\n200", 0})

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert :ok == ReleaseIdentity.main([@version, package, docs], runner)
           end) =~ "accepted"

    File.write!(package, "changed package bytes")

    assert_raise RuntimeError, ~r/checksum differs from the built package/, fn ->
      ReleaseIdentity.main([@version, package, docs], runner)
    end

    File.write!(package, bytes)
    File.write!(docs, :zlib.gzip("not a tarball"))

    assert_raise RuntimeError, ~r/Built docs archive is invalid/, fn ->
      ReleaseIdentity.main([@version, package, docs], runner)
    end
  end

  test "ambiguous lookups and malformed served docs refuse without response values" do
    failures = [
      {"private-response-value\n200", 0},
      {"{}\n301", 0},
      {"{}\n401", 0},
      {"{}\n403", 0},
      {"{}\n429", 0},
      {"{}\n500", 0},
      {"{}\n404", 7},
      {"no status", 0}
    ]

    for response <- failures do
      assert {:error, message} = check(response)
      refute message =~ "private-response-value"
    end

    for docs_response <- [{:zlib.gzip("not a tarball") <> "\n200", 0} | failures] do
      runner = runner(response(metadata(true)), docs_response)

      assert {:error, message} =
               ReleaseIdentity.check_archive(@version, @digest, true, runner)

      refute message =~ "private-response-value"
    end
  end

  defp check(response) do
    ReleaseIdentity.check_archive(@version, nil, false, runner(response, :unreachable))
  end

  defp runner(release, docs) do
    fn "curl", args ->
      case List.last(args) do
        "https://hex.pm/api/packages/ash_replicant/releases/" <> @version -> release
        "https://repo.hex.pm/docs/ash_replicant-" <> @version <> ".tar.gz" -> docs
      end
    end
  end

  defp metadata(docs?) do
    %{"version" => @version, "checksum" => @digest, "retirement" => nil, "has_docs" => docs?}
  end

  defp response(body), do: {Jason.encode!(body) <> "\n200", 0}
end
