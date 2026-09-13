# Running excalidraw-collaboration on arm64 devices

## Prerequisites

- An arm64 device (Raspberry Pi, other SBC, arm64 VPS, etc.) with SSH/shell access.
- Know the device's own LAN IP (`hostname -I`) — needed below as `IP`.

## Quick start

From the repo root, on the arm64 device itself:

```sh
make install-docker   # one-time, only if Docker isn't already installed
make all IP=<this-device's-LAN-IP>
```

Then visit `https://<IP>` — click through the one-time self-signed
certificate warning in your browser (this is required: Live Collaboration
needs HTTPS to work at all, plain `http://` will not support it).

## Individual steps

```sh
make clone                  # fetch + patch the three upstream source repos
make build IP=<your-IP>     # build all three images natively for arm64
make certs IP=<your-IP>     # generate a self-signed TLS cert for that IP
make up                     # start the stack
make ps                     # check container status
make logs                   # tail logs
make down                   # stop the stack
make clean                  # remove fetched source (keeps images/certs)
```

## If the device's IP ever changes

Re-run:

```sh
make build certs up IP=<new-IP>
```

Both the frontend bundle and the TLS cert are built for one specific IP
address and need rebuilding when it changes.
