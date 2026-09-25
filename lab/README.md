# Lab stack

A throwaway copy of the whole stack for trying changes without touching the
live deployment. It runs side by side with live on the same machine, but has
its own:

| | Live | Lab |
|---|---|---|
| Compose project | `basic` | `excalidraw-lab` |
| Images | `excalidraw-*:arm64-<version>` | `excalidraw-*:lab` |
| Storage volume | `basic_storage-data` | `excalidraw-lab_lab-storage-data` |
| Listens on | `127.0.0.1:443` | `127.0.0.1:8443` |
| URL (tailnet) | `https://<host>.<tailnet>.ts.net` | `https://<host>.<tailnet>.ts.net:8443` |

The one thing it shares with live is CPU: builds make the Pi busy for a few
minutes.

> **Always build with the `:lab` image tags.** The Makefile's default tags are
> the same ones live uses. Building under those names doesn't change running
> containers, but the next time live restarts it would pick up whatever you
> built.

## Bring it up

On the host. Replace `<host>.<tailnet>.ts.net` with your machine's Tailscale
name and `<your-fork-url>` / `<branch>` with where this repo lives; prefix
`docker` with `sudo` if your user isn't in the `docker` group:

```sh
git clone --branch <branch> <your-fork-url> ~/excalidraw-lab
cd ~/excalidraw-lab

# fetch the upstream sources and apply our patches
make clone

# build under :lab tags -- never the default (live) tags
make build DOCKER="sudo docker" \
  FRONTEND_IMG=excalidraw-frontend:lab \
  STORAGE_IMG=excalidraw-storage-backend:lab \
  ROOM_IMG=excalidraw-room-go:lab

# self-signed cert for nginx (tailscale serve sits in front, so this is
# only ever seen by tailscale itself)
mkdir -p lab/certs
openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout lab/certs/privkey.pem -out lab/certs/fullchain.pem \
  -subj "/CN=<host>.<tailnet>.ts.net" \
  -addext "subjectAltName=DNS:<host>.<tailnet>.ts.net"

# start it (run from the repo root; the compose file uses ../basic paths)
sudo docker compose -f lab/docker-compose.lab.yaml up -d

# expose it on the tailnet only, with Tailscale's trusted cert
sudo tailscale serve --bg --https=8443 https+insecure://127.0.0.1:8443
```

Open `https://<host>.<tailnet>.ts.net:8443`.

To try a code change: edit the source under `build/`, rebuild just the image
you changed with its `:lab` tag, then
`sudo docker compose -f lab/docker-compose.lab.yaml up -d` again. Once it
works, regenerate the matching file in `patches/` (see below) so the change
survives a fresh `make clone`.

## Quick checks

```sh
L=https://<host>.<tailnet>.ts.net:8443
curl -s -o /dev/null -w "%{http_code}\n" $L/                      # 200
curl -s $L/api/v2/boards                                          # []
curl -s -o /dev/null -w "%{http_code}\n" "$L/socket.io/?EIO=4&transport=polling"  # 200
```

Point test scripts at the `:8443` URL. Anything that writes (creating
rooms, boards, scenes) against the live URL lands in live data.

## Turning source edits into patches

The Boards feature (and any future source change) lives in `patches/` and is
applied by `make clone`. After editing under `build/`:

```sh
cd build/excalidraw-frontend        # or build/excalidraw-storage-backend
git add -N <any new files>           # so git diff includes them
git diff -- excalidraw-app > ../../patches/frontend-boards.patch   # or: -- src
```

Test it applies cleanly to fresh upstream source:

```sh
make clone BUILD_DIR=/tmp/labtest && rm -rf /tmp/labtest
```

## Promote a lab build to live

This deploys the exact images you tested, with an instant rollback:

```sh
for pair in \
  "excalidraw-frontend:arm64-v0.18.1-fork-b2 excalidraw-frontend:lab" \
  "excalidraw-storage-backend:arm64-v2023.11.11 excalidraw-storage-backend:lab" \
  "excalidraw-room-go:arm64-v0.1.0 excalidraw-room-go:lab"; do
  set -- $pair
  sudo docker tag "$1" "${1%%:*}:rollback"   # keep what live runs now
  sudo docker tag "$2" "$1"                  # point live's name at the lab build
done

# from the live deployment's basic/ directory
sudo docker compose -f docker-compose.arm64.yaml up -d
```

Roll back by tagging the `:rollback` images back to the live names and running
`up -d` again.

Live's storage is SQLite on the `basic_storage-data` volume, so promoting new
images keeps its data. Never run `down -v` on live: the `-v` deletes that
volume.

## Take it down

```sh
cd ~/excalidraw-lab
sudo docker compose -f lab/docker-compose.lab.yaml down -v   # -v: drops the lab volume
sudo tailscale serve --https=8443 off
sudo docker rmi excalidraw-frontend:lab excalidraw-storage-backend:lab excalidraw-room-go:lab
cd ~ && rm -rf ~/excalidraw-lab
```

`docker rmi` on a `:lab` tag only removes the tag if live is running the same
image, so it's safe after a promotion.
