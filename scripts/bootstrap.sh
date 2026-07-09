#!/usr/bin/env bash
# First-time server setup. Run once on a fresh machine.
#
# Run this AS THE ghrunner USER, so INSTALL_DIR lands at /home/ghrunner/infra-portainer.
# That path is load-bearing: infra-runner's COMPOSE_FILE refers to ../infra-portainer/...,
# resolved relative to its own project dir /home/ghrunner/infra-runner.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uye-ltd/infra-portainer/main/scripts/bootstrap.sh | bash
#   or: bash scripts/bootstrap.sh
set -euo pipefail

REPO="https://github.com/uye-ltd/infra-portainer.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/infra-portainer}"

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "${GREEN}==>${NC} $*"; }
box()  { echo -e "${BOLD}$*${NC}"; }

for cmd in git make curl; do
  command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not installed."; exit 1; }
done

# Docker socket check — common failure point on first run
if ! docker info >/dev/null 2>&1; then
  echo ""
  echo "Error: cannot connect to Docker."
  echo ""
  echo "  Fix:"
  echo "    sudo usermod -aG docker \$USER"
  echo "    exit   # disconnect SSH completely, then reconnect"
  echo ""
  echo "  A new SSH session is required — group changes don't apply to existing sessions."
  echo ""
  exit 1
fi

# Docker Compose v2 check (plugin, not standalone docker-compose)
if ! docker compose version >/dev/null 2>&1; then
  echo "Error: Docker Compose v2 plugin not found."
  echo "Install Docker Engine via: https://docs.docker.com/engine/install/ubuntu/"
  exit 1
fi

# Clone or update the repository
if [ -d "$INSTALL_DIR/.git" ]; then
  step "Repository already exists — pulling latest..."
  git -C "$INSTALL_DIR" pull origin main
else
  step "Cloning repository to $INSTALL_DIR..."
  git clone "$REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

if [ ! -f docker/.env ]; then
  cp docker/.env.example docker/.env
  step "Created docker/.env from template"
fi

# Pull the cosign-signed image rather than building from the `build:` key — a local build would be
# unsigned yet carry the ghcr.io/uye-ltd/portainer:latest tag, defeating the deployer's signature check.
# Requires the GHCR package to be public; see the next-steps box below.
step "Pulling the signed portainer image..."
if ! docker compose -f docker/docker-compose.yml pull portainer; then
  echo ""
  echo "Error: could not pull ghcr.io/uye-ltd/portainer:latest."
  echo ""
  echo "  Most likely the GHCR package is still private. Make it public:"
  echo "    https://github.com/orgs/uye-ltd/packages/container/portainer/settings"
  echo ""
  echo "  The deployer authenticates as a GitHub App, and App installation tokens"
  echo "  cannot pull private GHCR packages — so this is required, not optional."
  echo ""
  echo "  (Also confirm CI has pushed the image at least once.)"
  echo ""
  exit 1
fi

step "Starting containers (portainer + portainer-proxy, network, volume)..."
docker compose -f docker/docker-compose.yml up -d

echo ""
box "================================================================"
box "  Setup complete. Next steps:"
box "================================================================"
echo ""
echo "  1. Open an SSH tunnel from your machine and set the admin password:"
echo "       ssh -L 9000:127.0.0.1:9000 <user>@<server>"
echo "       → browse http://localhost:9000 and create the admin user"
echo "     (If the initial-setup window times out: 'docker restart portainer' and retry.)"
echo ""
echo "  2. Register with the infra-runner deployer. In infra-runner's .env:"
echo ""
echo "     APPEND this to the EXISTING COMPOSE_FILE value — do not replace it. The line is"
echo "     shared with docker-compose.override.yml and the vault overlay, and overwriting it"
echo "     silently unregisters the vault plugin:"
echo "       :../infra-portainer/deploy/docker-compose.infra-runner.yml"
echo ""
echo "     Then add these two new lines:"
echo "       PORTAINER_DIR=$INSTALL_DIR"
echo "       PORTAINER_CERT_IDENTITY=https://github.com/uye-ltd/infra-portainer/.github/workflows/ci.yml@refs/heads/main"
echo ""
echo "     Check it, then recreate only the deployer:"
echo "       grep -E '^COMPOSE_FILE|^PORTAINER_' .env"
echo "       docker compose up -d --no-deps deployer"
echo ""
echo "  3. Keep the on-server clone current (the deployer never git-pulls it):"
echo "       (crontab -l 2>/dev/null; echo '*/5 * * * * git -C $INSTALL_DIR pull --ff-only origin main') | crontab -"
echo ""
echo "  After that, every push to main rebuilds, signs, and auto-deploys — no SSH needed."
echo ""
