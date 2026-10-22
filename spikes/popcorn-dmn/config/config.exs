import Config

# Tree-shaking removes code only reached through dynamic calls (protocols, behaviours,
# Exception.message/1, ...), so every dependency is preserved; only OTP/Elixir built-ins are shaken.
config :popcorn,
  treeshake: [preserved_apps: [:elixir, :feel, :decimal, :saxy, :tz, :dmn_spike]],
  brotli_effort: :max
