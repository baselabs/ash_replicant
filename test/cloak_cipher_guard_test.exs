defmodule AshReplicant.CloakCipherGuardTest do
  use ExUnit.Case, async: true

  @source_directories ~w(lib config test/support)
  @allowed_cipher "Cloak.Ciphers.AES.GCM"
  @cipher_namespaces ~w(Cloak.Ciphers Cloak.Ciphers.AES Cloak.Ciphers.Deprecated Cloak.Ciphers.Deprecated.AES)

  @tag :source_tree
  test "source tree references and configures only the authenticated Cloak AES-GCM cipher" do
    assert_gcm_only!(Path.expand("..", __DIR__))
  end

  @tag :tmp_dir
  test "the source guard rejects forbidden references and cipher configurations", %{tmp_dir: root} do
    copy_source_tree!(root)

    mutations = [
      "Cloak.Ciphers.AES.CTR",
      "Cloak.Ciphers.AES.CTR.encrypt(data, [])",
      "Elixir.Cloak.Ciphers.AES.CTR",
      ":\"Elixir.Cloak.Ciphers.AES.CTR\"",
      "Cloak.Ciphers.Deprecated.AES.CTR",
      "Cloak.Ciphers.AES.CBC",
      "alias Cloak, as: C; C.Ciphers.AES.CTR",
      "alias Cloak.{Ciphers}; Ciphers.AES.CTR",
      "alias Cloak.Ciphers.AES, as: AES; AES.CTR",
      "alias Cloak.Ciphers.AES.{GCM, CTR}",
      "config :ash_replicant, SomeVault, ciphers: [default: {SomeCustomCipher, []}]",
      "Keyword.put(config, :ciphers, [default: {SomeCustomCipher, []}])",
      "config |> Keyword.put(:ciphers, [default: {SomeCustomCipher, []}])",
      "import Keyword; put(config, :ciphers, [default: {SomeCustomCipher, []}])",
      "Application.put_env(:ash_replicant, :ciphers, [default: {SomeCustomCipher, []}])",
      "config :ash_replicant, :ciphers, [default: {SomeCustomCipher, []}]",
      "ciphers = [default: {SomeCustomCipher, []}]",
      "ciphers = [default: {Module.concat([Cloak, Ciphers, AES, CTR]), []}]",
      "ciphers = [default: {String.to_existing_atom(\"Elixir.Cloak.Ciphers.AES.CTR\"), []}]"
    ]

    for directory <- @source_directories, mutation <- mutations do
      file = Path.join([root, directory, ".cipher_guard_probe.exs"])
      File.write!(file, mutation)

      try do
        assert_raise ExUnit.AssertionError, ~r/Only Cloak.Ciphers.AES.GCM/, fn ->
          assert_gcm_only!(root)
        end
      after
        File.rm!(file)
      end
    end
  end

  @tag :tmp_dir
  test "the source guard accepts GCM aliases and keeps aliases scoped", %{tmp_dir: root} do
    copy_source_tree!(root)

    File.write!(Path.join(root, "lib/cipher_guard_probe.exs"), """
    alias Cloak, as: C
    C.Ciphers.AES.GCM
    C.Ciphers.AES.GCM.encrypt(data, [])
    alias Cloak.{Ciphers}
    Ciphers.AES.GCM
    alias Cloak.Ciphers.AES, as: AES
    AES.GCM
    alias OtherLibrary, as: GCM
    alias Cloak.Ciphers.AES.{GCM}
    ciphers = [default: {GCM, []}]
    Keyword.put(config, :ciphers, ciphers)
    defmodule OtherScope do
      alias OtherLibrary, as: C
      C.Ciphers.AES.CTR
    end
    C.Ciphers.AES.GCM
    """)

    assert_gcm_only!(root)
  end

  defp copy_source_tree!(root) do
    on_exit(fn -> File.rm_rf!(root) end)

    for directory <- @source_directories do
      destination = Path.join(root, directory)
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(Path.expand("../#{directory}", __DIR__), destination)
    end
  end

  defp assert_gcm_only!(root) do
    files =
      Enum.flat_map(@source_directories, fn directory ->
        path = Path.join(root, directory)
        assert File.dir?(path), "missing source directory: #{directory}"
        Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true)
      end)

    assert files != [], "the cipher guard must inspect Elixir source files"

    violations =
      Enum.flat_map(files, fn file ->
        ast = file |> File.read!() |> Code.string_to_quoted!(file: file)
        {violations, _environment} = walk(ast, %{aliases: %{}, values: %{}}, 1)
        Enum.map(violations, &"#{Path.relative_to(file, root)}:#{&1}")
      end)

    assert violations == [],
           "Only #{@allowed_cipher} is allowed in #{Enum.join(@source_directories, ", ")}:\n" <>
             Enum.join(violations, "\n")
  end

  defp walk({:__block__, _, expressions}, environment, line),
    do: walk_sequence(expressions, environment, line)

  defp walk({:alias, metadata, [target | options]} = node, environment, line) do
    {violations, _environment} = walk_children(node, environment, line)
    aliases = alias_targets(target, environment)
    explicit_name = options |> List.first() |> Kernel.||([]) |> Keyword.get(:as)

    updated =
      Enum.reduce(aliases, environment.aliases, fn target, aliases ->
        name = module_name(explicit_name, %{aliases: %{}}) || List.last(String.split(target, "."))
        Map.put(aliases, name, target)
      end)

    {violations ++ Enum.flat_map(aliases, &reference_name_violations(&1, metadata[:line] || line)),
     %{environment | aliases: updated}}
  end

  defp walk({:=, metadata, [{name, _, context}, value]} = node, environment, line)
       when is_atom(name) and is_atom(context) do
    {violations, _environment} = walk_children(node, environment, line)

    config =
      if name == :ciphers,
        do: cipher_config_violations(value, environment, metadata[:line]),
        else: []

    values = Map.put(environment.values, name, {value, environment})
    {violations ++ config, %{environment | values: values}}
  end

  defp walk({:ciphers, value} = node, environment, line) do
    {violations, _environment} = walk_children(node, environment, line)
    {violations ++ cipher_config_violations(value, environment, line), environment}
  end

  defp walk({:|>, metadata, [left, {call, call_metadata, arguments}]}, environment, line)
       when is_list(arguments),
       do: walk({call, call_metadata, [left | arguments]}, environment, metadata[:line] || line)

  defp walk({operation, metadata, [_config, :ciphers, value]} = node, environment, line)
       when operation in [:config, :put, :put_new, :replace, :replace!, :put_env] do
    {violations, _environment} = walk_children(node, environment, line)

    {violations ++ cipher_config_violations(value, environment, metadata[:line] || line),
     environment}
  end

  defp walk(
         {{:., _, [module, operation]}, metadata, [_config, :ciphers, value]} = node,
         environment,
         line
       )
       when operation in [:put, :put_new, :replace, :replace!, :put_env] do
    {violations, _environment} = walk_children(node, environment, line)

    config =
      if module_name(module, environment) in ["Keyword", "Map", "Application"],
        do: cipher_config_violations(value, environment, metadata[:line] || line),
        else: []

    {violations ++ config, environment}
  end

  defp walk(node, environment, line) do
    {violations, _environment} = walk_children(node, environment, line)
    {reference_violations(node, environment, line) ++ violations, environment}
  end

  defp walk_children({form, metadata, arguments}, environment, line) when is_list(arguments),
    do: walk_sequence([form | arguments], environment, metadata[:line] || line)

  defp walk_children(node, environment, line) when is_tuple(node),
    do: node |> Tuple.to_list() |> walk_sequence(environment, line)

  defp walk_children(node, environment, line) when is_list(node),
    do: walk_sequence(node, environment, line)

  defp walk_children(_node, environment, _line), do: {[], environment}

  defp walk_sequence(nodes, environment, line) do
    {groups, environment} = Enum.map_reduce(nodes, environment, &walk(&1, &2, line))
    {List.flatten(groups), environment}
  end

  defp alias_targets({{:., _, [prefix, :{}]}, _, suffixes}, environment) do
    for suffix <- suffixes,
        prefix_name = module_name(prefix, environment),
        suffix_name = module_name(suffix, %{aliases: %{}}),
        is_binary(prefix_name) and is_binary(suffix_name),
        do: prefix_name <> "." <> suffix_name
  end

  defp alias_targets(target, environment) do
    case module_name(target, environment) do
      nil -> []
      name -> [name]
    end
  end

  defp module_name({:__aliases__, _, [:"Elixir" | parts]}, _environment),
    do: Enum.join(parts, ".")

  defp module_name({:__aliases__, _, [head | tail]}, environment) when is_atom(head) do
    if Enum.all?(tail, &is_atom/1) do
      prefix = Map.get(environment.aliases, Atom.to_string(head), Atom.to_string(head))
      Enum.join([prefix | tail], ".")
    end
  end

  defp module_name(nil, _environment), do: nil

  defp module_name(module, _environment) when is_atom(module),
    do: module |> Atom.to_string() |> String.trim_leading("Elixir.")

  defp module_name(_node, _environment), do: nil

  defp reference_violations(node, environment, line) do
    reference_name_violations(module_name(node, environment), line)
  end

  defp reference_name_violations(reference, line) do
    case reference do
      "Cloak.Ciphers." <> _ = reference
      when reference != @allowed_cipher and reference not in @cipher_namespaces ->
        ["#{line}: #{reference}"]

      _ ->
        []
    end
  end

  defp cipher_config_violations({name, _, context}, environment, line)
       when is_atom(name) and is_atom(context) do
    case Map.fetch(environment.values, name) do
      {:ok, {value, binding_environment}} ->
        cipher_config_violations(value, binding_environment, line)

      :error ->
        ["#{line}: cipher configuration cannot be resolved statically"]
    end
  end

  defp cipher_config_violations(ciphers, environment, line) when is_list(ciphers) do
    Enum.flat_map(ciphers, fn
      {name, {cipher, _options}} when is_atom(name) ->
        if module_name(cipher, environment) == @allowed_cipher,
          do: [],
          else: ["#{line}: configured cipher must resolve statically to #{@allowed_cipher}"]

      _ ->
        ["#{line}: cipher configuration cannot be resolved statically"]
    end)
  end

  defp cipher_config_violations(_ciphers, _environment, line),
    do: ["#{line}: cipher configuration cannot be resolved statically"]
end
