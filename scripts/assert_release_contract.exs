unless Code.ensure_loaded?(AshReplicant.DependencyRequirements) do
  Code.require_file(Path.expand("../lib/ash_replicant/dependency_requirements.ex", __DIR__))
end

Code.require_file(Path.join(__DIR__, "dependency_lanes.exs"))

defmodule AshReplicant.ReleaseContractError do
  defexception [:message]
end

defmodule AshReplicant.ReleaseContract do
  alias AshReplicant.DependencyLanes
  alias AshReplicant.DependencyRequirements
  alias AshReplicant.ReleaseContractError
  alias Jason.DecodeError
  alias YamlElixir.ParsingError

  @fail_late "${{ !cancelled() && steps.compile.outcome == 'success' }}"
  @report_if "${{ !cancelled() && steps.runtime.outcome == 'success' }}"
  @immutable_action ~r/\A[^@\s]+@[0-9a-f]{40}\z/
  @postgres_action "./.github/actions/postgres"

  @public_engine_check ~S"""
  engine="$(cat .github/postgres.ref)"
  [[ "$engine" =~ ^ghcr\.io/baselabs/postgres:[0-9]+\.[0-9]+-inputs-[0-9a-f]{64}@sha256:[0-9a-f]{64}$ ]]
  current_digest="$(python3 - <<'PY'
  import json, re, urllib.request
  host, path = 'ghcr.io', 'baselabs/postgres'
  with urllib.request.urlopen(f'https://{host}/token?scope=repository:{path}:pull', timeout=30) as response:
      token = json.load(response)['token']
  request = urllib.request.Request(f'https://{host}/v2/{path}/manifests/current', method='HEAD', headers={
      'Authorization': 'Bearer ' + token,
      'Accept': ', '.join(('application/vnd.oci.image.index.v1+json', 'application/vnd.oci.image.manifest.v1+json',
                           'application/vnd.docker.distribution.manifest.list.v2+json',
                           'application/vnd.docker.distribution.manifest.v2+json'))})
  with urllib.request.urlopen(request, timeout=30) as response:
      digest = response.headers.get('Docker-Content-Digest', '')
  if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
      raise SystemExit('ghcr.io/baselabs/postgres:current: registry named no digest')
  print(digest)
  PY
  )"
  if [ "${engine##*@}" != "$current_digest" ]; then
    echo 'checked PostgreSQL digest differs from ghcr.io/baselabs/postgres:current' >&2; exit 1
  fi
  docker pull "$engine"
  """

  @postgres_manage ~S"""
  set -euo pipefail
  [[ "$CONTAINER" =~ ^[a-z][a-z0-9-]*$ && "$PORT" =~ ^[1-9][0-9]{3,4}$ ]]
  hba="${RUNNER_TEMP:?}/postgres-$CONTAINER-hba.conf"
  case "$MODE" in
    stop)
      cleanup_status=0
      if docker container inspect "$CONTAINER" > /dev/null 2>&1; then
        docker logs "$CONTAINER" || cleanup_status=1
        docker rm -f -v "$CONTAINER" || cleanup_status=1
      fi
      rm -f "$hba"
      exit "$cleanup_status"
      ;;
    start) ;;
    *) echo 'mode must be start or stop' >&2; exit 1 ;;
  esac
  settings=(-c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20)
  if [[ -z "$IMAGE" ]]; then
    [[ "$DECODER_SOURCE" == false ]]
    engine="$(cat .github/postgres.ref)"
    docker run --detach --pull=never --name "$CONTAINER" \
      --publish "127.0.0.1:$PORT:5432" \
      --tmpfs /var/lib/pg:uid=26,gid=26,mode=0750 --tmpfs /tmp \
      --env TEST_PG_USER --env TEST_PG_PASSWORD --env TEST_PG_DATABASE \
      --entrypoint baselabs-test-postgres "$engine" "${settings[@]}"
  else
    mounts=()
    case "$DECODER_SOURCE" in
      true)
        [[ "$IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]]
        # Peer for entrypoint initialization; all host logins require a password.
        printf 'local all all peer\nhost all all all md5\nhost replication all all md5\n' > "$hba"
        mounts=(--volume "$hba:/hba.conf:ro")
        settings+=(-c shared_preload_libraries=pglogical -c hba_file=/hba.conf)
        ;;
      false)
        [[ "$IMAGE" =~ ^postgres:[0-9][a-z0-9.-]*@sha256:[0-9a-f]{64}$ ]]
        docker pull "$IMAGE"
        ;;
      *) echo 'decoder-source must be true or false' >&2; exit 1 ;;
    esac
    docker run --detach --pull=never --name "$CONTAINER" \
      --publish "127.0.0.1:$PORT:5432" \
      --env POSTGRES_USER --env POSTGRES_PASSWORD --env POSTGRES_DB \
      "${mounts[@]}" "$IMAGE" "${settings[@]}"
  fi
  ready=false
  for ((attempt=0; attempt<60; attempt++)); do
    if docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U "$TEST_PG_USER" -d "$TEST_PG_DATABASE"; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    docker logs "$CONTAINER"
    echo 'PostgreSQL did not become ready within 60 attempts' >&2
    exit 1
  fi
  """

  @checkout "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
  @setup_beam "erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124"
  @participant_example_start "<!-- ash-replicant-destination-participant-example:start -->"
  @participant_example_end "<!-- ash-replicant-destination-participant-example:end -->"

  @toolchain_action "./.github/actions/toolchain"
  @beam_action "./.github/actions/beam"
  @runtime_inputs %{
    "elixir" => "${{ steps.toolchain.outputs.elixir }}",
    "otp" => "${{ steps.toolchain.outputs.otp }}"
  }
  @toolchain_sha256 "25bbfa023b7f031256428b498fe300fcc460988fea81277072355e4c0d933764"

  @install_hex ~S"""
  mix local.hex "$WANT_HEX" --force
  installed=$(mix hex.info | awk '$1 == "Hex:" {print $2}')
  if [ "$installed" != "$WANT_HEX" ]; then
    echo "::error::Installed Hex $installed; expected $WANT_HEX."
    exit 1
  fi
  echo "Hex $installed, as pinned"
  """

  @publish_owner_condition "contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.actor) && contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.triggering_actor)"

  @publish_unreleased_check ~S"""
  test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
  test "$(git ls-remote --exit-code origin refs/heads/main | cut -f1)" = "$GITHUB_SHA"
  version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
  scripts/assert-release-tree.sh "$version" "v$version" --unreleased
  printf 'version=%s\n' "$version" >> "$GITHUB_OUTPUT"
  """

  @publish_package_inspection ~S"""
  scripts/build-release-docs.sh "$RUNNER_TEMP/hex-docs.tar.gz"
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh mix hex.build --output "$RUNNER_TEMP/package.tar"
  scripts/inspect-release-package.sh "$RUNNER_TEMP/package.tar"
  test "$(git ls-remote --exit-code origin refs/heads/main | cut -f1)" = "$GITHUB_SHA"
  scripts/assert-release-tree.sh "$VERSION" "v$VERSION" --unreleased "$RUNNER_TEMP/package.tar" "$RUNNER_TEMP/hex-docs.tar.gz"
  chmod a-w "$RUNNER_TEMP/package.tar" "$RUNNER_TEMP/hex-docs.tar.gz"
  """

  @read_release_assets_script ~S"""
  #!/usr/bin/env bash
  # Keyless registry read-back: retain served docs and report their published commit.
  set -euo pipefail
  root="$(cd "$(dirname "$0")/.." && pwd)"
  version="${1:?usage: read-release-assets.sh VERSION PACKAGE_ARCHIVE ASSET_DIRECTORY}"
  package="${2:?}"
  assets="${3:?}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ! -e "$assets" ]] || exit 2
  work="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-readback.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  # Refresh the actual default branch; missing or shallow history fails inspection.
  git -C "$root" fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
  fetch_archive() {
    local url="$1" output="$2" status
    status="$(curl --silent --show-error --connect-timeout 10 --max-time 60 \
      --output "$output" --write-out '%{http_code}' "$url")"
    [[ "$status" == 200 ]] || { echo 'Hex archive read-back is unavailable' >&2; exit 1; }
  }
  fetch_archive "https://repo.hex.pm/tarballs/ash_replicant-$version.tar" "$work/package.tar"
  cmp "$package" "$work/package.tar"
  fetch_archive "https://repo.hex.pm/docs/ash_replicant-$version.tar.gz" "$work/docs.tar.gz"
  python3 -I "$root/scripts/check-docs-archive.py" "$work/docs.tar.gz" \
    --version "$version" --commit "${GITHUB_SHA:?}" --repository "$root" \
    --commit-output "$work/published-commit" --assets "$assets" --package-archive "$work/package.tar"
  published_commit="$(cat "$work/published-commit")"
  printf 'published_commit=%s\n' "$published_commit" >> "${GITHUB_OUTPUT:?}"
  echo "Release read-back: published commit $published_commit"
  """

  @fresh_consumer_audits ~S"""
  consumer_mix deps.get >/dev/null
  consumer_mix hex.audit
  (cd "$root" && mix deps.audit --path "$consumer")
  consumer_mix deps.compile >/dev/null
  """

  @publish_hex_artifacts_script ~S"""
  # Runs with --no-mix-exs: only Hex and the already inspected archives are loaded.
  # No dependency fetch, build, project code, credential persistence, or response logging.
  defmodule PublishHexArtifacts do
    @moduledoc false

    def main([name, version, archive, docs]) do
      if Mix.Project.get(), do: raise("publication must run without a Mix project")

      # Read both files before uploading anything. The keyless build inspected these paths.
      package_bytes = File.read!(archive)
      docs_bytes = File.read!(docs)
      key = System.fetch_env!("HEX_API_KEY")
      if key == "", do: raise("HEX_API_KEY is empty; publication stopped")
      Hex.start()
      auth = [key: key]

      # A missing release alone cannot prove the package name already exists.
      existing_package!(Hex.API.Package.get_anonymous(nil, name), name)
      digest = :crypto.hash(:sha256, package_bytes) |> Base.encode16(case: :lower)

      case release_state!(Hex.API.Release.get(nil, name, version), version, digest) do
        :fresh ->
          Hex.API.Release.publish(nil, package_bytes, auth)
          |> accepted!("Hex package")
          |> approved!()

        {:held, _docs?} ->
          :ok
      end

      # Re-read after the package decision: docs may have appeared in the meantime.
      case release_state!(Hex.API.Release.get(nil, name, version), version, digest) do
        {:held, docs?} ->
          case docs_action!(Hex.Repo.get_docs("hexpm", name, version), docs?) do
            :upload ->
              Hex.API.ReleaseDocs.publish(nil, name, version, docs_bytes, auth)
              |> accepted!("Hex docs")
              |> approved!()

            :skip ->
              :ok
          end

        :fresh ->
          raise "Hex package is not served yet; inspect public state before retrying"
      end

      read_back!(Hex.API.Release.get(nil, name, version), version, digest)
      package_read_back!(Hex.Repo.get_tarball("hexpm", name, version), digest)
      docs_read_back!(Hex.Repo.get_docs("hexpm", name, version))
    end

    def main(_argv),
      do: raise("usage: publish_hex_artifacts.exs NAME VERSION PACKAGE_ARCHIVE DOCS_ARCHIVE")

    def existing_package!({:ok, {200, _headers, _body}}, _name), do: :ok

    def existing_package!({:ok, {404, _headers, _body}}, name),
      do: raise("the name #{name} is not on Hex; a first publication is the owner's decision")

    def existing_package!(_result, _name),
      do: raise("Hex package lookup failed; publication refused")

    def release_state!({:ok, {404, _headers, _body}}, _version, _digest), do: :fresh

    def release_state!({:ok, {200, _headers, metadata}}, version, digest) do
      case metadata do
        %{
          "version" => ^version,
          "checksum" => ^digest,
          "retirement" => nil,
          "has_docs" => docs?
        }
        when is_boolean(docs?) ->
          if is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
            {:held, docs?}
          else
            raise "Hex release checksum is invalid; publication refused"
          end

        %{"retirement" => retirement} when not is_nil(retirement) ->
          raise "Hex release is retired; publication refused"

        _other ->
          raise "Hex release identity does not match the built package; publication refused"
      end
    end

    def release_state!(_result, _version, _digest),
      do: raise("Hex release lookup failed; publication refused")

    def accepted!({:ok, {code, _headers, body}}, label) when code in 200..299 do
      IO.puts("#{label}: archive accepted")
      if is_map(body) and body["status"] == "staged", do: :staged, else: :published
    end

    def accepted!(_result, label),
      do: raise("#{label} upload failed or ambiguous; inspect public state before retrying")

    def approved!(:published), do: :ok

    def approved!(:staged),
      do: raise("Hex approval pending; inspect public state before retrying the same commit")

    def read_back!(response, version, digest) do
      case release_state!(response, version, digest) do
        {:held, _docs?} -> :ok
        _other -> raise "Hex package is not served; inspect public state before retrying"
      end
    end

    def package_read_back!({:ok, {200, _headers, bytes}}, digest) when is_binary(bytes) do
      if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) != digest do
        raise "Hex package archive checksum differs from the built package; publication refused"
      end

      :ok
    end

    def package_read_back!(_response, _digest),
      do: raise("Hex package archive is unavailable; inspect public state before retrying")

    # Read raw bytes from the repository API. ReleaseDocs.get decodes API responses
    # and can return nil for a successful binary response. Never replace served docs.
    def docs_action!({:ok, {200, _headers, bytes}}, _required?) do
      if docs_archive?(bytes),
        do: :skip,
        else: raise("Hex docs archive is malformed; publication refused")
    end

    def docs_action!({:ok, {404, _headers, _body}}, false), do: :upload

    def docs_action!({:ok, {404, _headers, _body}}, true),
      do: raise("Hex docs metadata and repository disagree; inspect public state before retrying")

    def docs_action!(_response, _required?),
      do: raise("Hex docs archive is unavailable; inspect public state before retrying")

    def docs_read_back!(response) do
      :skip = docs_action!(response, true)
      :ok
    end

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
  end

  PublishHexArtifacts.main(System.argv())
  """

  @release_notes_script ~S'''
  #!/usr/bin/env python3
  """Validate the release changelog before publication and read it from a served package."""

  import argparse
  import io
  from pathlib import Path
  import re
  import sys
  import tarfile


  def section(version, changelog):
      sections = re.findall(
          rf"^## \[{re.escape(version)}\][^\n]*(?:\n|\Z).*?(?=^## |\Z)", changelog,
          re.M | re.S,
      )
      body = sections[0].partition("\n")[2] if len(sections) == 1 else ""
      if not re.sub(r"^\s*#+[^\n]*$", "", body, flags=re.M).strip():
          raise ValueError("The release changelog section is missing, duplicated or empty.")
      return sections[0].strip()


  def verify_changelog(mixfile, changelog):
      versions = re.findall(r'^  @version "([^"]+)"$', mixfile.read_text(encoding="utf-8"), re.M)
      if len(versions) != 1:
          raise ValueError("Expected exactly one Mix project version.")
      section(versions[0], changelog.read_text(encoding="utf-8"))


  def member(packed, name):
      matches = [entry for entry in packed if entry.name == name]
      if len(matches) != 1 or not matches[0].isfile():
          raise ValueError("Hex package changelog is missing, duplicated or malformed.")
      return packed.extractfile(matches[0]).read()


  def package_section(archive, version):
      with tarfile.open(archive, "r:") as package:
          contents = member(package, "contents.tar.gz")
      with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as contents:
          changelog = member(contents, "CHANGELOG.md").decode("utf-8")
      return section(version, changelog)


  def main():
      parser = argparse.ArgumentParser(description=__doc__)
      parser.add_argument("--mixfile", type=Path, default=Path("mix.exs"))
      parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
      args = parser.parse_args()
      try:
          verify_changelog(args.mixfile, args.changelog)
      except (OSError, UnicodeError, ValueError) as error:
          print(f"Release notes refused: {error}", file=sys.stderr)
          return 1
      print("CHANGELOG OK: exactly one nonempty release section")
      return 0


  if __name__ == "__main__":
      raise SystemExit(main())
  '''

  @docs_inspection_script ~S'''
  #!/usr/bin/env python3
  """Inspect rendered or served Hex docs and their release provenance."""

  import argparse
  import hashlib
  import importlib.util
  import json
  from pathlib import Path, PurePosixPath
  import re
  import shutil
  import subprocess
  import sys
  import tarfile
  import zlib


  spec = importlib.util.spec_from_file_location(
      "release_notes", Path(__file__).with_name("release-notes.py")
  )
  release_notes = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(release_notes)


  SEMVER = re.compile(
      r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
      r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
  )


  def provenance(payload, package, version, commit, repository):
      def unique_fields(pairs):
          result = {}
          for key, value in pairs:
              if key in result:
                  raise ValueError("Duplicate release.json field.")
              result[key] = value
          return result

      try:
          release = json.loads(payload, object_pairs_hook=unique_fields)
      except (UnicodeError, json.JSONDecodeError) as error:
          raise ValueError("Invalid release.json JSON.") from error
      if (not isinstance(release, dict) or set(release) != {"package", "version", "commit"}
              or release["package"] != package or release["version"] != version
              or not isinstance(release["commit"], str)
              or not re.fullmatch(r"[0-9a-f]{40}", release["commit"])):
          raise ValueError("Invalid release.json identity.")
      published = release["commit"]
      if repository is None:
          if published != commit:
              raise ValueError("Built docs commit differs from the dispatched commit.")
      else:
          def git(*args):
              result = subprocess.run(["git", "-C", str(repository), *args],
                                      capture_output=True, check=False)
              if result.returncode:
                  raise ValueError("Docs provenance is outside available default-branch history.")
              return result.stdout.strip()

          if git("rev-parse", "--is-shallow-repository") != b"false":
              raise ValueError("Complete default-branch history is required.")
          git("show-ref", "--verify", "refs/remotes/origin/main")
          git("merge-base", "--is-ancestor", commit, "refs/remotes/origin/main")
          git("merge-base", "--is-ancestor", published, commit)
      return published


  def check(archive, directory=None, *, package="ash_replicant", version, commit, repository=None):
      if not SEMVER.fullmatch(version) or not re.fullmatch(r"[0-9a-f]{40}", commit):
          raise ValueError("Expected release identity is invalid.")
      source = None
      if directory is not None:
          if not directory.is_dir():
              raise ValueError("Documentation source directory is missing.")
          # Hex excludes dot-prefixed files and directories, including ExDoc's manifests.
          source = {}
          for path in directory.rglob("*"):
              if path.is_symlink() or not (path.is_file() or path.is_dir()):
                  raise ValueError("Documentation contains a link or special entry.")
              relative = path.relative_to(directory)
              if path.is_file() and not any(part.startswith(".") for part in relative.parts):
                  source[relative.as_posix()] = path
      names = set()
      ordered = []
      release = None
      with tarfile.open(archive, "r:gz") as packed:
          # Legacy served archives must refuse for their missing release identity.
          try:
              packed.getmember("release.json")
          except KeyError as error:
              raise ValueError("Docs archive requires top-level release.json.") from error
          # Hex emits a fixed gzip header: no original filename, timestamp, or OS.
          with archive.open("rb") as stream:
              if stream.read(10) != bytes((31, 139, 8, 0, 0, 0, 0, 0, 0, 0)):
                  raise ValueError("Docs gzip header must have no name or mtime.")
          for member in packed:
              path = PurePosixPath(member.name)
              if (not member.isfile() or path.is_absolute() or "\\" in member.name
                      or any(part in ("", ".", "..") for part in member.name.split("/"))):
                  raise ValueError(f"Unsafe docs archive member: {member.name!r}")
              if SEMVER.fullmatch(path.parts[0]):
                  raise ValueError("Top-level documentation filenames cannot be semantic versions.")
              if path.suffix == ".epub":
                  raise ValueError("EPUB embeds build time by default; only HTML and Markdown ship.")
              if (member.uid != 0 or member.gid != 0 or member.uname or member.gname
                      or member.mtime != 946684800):
                  raise ValueError("Docs tar metadata must use fixed times and empty ownership.")
              if member.name in names:
                  raise ValueError(f"Duplicate docs archive member: {member.name!r}")
              names.add(member.name)
              ordered.append(member.name)
              payload = packed.extractfile(member).read()
              if len(payload) != member.size:
                  raise ValueError("Truncated docs archive member.")
              if member.name == "release.json":
                  release = payload
              if source is not None:
                  if member.name not in source:
                      raise ValueError(f"Docs archive member has no source: {member.name!r}")
                  if payload != source[member.name].read_bytes():
                      raise ValueError(f"Docs archive bytes differ from source: {member.name!r}")
      if not {"index.html", "readme.html"} <= names:
          raise ValueError("Docs archive requires top-level index.html and readme.html.")
      if release is None:
          raise ValueError("Docs archive requires top-level release.json.")
      published = provenance(release, package, version, commit, repository)
      if source is not None and names != source.keys():
          raise ValueError(f"Docs archive omits source files: {sorted(source.keys() - names)!r}")
      if ordered != sorted(ordered):
          raise ValueError("Docs archive entries must be sorted.")
      with archive.open("rb") as stream:
          digest = hashlib.file_digest(stream, "sha256").hexdigest()
      print(f"DOCS OK: {len(names)} regular files; contents and release provenance inspected")
      print(f"SHA256: {digest}")
      print(f"Published commit: {published}")
      return published


  def retain_assets(archive, package_archive, assets, version, published):
      # Both archives are the verified served bytes. Notes come from the package they identify.
      notes = release_notes.package_section(package_archive, version)
      if not re.fullmatch(r"[0-9a-f]{40}", published):
          raise ValueError("Release notes require the full published commit.")
      assets.mkdir()
      try:
          paths = [assets / f"ash_replicant-{version}.tar", assets / f"ash_replicant-{version}-docs.tar.gz"]
          shutil.copyfile(package_archive, paths[0])
          shutil.copyfile(archive, paths[1])
          sums = ""
          digests = []
          for path in paths:
              with path.open("rb") as stream:
                  digest = hashlib.file_digest(stream, "sha256").hexdigest()
              digests.append(digest)
              sums += f"{digest}  {path.name}\n"
          (assets / "SHA256SUMS").write_text(sums)
          (assets / "RELEASE-NOTES.md").write_text(
              f"{notes}\n\nCommit: {published}\n\n"
              f"Package SHA-256: {digests[0]}\n\nDocs SHA-256: {digests[1]}\n",
              encoding="utf-8",
          )
          (assets / "published-commit.txt").write_text(published + "\n")
      except BaseException:
          shutil.rmtree(assets)
          raise


  def main():
      parser = argparse.ArgumentParser(description=__doc__)
      parser.add_argument("archive", type=Path)
      parser.add_argument("directory", type=Path, nargs="?")
      parser.add_argument("--package", default="ash_replicant")
      parser.add_argument("--version", required=True)
      parser.add_argument("--commit", required=True)
      parser.add_argument("--repository", type=Path)
      parser.add_argument("--commit-output", type=Path)
      parser.add_argument("--assets", type=Path)
      parser.add_argument("--package-archive", type=Path)
      args = parser.parse_args()
      try:
          published = check(args.archive, args.directory, package=args.package, version=args.version,
                            commit=args.commit, repository=args.repository)
          if args.assets:
              if args.repository is None or args.package_archive is None:
                  raise ValueError("Release assets require served docs and default-branch history.")
              retain_assets(args.archive, args.package_archive, args.assets, args.version, published)
          if args.commit_output:
              args.commit_output.write_text(published + "\n")
      except (OSError, UnicodeError, ValueError, tarfile.TarError, EOFError, zlib.error) as error:
          print(f"Docs archive refused: {error}", file=sys.stderr)
          return 1
      return 0


  if __name__ == "__main__":
      raise SystemExit(main())
  '''

  @publish_hex_artifacts_tests ~S"""
  # Load the real uploader module, without executing its publication entrypoint.
  if Mix.Project.get(), do: raise("upload preconditions must run without a Mix project")

  path = Path.join(__DIR__, "publish_hex_artifacts.exs")
  {:ok, {:__block__, _, [module, _entrypoint]}} = Code.string_to_quoted(File.read!(path))
  Code.compile_quoted(module, path)
  Hex.start()

  defmodule PublishHexArtifactsSelfTest do
    def reject(expected, function) do
      function.()
      raise "upload preconditions accepted a forbidden release"
    rescue
      error in RuntimeError ->
        unless error.message == expected, do: reraise(error, __STACKTRACE__)
    end
  end

  PublishHexArtifacts.existing_package!(
    Hex.API.Package.get_anonymous(nil, "ash_replicant"),
    "ash_replicant"
  )

  :fresh =
    PublishHexArtifacts.release_state!(
      Hex.API.Release.get(nil, "ash_replicant", "999999.0.0"),
      "999999.0.0",
      String.duplicate("0", 64)
    )

  # A dot cannot occur in a Hex package name, so this real lookup cannot name a package.
  PublishHexArtifactsSelfTest.reject(
    "the name ash_replicant.invalid is not on Hex; a first publication is the owner's decision",
    fn ->
      PublishHexArtifacts.existing_package!(
        Hex.API.Package.get_anonymous(nil, "ash_replicant.invalid"),
        "ash_replicant.invalid"
      )
    end
  )

  {:ok, {200, _, metadata}} = Hex.API.Release.get(nil, "ash_replicant", "1.6.3")

  {:held, true} =
    PublishHexArtifacts.release_state!({:ok, {200, [], metadata}}, "1.6.3", metadata["checksum"])

  package_response = Hex.Repo.get_tarball("hexpm", "ash_replicant", "1.6.3")
  :ok = PublishHexArtifacts.package_read_back!(package_response, metadata["checksum"])

  docs_response = Hex.Repo.get_docs("hexpm", "ash_replicant", "1.6.3")

  :skip = PublishHexArtifacts.docs_action!(docs_response, false)
  :skip = PublishHexArtifacts.docs_action!(docs_response, true)
  :ok = PublishHexArtifacts.docs_read_back!(docs_response)

  :upload =
    PublishHexArtifacts.docs_action!(
      Hex.Repo.get_docs("hexpm", "ash_replicant", "999999.0.0"),
      false
    )

  # These real published docs predate release.json: presence is sufficient for
  # upload planning, but provenance read-back must refuse them without an upload.
  {:ok, {200, _, package_bytes}} = package_response
  work = Path.join(System.tmp_dir!(), "ash-docs-live-#{System.unique_integer([:positive])}")
  File.mkdir!(work)

  try do
    archive = Path.join(work, "package.tar")
    assets = Path.join(work, "assets")
    File.write!(archive, package_bytes)

    {output, 1} =
      System.cmd(
        Path.join(__DIR__, "read-release-assets.sh"),
        ["1.6.3", archive, assets],
        stderr_to_stdout: true
      )

    unless output =~ "requires top-level release.json",
      do: raise("legacy docs refused for wrong reason")

    if File.exists?(assets), do: raise("legacy docs retained release assets")
  after
    File.rm_rf!(work)
  end

  PublishHexArtifactsSelfTest.reject(
    "Hex release identity does not match the built package; publication refused",
    fn ->
      PublishHexArtifacts.release_state!(
        {:ok, {200, [], metadata}},
        "1.6.3",
        String.duplicate("0", 64)
      )
    end
  )

  IO.puts("upload preconditions: live Hex self-tests PASS (no upload or key)")
  """

  @docs_inspection_tests ~S"""
  #!/usr/bin/env python3
  # Exercise the inspector against actual ExDoc output and mutated archive bytes.

  import gzip
  import importlib.util
  import io
  import hashlib
  import json
  import subprocess
  import sys
  import tarfile
  import tempfile
  from pathlib import Path

  spec = importlib.util.spec_from_file_location(
      "release_docs", Path(__file__).with_name("check-docs-archive.py")
  )
  inspector = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(inspector)
  archive, directory, package_archive = sys.argv[1:]
  identity = json.loads((Path(directory) / "release.json").read_text())
  version, commit = identity["version"], identity["commit"]


  def check(candidate, tree=None, **kwargs):
      return inspector.check(Path(candidate), tree, version=version, commit=commit, **kwargs)


  # The same parser admits the checkout preflight and the changelog inside served packages.
  notes = inspector.release_notes
  valid_section = f"## [{version}] - 2026-11-22\n\n### Fixed\n\n- Packaged release note."
  assert notes.section(version, valid_section + "\n\n## [0.0.0]\n\n- Older.\n") == valid_section

  for changelog in [
      "## [Unreleased]\n\n- A different release.\n",
      valid_section + "\n\n" + valid_section,
      f"## [{version}]",
      f"## [{version}]\n\n### Fixed\n\n",
  ]:
      try:
          notes.section(version, changelog)
      except ValueError as error:
          assert "missing, duplicated or empty" in str(error)
      else:
          raise AssertionError("release notes accepted an invalid changelog section")

  with tempfile.TemporaryDirectory(prefix="ash-replicant-changelog-") as scratch:
      work = Path(scratch)
      mixfile, changelog = work / "mix.exs", work / "CHANGELOG.md"
      mixfile.write_text(f'  @version "{version}"\n')
      changelog.write_text(valid_section)
      notes.verify_changelog(mixfile, changelog)
      command = [sys.executable, "-I", str(Path(notes.__file__)),
                 "--mixfile", str(mixfile), "--changelog", str(changelog)]
      subprocess.run(command, check=True, capture_output=True)
      for invalid in ["", valid_section + "\n\n" + valid_section,
                      f"## [{version}]\n\n### Fixed\n"]:
          changelog.write_text(invalid)
          result = subprocess.run(command, check=False, capture_output=True)
          assert result.returncode == 1 and b"missing, duplicated or empty" in result.stderr
      changelog.write_text(valid_section)
      for invalid in ["", f'  @version "{version}"\n  @version "{version}"\n']:
          mixfile.write_text(invalid)
          result = subprocess.run(command, check=False, capture_output=True)
          assert result.returncode == 1 and b"exactly one Mix project version" in result.stderr


  check(archive, Path(directory))

  with tempfile.TemporaryDirectory(prefix="ash-replicant-docs-check-") as work:
      reasons = {
          "missing": "requires top-level",
          "changed": "bytes differ from source",
          "extra": "has no source",
          "duplicate": "Duplicate docs archive member",
          "traversal": "Unsafe docs archive member",
          "symlink": "Unsafe docs archive member",
      }
      for mutation in ["clean", *reasons]:
          candidate = Path(work) / "docs.tar.gz"
          packed = io.BytesIO()
          with tarfile.open(archive, "r:gz") as original, tarfile.open(fileobj=packed, mode="w") as output:
              for entry in original:
                  if entry.isfile():
                      payload = original.extractfile(entry).read()
                      if entry.name.removeprefix("./") == "index.html":
                          if mutation == "missing":
                              continue
                          if mutation == "changed":
                              payload += b"changed"
                              entry.size = len(payload)
                      output.addfile(entry, io.BytesIO(payload))
                  else:
                      output.addfile(entry)
              if mutation in ["extra", "duplicate", "traversal", "symlink"]:
                  name = {
                      "extra": "unexpected.html",
                      "duplicate": "index.html",
                      "traversal": "../outside.html",
                      "symlink": "linked.html",
                  }[mutation]
                  entry = tarfile.TarInfo(name)
                  entry.mtime = 946684800
                  if mutation == "symlink":
                      entry.type = tarfile.SYMTYPE
                      entry.linkname = "index.html"
                  output.addfile(entry, io.BytesIO(b""))
          # Preserve the fixed gzip header so each negative reaches its intended guard.
          compressed = gzip.compress(packed.getvalue(), mtime=0)
          candidate.write_bytes(bytes((31, 139, 8, 0, 0, 0, 0, 0, 0, 0)) + compressed[10:])
          if mutation == "clean":
              check(candidate, Path(directory))
              continue
          try:
              check(candidate, Path(directory))
          except ValueError as error:
              if reasons[mutation] not in str(error):
                  raise AssertionError(f"wrong rejection for {mutation}: {error}") from error
          else:
              raise AssertionError(f"docs inspector accepted {mutation}")

  # Build real archive variants from rendered output, and exercise actual Git ancestry.
  with tempfile.TemporaryDirectory(prefix="ash-replicant-docs-provenance-") as scratch:
      work = Path(scratch)
      repo = work / "repo"
      repo.mkdir()

      def git(*args):
          return subprocess.run(["git", "-C", str(repo), *args], check=True,
                                capture_output=True).stdout.decode().strip()

      git("init", "--initial-branch=main")
      git("config", "user.name", "Docs provenance test")
      git("config", "user.email", "docs@example.invalid")
      git("commit", "--allow-empty", "-m", "Ancestor")
      ancestor = git("rev-parse", "HEAD")
      git("commit", "--allow-empty", "-m", "Dispatch")
      dispatched = git("rev-parse", "HEAD")
      git("commit", "--allow-empty", "-m", "Descendant")
      descendant = git("rev-parse", "HEAD")
      git("update-ref", "refs/remotes/origin/main", dispatched)
      git("checkout", "--orphan", "unrelated")
      git("commit", "--allow-empty", "-m", "Outside default history")
      unrelated = git("rev-parse", "HEAD")

      def variant(release, *, omit=False):
          candidate = work / "served.tar.gz"
          packed = io.BytesIO()
          with tarfile.open(archive, "r:gz") as original, tarfile.open(fileobj=packed, mode="w") as output:
              for entry in original:
                  payload = original.extractfile(entry).read()
                  if entry.name == "release.json":
                      if omit:
                          continue
                      payload = release if isinstance(release, bytes) else json.dumps(release).encode()
                      entry.size = len(payload)
                  output.addfile(entry, io.BytesIO(payload))
          compressed = gzip.compress(packed.getvalue(), mtime=0)
          candidate.write_bytes(bytes((31, 139, 8, 0, 0, 0, 0, 0, 0, 0)) + compressed[10:])
          return candidate

      def served(candidate, **kwargs):
          return inspector.check(candidate, version=version, commit=dispatched, repository=repo, **kwargs)

      for accepted in [ancestor, dispatched]:
          assert served(variant({**identity, "commit": accepted})) == accepted

      negatives = [
          ({**identity, "package": "other"}, "identity"),
          ({**identity, "version": "0.0.0"}, "identity"),
          ({**identity, "commit": 1}, "identity"),
          ({**identity, "commit": "bad"}, "identity"),
          ({**identity, "extra": True}, "identity"),
          ({"package": "ash_replicant", "version": version}, "identity"),
          ({**identity, "commit": descendant}, "outside available"),
          ({**identity, "commit": unrelated}, "outside available"),
          ({**identity, "commit": "0" * 40}, "outside available"),
          (b"not JSON", "JSON"),
          (b'{"package": "ash_replicant", "package": "other"}', "Duplicate"),
          ([], "identity"),
      ]
      for release, reason in negatives:
          try:
              served(variant(release))
          except ValueError as error:
              assert reason in str(error), (reason, error)
          else:
              raise AssertionError("served docs accepted invalid release provenance")

      for mode, reason in [("missing", "requires top-level release.json"),
                           ("history", "outside available"), ("shallow", "Complete default-branch")]:
          candidate = variant({**identity, "commit": ancestor}, omit=mode == "missing")
          if mode == "history":
              git("update-ref", "-d", "refs/remotes/origin/main")
          if mode == "shallow":
              git("update-ref", "refs/remotes/origin/main", dispatched)
              (repo / ".git/shallow").write_text(ancestor + "\n")
          try:
              served(candidate)
          except ValueError as error:
              assert reason in str(error), (reason, error)
          else:
              raise AssertionError("served docs accepted missing provenance or history")
      (repo / ".git/shallow").unlink()

      # The ancestor archive differs from this job's rendering. Retention uses its bytes.
      candidate = variant({**identity, "commit": ancestor})
      published = served(candidate)
      package = work / "package.tar"
      package.write_bytes(Path(package_archive).read_bytes())
      assets = work / "release-assets"
      inspector.retain_assets(candidate, package, assets, version, published)
      retained = assets / f"ash_replicant-{version}-docs.tar.gz"
      assert retained.read_bytes() == candidate.read_bytes()
      assert retained.read_bytes() != Path(archive).read_bytes()
      sums = (assets / "SHA256SUMS").read_text()
      assert hashlib.sha256(candidate.read_bytes()).hexdigest() + "  " + retained.name in sums
      assert (assets / "published-commit.txt").read_text().strip() == ancestor
      package_digest = hashlib.sha256(package.read_bytes()).hexdigest()
      docs_digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
      release_text = (assets / "RELEASE-NOTES.md").read_text()
      assert release_text == (
          notes.package_section(package, version) + f"\n\nCommit: {ancestor}\n\n"
          f"Package SHA-256: {package_digest}\n\nDocs SHA-256: {docs_digest}\n"
      )
      assert f"Commit: {dispatched}" not in release_text
      assert package_digest + "  " + f"ash_replicant-{version}.tar" in sums

      for invalid_commit in ["", ancestor[:7], "g" * 40]:
          destination = work / "assets-invalid-commit"
          try:
              inspector.retain_assets(candidate, package, destination, version, invalid_commit)
          except ValueError as error:
              assert "full published commit" in str(error) and not destination.exists()
          else:
              raise AssertionError("release notes accepted an incomplete published commit")

      # Mutate the actual built package in memory; never extract archive paths to disk.
      with tarfile.open(package_archive, "r:") as original:
          original_entries = [(entry, original.extractfile(entry).read()) for entry in original]
      contents = next(payload for entry, payload in original_entries if entry.name == "contents.tar.gz")
      for mutation in ["changed", "missing", "duplicate", "empty", "linked", "duplicate_member"]:
          packed = io.BytesIO()
          with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as original, \
                  tarfile.open(fileobj=packed, mode="w:gz") as output:
              for entry in original:
                  payload = original.extractfile(entry).read()
                  if entry.name == "CHANGELOG.md":
                      if mutation == "missing":
                          continue
                      payload = valid_section.encode()
                      if mutation == "duplicate":
                          payload += b"\n\n" + payload
                      if mutation == "empty":
                          payload = f"## [{version}]\n\n### Fixed\n".encode()
                      entry.size = len(payload)
                      if mutation == "linked":
                          entry.type, entry.linkname, entry.size = tarfile.SYMTYPE, "README.md", 0
                  output.addfile(entry, io.BytesIO(payload))
                  if mutation == "duplicate_member" and entry.name == "CHANGELOG.md":
                      output.addfile(entry, io.BytesIO(payload))
          altered = work / "package-variant.tar"
          with tarfile.open(altered, "w:") as output:
              for entry, payload in original_entries:
                  if entry.name == "contents.tar.gz":
                      payload = packed.getvalue()
                      entry.size = len(payload)
                  output.addfile(entry, io.BytesIO(payload))
          destination = work / f"assets-{mutation}"
          if mutation == "changed":
              inspector.retain_assets(candidate, altered, destination, version, ancestor)
              retained_notes = (destination / "RELEASE-NOTES.md").read_text()
              assert retained_notes.startswith(valid_section + "\n\nCommit: " + ancestor)
              assert hashlib.sha256(altered.read_bytes()).hexdigest() in retained_notes
          else:
              try:
                  inspector.retain_assets(candidate, altered, destination, version, ancestor)
              except ValueError:
                  assert not destination.exists()
              else:
                  raise AssertionError("release assets accepted invalid packaged release notes")

  print("docs inspection: real renders, negative archives, provenance, ancestry and served assets PASS")
  """

  @upload_archive_checks ~S"""
  trap 'rm -rf "$RUNNER_TEMP/package.tar" "$RUNNER_TEMP/hex-docs.tar.gz" "$RUNNER_TEMP/hex-docs.tar.gz.rendered"' EXIT
  version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
  python3 -I scripts/check-docs-archive.py "$RUNNER_TEMP/hex-docs.tar.gz" "$RUNNER_TEMP/hex-docs.tar.gz.rendered" --version "$version" --commit "$GITHUB_SHA"
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh mix hex.build --output "$RUNNER_TEMP/package.tar"
  scripts/inspect-release-package.sh "$RUNNER_TEMP/package.tar"
  python3 -B scripts/test_release_docs.py "$RUNNER_TEMP/hex-docs.tar.gz" "$RUNNER_TEMP/hex-docs.tar.gz.rendered" "$RUNNER_TEMP/package.tar"
  cd "$RUNNER_TEMP"
  mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/test_publish_hex_artifacts.exs"
  """

  @docs_build_script ~S"""
  #!/usr/bin/env bash
  # Render once with locked dependencies; inspect the archive and its release provenance.
  set -euo pipefail
  root="$(cd "$(dirname "$0")/.." && pwd)"
  output="${1:?usage: build-release-docs.sh ABSOLUTE_ARCHIVE_PATH}"
  [[ "$output" == /* && ! -e "$output" && ! -e "$output.rendered" ]] || exit 2
  work="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-docs.XXXXXX")"
  complete=false
  cleanup() {
    rm -rf "$work"
    if [[ "$complete" != true ]]; then
      rm -rf "$output" "$output.rendered"
    fi
  }
  trap cleanup EXIT
  unset ASH_REPLICANT_ASH_VERSION ASH_REPLICANT_REPLICANT_VERSION ASH_REPLICANT_ONETIME_VERSION
  export MIX_ENV=dev
  tree="$work/source"
  mkdir "$tree"
  git -C "$root" archive HEAD | tar -x -C "$tree"
  (
    cd "$tree"
    mix deps.get --check-locked
    mix docs --warnings-as-errors
  )
  version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$tree/mix.exs")"
  commit="$(git -C "$root" rev-parse HEAD)"
  [[ "$commit" == "${GITHUB_SHA:?}" ]] || exit 1
  python3 - "$tree/doc/release.json" "$version" "$commit" <<'PROVENANCE'
  import json
  from pathlib import Path
  import sys
  path, version, commit = sys.argv[1:]
  Path(path).write_text(json.dumps({"package": "ash_replicant", "version": version, "commit": commit}) + "\n")
  PROVENANCE
  (cd "$work" && mix run --no-mix-exs "$root/scripts/build-docs-archive.exs" \
    "$tree/doc" "$work/docs.tar.gz")
  python3 -I "$root/scripts/check-docs-archive.py" "$work/docs.tar.gz" "$tree/doc" \
    --version "$version" --commit "$commit"
  cp "$work/docs.tar.gz" "$output"
  cp -R "$tree/doc" "$output.rendered"
  complete=true
  echo 'release docs: rendered once; archive contents and release provenance inspected'
  """

  @docs_archive_builder ~S"""
  unless is_nil(Mix.Project.get()) do
    Mix.raise("Docs archives must be built outside a Mix project")
  end

  [directory, output] = System.argv()
  directory = Path.expand(directory)

  unless File.regular?(Path.join(directory, "index.html")) do
    Mix.raise("Documentation must contain a top-level index.html")
  end

  Hex.start()
  Code.ensure_loaded!(:mix_hex_tarball)

  # The same listing mix hex.publish makes: Path.wildcard/1 matches no file or
  # directory whose name starts with a dot, so ExDoc's .build manifests stay out.
  files =
    directory
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.filter(fn path ->
      case File.lstat!(path).type do
        :regular -> true
        :directory -> false
        _other -> Mix.raise("Documentation must contain only regular files and directories")
      end
    end)
    |> Enum.map(fn path ->
      name = Path.relative_to(path, directory)
      top_level = name |> Path.split() |> List.first()

      if match?({:ok, _}, Version.parse(top_level)) do
        Mix.raise("Top-level documentation filenames cannot be semantic versions")
      end

      {String.to_charlist(name), File.read!(path)}
    end)

  # Hex 2.7.0 sorts entries, fixes times to 2000-01-01 and uid/gid to 0,
  # leaves owner/group names empty, and emits gzip without a filename or mtime.
  {:ok, data} = :mix_hex_tarball.create_docs(files)
  File.write!(output, data)
  IO.puts("Docs archive: #{output}")
  """

  @release_identity_script ~S"""
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
  """

  @fixture_audit_script ~S"""
  #!/usr/bin/env bash
  set -euo pipefail

  root="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$root"

  # Match upgrade_checkpoint_test.exs: the real consumer inherits the root lock.
  fixture="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-upgrade-audit.XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  cp -R test/fixtures/upgrade_0_4_app/. "$fixture/"
  cp mix.lock "$fixture/mix.lock"
  export ASH_REPLICANT_PATH="$root"
  (cd "$fixture" && mix deps.get --check-locked && mix hex.audit)
  mix deps.audit --path "$fixture"
  """

  @release_tree_script ~S"""
  #!/usr/bin/env bash
  set -euo pipefail

  release_tree_fail() { echo "release tree: $1" >&2; exit 1; }

  # Publication may add a version, never a package name. Read anonymously first.
  assert_hex_package_exists() {
    local name="$1" url="$2" code
    code="$(curl --silent --show-error --max-time 30 --output /dev/null \
      --write-out '%{http_code}' "$url")" || release_tree_fail "$name package lookup failed"
    case "$code" in
      200) ;;
      404) release_tree_fail "$name is not on Hex; first publication is the owner's decision" ;;
      *) release_tree_fail "$name package lookup failed" ;;
    esac
  }

  # Only an HTTP 404 proves absence. A transport error, redirect, or any other
  # response refuses publication. GitHub uses the caller's read-only job token.
  assert_release_absent() {
    local label="$1" url="$2" code
    code="$(curl --silent --show-error --max-time 30 --output /dev/null \
      --write-out '%{http_code}' "$url")" || release_tree_fail "$label lookup failed"
    case "$code" in
      404) ;;
      200) release_tree_fail "$label already exists" ;;
      *) release_tree_fail "$label lookup failed" ;;
    esac
  }

  # gh exits 1 for HTTP errors, including the 404 that proves absence. Inspect
  # the first status line and the exit code; never print the response or stderr.
  assert_github_release_absent() {
    local path="$1" response protocol code result=0
    [[ -n "${GH_TOKEN:-}" ]] || release_tree_fail 'GitHub token is required'
    response="$(gh api --hostname github.com -i "$path" 2>/dev/null)" || result=$?
    read -r protocol code _ <<< "$response"
    [[ "$protocol" == HTTP/* ]] || release_tree_fail 'GitHub release lookup failed'
    case "$code:$result" in
      404:1) ;;
      200:0) release_tree_fail 'GitHub release already exists' ;;
      *) release_tree_fail 'GitHub release lookup failed' ;;
    esac
  }

  release_tree_main() {
    local version="${1:?usage: assert-release-tree.sh VERSION TAG [--unreleased [PACKAGE DOCS]]}"
    local tag="${2:?usage: assert-release-tree.sh VERSION TAG [--unreleased [PACKAGE DOCS]]}"
    local mode="${3:-}" tag_sha result tree_status
    [[ "$#" -eq 2 || ( ( "$#" -eq 3 || "$#" -eq 5 ) && "$mode" == --unreleased ) ]] || exit 2
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_tree_fail 'invalid release version'
    [[ "$tag" == "v$version" ]] || release_tree_fail 'tag must match version'
    tree_status="$(git status --porcelain --untracked-files=all)" || release_tree_fail 'git status failed'
    [[ -z "$tree_status" ]] || release_tree_fail 'dirty tree'

    if [[ "$mode" == --unreleased ]]; then
      assert_hex_package_exists ash_replicant https://hex.pm/api/packages/ash_replicant
      [[ "$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)" == "$version" ]] \
        || release_tree_fail 'project version differs from release version'
      result=0
      git show-ref --verify --quiet "refs/tags/$tag" || result=$?
      case "$result" in
        0) release_tree_fail 'local tag already exists' ;;
        1) ;;
        *) release_tree_fail 'local tag lookup failed' ;;
      esac
      result=0
      GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || result=$?
      case "$result" in
        0) release_tree_fail 'remote tag already exists' ;;
        2) ;;
        *) release_tree_fail 'remote tag lookup failed' ;;
      esac
      assert_github_release_absent "repos/baselabs/ash_replicant/releases/tags/$tag"
      elixir "$(dirname "${BASH_SOURCE[0]}")/release_identity.exs" "$version" "${@:4}"
      echo 'release tree: version is untagged and its Hex identity is admissible'
      return
    fi

    tag_sha="$(git rev-parse --verify "refs/tags/$tag^{commit}")" || release_tree_fail 'tag cannot be resolved'
    [[ "$(git rev-parse HEAD)" == "$tag_sha" ]] || release_tree_fail 'HEAD differs from tag'
    [[ "$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)" == "$version" ]] \
      || release_tree_fail 'project version differs from release version'
    echo "$tag_sha"
  }

  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    release_tree_main "$@"
  fi
  """

  @upgrade_fixture_project """
  defmodule UpgradeFixture.MixProject do
    use Mix.Project

    def project do
      [
        app: :upgrade_fixture,
        version: "0.4.0",
        elixir: "~> 1.20",
        deps: deps(),
        # The inherited root lock has the same GCM-only policy. The source guard
        # covers this fixture too; it neither references nor configures AES-CTR.
        hex: [ignore_advisories: ["EEF-CVE-2026-95105"]]
      ]
    end

    def application do
      [extra_applications: [:logger], mod: {UpgradeFixture.Application, []}]
    end

    defp deps do
      [
        {:ash_replicant, path: System.fetch_env!("ASH_REPLICANT_PATH")},
        {:igniter, ">= 0.8.3 and < 1.0.0-0", runtime: false}
      ]
    end
  end
  """

  @github_target_lookup ~S"""
  target="$(gh api --hostname github.com "repos/baselabs/ash_replicant/releases/tags/$tag" --jq .target_commitish 2>/dev/null)" \
    || fail "GitHub release lookup failed"
  """

  @qualification_lookup ~S"""
          response = subprocess.run(
              [
                  "gh", "api", "--hostname", "github.com",
                  f"repos/{repository}/actions/runs/{run_id}/jobs"
                  f"?filter=latest&per_page=100&page={page}",
              ],
              check=True, capture_output=True, text=True, timeout=30,
          )
          body = json.loads(response.stdout)
  """

  @hex_package_guard_tests ~S"""
  assert_hex_package_exists ash_replicant https://hex.pm/api/packages/ash_replicant
  # A dot cannot occur in a Hex package name; this real name can never exist.
  reject "ash_replicant.invalid is not on Hex; first publication is the owner's decision" \
    assert_hex_package_exists ash_replicant.invalid https://hex.pm/api/packages/ash_replicant.invalid
  reject 'ash_replicant package lookup failed' assert_hex_package_exists ash_replicant https://127.0.0.1:1
  """

  @github_guard_tests ~S"""
  reject 'GitHub release already exists' assert_github_release_absent \
    repos/baselabs/ash_replicant/releases/tags/v1.6.3
  reject 'Hex release already exists' assert_release_absent 'Hex release' \
    https://hex.pm/api/packages/ash_replicant/releases/1.6.3
  assert_github_release_absent \
    repos/baselabs/ash_replicant/releases/tags/v999999.0.0
  without_github_token() (
    unset GH_TOKEN
    assert_github_release_absent "$@"
  )
  reject 'GitHub token is required' without_github_token \
    repos/baselabs/ash_replicant/releases/tags/v999999.0.0
  # A real invalid date query yields an HTTP error other than absence.
  reject 'GitHub release lookup failed' assert_github_release_absent \
    'repos/baselabs/ash_replicant/commits?since=not-a-date'
  """

  @resolve_dependencies """
  if [[ "$LOCKFILE" != 'mix.lock' ]]; then
    cp "$LOCKFILE" mix.lock
  fi
  mix deps.get --check-locked
  mix deps ash
  mix deps replicant
  mix deps ash_onetime
  scripts/assert-dependency-version.sh ash "$ASH_REQUIREMENT"
  scripts/assert-dependency-version.sh replicant "$REPLICANT_REQUIREMENT"
  scripts/assert-dependency-version.sh ash_onetime "$ONETIME_REQUIREMENT"
  """

  @drift_refusal ~S"""
  if [[ "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]]; then
    echo 'Drift reports run only on the default branch.' >&2
    exit 1
  fi
  """

  @drift_newest_checks [
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest ash",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest replicant",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest ash_onetime",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest ash_postgres",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest spark"
  ]

  @drift_resolution """
  rm mix.lock
  mix deps.get
  """

  @drift_versions ~S"""
  mix run --no-mix-exs --no-start -e '
  workspace = System.fetch_env!("GITHUB_WORKSPACE")

  versions = fn path ->
    path = Path.join(workspace, path)
    unless File.regular?(path), do: raise("dependency resolution lock is missing")

    Map.new(Mix.Dep.Lock.read(path), fn
      {name, {:hex, _, version, _, _, _, _, _}} -> {name, version}
    end)
  end

  locked = versions.("locks/latest-compatible.lock")
  resolved = versions.("mix.lock")

  (Map.keys(locked) ++ Map.keys(resolved))
  |> Enum.uniq()
  |> Enum.sort()
  |> Enum.each(fn name ->
    IO.puts("#{name}: committed=#{locked[name] || "absent"} resolved=#{resolved[name] || "absent"}")
  end)
  '
  """

  @create_database """
  mix ecto.create
  mix ecto.migrate
  """

  # New candidate refs have no prior push head. Fetch main;
  # an unavailable base or an evidence-machinery diff runs the full matrix.
  @mutation_gates_run """
  if git fetch --no-tags --quiet origin main; then
    scripts/run-mutation-gates.py --diff-base FETCH_HEAD
  else
    scripts/run-mutation-gates.py
  fi
  """

  @public_dependency_check """
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix run --no-start -e '
  deps = Mix.Project.config() |> Keyword.fetch!(:deps)

  expected = AshReplicant.DependencyRequirements.read!("mix.exs")

  public_deps = Enum.reject(deps, fn dependency ->
    options = if tuple_size(dependency) == 3, do: elem(dependency, 2), else: []
    Keyword.has_key?(options, :only)
  end)

  unless Enum.sort(Enum.map(public_deps, &elem(&1, 0))) == Enum.sort(Map.keys(expected)),
    do: raise("unexpected public dependency set")

  Enum.each(expected, fn {dependency, requirement} ->
    actual = deps |> List.keyfind!(dependency, 0) |> elem(1)
    unless actual == requirement, do: raise("unexpected public dependency requirement")
  end)
  '
  """

  @command_status_guards [
    {"scripts/with-release-runtime.sh",
     ~S"""
     pins="$("$root/scripts/toolchain.sh" "$root/.tool-versions")"
     """},
    {"scripts/with-release-runtime.sh",
     ~S"""
     "$root/scripts/toolchain.sh" --installed "elixir=$elixir_pin" "erlang=$erlang_pin"
     """},
    {"config/config.exs",
     ~S"""
     {output, status} = System.cmd(reader, [Path.join(root, ".tool-versions")], stderr_to_stdout: true)
     """},
    {"config/config.exs",
     ~S"""
     actual_elixir = System.version() <> "-otp-" <> System.build_info()[:otp_release]
     """},
    {"scripts/assert-release-tree.sh",
     ~S"""
       tree_status="$(git status --porcelain --untracked-files=all)" || release_tree_fail 'git status failed'
       [[ -z "$tree_status" ]] || release_tree_fail 'dirty tree'
     """},
    {"scripts/inspect-release-package.sh",
     ~S"""
     package_files="$(cd "$work/package" && find . \( -type f -o -type l \) | sed 's|^./||' | LC_ALL=C sort)"
     if ! diff -u "$root/scripts/release-package-files.txt" - <<<"$package_files"; then
     """},
    {"scripts/run-structural-tests.sh",
     ~S"""
     logger_error_count="$(grep -Ec '(^|[[:space:]])\[error\]' "$raw_output")" || [[ $? -eq 1 ]]
     exception_banner_count="$(grep -Ec '\*\* \(' "$raw_output")" || [[ $? -eq 1 ]]
     """},
    {"scripts/assert-exunit-output.sh",
     ~S"""
     result_count="$(grep -c '^Result: ' "$output_file")" || [[ $? -eq 1 ]]
     """},
    {"scripts/bump-version.sh",
     ~S"""
     charter_updated="$(grep -o '\*\*Updated:\*\* [0-9-]*' docs/CHARTER.md | cut -d' ' -f2)"
     """},
    {"scripts/bump-version.sh",
     ~S"""
       count="$(grep -cF "$old" "$file")" || [[ $? -eq 1 ]]
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
     grep -qF "$selector_free_build" <<<"$inspection" || {
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
       build_status=0
       grep -q 'mix hex.build' <<<"$staged" || build_status=$?
       if [[ "$build_status" -ne 1 ]]; then
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
       inspection_script="$(rebind_staging)" || return
       ASH_REPLICANT_PACKAGE_FIXTURE="$1" bash -euo pipefail -c "$inspection_script"
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
       staged="$(printf '%s\n' "$inspection" \
         | sed -e 's|^package_dir=\$(mktemp -d)$|package_dir="$ASH_REPLICANT_PACKAGE_FIXTURE"|' \
               -e "s|^${selector_free_build}\$|: # self-test staged fixture|")" || return
     """}
  ]

  @package_inspection ~S"""
  package_dir=$(mktemp -d)
  trap 'rm -rf "$package_dir"' EXIT
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix hex.build --unpack --output "$package_dir"

  for required in lib .formatter.exs mix.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md \
    lib/ash_replicant/upgrade.ex lib/ash_replicant/upgrade/checkpoint.ex \
    lib/mix/tasks/ash_replicant.upgrade.ex; do
    test -e "$package_dir/$required" || {
      echo "::error::Missing package path: $required"
      exit 1
    }
  done

  residue="$(find "$package_dir" -type d \( -name test -o -name _build -o -name '.*' ! -name . \) -print -quit)"
  if [[ -n "$residue" ]]; then
    echo "::error::Package contains test, build, or dot-directory residue"
    exit 1
  fi

  if test -e "$package_dir/priv"; then
    echo "::error::Package contains private migrations"
    exit 1
  fi

  credentials="$(find "$package_dir" -type f \( -name '.env*' -o -name '*.pem' -o -name '*.key' \) -print -quit)"
  if [[ -n "$credentials" ]]; then
    echo "::error::Package contains a credential-shaped file"
    exit 1
  fi

  package_files="$(cd "$package_dir" && find . \( -type f -o -type l \) | sed 's|^./||' | LC_ALL=C sort)"
  if ! diff -u scripts/release-package-files.txt - <<<"$package_files"; then
    echo "::error::Package files differ from the release allowlist"
    exit 1
  fi
  """

  @job_env %{
    "postgres-lanes" => nil,
    "no-database" => %{
      "MIX_ENV" => "test",
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}"
    },
    "compatibility" => %{
      "EXPECTED_PG_MAJOR" => "${{ matrix.pg_major }}",
      "MIX_ENV" => "test",
      "ASH_REPLICANT_ASH_VERSION" => "${{ matrix.ash_selector }}",
      "ASH_REPLICANT_REPLICANT_VERSION" => "${{ matrix.replicant_selector }}",
      "ASH_REPLICANT_ONETIME_VERSION" => "${{ matrix.onetime_selector }}",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
    },
    "release-artifact" => %{"MIX_ENV" => "dev"},
    "fresh-consumer" => %{
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}",
      "MIX_ENV" => "dev",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
    },
    "performance" => %{
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}",
      "MIX_ENV" => "test",
      "ASH_REPLICANT_TEST_URL" =>
        "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test",
      "ASH_REPLICANT_PERFORMANCE" => "1"
    },
    "decoder-old-majors" => %{
      "EXPECTED_PGOLD_MAJOR" => "${{ matrix.pg_major }}",
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}",
      "MIX_ENV" => "test",
      "ASH_REPLICANT_TEST_URL" =>
        "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test",
      "ASH_REPLICANT_PGOLD_URL" =>
        "postgres://postgres:postgres@127.0.0.1:5433/ash_replicant_test"
    }
  }

  @job_keys %{
    "postgres-lanes" => ~w(name outputs runs-on steps timeout-minutes),
    "no-database" => ~w(env name permissions runs-on steps timeout-minutes needs),
    "compatibility" => ~w(env name runs-on steps strategy timeout-minutes needs),
    "release-artifact" => ~w(env name runs-on steps timeout-minutes),
    "fresh-consumer" => ~w(env name permissions runs-on steps timeout-minutes needs),
    "performance" => ~w(env name runs-on steps timeout-minutes needs),
    "decoder-old-majors" => ~w(env name runs-on steps strategy timeout-minutes needs)
  }

  @job_steps %{
    "postgres-lanes" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "scripts/ci/postgres-lanes.sh", %{"id" => "lanes"}},
      {:run, "python3 -B -m unittest discover -s scripts -p 'test_postgres_lanes.py'"}
    ],
    "no-database" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors", %{"id" => "compile"}},
      {:run, "mix format --check-formatted", %{"if" => @fail_late}},
      {:run, "elixir --version", %{"if" => @fail_late}},
      {:run, "scripts/test-prepush.sh", %{"if" => @fail_late}},
      {:run, "scripts/test-release-checkers.sh", %{"if" => @fail_late}},
      {:run, "scripts/test-release-guards.sh",
       %{"if" => @fail_late, "env" => %{"GH_TOKEN" => "${{ github.token }}"}}},
      {:run, "scripts/test-release-contract.sh", %{"if" => @fail_late}},
      {:run, "python3 -B -m unittest discover -s scripts -p 'test_qualify.py'",
       %{"if" => @fail_late}},
      {:run, "mix credo --strict", %{"if" => @fail_late}},
      {:run, "mix deps.audit", %{"if" => @fail_late}},
      {:run, "scripts/audit-fixtures.sh", %{"if" => @fail_late}},
      {:run,
       "env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh --allow-excluded --exclude integration",
       %{"if" => @fail_late}},
      {:run, String.trim(@mutation_gates_run), %{"if" => @fail_late}}
    ],
    "compatibility" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @postgres_action, %{"image" => "${{ matrix.pg_image }}"}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, String.trim(@resolve_dependencies),
       %{
         "env" => %{
           "LOCKFILE" => "${{ matrix.lockfile }}",
           "ASH_REQUIREMENT" => "${{ matrix.ash_requirement }}",
           "REPLICANT_REQUIREMENT" => "${{ matrix.replicant_requirement }}",
           "ONETIME_REQUIREMENT" => "${{ matrix.onetime_requirement }}"
         }
       }},
      {:run, "mix deps.compile"},
      {:run, String.trim(@create_database)},
      {:run, "mix compile --warnings-as-errors", %{"id" => "compile"}},
      {:run, "elixir --version", %{"if" => @fail_late}},
      {:run, "scripts/test-release-checkers.sh", %{"if" => @fail_late}},
      {:run, "scripts/assert-release-contract.sh", %{"if" => @fail_late}},
      {:run, "mix deps.audit", %{"if" => @fail_late}},
      {:run, "scripts/test-migration-drift-gate.sh", %{"if" => @fail_late}},
      {:run, "scripts/run-structural-tests.sh --include integration", %{"if" => @fail_late}},
      {:run, "scripts/run-structural-tests.sh test/integration --include integration",
       %{"if" => @fail_late}},
      {:run, "mix dialyzer", %{"if" => @fail_late}},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}
    ],
    "performance" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @postgres_action, :absent},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, String.trim(@create_database)},
      {:run,
       "scripts/run-structural-tests.sh test/integration/performance_bounds_test.exs --include integration"},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}
    ],
    "decoder-old-majors" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run,
       ~S"""
       docker build -f test/support/pg_old.dockerfile --build-arg "BASE=$PG_BASE" -t pgold-plugins:ci .
       image="$(docker image inspect --format '{{.Id}}' pgold-plugins:ci)"
       printf 'image=%s\n' "$image" >> "$GITHUB_OUTPUT"
       """
       |> String.trim(), %{"id" => "plugins", "env" => %{"PG_BASE" => "${{ matrix.base }}"}}},
      {:uses, @postgres_action, :absent},
      {:uses, @postgres_action,
       %{
         "name" => "pgold",
         "port" => "5433",
         "image" => "${{ steps.plugins.outputs.image }}",
         "decoder-source" => "true"
       }},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, String.trim(@create_database)},
      {:run,
       "scripts/run-structural-tests.sh test/integration/decoder_admission_test.exs --include pgold"},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}},
      {:uses, @postgres_action, %{"mode" => "stop", "name" => "pgold", "port" => "5433"},
       %{"if" => "always()"}}
    ],
    "fresh-consumer" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:uses, @postgres_action, :absent},
      {:run, "scripts/test-fresh-consumer.sh"},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}
    ],
    "release-artifact" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run,
       "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, "elixir --version"},
      {:run, "scripts/assert-release-contract.sh"},
      {:run, String.trim(@public_dependency_check)},
      {:run, ~s(scripts/build-release-docs.sh "$RUNNER_TEMP/hex-docs.tar.gz")},
      {:run, String.trim(@upload_archive_checks)},
      {:run, String.trim(@package_inspection)}
    ]
  }

  @named_separator_entities ~w(
    af ApplyFunction emsp13 emsp14 emsp ensp hairsp ic InvisibleComma
    InvisibleTimes it lrm MediumSpace nbsp NegativeMediumSpace NegativeThickSpace
    NegativeThinSpace NegativeVeryThinSpace NewLine NoBreak NonBreakingSpace numsp
    puncsp rlm shy Tab ThickSpace thinsp ThinSpace VeryThinSpace ZeroWidthSpace zwj zwnj
  )

  defp doc_contracts(root) do
    requirements = public_requirements(root)

    [
      {"README.md", "### Supported foundation",
       [
         "- Elixir 1.20.3 on Erlang/OTP 29;",
         "- Ash `#{requirements.ash}` (current lock 3.38.1);",
         "- AshPostgres `#{requirements.ash_postgres}` (current lock 2.15.2 with AshSql 0.8.8; qualification tests the reviewed compatibility lock);",
         "- Spark `#{requirements.spark}` (effective floor 2.7.6 through Ash; current lock 2.7.9);",
         "- Replicant `#{requirements.replicant}` (current lock 1.6.0)",
         "- Postgrex `#{requirements.postgrex}` (current lock 0.23.0);",
         "- DBConnection `#{requirements.db_connection}` (current lock 2.10.3).",
         "- AshOnetime `#{requirements.ash_onetime}` (current lock 1.5.0)",
         "- AshCloak `#{requirements.ash_cloak}` (current lock 0.4.0"
       ]},
      {"CONTRIBUTING.md", "## Prerequisites",
       [
         "- **Elixir 1.20.3** and **Erlang/OTP 29**",
         "- Ash `#{requirements.ash}`; selector-free development uses this public range",
         "- Replicant `#{requirements.replicant}` from Hex; the lock is 1.6.0.",
         "- Postgrex `#{requirements.postgrex}` from Hex; the lock is 0.23.0.",
         "- DBConnection `#{requirements.db_connection}` from Hex. The lock is 2.10.3.",
         "- AshCloak `#{requirements.ash_cloak}` from Hex; the current lock is 0.4.0 (the"
       ]},
      {"AGENTS.md", "## Development workflow",
       [
         "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
           "`#{requirements.ash}` (current lock 3.38.1) and Replicant\n" <>
           "`#{requirements.replicant}` (current lock 1.6.0), plus\n" <>
           "AshOnetime `#{requirements.ash_onetime}` (current lock 1.5.0) and AshCloak\n" <>
           "`#{requirements.ash_cloak}` (current lock 0.4.0; releases below 0.4.0 carry\n" <>
           "CVE-2026-81319 and CVE-2026-81322 and are not admitted).",
         "Postgrex requires `#{requirements.postgrex}` (current lock 0.23.0)",
         "DBConnection requires `#{requirements.db_connection}` (current lock 2.10.3)."
       ]},
      {"docs/adr/0002-supported-runtime-and-dependencies.md", nil,
       [
         "Postgrex is declared `#{requirements.postgrex}`",
         "Replicant `#{requirements.replicant}`:",
         "DBConnection is declared `#{requirements.db_connection}`"
       ]},
      {"docs/adr/0005-replicant-coordination.md", nil,
       ["The public dependency is `#{requirements.replicant}`"]}
    ]
  end

  @b1_doc_contracts [
    {"README.md", "## Destination transaction boundary",
     [
       "Every admitted destination resource uses the sink's literal AshPostgres Repo and the same effective dynamic Repo.",
       "Declarations are trusted metadata; they do not prove an arbitrary Elixir body.",
       "AshOnetime one-time nonces are rejected for WAL replay.",
       "A Replicant v1 retry and incremental resume are physically effect-once for resources declaring `snapshot_provenance true`:"
     ]},
    {"usage-rules.md", "## Destination transaction boundary",
     [
       "Every admitted destination resource uses the sink's literal AshPostgres Repo and the same effective dynamic Repo.",
       "Declarations are trusted metadata; they do not prove an arbitrary Elixir body.",
       "AshOnetime one-time nonces are rejected for WAL replay.",
       "V1 retry and incremental resume are physically effect-once for opted-in resources:"
     ]},
    {"AGENTS.md", "## Critical rules",
     [
       "**6. Effect-once = one admitted destination graph, one transaction, watermark dedup.**",
       "A declaration is trusted metadata, not proof of an arbitrary body;",
       "Reject nonce, independent, external,"
     ]},
    {"docs/CHARTER.md", "## Destination and AshOnetime boundary for 1.0.0",
     [
       "The B1 implementation admits one recursive destination action graph before delivery.",
       "This verifies the declaration, not the truth of an arbitrary Elixir body",
       "Nonce and independent-commit modes are rejected for WAL retry."
     ]}
  ]

  @b1_contract_paths ["README.md", "usage-rules.md", "AGENTS.md", "docs/CHARTER.md"]
  @b1_forbidden_positive_claims [
    "Every mapped row action is protected by AshOnetime one_time_nonce.",
    "Replicant v1 snapshot retries are physically duplicate-free.",
    "DestinationParticipant proves arbitrary callback bodies contain no undeclared effects."
  ]

  @census_doc_contracts [
    {"README.md", "### 4. Start the pipeline",
     [
       "The owner continuously re-runs destination-generation, live contract,\n" <>
         "  durable checkpoint, and full source-coverage checks.",
       "Drift halts immediately; a checker fault or timeout\n" <>
         "  is never a pass and halts after the configured consecutive budget.",
       "one\n  owner never overlaps census work (ADR-0019)."
     ]},
    {"usage-rules.md", "### 4. Start the pipeline",
     [
       "Exact bounds are\n  `interval_ms: 50..86_400_000`, `jitter_ratio: 0.0..0.5`,\n" <>
         "  `timeout_ms: 1..60_000`, and `max_consecutive_faults: 1..1_000`."
     ]},
    {"usage-rules.md", "### Continuous invariant census",
     [
       "A run enters through the same admitted callback guard as\n" <>
         "delivery, including owner-liveness checks and dynamic-Repo pinning",
       "Any drift halts the temporary pipeline immediately and freezes checkpoint\nadvance.",
       "the exact configured consecutive fault\nhalts with `:census_unverifiable`."
     ]},
    {"AGENTS.md", "## Architecture (realized)",
     [
       "The same owner schedules the C01 continuous invariant census through the admitted\n" <>
         "callback guard (never a second Replicant callback)",
       "The next run is scheduled only after the\n" <>
         "current one settles. Graceful owner/application teardown drains admitted work;"
     ]}
  ]

  @census_source_contracts [
    {"lib/ash_replicant/census.ex", "@defaults %{\n"},
    {"lib/ash_replicant/census.ex", "    enabled?: true,\n"},
    {"lib/ash_replicant/census.ex", "    interval_ms: 60_000,\n"},
    {"lib/ash_replicant/census.ex", "    jitter_ratio: 0.1,\n"},
    {"lib/ash_replicant/census.ex", "    timeout_ms: 10_000,\n"},
    {"lib/ash_replicant/census.ex", "    max_consecutive_faults: 3\n"},
    {"lib/ash_replicant.ex", "{:ok, census} <- Census.options(opts),"},
    {"lib/ash_replicant.ex", "{:ok, Map.merge(admitted, %{sink: sink, census: census})}"},
    {"lib/ash_replicant/pipeline_guard.ex",
     "send(owner, {:census_result, token, Census.run(slot, sink)})"},
    {"lib/ash_replicant/pipeline_owner.ex",
     "schedule_next_census(%{state | consecutive_faults: 0, last_census: :healthy})"},
    {"lib/ash_replicant/pipeline_owner.ex",
     "halt_for_census(state, check, :census_unverifiable)"},
    {"lib/ash_replicant/telemetry.ex", "[:ash_replicant, :census, :passed],\n"},
    {"lib/ash_replicant/telemetry.ex", "[:ash_replicant, :census, :faulted],\n"},
    {"lib/ash_replicant/telemetry.ex", "[:ash_replicant, :census, :halted],\n"}
  ]

  @upgrade_doc_contracts [
    {"README.md", "### 1. Define the checkpoint resource",
     [
       "mix ash_replicant.upgrade 0.4.0 1.0.0",
       "It never infers ownership from a slot-only row."
     ]},
    {"usage-rules.md", "## Upgrading from the slot-only checkpoint",
     [
       "the 1.0.0 upgrader never infers ownership",
       "the generated migration\nrefuses without that explicit assertion",
       "restore from backup or remain on 1.0"
     ]},
    {"AGENTS.md", "## Critical rules",
     ["**10. The 0.4.0 to 1.0.0 upgrade never infers checkpoint ownership.**"]},
    {"docs/adr/0007-source-bound-checkpoint-effect-once.md", "## Decision",
     ["mix ash_replicant.upgrade 0.4.0 1.0.0", "checksummed rollback ledger"]},
    # CHANGELOG is matched whole-file, not by first-section extraction: an
    # [Unreleased] block legitimately carries its own `### Added` heading
    # ahead of the released section that owns this entry.
    {"CHANGELOG.md", nil, ["**Guarded 0.4.0 to 1.0.0 package upgrade and rollback.**"]}
  ]

  @upgrade_source_contracts [
    {"lib/ash_replicant/upgrade/checkpoint.ex", "def up(repo, opts)"},
    {"lib/ash_replicant/upgrade/checkpoint.ex", "def down(repo, opts)"},
    {"lib/ash_replicant/upgrade/checkpoint.ex", "pg_advisory_xact_lock"},
    {"lib/ash_replicant/upgrade/checkpoint.ex", "IN ACCESS EXCLUSIVE MODE"},
    {"lib/ash_replicant/upgrade/checkpoint.ex",
     "defp verify_rollback_state(repo, config, ledger)"},
    {"lib/ash_replicant/upgrade.ex", "def render_checkpoint_snapshot(repo)"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "use Igniter.Mix.Task"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "Mix.Task.run(\"compile\")"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "Application.ensure_all_started(:postgrex)"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "Checkpoint.check(plan.repo"}
  ]

  # The exact package-inspection bytes the contract enforces on the workflow.
  # The package-inspection self-test executes these bytes against staged
  # fixtures (leak + clean), so the shipped predicate is proven to REJECT, not
  # merely to exist as text.
  @doc false
  def package_inspection, do: @package_inspection

  def run(root) do
    workflow = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/qualification.yml"))
    landing = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/ci.yml"))
    drift = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/drift-report.yml"))

    publish = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/publish.yml"))

    assert_landing(landing)
    assert_publish(publish, root)
    assert_qualification(workflow, root)
    assert_drift_report(drift, root)
    assert_workflow_runners(root)
    assert_ci_sources(root)
    assert_postgres(root)
    assert_qualification_inventory(root, workflow)
    assert_runtime(workflow, root)
    assert_jobs(workflow)
    assert_compatibility(workflow)
    assert_mix_contract(root)
    assert_replicant_contract(root)
    assert_checker_wiring(root)
    assert_fresh_consumer(root)
    assert_docs(root)
    assert_b1_docs(root)
    assert_b1_examples(root)
    assert_no_b1_positive_contradictions(root)
    assert_census_contract(root)
    assert_upgrade_contract(root)
    assert_b5_absence_scans(root)
  rescue
    _error in [ParsingError, File.Error, DecodeError] -> fail("release contract input is invalid")
  end

  # U3/B5 (D6): the durable effect ledger stays ABSENT from lib/. The only
  # permitted occurrences are the exact compile-only legacy marker, activation
  # refusal, and upgrade codemod surface. No secret-shaped literal ships in lib/.
  defp assert_b5_absence_scans(root) do
    lib =
      Path.wildcard(Path.join(root, "lib/*.ex")) ++
        Path.wildcard(Path.join(root, "lib/**/*.ex"))

    lib = lib |> Enum.uniq()

    ledger_hits =
      lib
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, ix} ->
          if String.contains?(line, "apply_ledger"),
            do: [{Path.expand(path), ix + 1, String.trim(line)}],
            else: []
        end)
      end)

    sink_path = root |> Path.join(Path.join(["lib", "ash_replicant", "sink.ex"])) |> Path.expand()
    root_path = root |> Path.join(Path.join(["lib", "ash_replicant.ex"])) |> Path.expand()

    task_path =
      root
      |> Path.join(Path.join(["lib", "mix", "tasks", "ash_replicant.upgrade.ex"]))
      |> Path.expand()

    allowed_hits =
      MapSet.new([
        {sink_path, "legacy_apply_ledger? = Keyword.has_key?(opts, :apply_ledger)"},
        {sink_path,
         "# removed `apply_ledger`) must surface as a compile-time failure on the host,"},
        {sink_path, ":apply_ledger"},
        {sink_path, "\"legacy :apply_ledger marker\""},
        {sink_path, "legacy_apply_ledger?: unquote(legacy_apply_ledger?)"},
        {root_path, "%{legacy_apply_ledger?: true} ->"},
        {task_path, "compile-only `apply_ledger` marker from each explicitly bound legacy sink."},
        {task_path, "{:ok, options} <- CodeKeyword.remove_keyword_key(options, :apply_ledger) do"}
      ])

    actual_hits = MapSet.new(ledger_hits, fn {path, _line, content} -> {path, content} end)

    assert(
      length(ledger_hits) == 8 and actual_hits == allowed_hits,
      "apply_ledger must appear ONLY in the exact compile-only upgrade compatibility surface, found: #{inspect(ledger_hits)}"
    )

    secret_hits =
      lib
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, ix} ->
          # Standard base64 (the +/ alphabet), plus the URL-safe alphabet
          # ONLY for runs containing a hyphen (cross-vendor finding: base64url
          # tokens) — a bare [A-Za-z0-9_-]{40,} run matches every long
          # snake_case identifier in the source, a false-positive class, not
          # a detector. This is a tripwire, not a secret scanner.
          if Regex.match?(~r|[A-Za-z0-9+/]{40,}={0,2}|, line) or
               Regex.match?(~r|[A-Za-z0-9_-]*-[A-Za-z0-9_-]{39,}={0,2}|, line),
             do: ["#{path}:#{ix + 1}"],
             else: []
        end)
      end)

    assert(
      secret_hits == [],
      "secret-shaped literals in lib/ are a classified-boundary violation, found: #{inspect(secret_hits)}"
    )
  rescue
    _error in [File.Error] -> fail("absence-scan input is invalid")
  end

  defp assert_checker_wiring(root) do
    source = root |> Path.join("scripts/test-release-checkers.sh") |> File.read!()

    count =
      source
      |> String.split("\n")
      |> Enum.count(
        &(String.trim(&1) == "scripts/test-ash-onetime-migration-checker.sh >/dev/null")
      )

    assert(count == 1, "AshOnetime migration checker wiring is incomplete")

    inspection_count =
      source
      |> String.split("\n")
      |> Enum.count(&(String.trim(&1) == "scripts/test-release-package-inspection.sh >/dev/null"))

    assert(inspection_count == 1, "package inspection checker wiring is incomplete")

    lanes_count =
      source
      |> String.split("\n")
      |> Enum.count(
        &(String.trim(&1) ==
            "python3 -B -m unittest discover -s scripts -p 'test_postgres_lanes.py' >/dev/null")
      )

    assert(lanes_count == 1, "PostgreSQL lane checker wiring is incomplete")

    assert(
      not String.contains?(source, "scripts/test-release-guards.sh"),
      "live release guards must run only in their dedicated step"
    )
  rescue
    _error in [File.Error] -> fail("release checker wiring input is invalid")
  end

  def run_cli(root) do
    run(root)
  rescue
    error in ReleaseContractError ->
      IO.puts(:stderr, error.message)
      System.halt(1)
  end

  defp assert_fresh_consumer(root) do
    source = File.read!(Path.join(root, "scripts/test-fresh-consumer.sh"))

    assert(
      String.contains?(source, "export MIX_ENV=dev\n") and
        String.contains?(source, @fresh_consumer_audits),
      "fresh consumer must audit its resolved lock from the dev repository root"
    )
  end

  defp assert_landing(workflow) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(concurrency defaults jobs name on permissions) and
        workflow["name"] == "CI" and workflow["permissions"] == %{"contents" => "read"} and
        workflow["concurrency"] ==
          %{"group" => "ci-${{ github.ref }}", "cancel-in-progress" => true},
      "CI landing workflow control is invalid"
    )

    assert(
      workflow["on"] == %{"push" => %{"branches" => ["kci/**"]}},
      "CI trigger must qualify only candidate branch pushes"
    )

    jobs = Map.get(workflow, "jobs", %{})

    assert(
      Enum.sort(Map.keys(jobs)) == ~w(qualification qualified),
      "CI landing jobs are invalid"
    )

    assert(
      jobs["qualification"] == %{"uses" => "./.github/workflows/qualification.yml"},
      "CI qualification caller is invalid"
    )

    assert(
      jobs["qualified"] == %{
        "if" => "always()",
        "needs" => ["qualification"],
        "runs-on" => "ubuntu-24.04",
        "timeout-minutes" => 5,
        "permissions" => %{"actions" => "read", "contents" => "read"},
        "steps" => [
          %{"uses" => @checkout, "with" => %{"persist-credentials" => false}},
          %{
            "run" => "python3 scripts/qualify.py",
            "env" => %{
              "GH_TOKEN" => "${{ github.token }}",
              "QUALIFICATION_RESULT" => "${{ needs.qualification.result }}",
              "EXPECTED_CHECKS" => "${{ needs.qualification.outputs.checks }}"
            }
          }
        ]
      },
      "CI qualified verdict job contract is invalid"
    )
  end

  defp assert_qualification(workflow, root) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(defaults jobs name on permissions) and
        workflow["name"] == "Qualification" and
        workflow["permissions"] == %{"contents" => "read"},
      "qualification workflow control is invalid"
    )

    assert(
      workflow["on"] == %{
        "workflow_call" => %{
          "outputs" => %{
            "checks" => %{
              "description" => "Expected qualification check inventory",
              "value" => "${{ jobs.postgres-lanes.outputs.checks }}"
            }
          }
        }
      },
      "qualification must expose its check inventory through workflow_call only"
    )

    source = File.read!(Path.join(root, ".github/workflows/qualification.yml"))
    freshness_queries = ["--newest", "hex.pm/api/packages", "hex-release-candidates"]

    assert(
      not String.contains?(source, freshness_queries) and
        not Regex.match?(~r/\bmix\s+hex\.(?:outdated|info)\b/, source),
      "qualification must not query newest upstream releases"
    )
  end

  defp assert_drift_report(workflow, root) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(defaults jobs name on permissions) and
        workflow["name"] == "Dependency drift report" and
        workflow["permissions"] == %{"contents" => "read"} and
        workflow["on"] == %{
          "schedule" => [%{"cron" => "23 6 * * *"}],
          "workflow_dispatch" => nil
        },
      "drift report must be read-only and scheduled or dispatched only"
    )

    jobs = workflow["jobs"] || %{}
    assert(Map.keys(jobs) == ["report"], "drift report cannot supply a qualification verdict")
    job = jobs["report"]

    assert(
      Enum.sort(Map.keys(job)) == ~w(env name runs-on steps timeout-minutes) and
        job["name"] == "Upstream dependencies" and
        job["runs-on"] == "ubuntu-24.04" and job["timeout-minutes"] == 24 and
        job["env"] == %{
          "MIX_ENV" => "test",
          "ASH_REPLICANT_TEST_URL" =>
            "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
        },
      "drift report job cannot hold secrets, an environment, a cache, or write permissions"
    )

    admission = [
      {:run, String.trim(@drift_refusal),
       %{"env" => %{"DEFAULT_BRANCH" => "${{ github.event.repository.default_branch }}"}}},
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs, %{"id" => "runtime"}}
    ]

    reports =
      @drift_newest_checks ++
        [
          String.trim(@drift_resolution),
          {String.trim(@drift_versions), %{"working-directory" => "${{ runner.temp }}"}},
          "mix hex.audit",
          "mix deps.audit",
          "mix deps.compile",
          String.trim(@create_database),
          "mix compile --warnings-as-errors",
          "scripts/run-structural-tests.sh --include integration",
          "scripts/run-structural-tests.sh test/integration --include integration"
        ]

    admission =
      admission ++
        [
          {:run,
           ~S"""
           declarations="$(scripts/ci/postgres-lanes.sh --json)"
           major="$(jq -r .engine_major <<< "$declarations")"
           printf 'EXPECTED_PG_MAJOR=%s\n' "$major" >> "$GITHUB_ENV"
           """
           |> String.trim(), %{"if" => @report_if}}
        ]

    report_steps =
      Enum.map(reports, fn
        {run, controls} -> {:run, run, Map.put(controls, "if", @report_if)}
        run -> {:run, run, %{"if" => @report_if}}
      end)

    expected =
      admission ++
        List.insert_at(
          report_steps,
          10,
          {:uses, @postgres_action, :absent, %{"if" => @report_if}}
        ) ++
        [{:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}]

    assert(
      Enum.map(Map.get(job, "steps", []), &step_signature/1) == expected,
      "drift report must refuse other refs first and report every upstream check independently"
    )

    source = File.read!(Path.join(root, ".github/workflows/drift-report.yml"))
    assert(not String.contains?(source, "secrets."), "drift report must not read any secret")
    assert_runtime(workflow, root, %{"id" => "runtime"})
  end

  defp assert_publish(workflow, root) do
    assert_runtime(workflow, root)

    # Exact maps admit the registry key only in the isolated upload step,
    # and keep the published consumer outside every environment.
    expected = %{
      "name" => "Publish to Hex",
      "defaults" => %{"run" => %{"shell" => "bash"}},
      "permissions" => %{"contents" => "read"},
      "concurrency" => %{"group" => "publish", "cancel-in-progress" => false},
      "jobs" => %{
        "publish" => %{
          "name" => "Publish",
          "if" => @publish_owner_condition,
          "environment" => "publish",
          "runs-on" => "ubuntu-24.04",
          "timeout-minutes" => 5,
          "permissions" => %{"contents" => "read"},
          "env" => %{"MIX_ENV" => "dev"},
          "outputs" => %{
            "version" => "${{ steps.release.outputs.version }}",
            "published_commit" => "${{ steps.readback.outputs.published_commit }}"
          },
          "steps" => [
            %{
              "name" => "Refuse publishing outside the default branch",
              "run" => "test \"$GITHUB_REF\" = \"refs/heads/main\""
            },
            %{
              "uses" => "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
              "with" => %{"persist-credentials" => false, "fetch-depth" => 0}
            },
            %{
              "name" => "Refuse a missing, duplicated or empty release changelog section",
              "run" => "python3 -I scripts/release-notes.py"
            },
            %{"uses" => @toolchain_action, "id" => "toolchain"},
            %{"uses" => @beam_action, "with" => @runtime_inputs},
            %{"run" => "mix local.rebar --force"},
            %{
              "name" => "Refuse a tagged release or inadmissible Hex identity",
              "id" => "release",
              "env" => %{"GH_TOKEN" => "${{ github.token }}"},
              "run" => @publish_unreleased_check
            },
            %{"name" => "Fetch dependencies", "run" => "mix deps.get --check-locked"},
            %{
              "name" => "Build and inspect package and docs archives",
              "env" => %{
                "VERSION" => "${{ steps.release.outputs.version }}",
                "GH_TOKEN" => "${{ github.token }}"
              },
              "run" => @publish_package_inspection
            },
            %{
              "name" => "Upload inspected archives to hex.pm",
              "working-directory" => "${{ runner.temp }}",
              "env" => %{
                "VERSION" => "${{ steps.release.outputs.version }}",
                "HEX_API_KEY" => "${{ secrets.HEX_API_KEY }}"
              },
              "run" =>
                "mix run --no-mix-exs \"$GITHUB_WORKSPACE/scripts/publish_hex_artifacts.exs\" ash_replicant \"$VERSION\" \"$RUNNER_TEMP/package.tar\" \"$RUNNER_TEMP/hex-docs.tar.gz\""
            },
            %{
              "name" => "Read back served docs and prepare release assets without a key",
              "id" => "readback",
              "env" => %{"VERSION" => "${{ steps.release.outputs.version }}"},
              "run" =>
                "scripts/read-release-assets.sh \"$VERSION\" \"$RUNNER_TEMP/package.tar\" \"$RUNNER_TEMP/release-assets\""
            },
            %{
              "name" => "Retain verified release assets for infra",
              "uses" => "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
              "with" => %{
                "name" => "release-assets",
                "path" => "${{ runner.temp }}/release-assets/",
                "if-no-files-found" => "error",
                "retention-days" => 7
              }
            },
            %{
              "name" => "Remove release archives",
              "if" => "always()",
              "run" =>
                "rm -rf \"$RUNNER_TEMP/package.tar\" \"$RUNNER_TEMP/hex-docs.tar.gz\" \"$RUNNER_TEMP/hex-docs.tar.gz.rendered\" \"$RUNNER_TEMP/release-assets\""
            }
          ]
        },
        "published-package" => %{
          "name" => "Verify published package",
          "needs" => "publish",
          "if" => @publish_owner_condition,
          "runs-on" => "ubuntu-24.04",
          "timeout-minutes" => 90,
          "permissions" => %{"contents" => "read"},
          "env" => %{
            "MIX_ENV" => "dev",
            "VERSION" => "${{ needs.publish.outputs.version }}",
            "ASH_REPLICANT_TEST_URL" =>
              "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
          },
          "steps" => [
            %{
              "name" => "Refuse publishing outside the default branch",
              "run" => "test \"$GITHUB_REF\" = \"refs/heads/main\""
            },
            %{
              "uses" => "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
              "with" => %{"persist-credentials" => false}
            },
            %{"uses" => @toolchain_action, "id" => "toolchain"},
            %{"uses" => @beam_action, "with" => @runtime_inputs},
            %{"run" => "mix deps.get --check-locked"},
            %{"run" => "mix deps.compile"},
            %{
              "name" => "Start the published consumer's real PostgreSQL",
              "uses" => @postgres_action
            },
            %{
              "name" => "Audit and exercise the published package as a fresh consumer",
              "run" => "scripts/test-fresh-consumer.sh --from-hex \"$VERSION\""
            },
            %{
              "name" => "Remove the published consumer's PostgreSQL",
              "if" => "always()",
              "uses" => @postgres_action,
              "with" => %{"mode" => "stop"}
            }
          ]
        }
      },
      "on" => %{"workflow_dispatch" => nil}
    }

    assert(workflow == expected, "publish job contract is invalid")
    source = File.read!(Path.join(root, ".github/workflows/publish.yml"))
    assert(not String.contains?(source, "mix hex.publish"), "publish must upload inspected files")
  end

  defp assert_workflow_runners(root) do
    root
    |> Path.join(".github/workflows/*.{yml,yaml}")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      workflow = YamlElixir.read_from_file!(path)
      assert_actions(workflow)
      controls = if Path.basename(path) == "drift-report.yml", do: %{"id" => "runtime"}, else: %{}
      assert_runtime(workflow, root, controls)
      source = File.read!(path)

      assert(
        not String.contains?(source, [
          "version-file:",
          "elixir-version:",
          "otp-version:",
          ".tool-versions"
        ]) and
          not Regex.match?(~r/\b(?:elixir|erlang|otp)[_-]?(?:version)?\s*:\s*["']?[0-9]/i, source),
        "workflow runtime versions must come only from the shared reader outputs"
      )

      assert_workflow_controls(workflow, Path.basename(path) == "drift-report.yml")

      Enum.each(Map.get(workflow, "jobs", %{}), fn {name, job} ->
        if Map.has_key?(job, "uses") do
          assert(not Map.has_key?(job, "runs-on"), "workflow caller cannot select a runner")
        else
          assert(job["runs-on"] == "ubuntu-24.04", "workflow job runner must be ubuntu-24.04")
          assert_timeout(path, name, job["timeout-minutes"])
        end

        Enum.each(Map.get(job, "steps", []), fn step ->
          if String.starts_with?(Map.get(step, "uses", ""), "actions/checkout@") do
            assert(
              get_in(step, ["with", "persist-credentials"]) == false,
              "checkout must disable persisted credentials"
            )
          end
        end)
      end)
    end)
  end

  defp assert_timeout(path, name, timeout) do
    pattern = ~r/^  #{Regex.escape(name)}:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms
    [block] = Regex.run(pattern, File.read!(path)) || fail("CI job source is missing")

    if {Path.basename(path), name} in [
         {"publish.yml", "published-package"},
         {"qualification.yml", "postgres-lanes"}
       ] do
      assert(
        timeout == 90 and
          String.contains?(block, "    timeout-minutes: 90 # no green run yet\n"),
        "unmeasured job timeout must be 90 # no green run yet"
      )
    else
      assert_measured_timeout(block, timeout)
    end
  end

  defp assert_measured_timeout(block, timeout) do
    case Regex.run(~r/# Green run ([0-9]+):[^\n]*?([0-9]+)m([0-9]+)s/, block) do
      [_comment, run, minutes, seconds] ->
        measured = String.to_integer(minutes) * 60 + String.to_integer(seconds)
        expected = if measured < 150, do: 5, else: div(2 * measured + 59, 60)

        assert(
          run in ~w(44208487858 44214414813 44224060553 44227674373 44554148819 44572306314 44736595182 44738538737 44765244702 44884720928) and
            measured > 0 and measured <= 2700 and is_integer(timeout) and timeout <= 90 and
            timeout == expected,
          "CI timeout must follow its slowest measured green run and infra's 5-minute floor"
        )

      _missing ->
        fail("CI timeout needs its measured green run and duration comment")
    end
  end

  defp assert_ci_sources(root) do
    shell_scripts = Path.wildcard(Path.join(root, "scripts/**/*.sh"))
    assert(shell_scripts != [], "CI shell script inventory is missing")

    Enum.each(shell_scripts, fn path ->
      source = File.read!(path)

      assert(
        String.starts_with?(source, "#!/usr/bin/env bash\n") and
          String.contains?(source, "\nset -euo pipefail\n"),
        "CI shell scripts must use bash with errexit, nounset and pipefail"
      )
    end)

    Enum.each(@command_status_guards, fn {path, expected} ->
      assert(
        String.contains?(File.read!(Path.join(root, path)), expected),
        "CI command status must reach its check"
      )
    end)

    for {path, expected} <- [
          {"scripts/audit-fixtures.sh", @fixture_audit_script},
          {"scripts/assert-release-tree.sh", @release_tree_script},
          {"scripts/publish_hex_artifacts.exs", @publish_hex_artifacts_script},
          {"scripts/check-docs-archive.py", @docs_inspection_script},
          {"scripts/release-notes.py", @release_notes_script},
          {"scripts/build-release-docs.sh", @docs_build_script},
          {"scripts/read-release-assets.sh", @read_release_assets_script},
          {"scripts/build-docs-archive.exs", @docs_archive_builder},
          {"scripts/release_identity.exs", @release_identity_script},
          {"scripts/test_publish_hex_artifacts.exs", @publish_hex_artifacts_tests},
          {"scripts/test_release_docs.py", @docs_inspection_tests},
          {"test/fixtures/upgrade_0_4_app/mix.exs", @upgrade_fixture_project}
        ] do
      assert(
        File.read!(Path.join(root, path)) == expected,
        "CI safety script contract is invalid"
      )
    end

    for {path, expected} <- [
          {"scripts/verify-release.sh", @github_target_lookup},
          {"scripts/qualify.py", @qualification_lookup},
          {"scripts/test-release-guards.sh", @github_guard_tests},
          {"scripts/test-release-guards.sh", @hex_package_guard_tests}
        ] do
      source = File.read!(Path.join(root, path))
      assert(String.contains?(source, expected), "GitHub API lookup contract is invalid")
    end

    for path <- ["scripts/verify-release.sh", "scripts/qualify.py"] do
      source = File.read!(Path.join(root, path))

      required =
        if String.ends_with?(path, ".py"),
          do: ~s|if not os.environ.get("GH_TOKEN"):|,
          else: ~s([[ -n "${GH_TOKEN:-}" ]] || fail "GitHub token is required")

      assert(
        String.contains?(source, required),
        "GitHub lookup must require its environment token"
      )
    end

    upgrade = File.read!(Path.join(root, "test/integration/upgrade_checkpoint_test.exs"))

    assert(
      String.contains?(
        upgrade,
        ~s|assert_cmd!(:deps_get, mix, ["deps.get", "--check-locked"], temp, env)|
      ),
      "upgrade consumer must fetch its inherited lock without changes"
    )

    checker = Path.join(root, "test/fixtures/release_checker")

    assert(
      not File.exists?(Path.join(checker, "mix.exs")) and
        not File.exists?(Path.join(checker, "mix.lock")) and
        File.regular?(Path.join(checker, "recorded.lock")),
      "release checker fixtures must be recorded data, never an Elixir project"
    )

    for label <- ["exact-floors", "latest-compatible"] do
      path = Path.join(root, "locks/#{label}.lock")
      assert(File.read!(path) != "", "compatibility lane needs a committed lock")
    end
  end

  defp postgres_declarations(root) do
    root = Path.expand(root)

    reader = Path.join(root, "scripts/ci/postgres-lanes.sh")
    {output, status} = System.cmd(reader, ["--json", root], stderr_to_stdout: true)

    assert(status == 0, "PostgreSQL lane reader refused its declarations")
    Jason.decode!(output)
  end

  defp assert_postgres(root) do
    assert(
      not File.exists?(Path.join(root, ".github/dependency-lanes.json")),
      "CI dependency lanes must derive from Mix declarations"
    )

    declarations = postgres_declarations(root)

    assert(
      declarations["compatibility"]
      |> Enum.take(3)
      |> Enum.map(&Map.drop(&1, ["pg_major", "pg_image"])) ==
        DependencyLanes.lanes(public_requirements(root)),
      "CI dependency matrix is invalid"
    )

    action = YamlElixir.read_from_file!(Path.join(root, ".github/actions/postgres/action.yml"))
    [check, manage] = get_in(action, ["runs", "steps"])

    assert(
      get_in(action, ["runs", "using"]) == "composite",
      "PostgreSQL action must be composite"
    )

    assert(
      check["name"] == "Check the public platform engine and pull its digest" and
        check["if"] == "inputs.mode == 'start' && inputs.image == ''" and
        check["shell"] == "bash" and check["run"] == @public_engine_check,
      "public PostgreSQL digest check is invalid"
    )

    assert(
      manage["if"] == "always() && (inputs.mode == 'stop' || success())" and
        manage["shell"] == "bash" and manage["run"] == @postgres_manage,
      "PostgreSQL startup, readiness or cleanup is invalid"
    )

    assert(
      manage["env"] == %{
        "MODE" => "${{ inputs.mode }}",
        "CONTAINER" => "${{ inputs.name }}",
        "PORT" => "${{ inputs.port }}",
        "IMAGE" => "${{ inputs.image }}",
        "DECODER_SOURCE" => "${{ inputs.decoder-source }}",
        "TEST_PG_USER" => "postgres",
        "TEST_PG_PASSWORD" => "postgres",
        "TEST_PG_DATABASE" => "ash_replicant_test",
        "POSTGRES_USER" => "postgres",
        "POSTGRES_PASSWORD" => "postgres",
        "POSTGRES_DB" => "ash_replicant_test"
      },
      "PostgreSQL fixture environment is invalid"
    )

    dockerfile = File.read!(Path.join(root, "test/support/pg_old.dockerfile"))

    assert(
      Regex.match?(~r/^ARG BASE$/m, dockerfile) and
        not Regex.match?(~r/ARG BASE=|@sha256:/, dockerfile) and
        String.contains?(dockerfile, ~s("postgresql-server-dev-$PG_MAJOR=$PG_VERSION")) and
        String.contains?(dockerfile, "https://apt-archive.postgresql.org") and
        String.contains?(
          dockerfile,
          ~s|*) echo "unsupported plugin source major" >&2; exit 1|
        ) and
        String.contains?(dockerfile, "COPY --from=build /plugins/ /"),
      "plugin builds must use declared bases, exact archived headers and staged plugin files"
    )

    for row <- declarations["decoder"] do
      assert(
        String.contains?(dockerfile, row["pg_major"] <> ")"),
        "plugin source major must have an explicit build branch"
      )
    end

    for [_, commit] <- Regex.scan(~r/git checkout --quiet ([^;\s]+)/, dockerfile) do
      assert(Regex.match?(~r/\A[0-9a-f]{40}\z/, commit), "plugin source commit must be immutable")
    end

    for path <- Path.wildcard(Path.join(root, ".github/workflows/*.yml")) do
      source = File.read!(path)

      assert(
        not Regex.match?(
          ~r/postgres:[0-9]|ghcr\.io\/baselabs\/postgres|PostgreSQL [0-9]|pg_major:\s*["']?[0-9]|docker (run|rm)/,
          source
        ),
        "workflows must use PostgreSQL declarations and the composite action"
      )
    end
  end

  defp assert_qualification_inventory(root, workflow) do
    declarations = postgres_declarations(root)

    expected =
      workflow
      |> Map.fetch!("jobs")
      |> Enum.flat_map(fn {_id, job} ->
        rows =
          case get_in(job, ["strategy", "matrix", "include"]) do
            "${{ fromJSON(needs.postgres-lanes.outputs.compatibility) }}" ->
              declarations["compatibility"]

            "${{ fromJSON(needs.postgres-lanes.outputs.decoder) }}" ->
              declarations["decoder"]

            nil ->
              [%{}]

            _other ->
              fail("qualification matrix must come from the lane reader")
          end

        Enum.map(rows, &qualification_check_name(job["name"], &1))
      end)
      |> Enum.sort()

    inventory = declarations["checks"]

    assert(inventory == expected, "qualification check inventory differs from proof jobs")
  end

  defp qualification_check_name(name, row) do
    assert(is_binary(name), "qualification proof job name is missing")

    expanded =
      Regex.replace(~r/\$\{\{\s*matrix\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/, name, fn _match, key ->
        value = Map.get(row, key) || fail("qualification job matrix name is incomplete")
        to_string(value)
      end)

    assert(
      not String.contains?(expanded, "${{"),
      "qualification proof job name expression is invalid"
    )

    "qualification / " <> expanded
  end

  # Every installation consumes reader outputs and refuses an installed mismatch.
  defp assert_runtime(workflow, root, controls \\ %{}) do
    assert_toolchain_actions(root)
    pinned_runtime(root)
    assert(not Map.has_key?(workflow, "env"), "CI runtime must come only from the reader")

    for {_name, job} <- Map.get(workflow, "jobs", %{}),
        {step, index} <- Enum.with_index(Map.get(job, "steps", [])) do
      assert(
        not String.starts_with?(Map.get(step, "uses", ""), "erlef/setup-beam@"),
        "runtime installation must use the shared BEAM action"
      )

      if step["uses"] == @beam_action do
        assert(
          step == Map.merge(%{"uses" => @beam_action, "with" => @runtime_inputs}, controls),
          "runtime inputs must be unmodified reader outputs"
        )

        assert(
          index > 0 and
            Enum.at(job["steps"], index - 1) ==
              %{"uses" => @toolchain_action, "id" => "toolchain"},
          "runtime installation must follow the unconditional shared reader"
        )
      end
    end
  end

  defp assert_toolchain_actions(root) do
    path = Path.join(root, "scripts/toolchain.sh")
    digest = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    assert(
      digest == @toolchain_sha256 and Bitwise.band(File.stat!(path).mode, 0o7777) == 0o755,
      "shared toolchain reader bytes or mode differ from the pin"
    )

    toolchain =
      YamlElixir.read_from_file!(Path.join(root, ".github/actions/toolchain/action.yml"))

    beam = YamlElixir.read_from_file!(Path.join(root, ".github/actions/beam/action.yml"))

    outputs = %{
      "elixir" => %{
        "description" => "Exact Elixir version and OTP build suffix.",
        "value" => "${{ steps.versions.outputs.elixir }}"
      },
      "otp" => %{
        "description" => "Exact OTP version.",
        "value" => "${{ steps.versions.outputs.otp }}"
      }
    }

    reader_runs = %{
      "using" => "composite",
      "steps" => [
        %{
          "name" => "Test the shared toolchain reader",
          "shell" => "bash",
          "run" => "scripts/toolchain.sh --self-test"
        },
        %{
          "name" => "Read the checkout runtime",
          "id" => "versions",
          "shell" => "bash",
          "run" => ~s(scripts/toolchain.sh >> "$GITHUB_OUTPUT")
        }
      ]
    }

    assert(
      not Map.has_key?(toolchain, "inputs") and toolchain["outputs"] == outputs and
        toolchain["runs"] == reader_runs,
      "toolchain action must test and call the reader by path and expose its outputs"
    )

    inputs = %{
      "elixir" => %{
        "description" => "Exact Elixir version and OTP build suffix from the reader.",
        "required" => true
      },
      "otp" => %{"description" => "Exact OTP version from the reader.", "required" => true}
    }

    beam_runs = %{
      "using" => "composite",
      "steps" => [
        %{
          "uses" => @setup_beam,
          "with" => %{
            "elixir-version" => "${{ inputs.elixir }}",
            "otp-version" => "${{ inputs.otp }}",
            "version-type" => "strict",
            "install-hex" => false
          }
        },
        %{
          "name" => "Refuse a runtime other than the reader names",
          "shell" => "bash",
          "env" => %{"WANT_ELIXIR" => "${{ inputs.elixir }}", "WANT_OTP" => "${{ inputs.otp }}"},
          "run" =>
            ~s("$GITHUB_WORKSPACE/scripts/toolchain.sh" --installed "elixir=$WANT_ELIXIR" "erlang=$WANT_OTP")
        },
        %{
          "name" => "Install and verify the pinned Hex client",
          "shell" => "bash",
          "working-directory" => "${{ runner.temp }}",
          "env" => %{"WANT_HEX" => "2.7.0"},
          "run" => @install_hex
        }
      ]
    }

    assert(
      beam["inputs"] == inputs and beam["runs"] == beam_runs,
      "BEAM action must install strictly, immediately check the runtime and verify pinned Hex"
    )
  end

  defp pinned_runtime(root) do
    {output, status} =
      System.cmd(
        Path.join(Path.expand(root), "scripts/toolchain.sh"),
        [Path.join(Path.expand(root), ".tool-versions")],
        stderr_to_stdout: true
      )

    assert(status == 0, "shared toolchain reader refused its declarations")

    pins =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [name, version] = String.split(line, "=", parts: 2)
        {name, version}
      end)

    elixir = Map.get(pins, "elixir", "")
    otp = Map.get(pins, "otp", "")
    assert(Regex.match?(~r/\A\d+\.\d+\.\d+-otp-\d+\z/, elixir), "Elixir pin must be exact")
    assert(Regex.match?(~r/\A\d+(\.\d+)+\z/, otp), "OTP pin must be exact")
    {elixir |> String.split("-otp-") |> hd(), otp}
  end

  defp assert_actions(workflow) do
    actions = semantic_uses(workflow)

    assert(actions != [], "CI Action contract is incomplete")

    assert(
      Enum.all?(actions, &(not String.starts_with?(String.downcase(&1), "actions/cache"))),
      "CI workflows must not use actions/cache"
    )

    assert(
      Enum.all?(actions, fn action ->
        is_binary(action) and
          (String.starts_with?(action, "./") or Regex.match?(@immutable_action, action))
      end),
      "CI contains a non-immutable Action reference"
    )
  end

  defp semantic_uses(workflow) do
    workflow
    |> Map.get("jobs", %{})
    |> Enum.flat_map(fn {_name, job} ->
      job_actions = if is_binary(job["uses"]), do: [job["uses"]], else: []
      step_actions = job |> Map.get("steps", []) |> Enum.map(&Map.get(&1, "uses"))
      job_actions ++ Enum.filter(step_actions, &is_binary/1)
    end)
  end

  defp assert_workflow_controls(workflow, drift_report?) do
    triggers = workflow["on"]
    events = if is_map(triggers), do: Map.keys(triggers), else: List.wrap(triggers)

    assert(
      Enum.all?(events, &(&1 not in ["pull_request", "pull_request_target"])),
      "CI must not run repository code from a pull request"
    )

    for {_name, job} <- Map.get(workflow, "jobs", %{}), step <- Map.get(job, "steps", []) do
      run = Map.get(step, "run", "")

      assert(
        is_binary(run) and not String.contains?(run, "${{"),
        "workflow expressions must enter run scripts through step env"
      )

      unless drift_report? do
        fetches = Regex.scan(~r/\bmix\s+deps\.get\b([^\n;&|]*)/, run)

        assert(
          not Regex.match?(~r/\bmix\s+deps\.(?:unlock|update)\b/, run) and
            Enum.all?(fetches, fn [_command, args] ->
              String.contains?(args, "--check-locked")
            end),
          "upstream resolution belongs only in a drift report, never qualification or publication"
        )
      end
    end

    assert(
      workflow["defaults"] == %{"run" => %{"shell" => "bash"}},
      "every workflow must default to bash with pipefail"
    )

    Enum.each(Map.get(workflow, "jobs", %{}), fn {_name, job} ->
      assert(not Map.has_key?(job, "defaults"), "CI jobs must inherit the workflow shell")

      Enum.each(Map.get(job, "steps", []), fn step ->
        assert(Map.get(step, "shell", "bash") == "bash", "CI steps must use bash with pipefail")
      end)
    end)

    assert(
      Enum.all?(Map.get(workflow, "jobs", %{}), fn {_name, job} ->
        not Map.has_key?(job, "continue-on-error") and
          Enum.all?(Map.get(job, "steps", []), &(not Map.has_key?(&1, "continue-on-error")))
      end),
      "CI cannot continue on error"
    )
  end

  defp assert_jobs(workflow) do
    jobs = Map.get(workflow, "jobs", %{})

    assert(
      Enum.sort(Map.keys(jobs)) == Enum.sort(Map.keys(@job_steps)),
      "qualification proof job inventory is invalid"
    )

    Enum.each(@job_steps, fn {name, expected_steps} ->
      job = jobs[name] || fail("CI release jobs are incomplete")

      assert(
        Enum.sort(Map.keys(job)) == Enum.sort(@job_keys[name]),
        "CI release job control is invalid"
      )

      assert(job["runs-on"] == "ubuntu-24.04", "CI release runner is invalid")
      assert(job["env"] == @job_env[name], "CI release job environment is invalid")

      if name in [
           "no-database",
           "compatibility",
           "performance",
           "decoder-old-majors",
           "fresh-consumer"
         ] do
        assert(job["needs"] == "postgres-lanes", "database lanes must use the declaration job")
      end

      if name == "postgres-lanes" do
        assert(
          job["outputs"] == %{
            "engine_major" => "${{ steps.lanes.outputs.engine_major }}",
            "compatibility" => "${{ steps.lanes.outputs.compatibility }}",
            "decoder" => "${{ steps.lanes.outputs.decoder }}",
            "checks" => "${{ steps.lanes.outputs.checks }}"
          },
          "PostgreSQL lane outputs are invalid"
        )
      end

      if name in ["no-database", "fresh-consumer"] do
        assert(
          job["permissions"] == %{"contents" => "read"},
          "release guards need read-only contents"
        )
      end

      assert(
        Enum.map(Map.get(job, "steps", []), &step_signature/1) == expected_steps,
        "CI release step contract is invalid"
      )
    end)
  end

  defp step_signature(%{"run" => run} = step) when is_binary(run) do
    assert(
      Map.keys(step) -- ["name", "run", "id", "if", "env", "working-directory", "shell"] == [],
      "CI release run step control is invalid"
    )

    # Controls participate in the exact per-job signature, including the token
    # environment admitted only for the dedicated live release-guard step.
    case Map.take(step, ["id", "if", "env", "working-directory", "shell"]) do
      controls when map_size(controls) == 0 -> {:run, String.trim(run)}
      controls -> {:run, String.trim(run), controls}
    end
  end

  defp step_signature(%{"uses" => action} = step) when is_binary(action) do
    assert(
      Map.keys(step) -- ["name", "uses", "with", "id", "if"] == [],
      "CI release Action step control is invalid"
    )

    signature = {:uses, action, Map.get(step, "with", :absent)}

    case Map.take(step, ["id", "if"]) do
      controls when map_size(controls) == 0 -> signature
      controls -> Tuple.insert_at(signature, tuple_size(signature), controls)
    end
  end

  defp step_signature(_step), do: fail("CI release step is invalid")

  defp assert_compatibility(workflow) do
    job = get_in(workflow, ["jobs", "compatibility"]) || fail("CI compatibility job is missing")

    assert(
      job["strategy"] == %{
        "fail-fast" => false,
        "matrix" => %{"include" => "${{ fromJSON(needs.postgres-lanes.outputs.compatibility) }}"}
      },
      "CI Ash compatibility matrix is invalid"
    )
  end

  defp assert_mix_contract(root) do
    ast = root |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!()
    body = mix_project_body(ast)
    projects = find_definitions(body, :def, :project)
    dependency_lists = find_definitions(body, :defp, :deps)
    public_requirements(root)
    docs = find_definitions(body, :defp, :docs)
    [dependencies] = dependency_lists

    assert(
      match?([[main: _, formatters: ["html", "markdown"], source_ref: _, extras: _]], docs) and
        Enum.any?(dependencies, fn dependency ->
          match?(
            {:{}, _, [:ex_doc, "== 0.40.4", [only: :dev, runtime: false]]},
            dependency
          )
        end),
      "docs must pin ExDoc 0.40.4 and ship HTML and Markdown only"
    )

    assert(
      exact_project_contract?(projects) and
        Enum.any?(dependencies, fn dependency ->
          match?(
            {:{}, _, [:igniter, {:@, _, [{:igniter_requirement, _, _}]}, [optional: true]]},
            dependency
          )
        end) and
        Enum.any?(dependencies, fn dependency ->
          match?({:db_connection, {:@, _, [{:db_connection_requirement, _, _}]}}, dependency)
        end),
      "Mix release contract is incomplete"
    )
  rescue
    _error in [SyntaxError, TokenMissingError] -> fail("Mix release contract is invalid")
  end

  defp mix_project_body(
         {:defmodule, _, [{:__aliases__, _, [:AshReplicant, :MixProject]}, [do: body]]}
       ),
       do: block_expressions(body)

  defp mix_project_body(_ast), do: fail("Mix release contract is incomplete")

  defp exact_project_contract?([project]) when is_list(project) do
    Keyword.get_values(project, :elixir) == ["~> 1.20.3"] and
      match?(
        {:|>, _, [{:deps, _, []}, {:select_requirements, _, []}]},
        Keyword.get(project, :deps)
      )
  end

  defp exact_project_contract?(_projects), do: false

  defp public_requirements(root) do
    DependencyRequirements.read!(Path.join(root, "mix.exs"))
  rescue
    ArgumentError -> fail("Mix release contract is invalid")
  end

  defp assert_replicant_contract(root) do
    lock = root |> Path.join("mix.lock") |> File.read!()
    requirements = public_requirements(root)

    assert_hex_lock(
      lock,
      "replicant",
      expected_replicant_lock_version(lock, requirements.replicant)
    )

    assert(
      Version.match?(hex_lock_version(lock, "postgrex"), requirements.postgrex),
      "Postgrex dependency lock contract is incomplete"
    )

    assert(
      Version.match?(hex_lock_version(lock, "db_connection"), requirements.db_connection),
      "DBConnection dependency lock contract is incomplete"
    )

    session_source = read_dependency_source!(root, "lib/replicant/session_identity.ex")
    sink_source = read_dependency_source!(root, "lib/replicant/sink.ex")
    connection_source = read_dependency_source!(root, "lib/replicant/connection.ex")

    assert(
      String.contains?(session_source, "defmodule Replicant.SessionIdentity"),
      "Replicant package contract is incomplete"
    )

    assert(
      String.contains?(sink_source, "@callback handle_session_identity"),
      "Replicant package contract is incomplete"
    )

    assert(
      String.contains?(sink_source, "@callback handle_slot_origin") and
        String.contains?(sink_source, "def notify_slot_origin"),
      "Replicant checkpoint/slot contract is incomplete"
    )

    assert_replicant_fixed_floor_contract(root, connection_source)

    assert(
      semantic_identity_gate?(connection_source),
      "Replicant actual-session ordering contract is incomplete"
    )
  rescue
    _error in [File.Error, SyntaxError, TokenMissingError] ->
      fail("Replicant package contract input is invalid")
  end

  defp assert_replicant_fixed_floor_contract(root, connection_source) do
    telemetry_source = read_dependency_source!(root, "lib/replicant/telemetry.ex")

    incremental_source =
      read_dependency_source!(root, "lib/replicant/snapshotter/incremental.ex")

    sink_source = read_dependency_source!(root, "lib/replicant/sink.ex")

    assert(
      String.contains?(connection_source, "reason: :checkpoint_unknown"),
      "Replicant checkpoint/slot contract is incomplete"
    )

    assert(
      Regex.match?(~r/^\s*@meta_shapes %\{$/m, telemetry_source) and
        String.contains?(telemetry_source, "def validate_measurements!") and
        String.contains?(
          telemetry_source,
          ~s|validate_shapes!(meta, @meta_shapes, "metadata")|
        ),
      "Replicant typed-telemetry contract is incomplete"
    )

    assert(
      Regex.match?(~r/^\s*@max_table_attempts 3\s*$/m, incremental_source) and
        Regex.match?(
          ~r/^\s*def keyed_retry_decision\(attempts, _qualified, :window_reset\)/m,
          incremental_source
        ) and
        String.contains?(incremental_source, "attempt >= @max_table_attempts"),
      "Replicant keyed-contention contract is incomplete"
    )

    assert(
      String.contains?(sink_source, "binary() | nil | :backfill_pending") and
        String.contains?(connection_source, "def classify_progress({:ok, :backfill_pending})") and
        String.contains?(
          incremental_source,
          "def classify_durable_progress(:backfill_pending, :sink_owned)"
        ),
      "Replicant pending-backfill contract is incomplete"
    )

    assert(
      String.contains?(
        connection_source,
        "Replicant.Sink.sink_kind(state.sink) != :append_log"
      ),
      "Replicant append idle-advance contract is incomplete"
    )
  end

  defp expected_replicant_lock_version(lock, requirement) do
    case System.get_env("ASH_REPLICANT_REPLICANT_VERSION") do
      value when value in [nil, ""] ->
        lock |> hex_lock_version("replicant") |> validate_replicant_lock_version!(requirement)

      "latest" ->
        lock
        |> hex_lock_version("replicant")
        |> validate_replicant_lock_version!(requirement)

      value ->
        validate_replicant_lock_version!(value, requirement)
    end
  end

  defp validate_replicant_lock_version!(value, requirement) do
    with true <- is_binary(value),
         {:ok, _version} <- Version.parse(value),
         true <- Version.match?(value, requirement) do
      value
    else
      _other -> fail("Replicant dependency lock contract is incomplete")
    end
  end

  defp assert_hex_lock(lock, dependency, expected_version) do
    assert(
      hex_lock_version(lock, dependency) == expected_version,
      "Replicant dependency lock contract is incomplete"
    )
  end

  defp hex_lock_version(lock, dependency) do
    escaped_dependency = Regex.escape(dependency)

    pattern =
      Regex.compile!(
        "^\\s*\"#{escaped_dependency}\": \\{:hex, :#{escaped_dependency}, \"([^\"]+)\", " <>
          "\"[0-9a-f]{64}\", \\[[^\\n]*\\], \\[[^\\n]*\\], \"hexpm\", \"[0-9a-f]{64}\"\\},$",
        "m"
      )

    case Regex.run(pattern, lock) do
      [_entry, version] -> version
      _other -> fail("Replicant dependency lock contract is incomplete")
    end
  end

  defp read_dependency_source!(root, path),
    do: root |> Path.join("deps/replicant") |> Path.join(path) |> File.read!()

  defp semantic_identity_gate?(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:handle_result, _, _} = head, [do: body]]} = node, clauses ->
          {node, [{head, body} | clauses]}

        node, clauses ->
          {node, clauses}
      end)

    Enum.any?(clauses, fn {head, body} ->
      String.contains?(Macro.to_string(head), "step: :identity_check") and
        exact_identity_gate_body?(body)
    end)
  end

  defp exact_identity_gate_body?({:with, _, [first, second, [do: success, else: _failure]]}) do
    match?({:<-, _, [_, _]}, first) and
      match?({:<-, _, [_, _]}, second) and
      first |> generator_rhs() |> Macro.to_string() ==
        "Replicant.SessionIdentity.from_result(result)" and
      second
      |> generator_rhs()
      |> Macro.to_string()
      |> String.starts_with?("Replicant.Sink.accept_session_identity(state.sink, identity,") and
      Macro.to_string(success) == "begin_recovery(state)"
  end

  defp exact_identity_gate_body?(_body), do: false

  defp generator_rhs({:<-, _, [_pattern, rhs]}), do: rhs

  defp find_definitions(expressions, kind, name) do
    Enum.flat_map(expressions, fn
      {^kind, _, [{^name, _, context}, [do: body]]} when context in [nil, []] -> [body]
      _node -> []
    end)
  end

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp assert_docs(root) do
    paths = ~w(AGENTS.md CONTRIBUTING.md docs/adr/0002-supported-runtime-and-dependencies.md)

    for path <- paths do
      source = File.read!(Path.join(root, path))

      assert(
        not String.contains?(source, "kci/lock-bootstrap-ash") and
          not String.contains?(source, "uses `mix deps.unlock --all`"),
        "docs must not prescribe an upstream-resolution qualification workflow"
      )
    end

    Enum.each(doc_contracts(root), fn {path, heading, required_texts} ->
      visible = root |> Path.join(path) |> File.read!() |> visible_markdown()
      section = section(visible, heading)

      assert(section != nil, "published runtime or dependency contract section is missing")
      normalized_section = normalize_markdown(section)

      assert(
        Enum.all?(required_texts, &String.contains?(normalized_section, normalize_markdown(&1))),
        "published runtime or dependency contract is incomplete"
      )

      assert(
        not Regex.match?(
          ~r/(?:unsupported release foundation|does(?:[\s\p{Cf}]+not|n't)[\s\p{Cf}]+support[\s\p{Cf}]*(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.33\.4|Replicant 1(?:\.x|\.\d+(?:\.\d+)?))|(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.33\.4|Replicant 1(?:\.x|\.\d+(?:\.\d+)?))[\s\p{Cf}]*(?:is[\s\p{Cf}]+)?not[\s\p{Cf}]+supported)/iu,
          visible
        ),
        "published runtime or dependency contract is contradictory"
      )
    end)
  end

  defp assert_b1_docs(root) do
    Enum.each(@b1_doc_contracts, fn {path, heading, required_texts} ->
      visible = root |> Path.join(path) |> File.read!() |> visible_markdown()
      section = section(visible, heading)

      assert(section != nil, "published destination boundary section is missing")
      normalized_section = normalize_markdown(section)

      assert(
        Enum.all?(required_texts, &String.contains?(normalized_section, normalize_markdown(&1))),
        "published destination boundary contract is incomplete"
      )
    end)
  end

  defp assert_b1_examples(root) do
    Enum.each(["README.md", "usage-rules.md"], fn path ->
      content = root |> Path.join(path) |> File.read!()

      pattern =
        Regex.compile!(
          Regex.escape(@participant_example_start) <>
            "\\s*```elixir\\s*\\n(?<source>.*?)\\n```\\s*" <>
            Regex.escape(@participant_example_end),
          "s"
        )

      case Regex.scan(pattern, content, capture: :all_names) do
        [[source]] -> compile_b1_example(source, path)
        _matches -> fail("published destination participant example count is invalid")
      end
    end)
  end

  defp compile_b1_example(source, path) do
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          {:ok, Code.compile_string(source, path)}
        rescue
          _error -> :error
        catch
          _kind, _reason -> :error
        end
      end)

    compiled =
      case {result, diagnostics} do
        {{:ok, [_ | _] = compiled}, []} -> compiled
        _other -> fail("published destination participant example does not compile cleanly")
      end

    Enum.each(compiled, fn {module, _binary} ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp assert_no_b1_positive_contradictions(root) do
    visible =
      @b1_contract_paths
      |> Enum.map_join("\n", fn path ->
        root |> Path.join(path) |> File.read!() |> visible_markdown()
      end)
      |> normalize_markdown()
      |> String.downcase()

    assert(
      Enum.all?(@b1_forbidden_positive_claims, fn claim ->
        not String.contains?(visible, claim |> normalize_markdown() |> String.downcase())
      end),
      "published destination boundary contract contains a stale positive claim"
    )
  end

  defp assert_census_contract(root) do
    Enum.each(@census_doc_contracts, fn {path, heading, required_texts} ->
      content = root |> Path.join(path) |> File.read!() |> visible_markdown()
      section = section(content, heading)

      assert(section != nil, "published continuous-census contract section is missing")

      normalized_section = normalize_markdown(section)

      assert(
        Enum.all?(required_texts, &String.contains?(normalized_section, normalize_markdown(&1))),
        "published continuous-census contract is incomplete"
      )
    end)

    Enum.each(@census_source_contracts, fn {path, required} ->
      source = root |> Path.join(path) |> File.read!()

      assert(
        String.contains?(source, required),
        "continuous-census package contract is incomplete"
      )
    end)
  rescue
    _error in [File.Error] -> fail("continuous-census package contract input is invalid")
  end

  defp assert_upgrade_contract(root) do
    Enum.each(@upgrade_doc_contracts, fn {path, heading, required_texts} ->
      visible = root |> Path.join(path) |> File.read!() |> visible_markdown()

      if is_nil(heading) do
        # Whole-file pins: the entry must exist, wherever the changelog
        # structure places it.
        assert(
          Enum.all?(
            required_texts,
            &String.contains?(normalize_markdown(visible), normalize_markdown(&1))
          ),
          "published upgrade contract is incomplete"
        )
      else
        section = section(visible, heading)

        assert(section != nil, "published upgrade contract section is missing")
        normalized_section = normalize_markdown(section)

        assert(
          Enum.all?(
            required_texts,
            &String.contains?(normalized_section, normalize_markdown(&1))
          ),
          "published upgrade contract is incomplete"
        )
      end
    end)

    Enum.each(@upgrade_source_contracts, fn {path, required} ->
      source = root |> Path.join(path) |> File.read!()
      assert(String.contains?(source, required), "upgrade package contract is incomplete")
    end)
  rescue
    _error in [File.Error] -> fail("upgrade package contract input is invalid")
  end

  defp visible_markdown(content) do
    content
    |> then(&Regex.replace(~r/<!--.*?-->/s, &1, ""))
    |> String.split("\n")
    |> remove_code_lines()
    |> Enum.join("\n")
    |> decode_html_entities()
  end

  defp remove_code_lines(lines) do
    {visible, _fence} = Enum.reduce(lines, {[], nil}, &reduce_code_line/2)

    Enum.reverse(visible)
  end

  defp reduce_code_line(line, {visible, fence}) do
    case fence do
      nil ->
        case fence_marker(line) do
          nil -> reduce_visible_line(line, visible)
          marker -> {visible, marker}
        end

      marker ->
        if closing_fence?(line, marker), do: {visible, nil}, else: {visible, marker}
    end
  end

  defp reduce_visible_line(line, visible) do
    if String.starts_with?(line, "    ") or String.starts_with?(line, "\t"),
      do: {visible, nil},
      else: {[line | visible], nil}
  end

  defp fence_marker(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
      [_, marker] -> {String.first(marker), String.length(marker)}
      _ -> nil
    end
  end

  defp closing_fence?(line, {character, length}) do
    case Regex.run(~r/^ {0,3}(`+|~+)[ \t]*$/, line) do
      [_, marker] -> String.first(marker) == character and String.length(marker) >= length
      _ -> false
    end
  end

  defp decode_html_entities(content) do
    content
    |> then(
      &Regex.replace(~r/&#([0-9]+);/, &1, fn _, digits ->
        digits |> String.to_integer() |> List.wrap() |> List.to_string()
      end)
    )
    |> then(
      &Regex.replace(~r/&#x([0-9a-f]+);/i, &1, fn _, digits ->
        digits |> String.to_integer(16) |> List.wrap() |> List.to_string()
      end)
    )
    |> then(
      &Regex.replace(~r/&([A-Za-z][A-Za-z0-9]+);/, &1, fn entity, name ->
        if name in @named_separator_entities, do: " ", else: entity
      end)
    )
  rescue
    _error in [ArgumentError, UnicodeConversionError] ->
      fail("published contract entity is invalid")
  end

  defp normalize_markdown(content) do
    content
    |> String.replace(~r/[\s\p{Cf}]+/u, " ")
    |> String.trim()
  end

  defp section(content, nil), do: content

  defp section(content, heading) do
    lines = String.split(content, "\n")
    start = Enum.find_index(lines, &(&1 == heading))

    if start do
      level = heading |> String.split(" ", parts: 2) |> hd() |> String.length()

      lines
      |> Enum.drop(start)
      |> Enum.take_while(fn line ->
        line == heading or not heading_at_or_above?(line, level)
      end)
      |> Enum.join("\n")
    end
  end

  defp heading_at_or_above?(line, level) do
    case Regex.run(~r/^(#+)\s+/, line) do
      [_, marks] -> String.length(marks) <= level
      _ -> false
    end
  end

  defp assert(true, _message), do: :ok
  defp assert(false, message), do: fail(message)

  defp fail(message) do
    raise ReleaseContractError, message: message
  end
end
