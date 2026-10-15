# infra-portainer

Portainer CE for the UYE infrastructure. The UI binds to `127.0.0.1:9000` and uses `portainer-proxy` for Docker access. The proxy permits `CONTAINERS+POST`, so Portainer remains a host-level Docker risk and needs a separate isolation project.

## Release

CI validates configuration, builds `ghcr.io/uye-ltd/portainer` with an OCI commit revision label, signs its SHA-tagged digest and promotes that digest to `latest` after checks. The GHCR package must be public. CI has no SSH or server deploy credential.

The Ansible-installed host executor in `infra-ansible/roles/uye_deploy` independently verifies protected `main`, fast-forward history, SHA/latest agreement, exact signing identity and revision label. It pulls by digest, updates only the fixed `infra-portainer/portainer` Compose service, checks image ID and health, and restores the previous signed digest on a post-update health failure. The existing `infra-portainer_portainer-data` volume and `portainer-net` network are preserved. The infra-runner poller only reports signatures and cannot use Docker API.

The old `deploy/.infra-runner.plugin` and `deploy/docker-compose.infra-runner.yml` are retired and inert. Do not add them to runner `COMPOSE_FILE` or mount this checkout into the poller. The old manual `docker compose pull` bootstrap path is not an authorized production release path. Prepare and transfer the running service through `infra-ansible/playbooks/deployer-prepare.yml` and `playbooks/deployer-cutover.yml` after published releases pass verification.

## Access

Reach `127.0.0.1:9000` through the VPN reverse proxy or an SSH tunnel. Portainer data stays on the named volume. Its admin account remains an operator-managed secret. The socket proxy filters API paths, not container creation parameters; avoid treating its `EXEC=0` and `BUILD=0` settings as a container sandbox.

## Local checks

Run `docker compose -f docker/docker-compose.yml config --quiet` and the repository CI validation. Check executor status with `systemctl status uye-deploy.timer uye-deploy.service` and `/run/uye-deploy/status.json` on the server. Poller `/health` is observational only.
