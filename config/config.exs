import Config

# Checkout-only pins come from the same file setup-beam and the runtime scripts read.
# config/ is excluded from the Hex package; consumer support stays in mix.exs.
pins =
  Path.expand("../.tool-versions", __DIR__)
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Map.new(fn line ->
    [tool, version] = String.split(line)
    {tool, version}
  end)

expected_elixir = pins |> Map.fetch!("elixir") |> String.split("-otp-") |> hd()
expected_otp = Map.fetch!(pins, "erlang")
major = to_string(:erlang.system_info(:otp_release))
actual_otp = :code.root_dir() |> Path.join("releases/#{major}/OTP_VERSION") |> File.read!()

if System.version() != expected_elixir or String.trim(actual_otp) != expected_otp do
  raise "ash_replicant checkout requires the exact .tool-versions runtime; run `asdf install` from the repository root and re-run through scripts/with-release-runtime.sh"
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
