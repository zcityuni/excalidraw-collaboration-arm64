# Self-hosted excalidraw-collaboration, built from source (arm64 or amd64).
#
#   make HOSTS="<ip-or-name> ..."    first install: certificate, build, start
#   make                             update: rebuild and restart, keep the cert
#   make build                       fetch + patch sources, build images (TAG=... to retag)
#   make certs HOSTS="..."           (re)make the TLS certificate
#   make up | down | logs            start | stop | follow logs
#   make sources                     fetch + patch sources only
#   make clean                       delete build/
#
# HOSTS lists every IP and hostname people will open in the browser; it only
# feeds the self-signed certificate. See basic/README-arm64.md.

DOCKER    ?= docker
COMPOSE   ?= $(DOCKER) compose -f basic/docker-compose.arm64.yaml
BUILD_DIR := build
CERT_DIR  := basic/certs

# Upstream sources, pinned to the releases the patches in patches/ target.
excalidraw-frontend_REPO        := https://github.com/alswl/excalidraw.git
excalidraw-frontend_REF         := v0.18.1-fork-b2
excalidraw-storage-backend_REPO := https://github.com/alswl/excalidraw-storage-backend.git
excalidraw-storage-backend_REF  := v2023.11.11
excalidraw-room-go_REPO         := https://github.com/alswl/excalidraw-room-go.git
excalidraw-room-go_REF          := v0.1.0
COMPONENTS := excalidraw-frontend excalidraw-storage-backend excalidraw-room-go

.PHONY: all sources build certs up down logs clean

all: certs build up

## --- sources ----------------------------------------------------------------

sources: $(foreach c,$(COMPONENTS),$(BUILD_DIR)/$(c)/.patched)

# Clone each component at its pinned release (re-cloning if the recorded
# release differs), reset it to pristine upstream, then apply
# patches/<component>/*.patch in order. Re-runs when the Makefile or a patch
# changes.
.SECONDEXPANSION:
$(BUILD_DIR)/%/.patched: Makefile $$(wildcard patches/%/*.patch)
	@if [ ! -d $(@D)/.git ] || [ "$$(cat $(BUILD_DIR)/.ref-$* 2>/dev/null)" != "$($*_REF)" ]; then \
		echo "cloning $* $($*_REF)"; rm -rf $(@D) $(BUILD_DIR)/.ref-$*; \
		git -c advice.detachedHead=false clone -q --depth 1 --branch $($*_REF) $($*_REPO) $(@D) || exit 1; \
		echo "$($*_REF)" > $(BUILD_DIR)/.ref-$*; \
	fi
	@git -C $(@D) reset -q --hard
	@git -C $(@D) clean -fdq
	@for p in $(sort $(wildcard patches/$*/*.patch)); do \
		echo "applying $$p"; git -C $(@D) apply $(CURDIR)/$$p || exit 1; \
	done
	@touch $@

## --- build ------------------------------------------------------------------

# Anything the frontend doesn't pin falls back to excalidraw.com's public
# services (Firebase storage, the oss-collab relay), so refuse to build
# without the two settings that keep it self-hosted.
build: sources
	@for line in 'ENV VITE_APP_STORAGE_BACKEND=http' 'ENV VITE_APP_WS_SERVER_URL=/'; do \
		grep -qx "$$line" $(BUILD_DIR)/excalidraw-frontend/Dockerfile || \
		{ echo "ERROR: frontend Dockerfile is missing '$$line' -- check patches/excalidraw-frontend/"; exit 1; }; \
	done
	$(DOCKER) build -t excalidraw-room-go:$(or $(TAG),arm64-$(excalidraw-room-go_REF)) \
		--build-arg VERSION=$(excalidraw-room-go_REF) $(BUILD_DIR)/excalidraw-room-go
	$(DOCKER) build -t excalidraw-storage-backend:$(or $(TAG),arm64-$(excalidraw-storage-backend_REF)) \
		$(BUILD_DIR)/excalidraw-storage-backend
	$(DOCKER) build -t excalidraw-frontend:$(or $(TAG),arm64-$(excalidraw-frontend_REF)) \
		$(BUILD_DIR)/excalidraw-frontend

## --- TLS certificate (Live Collaboration needs HTTPS) ------------------------

# With HOSTS: (re)generate. Without: fine if a certificate already exists,
# otherwise stop here -- before any build -- with the usage line.
certs:
	@if [ -n "$(HOSTS)" ]; then \
		mkdir -p $(CERT_DIR); sans=""; \
		for h in $(HOSTS); do \
			case $$h in *[!0-9.]*) sans="$$sans,DNS:$$h";; *) sans="$$sans,IP:$$h";; esac; \
		done; \
		openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
			-keyout $(CERT_DIR)/privkey.pem -out $(CERT_DIR)/fullchain.pem \
			-subj "/CN=$(firstword $(HOSTS))" -addext "subjectAltName=$${sans#,}" 2>/dev/null && \
		echo "certificate for: $${sans#,}"; \
	elif [ ! -f $(CERT_DIR)/fullchain.pem ]; then \
		echo 'No certificate yet. Run: make HOSTS="<ip-or-hostname> [...]"'; exit 1; \
	fi

## --- run --------------------------------------------------------------------

# A regenerated certificate is only picked up when nginx restarts.
up: certs
	$(COMPOSE) up -d
	$(if $(HOSTS),$(COMPOSE) restart proxy)

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f --tail 50

clean:
	rm -rf $(BUILD_DIR)
