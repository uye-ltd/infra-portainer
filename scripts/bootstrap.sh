#!/usr/bin/env bash
# First-time server setup. Run once on a fresh machine.
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

step "Starting containers (building the portainer image locally for first run)..."
docker compose -f docker/docker-compose.yml up -d --build

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
echo "  2. Register with the infra-runner deployer. In infra-runner's .env add:"
echo "       COMPOSE_FILE=docker-compose.yml:../infra-portainer/deploy/docker-compose.infra-runner.yml"
echo "       PORTAINER_DIR=$INSTALL_DIR"
echo "       PORTAINER_CERT_IDENTITY=https://github.com/uye-ltd/infra-portainer/.github/workflows/ci.yml@refs/heads/main"
echo "     then:  docker compose up -d --no-deps deployer"
echo ""
echo "  3. Keep the on-server clone current (the deployer never git-pulls it):"
echo "       (crontab -l 2>/dev/null; echo '*/5 * * * * git -C $INSTALL_DIR pull --ff-only origin main') | crontab -"
echo ""
echo "  4. Make the GHCR 'portainer' package PUBLIC once CI has pushed it, so the"
echo "     deployer's GitHub-App token can pull it:"
echo "       https://github.com/orgs/uye-ltd/packages/container/portainer/settings"
echo ""
echo "  After that, every push to main rebuilds, signs, and auto-deploys — no SSH needed."
echo ""
