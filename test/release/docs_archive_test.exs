defmodule AshReplicant.DocsArchiveTest do
  use ExUnit.Case, async: true

  @builder Path.expand("../../scripts/build-docs-archive.exs", __DIR__)
  @checker Path.expand("../../scripts/check-docs-archive.py", __DIR__)

  setup do
    scratch =
      Path.join(System.tmp_dir!(), "ash-replicant-docs-#{System.unique_integer([:positive])}")

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)
    %{scratch: scratch}
  end

  test "Hex archives inspect every rendered byte", %{scratch: dir} do
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")

    for {tree, time} <- [{first, 1_000_000_000}, {second, 1_700_000_000}] do
      File.mkdir_p!(Path.join(tree, "assets"))
      File.mkdir_p!(Path.join(tree, ".build"))
      File.write!(Path.join(tree, ".build/html"), tree)

      for name <- ["index.html", "readme.html", "readme.md", "assets/code.js"] do
        path = Path.join(tree, name)
        File.write!(path, "rendered #{name}")
        File.touch!(path, time)
      end
    end

    one = build!(first, dir)
    two = build!(second, dir)
    assert {output, 0} = inspect_archive(one, first)
    assert output =~ "5 regular files; contents and release provenance inspected"

    File.write!(Path.join(first, "readme.html"), "mutated rendered bytes")
    assert {output, 1} = inspect_archive(one, first)
    assert output =~ "bytes differ from source"

    File.write!(Path.join(second, "missing.md"), "not archived")
    assert {output, 1} = inspect_archive(two, second)
    assert output =~ "omits source files"
  end

  test "generated source links refuse before their bytes are archived", %{scratch: dir} do
    tree = Path.join(dir, "linked-docs")
    File.mkdir_p!(tree)
    File.write!(Path.join(tree, "index.html"), "index")
    File.write!(Path.join(tree, "readme.html"), "readme")
    archive = build!(tree, dir)
    File.ln_s!("readme.html", Path.join(tree, "linked.html"))
    assert {output, 1} = inspect_archive(archive, tree)
    assert output =~ "link or special entry"

    assert {output, 1} =
             System.cmd("mix", ["run", "--no-mix-exs", @builder, tree, tree <> ".refused.tar.gz"],
               cd: dir,
               stderr_to_stdout: true
             )

    assert output =~ "only regular files and directories"
  end

  test "EPUB is refused even when its bytes match the rendered tree", %{scratch: dir} do
    tree = Path.join(dir, "docs")
    File.mkdir_p!(tree)
    File.write!(Path.join(tree, "index.html"), "index")
    File.write!(Path.join(tree, "readme.html"), "readme")
    File.write!(Path.join(tree, "replicant.epub"), "timestamped EPUB")
    archive = build!(tree, dir)
    assert {output, 1} = inspect_archive(archive, tree)
    assert output =~ "EPUB embeds build time"

    checker = File.read!(@checker)
    mutated = String.replace(checker, ~s|path.suffix == ".epub"|, "False")
    refute mutated == checker

    # This exact mutation must admit the otherwise valid EPUB archive.
    assert {_output, 0} =
             System.cmd(
               "python3",
               [
                 "-I",
                 "-c",
                 mutated,
                 archive,
                 tree,
                 "--version",
                 "1.6.4",
                 "--commit",
                 String.duplicate("a", 40)
               ],
               stderr_to_stdout: true
             )
  end

  defp build!(tree, scratch) do
    File.write!(
      Path.join(tree, "release.json"),
      Jason.encode!(%{
        package: "ash_replicant",
        version: "1.6.4",
        commit: String.duplicate("a", 40)
      })
    )

    archive = tree <> ".tar.gz"

    assert {_output, 0} =
             System.cmd("mix", ["run", "--no-mix-exs", @builder, tree, archive],
               cd: scratch,
               stderr_to_stdout: true
             )

    archive
  end

  defp inspect_archive(archive, tree) do
    System.cmd(
      "python3",
      [
        "-I",
        @checker,
        archive,
        tree,
        "--version",
        "1.6.4",
        "--commit",
        String.duplicate("a", 40)
      ],
      stderr_to_stdout: true
    )
  end
end
