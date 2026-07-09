# infra-portainer

Portainer CE for the UYE infrastructure. Runs as a Docker container on a bare-metal server,
manages Docker through a read-limited socket-proxy, and auto-updates via GitHub Actions +
the [infra-runner](https://github.com/uye-ltd/infra-runner) GitOps deployer.

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [First-time server setup](#first-time-server-setup)
- [Connecting the CI/CD pipeline](#connecting-the-cicd-pipeline)
- [Accessing the UI](#accessing-the-ui)
- [Customization & extension](#customization--extension)
- [Upgrading](#upgrading)
- [Troubleshooting](#troubleshooting)

## How it works

```
                 push to main
  developer ───────────────────►  GitHub Actions
                                     │  validate (compose + templates JSON)
                                     │  build → ghcr.io/uye-ltd/portainer  (Buildah)
                                     │  cosign sign @digest  (keyless OIDC)
                                     ▼
   ┌──────────────────── server ────────────────────────────────┐
   │                                                             │
   │   infra-runner deployer ──poll GHCR──► verify signature     │
   │        │  new digest → docker compose up -d --no-deps       │
   │        ▼                       portainer                    │
   │   ┌─────────────┐        ┌───────────────────┐              │
   │   │  portainer  │──2375─►│  portainer-proxy  │──► /var/run/ │
   │   │  :9000      │        │  (socket-proxy)   │    docker.sock│
   │   └──────┬──────┘        └───────────────────┘   (ro)       │
   │   127.0.0.1 only            portainer-net                   │
   └──────────┼──────────────────────────────────────────────────┘
              │  SSH tunnel / host reverse proxy
              ▼
          your browser
```

- **Portainer CE** runs from our own image `ghcr.io/uye-ltd/portainer` — a thin wrapper
  (`FROM portainer/portainer-ce`) built and **cosign-signed** in this repo's CI. We wrap the
  upstream image because the deployer only pulls images whose signature identity matches this
  repo's workflow; the wrapper is also where version pinning and future baked-in customization live.
- Portainer never touches the raw Docker socket. It talks to **`portainer-proxy`**
  (`tecnativa/docker-socket-proxy`) over `tcp://portainer-proxy:2375`, which exposes only the
  Docker API groups Portainer needs. `EXEC`/`BUILD` are off by default (see toggles below).
- The UI binds to **`127.0.0.1:9000` only**. Reach it via SSH tunnel or a host reverse proxy.
- **Deployment is GitOps.** No SSH, no deploy job. The infra-runner deployer polls GHCR, verifies
  the cosign signature, and restarts the `portainer` service in place when a new digest appears.
  `portainer-proxy` and `portainer-net` are created once at bootstrap and left untouched
  (the deployer runs `--no-deps portainer`).

## Prerequisites

- **Local:** `docker` + `docker compose` v2, `git`, `make`, `jq` (for editing/validating templates).
- **Server:** Docker Engine + Compose v2 plugin, `git`, `make`. The user must be in the `docker`
  group (requires a fresh SSH session after `usermod -aG docker`).
- An operational [infra-runner](https://github.com/uye-ltd/infra-runner) stack on the same server.

## First-time server setup

```bash
# Option A — one-liner
curl -fsSL https://raw.githubusercontent.com/uye-ltd/infra-portainer/main/scripts/bootstrap.sh | bash

# Option B — manual
git clone https://github.com/uye-ltd/infra-portainer.git ~/infra-portainer
cd ~/infra-portainer
cp docker/.env.example docker/.env
make up   # builds the wrapper image locally for the first run, starts portainer + portainer-proxy
```

Then:

1. **Set the admin password.** Open a tunnel and create the admin user (see [Accessing the UI](#accessing-the-ui)).
   The admin password is intentionally not pre-seeded (a bcrypt hash breaks compose interpolation, and a
   password-file bind mount would break under the deployer). If Portainer's initial-setup window times
   out, run `docker restart portainer` and retry.
2. **Register with the deployer** — see below.
3. **Make the GHCR package public** once CI has pushed it (the deployer's GitHub-App token cannot pull
   private packages): `https://github.com/orgs/uye-ltd/packages/container/portainer/settings`.

**GitHub Secrets: none required for deployment.** CI's only credential is the automatic `GITHUB_TOKEN`.

## Connecting the CI/CD pipeline

CI (`.github/workflows/ci.yml`) has two jobs:

- **`validate`** (GitHub-hosted, PR + push): `docker compose config` and `jq` validate the compose
  file and `templates.json`.
- **`build`** (self-hosted on the infra-runner, push only): Buildah builds the wrapper image with
  fuse-overlayfs (`--isolation=chroot`), pushes `:latest` + `:<sha>` to GHCR, and **cosign-signs by
  digest** via keyless OIDC. All `uses:` are SHA-pinned.

Register the plugin on the server by adding to **infra-runner's `.env`**:

```bash
COMPOSE_FILE=docker-compose.yml:../infra-portainer/deploy/docker-compose.infra-runner.yml
PORTAINER_DIR=/home/ghrunner/infra-portainer
# Signing happens in ci.yml, so the identity ends in ci.yml — NOT deploy.yml.
PORTAINER_CERT_IDENTITY=https://github.com/uye-ltd/infra-portainer/.github/workflows/ci.yml@refs/heads/main
```

then `docker compose up -d --no-deps deployer`. Because the deployer never `git pull`s the plugin
checkout, keep the on-server clone current with a cron:

```bash
(crontab -l 2>/dev/null; echo '*/5 * * * * git -C /home/ghrunner/infra-portainer pull --ff-only origin main') | crontab -
```

## Accessing the UI

The UI is bound to `127.0.0.1` on the server. From your machine:

```bash
make tunnel HOST=user@server          # prints the exact command, or:
ssh -L 9000:127.0.0.1:9000 user@server
# then browse http://localhost:9000
```

For persistent access, terminate TLS at a host-level reverse proxy (Caddy/Traefik/nginx) pointed
at `127.0.0.1:9000`.

## Customization & extension

- **App Templates** — edit `docker/portainer/templates/templates.json` and push. Portainer reloads
  it from `PORTAINER_TEMPLATES_URL` (its raw GitHub URL) with no image rebuild.
- **`.env` toggles** (`docker/.env`):
  - `PORTAINER_HTTP_PORT` — host port for the UI.
  - `PORTAINER_ENABLE_EXEC` / `PORTAINER_ENABLE_BUILD` — open the socket-proxy `EXEC`/`BUILD` groups
    (container console, image builds). Off by default.
  - `PORTAINER_SWARM` — enable the Swarm API groups when managing a cluster.
  - `PORTAINER_EXTRA_ARGS` — extra Portainer flags (edge, logging, custom logout hostname, …).
- **Baked-in changes** — extend `docker/portainer/Dockerfile` (COPY UI assets, add binaries) then push;
  the signed image updates automatically.
- **Post-deploy hook** — for API-driven provisioning (endpoints/stacks), add a
  `PLUGIN_POST_DEPLOY_*` entry to `deploy/.infra-runner.plugin` (see `infra-runner/deployer/PLUGINS.md`).

## Upgrading

Bump the base tag in `docker/portainer/Dockerfile` (`FROM portainer/portainer-ce:<new>`) and push.
CI rebuilds + signs; the deployer pulls the new digest and recreates the container.

## Troubleshooting

- **Initial admin setup timed out** — Portainer locks admin creation shortly after first start if
  left unconfigured. `docker restart portainer`, then reopen the tunnel promptly.
- **A Portainer action returns 403 / "permission denied"** — the socket-proxy is denying that Docker
  API group. Enable the relevant toggle (`PORTAINER_ENABLE_EXEC`, `PORTAINER_ENABLE_BUILD`,
  `PORTAINER_SWARM`) in `docker/.env` and `make up`.
- **Deployer stays unhealthy / won't deploy** — cosign verification failed. Confirm the GHCR package
  is **public** and that `PORTAINER_CERT_IDENTITY` matches the signing workflow exactly (`ci.yml`, not
  `deploy.yml`).
- **Changes to compose/.env/plugin not taking effect** — the deployer only updates the *image*. Pull
  the on-server clone (or wait for the cron) so compose/env/descriptor changes land.
