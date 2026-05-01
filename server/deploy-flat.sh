#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy CrabInvSync to the current VPS layout:
#   WorkingDirectory=/opt/crab-sync
#   ExecStart=/usr/bin/node server.js 3000
#
# The git repo stores the Node app in server/, so this script refreshes that
# folder from origin/master, copies server/. into /opt/crab-sync, installs deps,
# syntax-checks server.js, and restarts the existing systemd service.

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/crab-sync}"
SERVICE_NAME="${SERVICE_NAME:-crab-sync}"
REMOTE_NAME="${REMOTE_NAME:-origin}"
REPO_URL="${REPO_URL:-https://github.com/Dudiebug/CrabInvSync.git}"
BRANCH_NAME="${BRANCH_NAME:-master}"

cd "$DEPLOY_ROOT"

if [ ! -d .git ]; then
  git init
fi

if ! git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  git remote add "$REMOTE_NAME" "$REPO_URL"
fi

echo "[deploy] Fetching $REMOTE_NAME/$BRANCH_NAME"
git fetch "$REMOTE_NAME" "$BRANCH_NAME"

echo "[deploy] Updating repo server/ files"
git checkout -f "$REMOTE_NAME/$BRANCH_NAME" -- server

echo "[deploy] Copying server/ into flat service root"
cp -a server/. .

echo "[deploy] Installing production dependencies"
npm install --omit=dev

echo "[deploy] Checking server.js syntax"
node --check server.js

echo "[deploy] Restarting $SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "[deploy] Service status"
systemctl status "$SERVICE_NAME" --no-pager
