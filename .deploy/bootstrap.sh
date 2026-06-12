#!/usr/bin/env bash
# Bootstrap script for the world-cup-tracker prod LXC (192.168.2.22,
# wc.dojo.schuetzler.net). Idempotent: safe to re-run.
#
# Run as root inside the LXC after fresh Ubuntu 24.04 install.
# No database — the app keeps all state in memory and refetches on boot.

set -euo pipefail

APP_USER="world_cup_tracker"
APP_HOME="/opt/world-cup-tracker"

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ca-certificates \
    libncurses6 \
    openssl \
    locales \
    curl

echo "==> Ensuring en_US.UTF-8 locale is generated"
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8

echo "==> Creating system user '${APP_USER}'"
if ! id "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${APP_HOME}" \
            --shell /usr/sbin/nologin "${APP_USER}"
fi

echo "==> Creating directory layout under ${APP_HOME}"
install -d -o "${APP_USER}" -g "${APP_USER}" -m 0755 \
    "${APP_HOME}/current" \
    "${APP_HOME}/env"
chmod 0750 "${APP_HOME}/env"

echo "==> Installing env file (if absent)"
if [[ ! -f "${APP_HOME}/env/app.env" ]]; then
    cat >"${APP_HOME}/env/app.env" <<'ENV'
# World Cup Tracker prod environment.
# Loaded by systemd via EnvironmentFile=/opt/world-cup-tracker/env/app.env
# Public hostname (reverse-proxied): wc.dojo.schuetzler.net

PORT=4400
DISPLAY_TZ=America/Denver
ENV
    chown "${APP_USER}:${APP_USER}" "${APP_HOME}/env/app.env"
    chmod 0640 "${APP_HOME}/env/app.env"
fi

echo "==> Installing systemd unit"
cat >/etc/systemd/system/world-cup-tracker.service <<'UNIT'
[Unit]
Description=World Cup Tracker (Elixir)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=world_cup_tracker
Group=world_cup_tracker
WorkingDirectory=/opt/world-cup-tracker/current
EnvironmentFile=/opt/world-cup-tracker/env/app.env
Environment=LANG=en_US.UTF-8
ExecStart=/opt/world-cup-tracker/current/bin/world_cup_tracker start
Restart=on-failure
RestartSec=5
# Bandit defaults to a 5s graceful shutdown; give a generous window.
TimeoutStopSec=30
# Hardening
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable world-cup-tracker.service >/dev/null 2>&1 || true

echo
echo "==> Bootstrap complete."
echo "    App home: ${APP_HOME}"
echo "    Service:  world-cup-tracker.service (not yet started — release missing)"
echo "    Next:     run bin/deploy.sh from the dev host"
