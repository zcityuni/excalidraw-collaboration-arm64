# Running excalidraw-collaboration on arm64 devices

## Prerequisites

- An arm64 device (Raspberry Pi, other SBC, arm64 VPS, etc.) with SSH/shell access.
- Know the device's own LAN IP (`hostname -I`) — needed below as `IP`. This
  is only used for the TLS certificate; the app itself works from whatever
  address you actually browse to.

## Quick start

From the repo root, on the arm64 device itself:

```sh
make install-docker   # one-time, only if Docker isn't already installed
make all IP=<this-device's-LAN-IP>
```

Then visit `https://<IP>` — click through the one-time self-signed
certificate warning in your browser (this is required: Live Collaboration
needs HTTPS to work at all, plain `http://` will not support it).

## Reaching it from a second address too (e.g. Tailscale)

Add `TS_IP` when generating the cert to also cover another address on the
same certificate — no rebuild of the app needed, just a new cert:

```sh
make certs IP=<lan-ip> TS_IP=<tailscale-ip>
make up
```

## Individual steps

```sh
make clone                  # fetch + patch the three upstream source repos
make build                  # build all three images natively for arm64
make certs IP=<your-IP>     # generate a self-signed TLS cert for that IP
make up                     # start the stack
make ps                     # check container status
make logs                   # tail logs
make down                   # stop the stack
make clean                  # remove fetched source (keeps images/certs)
```

## If the device's IP ever changes

Just regenerate the cert — the app images don't need rebuilding:

```sh
make certs IP=<new-IP>
make up
```

## Boards list

Every live-collaboration room opened on the server is remembered server-side
(in the same SQLite volume). Open it from the main menu → **Boards**: most
recently opened first, with rename and remove. The server stores each room's
ID and encryption key so the list can reopen boards — fine for a server you
run yourself, but it does mean the server can read those boards.

Implemented as `patches/*.patch`, applied to the upstream sources by
`make clone`.

## Lab stack

To try changes without touching a running deployment, build `:lab` images
and run the isolated stack on port 8443 (own project name and volume):

```sh
make clone
make build FRONTEND_IMG=excalidraw-frontend:lab \
  STORAGE_IMG=excalidraw-storage-backend:lab ROOM_IMG=excalidraw-room-go:lab
# put a cert in lab/certs/ (fullchain.pem + privkey.pem), then:
docker compose -f lab/docker-compose.lab.yaml up -d
```
