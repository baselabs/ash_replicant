import Config

# Checkout-only runtime admission uses the same reader as CI.
# config/ is excluded from the Hex package; consumer support stays in mix.exs.
root = Path.expand("..", __DIR__)
reader = Path.join(root, "scripts/toolchain.sh")
{output, status} = System.cmd(reader, [Path.join(root, ".tool-versions")], stderr_to_stdout: true)

if status != 0, do: raise("checkout toolchain reader refused its declarations")

pins =
  output
  |> String.split("\n", trim: true)
  |> Map.new(fn line ->
    [name, version] = String.split(line, "=", parts: 2)
    {name, version}
  end)

expected_elixir = Map.fetch!(pins, "elixir")
expected_otp = Map.fetch!(pins, "otp")
actual_elixir = System.version() <> "-otp-" <> System.build_info()[:otp_release]
major = to_string(:erlang.system_info(:otp_release))
actual_otp = :code.root_dir() |> Path.join("releases/#{major}/OTP_VERSION") |> File.read!()

if actual_elixir != expected_elixir or String.trim(actual_otp) != expected_otp do
  raise "ash_replicant checkout requires the exact .tool-versions runtime"
end

# The string-length counting basis this package's resources, snapshots,
# and generated migrations are authored against (Ash >= 3.33 warns until
# the basis is explicit). Consumers set the same line in their OWN host
# config — see README "Manual installation"; the library never mutates
# global Ash config at runtime.
config :ash, default_string_length_count: :codepoints

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
