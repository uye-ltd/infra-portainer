# infra-portainer

Portainer CE for the UYE infrastructure. Runs as a Docker container on a bare-metal server,
manages Docker through a read-limited socket-proxy, and auto-updates via GitHub Actions +
the [infra-runner](https://github.com/uye-ltd/infra-runner) GitOps deployer.

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [First-time server setup](#first-time-server-setup)
- [Connecting the CI/CD pipeline](#connecting-the-cicd-pipeline)
- [Verifying a deployment](#verifying-a-deployment)
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

Do this **first**: make the GHCR package public at
`https://github.com/orgs/uye-ltd/packages/container/portainer/settings`. Everything below depends on
it — the deployer authenticates to GitHub as an App, and App installation tokens cannot pull private
GHCR packages.

The clone must live at `/home/ghrunner/infra-portainer` and be owned by `ghrunner`. That path is
load-bearing: infra-runner's `COMPOSE_FILE` refers to `../infra-portainer/...`, resolved relative to
`/home/ghrunner/infra-runner`.

```bash
# Option A — one-liner, run as ghrunner
curl -fsSL https://raw.githubusercontent.com/uye-ltd/infra-portainer/main/scripts/bootstrap.sh | bash

# Option B — manual, from any sudo-capable account
sudo -u ghrunner git clone https://github.com/uye-ltd/infra-portainer.git /home/ghrunner/infra-portainer
sudo -u ghrunner cp /home/ghrunner/infra-portainer/docker/.env.example \
                    /home/ghrunner/infra-portainer/docker/.env

sudo -u ghrunner bash -c 'cd /home/ghrunner/infra-portainer && \
  docker compose -f docker/docker-compose.yml pull portainer && \
  docker compose -f docker/docker-compose.yml up -d'
```

Two things about that last command:

- **`cd` goes inside the `sudo`.** `/home/ghrunner` is mode `750`, so your own user cannot traverse it,
  and `sudo cd` fails with `sudo: 'cd': command not found` — `cd` is a shell builtin, not a binary.
- **`pull` before `up`.** Without it, compose builds the wrapper locally from the `build:` key and tags
  the result `ghcr.io/uye-ltd/portainer:latest`, so you'd be running an *unsigned* image. The whole
  point of the wrapper is that the deployer verifies its cosign signature.

This creates `portainer-net`, the `portainer-data` volume, and both containers. The deployer only ever
runs `up -d --no-deps portainer`, so the proxy, network, and volume must already exist.

Then:

1. **Register with the deployer** — see below.
2. **Set the admin password.** Open a tunnel and create the admin user (see [Accessing the UI](#accessing-the-ui)).
   The admin password is intentionally not pre-seeded (a bcrypt hash breaks compose interpolation, and a
   password-file bind mount would break under the deployer). If Portainer's initial-setup window times
   out, run `docker restart portainer` and retry promptly.

**GitHub Secrets: none required for deployment.** CI's only credential is the automatic `GITHUB_TOKEN`.

## Connecting the CI/CD pipeline

CI (`.github/workflows/ci.yml`) has two jobs:

- **`validate`** (GitHub-hosted, PR + push): `docker compose config` and `jq` validate the compose
  file and `templates.json`.
- **`build`** (self-hosted on the infra-runner, push only): Buildah builds the wrapper image with
  fuse-overlayfs (`--isolation=chroot`), pushes `:latest` + `:<sha>` to GHCR, and **cosign-signs by
  digest** via keyless OIDC. All `uses:` are SHA-pinned.

Both jobs may briefly sit at *"Waiting for a runner to pick up this job"* — hosted-runner provisioning
for `validate`, and the warm self-hosted fleet for `build`. That resolves on its own.

Register the plugin on the server by editing **infra-runner's `.env`**. `COMPOSE_FILE` is shared with
`docker-compose.override.yml` and the vault overlay, so it must be **appended to, never replaced** —
overwriting it silently unregisters the vault plugin.

```bash
sudo -u ghrunner cp /home/ghrunner/infra-runner/.env /home/ghrunner/infra-runner/.env.bak

# Appends the overlay to the existing COMPOSE_FILE line. Not idempotent — run once.
sudo -u ghrunner sed -i \
  's#^COMPOSE_FILE=.*#&:../infra-portainer/deploy/docker-compose.infra-runner.yml#' \
  /home/ghrunner/infra-runner/.env

sudo -u ghrunner bash -c 'printf "\nPORTAINER_DIR=/home/ghrunner/infra-portainer\nPORTAINER_CERT_IDENTITY=https://github.com/uye-ltd/infra-portainer/.github/workflows/ci.yml@refs/heads/main\n" >> /home/ghrunner/infra-runner/.env'
```

Signing happens in `ci.yml`, so `PORTAINER_CERT_IDENTITY` ends in `ci.yml` — **not** `deploy.yml`.

Check the result before recreating anything. Expect one `COMPOSE_FILE` line ending in the portainer
overlay and still containing the override + vault entries, plus the two `PORTAINER_*` lines:

```bash
sudo -u ghrunner grep -E '^COMPOSE_FILE|^PORTAINER_' /home/ghrunner/infra-runner/.env
# COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:../infra-vault/docker-compose.infra-runner.yml:../infra-portainer/deploy/docker-compose.infra-runner.yml
# PORTAINER_DIR=/home/ghrunner/infra-portainer
# PORTAINER_CERT_IDENTITY=https://github.com/uye-ltd/infra-portainer/.github/workflows/ci.yml@refs/heads/main
```

Then recreate only the deployer:

```bash
sudo -u ghrunner bash -c 'cd /home/ghrunner/infra-runner && docker compose up -d --no-deps deployer'
```

Because the deployer never `git pull`s the plugin checkout, keep the on-server clone current with a cron:

```bash
sudo -u ghrunner bash -c "crontab -l 2>/dev/null; echo '*/5 * * * * git -C /home/ghrunner/infra-portainer pull --ff-only origin main'" | sudo -u ghrunner crontab -
```

## Verifying a deployment

```bash
# Both plugins mounted — portainer registered, vault survived the COMPOSE_FILE edit
docker exec infra-runner-deployer-1 ls /plugins        # portainer.plugin  vault-unseal.plugin

# Deployer is polling, with no pull or signature failures
docker logs --since 5m infra-runner-deployer-1 | grep -iE 'portainer|pull failed|verification FAILED'
#   want: "Checking plugin" plugin=portainer   — and nothing else

# Stack is healthy and answering
docker ps --filter name=portainer --format '{{.Names}}\t{{.Status}}'
curl -sf http://127.0.0.1:9000/api/status              # {"Version":"2.27.9",...}

# The running image is the one CI signed
docker image inspect ghcr.io/uye-ltd/portainer:latest --format '{{join .RepoDigests " "}}'

# Signature verifies. cosign is not on the host — borrow the deployer's copy.
docker exec infra-runner-deployer-1 cosign verify \
  --certificate-identity https://github.com/uye-ltd/infra-portainer/.github/workflows/ci.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/uye-ltd/portainer:latest

# The socket-proxy really is gating the API: denied group vs. allowed group
docker exec portainer wget -qSO- http://portainer-proxy:2375/swarm    2>&1 | head -1  # 403 Forbidden
docker exec portainer wget -qSO- http://portainer-proxy:2375/networks 2>&1 | head -1  # 200 OK
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
  the signed image updates automatically. Keep the base image registry-qualified
  (`docker.io/portainer/portainer-ce:…`) — see [Troubleshooting](#troubleshooting).
- **Local development** — `make up` / `make build` build the wrapper from source, which is the point
  locally. Never do this on the server; it produces an unsigned image under the GHCR tag.
- **Post-deploy hook** — for API-driven provisioning (endpoints/stacks), add a
  `PLUGIN_POST_DEPLOY_*` entry to `deploy/.infra-runner.plugin` (see `infra-runner/deployer/PLUGINS.md`).

## Upgrading

Bump the base tag in `docker/portainer/Dockerfile` (`FROM docker.io/portainer/portainer-ce:<new>` —
keep the registry prefix) and push.
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
- **CI: `short-name "portainer/portainer-ce:…" did not resolve to an alias and no unqualified-search
  registries are defined`** — Buildah, unlike Docker, will not guess a registry. It resolves short
  names only from the `containers-common` alias table (`alpine` is in it; namespaced third-party
  images are not). Fully qualify the base image: `FROM docker.io/portainer/portainer-ce:…`.
- **`cd: /home/ghrunner/infra-portainer: Permission denied`, and `sudo cd` says `'cd': command not
  found`** — `/home/ghrunner` is mode `750`, and `cd` is a shell builtin rather than a binary, so
  `sudo` cannot run it. Put the `cd` inside a `ghrunner` shell:
  `sudo -u ghrunner bash -c 'cd /home/ghrunner/infra-portainer && …'`.
- **Recreating the deployer fails with `invalid spec: :/workspace-portainer:ro: empty section between
  colons`** (plus `WARN The "PORTAINER_DIR" variable is not set`) — `PORTAINER_DIR` is missing from
  infra-runner's `.env`, so the overlay's bind mount expands to an empty source. Add it and retry;
  don't force it, as a blank value would mount the wrong path.
- **Checking whether the GHCR package is really public** — query the registry directly. Buildah pushes
  a single-arch **OCI image manifest**, so a probe that only offers the *index* media types comes back
  `MANIFEST_UNKNOWN` and looks private when it isn't. Ask for the image-manifest type and expect `200`
  (a private package gives `403`):

  ```bash
  TOK=$(curl -s 'https://ghcr.io/token?scope=repository:uye-ltd/portainer:pull&service=ghcr.io' \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  curl -s -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $TOK" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    https://ghcr.io/v2/uye-ltd/portainer/manifests/latest
  ```
