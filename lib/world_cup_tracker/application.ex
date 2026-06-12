defmodule WorldCupTracker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        WorldCupTracker.Store,
        # In :test the Poller starts but stays inert (poll_on_start?: false).
        WorldCupTracker.Poller
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: WorldCupTracker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The panel polls over Tailscale, so the listener must bind 0.0.0.0 — this
  # host is headless and loopback is unreachable from other devices. Tests hit
  # the Router with Plug.Test directly and disable the listener
  # (http_server?: false).
  defp http_children do
    if Application.get_env(:world_cup_tracker, :http_server?, true) do
      port = Application.get_env(:world_cup_tracker, :http_port, 4400)
      [{Bandit, plug: WorldCupTracker.Web.Router, scheme: :http, ip: {0, 0, 0, 0}, port: port}]
    else
      []
    end
  end
end
