.PHONY: up down build logs status tunnel

COMPOSE = docker compose -f docker/docker-compose.yml
PORTAINER_HTTP_PORT ?= 9000

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

build:
	$(COMPOSE) build --pull

logs:
	$(COMPOSE) logs -f portainer

status:
	$(COMPOSE) ps

# Print the SSH tunnel command for reaching the localhost-bound UI.
# Usage: make tunnel HOST=user@server
tunnel:
	@echo "ssh -L $(PORTAINER_HTTP_PORT):127.0.0.1:$(PORTAINER_HTTP_PORT) $(HOST)"
	@echo "then browse: http://localhost:$(PORTAINER_HTTP_PORT)"
