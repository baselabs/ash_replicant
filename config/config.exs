import Config

# Checkout toolchain assertion: this repository's supported release
# foundation is Elixir 1.20.3 on Erlang/OTP 29. config/ is NOT published
# with the Hex package, so the package's declared Elixir ~> 1.20 support
# window is unaffected — this fails config load in this checkout only.
# `:erlang.system_info(:otp_release)` returns a charlist; `to_string/1`
# normalizes it before the comparison.
expected_elixir = "1.20.3"
expected_otp = to_string(:erlang.system_info(:otp_release))

if System.version() != expected_elixir or expected_otp != "29" do
  raise "ash_replicant checkout requires Elixir #{expected_elixir} on Erlang/OTP 29 (config loaded with Elixir #{System.version()} on OTP #{expected_otp}); run `asdf install` from the repository root and re-run through scripts/with-release-runtime.sh"
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
