import Config

# Display snapshot builder (WorldCupTracker.Display.State).
config :world_cup_tracker,
  timezone: "America/Denver",
  followed_teams: ["USA"],
  goal_duration_ms: 16_500,
  final_hold_ms: 20 * 60 * 1000

# HTTP serving layer (WorldCupTracker.Web.Router via Bandit). Binds 0.0.0.0 so
# the panel can reach it over Tailscale.
config :world_cup_tracker,
  http_server?: true,
  http_port: 4400

import_config "#{config_env()}.exs"
