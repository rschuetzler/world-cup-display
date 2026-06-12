import Config

# Don't poll real upstreams during tests; the Poller starts but stays inert.
config :world_cup_tracker, poll_on_start?: false

# Router tests use Plug.Test conns directly; no listener in :test.
config :world_cup_tracker, http_server?: false
