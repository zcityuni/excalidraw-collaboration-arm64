# Running excalidraw-collaboration on arm64 devices

## Quick start

From the repo root, on the arm64 device itself:

```sh
make install-docker   # one-time, only if Docker isn't already installed
make all IP=<this-device's-LAN-IP>
```

Then visit `https://<IP>` (click through the one-time self-signed cert
warning). See `make help`-equivalent targets below if you want to run the
steps individually (`clone`, `build`, `certs`, `up`, `down`, `logs`, `clean`).

`IP` must be baked in again (`make build certs up`) any time the device's
LAN IP changes -- both the frontend bundle and the TLS cert are built for
that specific address.

## Why this is needed

The upstream `basic/docker-compose.yaml` pins three images that only publish
`linux/amd64` manifests on Docker Hub (confirmed via the registry API,
Sept 2026):

- `alswl/excalidraw:v0.18.1-fork-b2`
- `alswl/excalidraw-storage-backend:v2023.11.11`
- `alswl/excalidraw-room-go:v0.1.0`

None of the three actually need cross-compilation or emulation — all are
built with ordinary multi-arch base images (Go, Node, nginx) with no
amd64-specific assumptions in their Dockerfiles. Building natively on the
the device (arm64 host -> arm64 image, no QEMU needed) works, but required three
unrelated fixes because the source hasn't been rebuilt since 2023 and some
dependencies float on unpinned version ranges:

## 1. excalidraw-room-go (Go) -- worked with no changes

Plain `docker build .` on the tag `v0.1.0` source just worked.

## 2. excalidraw-storage-backend (NestJS) -- global CLI version drift

The Dockerfile runs `npm install -g @nestjs/cli` with no version pin.
In 2023 that resolved to Nest CLI 8.x, matching the project's own
`@nestjs/cli: ^8.0.0`. Today it installs the latest CLI (v11+), which
pulls in a far newer TypeScript than the project's pinned `^4.3.5`,
causing real compile errors (TS5011, TS5101, and a genuine type error on
`import * as Keyv from 'keyv'`).

**Fix:** pin the Dockerfile's global install to match the project:
`RUN npm install -g @nestjs/cli@8`.

## 3. excalidraw (frontend, Vite/React) -- two problems

**a) Node version floor drift.** The Dockerfile built on `node:18`.
Two *unpinned transitive* dependencies now resolve to majors that need a
newer Node than existed in 2023: `marked@16` needs Node >=20, and
`chevrotain@12` needs Node >=22. Bumped the build stage to `node:22`
(the final image is still `nginx:1.27-alpine`, so this only affects
build tooling, not the runtime container).

**b) VITE_APP_* is a build-time value, not a runtime env var.** Vite
inlines `import.meta.env.VITE_APP_*` into the static JS bundle at
`vite build` time. The upstream `docker-compose.yaml` sets these under
the frontend service's `environment:`, which does **nothing** for a
static nginx-served build -- it silently has zero effect. The published
upstream image must have been built by the vendor's own CI with these
values already baked in (hardcoded to `127.0.0.1`, i.e. only usable from
the same machine as the browser).

**Fix:** added `ARG`/`ENV` passthrough in the Dockerfile for the six
`VITE_APP_*` vars, and pass them as `--build-arg` at image build time,
pointing at the device's LAN IP instead of `127.0.0.1` so other devices on
the network can actually reach the storage/room services.

## Reproducing this build

```sh
mkdir -p build && cd build
git clone --depth 1 --branch v0.18.1-fork-b2 https://github.com/alswl/excalidraw.git excalidraw-frontend
git clone --depth 1 --branch v2023.11.11 https://github.com/alswl/excalidraw-storage-backend.git excalidraw-storage-backend
git clone --depth 1 --branch v0.1.0 https://github.com/alswl/excalidraw-room-go.git excalidraw-room-go

# storage-backend: pin the global nest CLI (Dockerfile line ~19)
sed -i 's/npm install -g @nestjs\/cli/npm install -g @nestjs\/cli@8/' excalidraw-storage-backend/Dockerfile
docker build -t excalidraw-storage-backend:arm64-v2023.11.11 excalidraw-storage-backend

# room-go: builds as-is
docker build --build-arg VERSION=v0.1.0 -t excalidraw-room-go:arm64-v0.1.0 excalidraw-room-go

# frontend: bump to node:22, add VITE_APP_* ARG/ENV passthrough (see this
# repo's excalidraw-frontend/Dockerfile for the exact diff), then:
docker build \
  --build-arg VITE_APP_BACKEND_V2_GET_URL=http://<YOUR_LAN_IP>:8081/api/v2/scenes/ \
  --build-arg VITE_APP_BACKEND_V2_POST_URL=http://<YOUR_LAN_IP>:8081/api/v2/scenes/ \
  --build-arg VITE_APP_WS_SERVER_URL=http://<YOUR_LAN_IP>:8082 \
  --build-arg VITE_APP_HTTP_STORAGE_BACKEND_URL=http://<YOUR_LAN_IP>:8081/api/v2 \
  --build-arg VITE_APP_STORAGE_BACKEND=http \
  --build-arg VITE_APP_FIREBASE_CONFIG='{}' \
  -t excalidraw-frontend:arm64-v0.18.1-fork-b2 excalidraw-frontend

cd ../basic
docker compose -f docker-compose.arm64.yaml up -d
```

Replace `<YOUR_LAN_IP>` in both the build-args above and in
`docker-compose.arm64.yaml`'s comments if deploying to a different host.

## Verified working (2026-09-13)

- `docker compose -f docker-compose.arm64.yaml ps` -- all three containers
  `Up`, frontend `healthy`.
- `POST /api/v2/scenes` on the storage backend returns `201` with CORS
  wide open (`Access-Control-Allow-Origin: *`).
- Room server responds `200` on the socket.io polling handshake.
- Frontend HTML/JS confirmed to reference the LAN IP, not `127.0.0.1` or
  the upstream `oss-collab.excalidraw.com` / `json.excalidraw.com`
  defaults.
- Access at: http://10.0.0.1

## Update: Live Collaboration requires HTTPS

After the above was working, "Start session" under Live Collaboration did
nothing when clicked -- no error dialog, no console-visible feedback in the
UI. Root cause: Excalidraw's collaboration feature end-to-end encrypts room
data using the browser's Web Crypto API
(`window.crypto.subtle.generateKey`, see
`packages/excalidraw/data/encryption.ts`). Browsers only expose
`crypto.subtle` in a **secure context**: `https:`, or `http://localhost`.
Serving over plain `http://10.0.0.1` (a LAN IP) is not a secure
context, so `window.crypto.subtle` is `undefined`, the call throws inside
an unhandled promise, and the button silently no-ops.

**Fix:** added a TLS-terminating nginx reverse proxy in front of everything:

- `certs/fullchain.pem` / `certs/privkey.pem` -- self-signed cert,
  `subjectAltName=IP:10.0.0.1`, generated with:
  `openssl req -x509 -nodes -newkey rsa:2048 -days 825 -keyout privkey.pem -out fullchain.pem -subj '/CN=10.0.0.1' -addext 'subjectAltName=IP:10.0.0.1'`
- `nginx-tls.conf` -- proxy container listens on 80 (redirects to 443) and
  443 (TLS terminate), path-routing `/` -> frontend, `/api/v2/` -> storage,
  `/socket.io/` -> room (with websocket upgrade headers).
- `docker-compose.arm64.yaml` -- added a `proxy` service (nginx:1.27-alpine)
  owning host ports 80/443; `frontend` no longer publishes a host port
  directly (only reachable via the proxy now).
- Rebuilt the frontend image with build-args pointing at
  `https://10.0.0.1` (path-routed through the proxy, no port suffix
  needed) instead of `http://10.0.0.1:8081` / `:8082`.

**You must now visit https://10.0.0.1** (not http://). Since the cert
is self-signed, every browser/device will show a security warning the
*first* visit -- click through it (e.g. Chrome: Advanced -> Proceed). After
that, `crypto.subtle` is available and Live Collaboration works normally.
This is a one-time-per-device click-through, not a real trust problem for a
private LAN tool -- for a warning-free experience across all your devices,
consider fronting this with Tailscale (`tailscale serve`) instead, which
gets a real trusted cert with no warning.

Verified: `curl -k https://10.0.0.1/` -> 200, storage POST -> 201,
room socket.io handshake -> 200, plain `http://` -> 301 redirect to https.
