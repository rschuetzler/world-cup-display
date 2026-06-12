import Config

# Prod runtime overrides, read from the environment at boot (systemd loads
# /opt/world-cup-tracker/env/app.env on the LXC).
if config_env() == :prod do
  if port = System.get_env("PORT") do
    config :world_cup_tracker, http_port: String.to_integer(port)
  end

  if tz = System.get_env("DISPLAY_TZ") do
    config :world_cup_tracker, timezone: tz
  end
end
