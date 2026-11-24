#!/usr/bin/env bash
set -euo pipefail
tarball="${1:?usage: inspect-release-package.sh TARBALL}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-publish-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/outer" "$work/package"
tar -xf "$tarball" -C "$work/outer"
tar -xzf "$work/outer/contents.tar.gz" -C "$work/package"
# Match Hex's --unpack file set, including its wrapper metadata file.
cp "$work/outer/metadata.config" "$work/package/hex_metadata.config"
package_files="$(cd "$work/package" && find . \( -type f -o -type l \) | sed 's|^./||' | LC_ALL=C sort)"
if ! diff -u "$root/scripts/release-package-files.txt" - <<<"$package_files"; then
  echo 'inspect-release-package: package files differ from the release allowlist' >&2
  exit 1
fi
elixir -r "$root/lib/ash_replicant/dependency_requirements.ex" -e '
  [mixfile, metadata_file] = System.argv()
  declared = AshReplicant.DependencyRequirements.read!(mixfile)
  expected = Map.new(declared, fn {app, requirement} -> {Atom.to_string(app), requirement} end)

  {:ok, metadata} = :file.consult(metadata_file)
  dependencies = metadata |> Map.new() |> Map.fetch!("requirements") |> Enum.map(&Map.new/1)

  packed =
    Map.new(dependencies, fn dependency ->
      {Map.fetch!(dependency, "app"), Map.fetch!(dependency, "requirement")}
    end)

  unless map_size(packed) == length(dependencies) and packed == expected do
    raise "packed dependency requirements differ from mix.exs"
  end

  unless Enum.any?(dependencies, &match?(%{
           "app" => "db_connection", "name" => "db_connection", "optional" => false,
           "repository" => "hexpm"
         }, &1)) do
    raise "packed DBConnection dependency must be required"
  end
' -- "$root/mix.exs" "$work/outer/metadata.config"

echo 'inspect-release-package: built package matches the release allowlist and dependency requirements'
