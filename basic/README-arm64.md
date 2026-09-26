# Self-hosted build (arm64 and others)

The images referenced by `basic/docker-compose.yaml` are published for
`linux/amd64` only. This setup builds all three services from source instead,
so it runs on a Raspberry Pi or any other arm64 (or amd64) machine, and it
keeps everything on your own server:

- **Frontend**: Excalidraw, built with every server URL pinned to this
  deployment.
- **Storage**: scenes, rooms and images in SQLite on a Docker volume.
- **Room server**: the Socket.IO relay for live collaboration.
- **Proxy**: nginx terminating TLS and routing `/`, `/api/v2/` and
  `/socket.io/` to the services above.

Live collaboration needs HTTPS (the browser only allows its encryption APIs on
secure pages), so the proxy always serves TLS.

## Quick start

Needs Docker with the Compose plugin
([install guide](https://docs.docker.com/engine/install/)), `git`, `make` and
`openssl`. On the machine that will host it:

```sh
make HOSTS=<lan-ip>
```

Open `https://<lan-ip>` and accept the self-signed certificate warning once
per browser.

`HOSTS` only feeds the TLS certificate: list every address people will type,
IPs and hostnames alike, e.g. `HOSTS="<lan-ip> <hostname>"`. The images don't
depend on it; to change addresses later, run `make up HOSTS="..."`.

## Commands

```sh
make HOSTS="<ip> ..."        # first install: certificate, build, start
make                         # update: rebuild and restart, keep the certificate
make build                   # fetch + patch sources, build the images
make certs HOSTS="<ip> ..."  # (re)make the certificate
make up                      # start (add HOSTS=... to also replace the certificate)
make down                    # stop (data is kept)
make logs                    # follow logs
make sources                 # fetch + patch sources without building
make clean                   # delete build/
```

`make` and `make up` check for a certificate first and stop immediately with
the command to run if there isn't one. Add `TAG=<name>` to `make build` to
build under a different image tag, e.g. for a test copy (see
[`../lab/README.md`](../lab/README.md)).

## Updating

```sh
git pull
make
```

Only containers whose image or settings changed are recreated. Each source
checkout is reset to pristine upstream before patching, and re-cloned if the
pinned upstream release changes, so a `build/` directory from an older version
can't leave stale changes behind.

## Serving over Tailscale only

To keep the site off your LAN and give it a trusted certificate, bind the proxy
to localhost and let `tailscale serve` front it:

```sh
echo "BIND_ADDR=127.0.0.1" > basic/.env
make HOSTS=localhost          # the cert is only seen by tailscale itself
sudo tailscale serve --bg --https=443 https+insecure://127.0.0.1:443
```

Open `https://<host>.<tailnet>.ts.net`. Tailscale ACLs then decide who can
reach it. Use `127.0.0.1`, not `localhost`, in the serve command: `localhost`
can resolve to the IPv6 `::1`, where nothing is listening.

Docker writes its own firewall rules, so a host firewall like ufw won't
reliably block published ports; setting `BIND_ADDR` is the dependable way to
keep them off the LAN.

## Boards

The main menu has a **Boards** item listing every live-collaboration room
opened on this server, most recent first, with rename and remove. Rooms are
recorded automatically when someone starts or joins a session. To keep any
drawing on the server, start a session on it; nobody else has to join.

To reopen boards, the server stores each room's ID **and its encryption key**,
and the list has no login. Anyone who can reach the site can open every listed
board. That suits a server you run for a small, trusted group; for anything
wider, keep it behind Tailscale or another access layer, and treat the
storage volume and its backups as sensitive.

## Data and backups

Everything lives in the `basic_storage-data` Docker volume
(`storage.sqlite`). It survives restarts, rebuilds and `make down`. It is only
deleted by `docker compose down -v` or `docker volume rm`, so never use `-v`
on a deployment you care about. Back up the volume to keep your boards.

## Why the patches exist

Upstream sources are cloned at pinned releases and patched from `patches/`:

| Patch | Why |
|---|---|
| `excalidraw-frontend/01-dockerfile.patch` | Node 18 → 22 (newer transitive dependencies need it); pins every `VITE_APP_*` value to this deployment. |
| `excalidraw-frontend/02-boards.patch` | The Boards list and automatic room recording. |
| `excalidraw-storage-backend/01-dockerfile.patch` | Pins the Nest CLI to v8 (a current CLI breaks the build); makes the data directory writable for SQLite. |
| `excalidraw-storage-backend/02-boards.patch` | The `/api/v2/boards` endpoints. |

The frontend pins matter most. Vite bakes these values into the static bundle
at build time, and any value left unset is filled from upstream's
`.env.production`, which points live collaboration at **excalidraw.com's
public services**: its Firebase project for storage and
`oss-collab.excalidraw.com` for the websocket relay. `make build`
refuses to build unless `VITE_APP_STORAGE_BACKEND=http` and
`VITE_APP_WS_SERVER_URL=/` are set, and setting them in a compose
`environment:` block has no effect on an already-built bundle.

## Troubleshooting

**"Couldn't save to the backend database"**, often with
`a.reduce is not a function` or a Firebase error in the browser console. The
frontend was built without the storage pin and is trying to use Firebase. Run
`make clean` and `make`.

**Collaboration fails, and the console shows a websocket to
`oss-collab.excalidraw.com`.** Same cause, for the websocket pin; same fix.

**The Boards menu item is missing after an update.** The browser is still
running the previous version from its offline cache (Excalidraw installs a
service worker). Close all its tabs, reopen, and hard-reload (Ctrl+Shift+R);
failing that, clear the site's data.

**Nothing loads over `http://`.** Expected: use `https://`. Port 80 only
redirects to it.
