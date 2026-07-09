# Thin wrapper around the upstream Portainer CE image.
#
# Why wrap it at all: the infra-runner deployer only pulls images carrying a cosign signature
# whose OIDC identity matches THIS repo's CI workflow. Upstream portainer/portainer-ce is not
# signed that way, so we rebuild it here, push to GHCR, and cosign-sign it in ci.yml.
#
# The -alpine variant ships a shell + wget (the default image is distroless), which the compose
# healthcheck relies on and which makes any future baked-in customization simpler.
#
# This is currently a passthrough — it inherits Portainer's ENTRYPOINT unchanged. It is also the
# extension point: COPY in custom UI assets, extra binaries, etc. Bump the base tag to upgrade.
#
# The registry is spelled out: CI builds with Buildah, which refuses to resolve short names that
# aren't in the containers-common shortname alias table (Docker would silently assume docker.io).
FROM docker.io/portainer/portainer-ce:2.27.9-alpine

LABEL org.opencontainers.image.source="https://github.com/uye-ltd/infra-portainer" \
      org.opencontainers.image.title="uye-portainer" \
      org.opencontainers.image.description="Portainer CE for UYE infra, deployed via infra-runner"
