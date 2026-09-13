# arm64 self-host build for excalidraw-collaboration (any arm64 device --
# Raspberry Pi, other SBCs, arm64 VPS, etc).
#
# The upstream images in basic/docker-compose.yaml only publish linux/amd64
# manifests, so this builds all three services natively for arm64 instead.
# See basic/README-arm64.md for the full explanation of why each step below
# is needed.
#
# Usage:
#   make all IP=10.0.0.1
#
# Or step by step:
#   make clone
#   make build
#   make certs IP=10.0.0.1
#   make up
#
# IP is only needed for the TLS certificate (Live Collaboration requires
# HTTPS, so the cert's IP must match whatever address you actually browse
# to). The frontend image itself is address-independent -- it only ever
# talks to whatever origin served the page, so one build works from any
# address the cert (and your network) allows.
#
# To also reach it over a second address (e.g. a Tailscale IP in addition
# to your LAN IP), pass TS_IP too -- it just adds another SAN to the same
# cert, no rebuild of the frontend needed:
#   make certs IP=10.0.0.1 TS_IP=100.x.x.x
#
# If the device's IP ever changes, just regenerate the cert:
#   make certs IP=<new-IP>
# (no need to rebuild or restart anything else).

DOCKER       ?= docker
COMPOSE      ?= $(DOCKER) compose -f basic/docker-compose.arm64.yaml
BUILD_DIR    := build
CERT_DIR     := basic/certs
comma        := ,

FRONTEND_TAG := v0.18.1-fork-b2
STORAGE_TAG  := v2023.11.11
ROOM_TAG     := v0.1.0

FRONTEND_IMG := excalidraw-frontend:arm64-$(FRONTEND_TAG)
STORAGE_IMG  := excalidraw-storage-backend:arm64-$(STORAGE_TAG)
ROOM_IMG     := excalidraw-room-go:arm64-$(ROOM_TAG)

TS_IP        ?=
SANS         := IP:$(IP)$(if $(TS_IP),$(comma)IP:$(TS_IP))

.PHONY: all install-docker clone patch \
        build build-frontend build-storage build-room \
        certs up down restart ps logs clean distclean check-ip

all: clone build certs up

## --- one-time host setup -----------------------------------------------

install-docker:
	curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $$(. /etc/os-release && echo $$VERSION_CODENAME) stable" \
		| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
	sudo apt-get update
	sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	sudo usermod -aG docker $$USER
	@echo "Log out and back in for group membership to take effect, then re-run make."

## --- fetch + patch upstream source --------------------------------------

clone:
	mkdir -p $(BUILD_DIR)
	[ -d $(BUILD_DIR)/excalidraw-frontend ] || \
		git clone --depth 1 --branch $(FRONTEND_TAG) https://github.com/alswl/excalidraw.git $(BUILD_DIR)/excalidraw-frontend
	[ -d $(BUILD_DIR)/excalidraw-storage-backend ] || \
		git clone --depth 1 --branch $(STORAGE_TAG) https://github.com/alswl/excalidraw-storage-backend.git $(BUILD_DIR)/excalidraw-storage-backend
	[ -d $(BUILD_DIR)/excalidraw-room-go ] || \
		git clone --depth 1 --branch $(ROOM_TAG) https://github.com/alswl/excalidraw-room-go.git $(BUILD_DIR)/excalidraw-room-go
	$(MAKE) patch

patch: $(BUILD_DIR)/excalidraw-storage-backend/.patched $(BUILD_DIR)/excalidraw-frontend/.patched

$(BUILD_DIR)/excalidraw-storage-backend/.patched: Makefile
	sed -i 's/npm install -g @nestjs\/cli$$/npm install -g @nestjs\/cli@8/' $(BUILD_DIR)/excalidraw-storage-backend/Dockerfile
	grep -q 'mkdir -p /app/data' $(BUILD_DIR)/excalidraw-storage-backend/Dockerfile || \
		sed -i '/^USER node$$/i RUN mkdir -p /app/data \&\& chown node:node /app/data\n' \
		$(BUILD_DIR)/excalidraw-storage-backend/Dockerfile
	touch $@

# Frontend gets: (a) node:18 -> node:22 (unpinned transitive deps -- marked,
# chevrotain -- now need newer Node than existed in 2023), and (b) fixed
# relative-path ENV values instead of the upstream defaults (which point at
# oss-collab.excalidraw.com / json.excalidraw.com). Relative paths, not a
# baked-in https://<IP> -- fetch() resolves them against whatever origin
# served the page, so this works from any address. VITE_APP_WS_SERVER_URL
# is deliberately left unset: socket.io-client's own default already falls
# back to window.location when no URL is given.
$(BUILD_DIR)/excalidraw-frontend/.patched: Makefile
	sed -i 's/^FROM node:18 AS build$$/FROM node:22 AS build/' $(BUILD_DIR)/excalidraw-frontend/Dockerfile
	grep -q VITE_APP_HTTP_STORAGE_BACKEND_URL $(BUILD_DIR)/excalidraw-frontend/Dockerfile || \
		sed -i '/^RUN yarn build:app:docker$$/i \
ENV VITE_APP_BACKEND_V2_GET_URL=/api/v2/scenes/\
ENV VITE_APP_BACKEND_V2_POST_URL=/api/v2/scenes/\
ENV VITE_APP_HTTP_STORAGE_BACKEND_URL=/api/v2\
ENV VITE_APP_STORAGE_BACKEND=http\
ENV VITE_APP_FIREBASE_CONFIG={}' \
		$(BUILD_DIR)/excalidraw-frontend/Dockerfile
	touch $@

## --- build images natively for arm64 ------------------------------------

check-ip:
ifndef IP
	$(error IP is not set. Usage: make certs IP=10.0.0.1)
endif

build: build-room build-storage build-frontend

build-room: clone
	$(DOCKER) build --build-arg VERSION=$(ROOM_TAG) -t $(ROOM_IMG) $(BUILD_DIR)/excalidraw-room-go

build-storage: clone
	$(DOCKER) build -t $(STORAGE_IMG) $(BUILD_DIR)/excalidraw-storage-backend

build-frontend: clone
	$(DOCKER) build -t $(FRONTEND_IMG) $(BUILD_DIR)/excalidraw-frontend

## --- TLS cert (required: Live Collaboration needs a secure context) ----

certs: check-ip
	mkdir -p $(CERT_DIR)
	openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
		-keyout $(CERT_DIR)/privkey.pem -out $(CERT_DIR)/fullchain.pem \
		-subj "/CN=$(IP)" -addext "subjectAltName=$(SANS)"

## --- run -----------------------------------------------------------------

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart: down up

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail 50

## --- cleanup ---------------------------------------------------------------

clean:
	rm -rf $(BUILD_DIR)

distclean: down clean
	rm -rf $(CERT_DIR)
	$(DOCKER) image rm -f $(FRONTEND_IMG) $(STORAGE_IMG) $(ROOM_IMG) 2>/dev/null || true
