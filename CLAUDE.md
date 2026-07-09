# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Portainer CE for the UYE infrastructure, deployed and auto-updated by the infra-runner GitOps
deployer. This repo holds the compose stack, a thin wrapper image, CI that builds + cosign-signs
it, and the infra-runner plugin descriptor.

## Architecture

- `docker/docker-compose.yml` — two services on the `portainer-net` bridge:
  - `portainer` — our image `ghcr.io/uye-ltd/portainer` (built from `docker/portainer/Dockerfile`).
    Talks to Docker via `-H tcp://portainer-proxy:2375`. UI bound to `127.0.0.1:9000`.
  - `portainer-proxy` — `tecnativa/docker-socket-proxy` (pinned by digest), the only thing that
    mounts `/var/run/docker.sock`.
- `docker/portainer/Dockerfile` — `FROM portainer/portainer-ce:<tag>-alpine`, wrapper/extension point.
- `docker/portainer/templates/templates.json` — custom App Templates, served via `PORTAINER_TEMPLATES_URL`.
- `deploy/.infra-runner.plugin` + `deploy/docker-compose.infra-runner.yml` — register with the deployer.
- `.github/workflows/ci.yml` — `validate` (compose + JSON) and `build` (Buildah + cosign, self-hosted).
- `scripts/bootstrap.sh`, `Makefile` — server bootstrap and local ops.

## Common commands

```bash
make up        # docker compose up -d (builds wrapper on first run)
make down
make build     # rebuild the wrapper image
make logs      # follow portainer logs
make status    # compose ps
make tunnel HOST=user@server   # print SSH tunnel command for the localhost UI
```

## Key design decisions

- **Wrapper image for signing.** The deployer only pulls images whose cosign identity matches this
  repo's CI workflow, so upstream `portainer/portainer-ce` can't flow through it directly. We rebuild
  it (`FROM portainer/portainer-ce`) and sign in `ci.yml`. Hence `PLUGIN_CERT_IDENTITY` ends in
  `ci.yml@refs/heads/main`, not `deploy.yml`.
- **`portainer` service must have NO host bind mounts.** The deployer runs
  `docker compose --project-directory docker up -d --no-deps portainer`; relative bind paths would
  resolve to the deployer container's filesystem, not the host. Config comes via `docker/.env`; state
  via the `portainer-data` named volume. Only `portainer-proxy` (brought up by `make up`, never by the
  deployer) mounts the socket.
- **Socket-proxy, read-limited.** Management groups on by default; `EXEC`/`BUILD`/`SWARM` gated behind
  `.env` toggles. Enabling `EXEC`/`BUILD` widens the container-escape surface.
- **Admin password not pre-seeded.** A bcrypt hash contains `$` (breaks compose interpolation) and a
  password-file bind mount would break the deployer's path model. Operator sets it on first login.
- **`-alpine` base tag.** Gives the image a shell + `wget` for the compose healthcheck; the default
  Portainer image is distroless.
- **Base image must be registry-qualified.** `docker.io/portainer/portainer-ce`, not
  `portainer/portainer-ce`. CI builds with Buildah, which only resolves short names that appear in
  the `containers-common` shortname alias table (`alpine` is there; namespaced third-party images
  are not).
- **GHCR package must be public** — the deployer's GitHub-App token cannot pull private packages.

## GitHub Actions secrets required

None. CI uses only the automatic `GITHUB_TOKEN` (GHCR login + cosign registry auth).
