#!/usr/bin/env bash
# Build a prod release on this host and ship it to the prod LXC.
# Adapted from travis-tracker's bin/deploy.sh; this app has no Postgres,
# no assets pipeline, and no migrate step.
#
# Assumes:
#   - mise shims resolvable (script prepends them to PATH).
#   - This host can ssh to ${DEPLOY_HOST} as ${DEPLOY_USER} with key auth.
#   - The remote already went through .deploy/bootstrap.sh once.
#
# Env var overrides:
#   DEPLOY_HOST      target host                  (default: 192.168.2.22)
#   DEPLOY_USER      ssh user on target           (default: root)
#   DEPLOY_APP_DIR   release dir on target        (default: /opt/world-cup-tracker)
#   DEPLOY_SERVICE   systemd unit name on target  (default: world-cup-tracker)

set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-192.168.2.22}"
DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_APP_DIR="${DEPLOY_APP_DIR:-/opt/world-cup-tracker}"
DEPLOY_SERVICE="${DEPLOY_SERVICE:-world-cup-tracker}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

# mise shims aren't on PATH in non-interactive shells; prepend them so
# `mix` resolves to the project's .tool-versions runtime.
export PATH="${HOME}/.local/share/mise/shims:${PATH}"

TARBALL="${PROJECT_ROOT}/.deploy/release.tar.gz"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

git_describe="$(git describe --always --dirty 2>/dev/null || echo "no-git")"
step "Deploying ${git_describe} to ${DEPLOY_USER}@${DEPLOY_HOST}"

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "    note: working tree has uncommitted changes" >&2
fi

step "Building prod release"
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release --overwrite

step "Packaging release tarball"
mkdir -p "${PROJECT_ROOT}/.deploy"
tar -C "${PROJECT_ROOT}/_build/prod/rel/world_cup_tracker" -czf "${TARBALL}" .
ls -lh "${TARBALL}"

step "Uploading to ${DEPLOY_HOST}"
scp "${TARBALL}" "${DEPLOY_USER}@${DEPLOY_HOST}:/tmp/release.tar.gz"

step "Swapping release on ${DEPLOY_HOST}"
ssh "${DEPLOY_USER}@${DEPLOY_HOST}" bash -s -- \
    "${DEPLOY_APP_DIR}" "${DEPLOY_SERVICE}" <<'REMOTE'
set -euo pipefail
APP_DIR="$1"
SERVICE="$2"

echo "    stopping ${SERVICE}"
systemctl stop "${SERVICE}" || true

echo "    wiping ${APP_DIR}/current"
rm -rf "${APP_DIR}/current"/*

echo "    extracting new release"
sudo -u world_cup_tracker tar -C "${APP_DIR}/current" -xzf /tmp/release.tar.gz
rm -f /tmp/release.tar.gz

echo "    starting ${SERVICE}"
systemctl start "${SERVICE}"

# Wait for the unit to settle; Bandit prints its listen line a couple
# seconds after start.
for i in 1 2 3 4 5 6 7 8 9 10; do
    state="$(systemctl is-active "${SERVICE}" || true)"
    if [[ "${state}" == "active" ]]; then
        echo "    ${SERVICE}: active"
        break
    fi
    sleep 1
done

if [[ "$(systemctl is-active "${SERVICE}" || true)" != "active" ]]; then
    echo "    ${SERVICE} failed to reach active; last 30 log lines:" >&2
    journalctl -u "${SERVICE}" --no-pager -n 30 >&2
    exit 1
fi
REMOTE

step "Smoke check"
sleep 2
if curl -fsS --max-time 5 "http://${DEPLOY_HOST}:4400/healthz"; then
    echo
    echo "    healthz OK"
else
    echo "    healthz FAILED" >&2
    exit 1
fi

step "Done"
echo "    ${git_describe} live on ${DEPLOY_HOST} (wc.dojo.schuetzler.net)"
