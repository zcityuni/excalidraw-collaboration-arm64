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

> **Always build with `TAG=lab`.** Without it, `make build` uses the same image
> tags as live. That doesn't change running containers, but the next time live
> restarts it would pick up whatever you built.

## Bring it up

On the host. Replace `<host>.<tailnet>.ts.net` with your machine's Tailscale
name and `<your-fork-url>` / `<branch>` with where this repo lives; prefix
`docker` with `sudo` if your user isn't in the `docker` group:

```sh
git clone --branch <branch> <your-fork-url> ~/excalidraw-lab
cd ~/excalidraw-lab

# fetch + patch sources, build under :lab tags -- never the default (live) tags
make build TAG=lab DOCKER="sudo docker"

# self-signed cert for the lab's nginx (tailscale serve sits in front, so
# it's only ever seen by tailscale itself)
make certs HOSTS=localhost CERT_DIR=lab/certs

# start it (run from the repo root; the compose file uses ../basic paths)
sudo docker compose -f lab/docker-compose.lab.yaml up -d

# expose it on the tailnet only, with Tailscale's trusted cert
sudo tailscale serve --bg --https=8443 https+insecure://127.0.0.1:8443
```

Open `https://<host>.<tailnet>.ts.net:8443`.

To try a code change: edit the source under `build/`, rebuild just that image
again with `make build TAG=lab` (unchanged images come straight from the build
cache), then
`sudo docker compose -f lab/docker-compose.lab.yaml up -d` again. Once it
works, capture it as a file in `patches/` (see below), or the next source
reset will discard it.

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

Every change to upstream code lives in `patches/<component>/` and is applied in
filename order whenever the sources are prepared (`make sources`, and
therefore `make build`), after resetting them to pristine upstream. So edits
under `build/` are lost the next time the Makefile or a patch changes unless
they are captured in a patch.

To turn an edit into a new patch, snapshot the patched state in git's index
(never commit inside `build/`), edit, then diff against that snapshot:

```sh
cd build/excalidraw-frontend              # or build/excalidraw-storage-backend
git add -A                                # snapshot: sources as patched by make
# ... edit, rebuild with TAG=lab, test ...
git add -N .                              # include any new files in the diff
git diff > ../../patches/excalidraw-frontend/03-my-change.patch
```

`git diff` compares against the snapshot, so the new patch holds only your
edits. Preparing the sources resets the index along with the files, so the
snapshot can't leak into the next build.

Check that the full set applies cleanly to fresh upstream source:

```sh
make sources BUILD_DIR=/tmp/labtest && rm -rf /tmp/labtest
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
