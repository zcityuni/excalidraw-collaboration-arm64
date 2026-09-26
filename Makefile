# Self-hosted excalidraw-collaboration, built natively (arm64 or amd64).
#
#   make all HOSTS=<lan-ip>          clone, patch, build, make a cert, start
#
# Step by step:
#   make clone                        fetch upstream sources + apply patches/
#   make build                        build the three images
#   make certs HOSTS="<ip> <name>"    self-signed TLS cert for those addresses
#   make up / down / ps / logs
#
# HOSTS is only used for the TLS certificate: the IPs and/or hostnames people
# will open in their browser. The images themselves are address-independent.
# See basic/README-arm64.md.

DOCKER    ?= docker
COMPOSE   ?= $(DOCKER) compose -f basic/docker-compose.arm64.yaml
BUILD_DIR := build
CERT_DIR  := basic/certs

# Upstream sources, pinned to the releases the patches were written against.
FRONTEND_REPO := https://github.com/alswl/excalidraw.git
FRONTEND_REF  := v0.18.1-fork-b2
STORAGE_REPO  := https://github.com/alswl/excalidraw-storage-backend.git
STORAGE_REF   := v2023.11.11
ROOM_REPO     := https://github.com/alswl/excalidraw-room-go.git
ROOM_REF      := v0.1.0

# TAG overrides all three image tags at once, e.g. `make build TAG=lab`.
FRONTEND_IMG := excalidraw-frontend:$(or $(TAG),arm64-$(FRONTEND_REF))
STORAGE_IMG  := excalidraw-storage-backend:$(or $(TAG),arm64-$(STORAGE_REF))
ROOM_IMG     := excalidraw-room-go:$(or $(TAG),arm64-$(ROOM_REF))

COMPONENTS := excalidraw-frontend excalidraw-storage-backend excalidraw-room-go

.PHONY: all install-docker clone patch build build-frontend build-storage \
        build-room certs up down restart ps logs clean distclean

all: clone build certs up

## --- one-time host setup (Debian / Raspberry Pi OS) ------------------------

install-docker:
	curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $$(. /etc/os-release && echo $$VERSION_CODENAME) stable" \
		| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
	sudo apt-get update
	sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	sudo usermod -aG docker $$USER
	@echo "Log out and back in for group membership to take effect, then re-run make."

## --- fetch + patch upstream source ------------------------------------------

clone:
	@mkdir -p $(BUILD_DIR)
	@[ -d $(BUILD_DIR)/excalidraw-frontend ] || git clone --depth 1 --branch $(FRONTEND_REF) $(FRONTEND_REPO) $(BUILD_DIR)/excalidraw-frontend
	@[ -d $(BUILD_DIR)/excalidraw-storage-backend ] || git clone --depth 1 --branch $(STORAGE_REF) $(STORAGE_REPO) $(BUILD_DIR)/excalidraw-storage-backend
	@[ -d $(BUILD_DIR)/excalidraw-room-go ] || git clone --depth 1 --branch $(ROOM_REF) $(ROOM_REPO) $(BUILD_DIR)/excalidraw-room-go
	@$(MAKE) --no-print-directory patch

patch: $(foreach c,$(COMPONENTS),$(BUILD_DIR)/$(c)/.patched)

# Each component is reset to pristine upstream source, then every file in
# patches/<component>/ is applied in order. Re-runs whenever the Makefile or a
# patch changes, and never builds on top of a half-patched tree.
.SECONDEXPANSION:
$(BUILD_DIR)/%/.patched: Makefile $$(wildcard patches/%/*.patch)
	git -C $(@D) reset -q --hard
	git -C $(@D) clean -fdq
	@for p in $(sort $(wildcard patches/$*/*.patch)); do \
		echo "applying $$p"; git -C $(@D) apply $(CURDIR)/$$p || exit 1; \
	done
	@touch $@

## --- build ------------------------------------------------------------------

build: build-room build-storage build-frontend

build-room: clone
	$(DOCKER) build --build-arg VERSION=$(ROOM_REF) -t $(ROOM_IMG) $(BUILD_DIR)/excalidraw-room-go

build-storage: clone
	$(DOCKER) build -t $(STORAGE_IMG) $(BUILD_DIR)/excalidraw-storage-backend

# Anything the frontend doesn't pin falls back to excalidraw.com's public
# services (Firebase storage, the oss-collab relay). Refuse to build without
# the two settings that keep it self-hosted.
build-frontend: clone
	@for line in 'ENV VITE_APP_STORAGE_BACKEND=http' 'ENV VITE_APP_WS_SERVER_URL=/'; do \
		grep -qx "$$line" $(BUILD_DIR)/excalidraw-frontend/Dockerfile || \
		{ echo "ERROR: frontend Dockerfile is missing '$$line' -- run 'make clean clone'"; exit 1; }; \
	done
	$(DOCKER) build -t $(FRONTEND_IMG) $(BUILD_DIR)/excalidraw-frontend

## --- TLS certificate (Live Collaboration needs HTTPS) ------------------------

certs:
	@[ -n "$(HOSTS)" ] || { echo 'Usage: make certs HOSTS="<ip-or-hostname> [...]"'; exit 1; }
	@mkdir -p $(CERT_DIR)
	@sans=""; for h in $(HOSTS); do \
		case $$h in *[!0-9.]*) sans="$$sans,DNS:$$h";; *) sans="$$sans,IP:$$h";; esac; \
	done; \
	openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
		-keyout $(CERT_DIR)/privkey.pem -out $(CERT_DIR)/fullchain.pem \
		-subj "/CN=$(firstword $(HOSTS))" -addext "subjectAltName=$${sans#,}" 2>/dev/null && \
	echo "certificate for: $${sans#,}"

## --- run --------------------------------------------------------------------

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart: down up

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail 50

## --- cleanup ----------------------------------------------------------------

clean:
	rm -rf $(BUILD_DIR)

# Removes the containers, images and certificate. Keeps the storage volume.
distclean: down clean
	rm -rf $(CERT_DIR)
	$(DOCKER) image rm -f $(FRONTEND_IMG) $(STORAGE_IMG) $(ROOM_IMG) 2>/dev/null || true
