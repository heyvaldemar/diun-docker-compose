# Diun on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/diun-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/diun-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys Diun — which watches the image tags of everything you are running and tells you when a newer one is published. It never pulls, never recreates, never restarts. Notify-only, by design.

That restraint is the point. A stateful service is not something to auto-upgrade: a major PostgreSQL bump wants a migration, and an application that changed a required variable wants you to read its release notes first. Diun tells you; you decide.

There is no Traefik here and no certificate, because Diun has no web interface.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/diun-docker-compose
cd diun-docker-compose

# 2. Create the Docker network the stack expects
docker network create diun-network

# 3. Copy the environment template and set where notifications go
cp .env.example .env
$EDITOR .env        # ^ Required: DIUN_WEBHOOK_URL

# 4. Deploy
docker compose -f diun-docker-compose.yml -p diun up -d
```

`DIUN_WEBHOOK_URL` is the one required value, and the compose file refuses to start without it. A notifier with nowhere to notify is the single configuration that makes the whole stack pointless while looking entirely healthy.

The `slack` notifier speaks the Slack incoming-webhook format, which Mattermost, Rocket.Chat and Discord (with `/slack` on the URL) all accept, so one variable covers most of what people use. Diun also supports email, Telegram, Gotify, ntfy, Matrix, Pushover and Signal — those go in the compose file's environment block; `.env.example` says where to look.

### What success looks like

```bash
docker compose -f diun-docker-compose.yml -p diun logs diun | grep "Jobs completed"
# INF Jobs completed added=23 failed=0 skipped=0 unchanged=0 updated=0
```

`added` is how many images it is now watching. If that is zero, see the next section — it is almost always the same cause.

### Common first-deploy issues

- **`No image found`, and `added=0`.** Diun lists your containers and then inspects each image to learn its digest. The proxy's allow-list must permit both; without `IMAGES` the listing succeeds, every inspect gets a 403, and you have a stack that is healthy, running and watching nothing. This template sets both — the note exists because it is the first thing to check if you change that block.
- **`Cannot create Docker client … dial unix /var/run/docker.sock`.** Diun ignores `DOCKER_HOST`. Its own setting is `DIUN_PROVIDERS_DOCKER_ENDPOINT`, and a proxy configured the other way is silently bypassed in favour of a socket that is not mounted.
- **Nothing ever arrives in chat.** Turn `DIUN_WATCH_FIRSTCHECKNOTIF` on for one scan: it makes Diun report every image it has not seen before, which is how you confirm delivery without waiting for an upstream release. Turn it off again.
- **A flood on the first run.** That is the same variable left on. Diun records first-seen images silently by default for exactly this reason.

## Exact pins need four labels, or you will never hear about a new version

This is the part that catches people, and it catches them silently.

Diun watches, by default, **the digest the running tag resolves to**. For a floating tag — `postgres:17`, `alpine:3`, `nextcloud:33-apache` — that is exactly right: when upstream re-pushes that tag, the digest moves and Diun tells you.

For an **exact** pin — `jellyfin/jellyfin:10.11.11`, `traefik:v3.7.7` — digest-watching will never report a new version, because 10.11.12 is not a re-push of 10.11.11. It is a different tag, and nothing is watching for it. The pin keeps doing exactly what you asked; you simply stop hearing about releases.

Add these four labels to that container:

```yaml
labels:
  - "diun.watch_repo=true"
  - "diun.sort_tags=semver"
  - "diun.max_tags=1"
  - "diun.include_tags=^v\\d+\\.\\d+\\.\\d+$$"
```

Three things about them, each learned the hard way:

- **`max_tags=1` is not optional.** With a larger window you get a card for every tag in it — including versions *older* than the one you are running, each one reading as an invitation to downgrade.
- **The regex must match that image's tag scheme.** Otherwise release candidates, betas and variant tags arrive alongside the releases.
- **Do not add `watch_repo` to a container on a rolling tag.** Its digest is already watched; the labels only add a card per tag in the window. On one host that produced twenty cards in a minute.

In compose files `$` must be doubled — `$$` — or Compose interpolates the regex before Diun ever sees it.

## Two statuses, and both need you

**`new`** means a newer tag was published for an exactly-pinned image. Nothing has changed on your server; the pin still holds.

**`update`** means a pinned tag now resolves to a different image. For a rolling tag that happens on every patch; for an exact tag it happens when the base image is rebuilt, which is usually a security fix. The change arrives on your next recreate.

Neither is noise. A template that labelled `new` as "no action needed" would be dismissing the one event this whole stack exists to report.

## Diun never gets the Docker socket

Diun's job is to read what you are running. It never acts on anything, so it has no business holding a socket that could — and `:ro` on a socket mount would not stop it, because the Docker API is root-equivalent whichever way the file is mounted.

A proxy holds it and forwards `CONTAINERS` and `IMAGES` only, with `POST` denied. Checked on every CI run, along with the Diun container's mount list:

| through the proxy | answer |
| :--- | :--- |
| `GET /containers/json` | `200` |
| `POST /containers/<id>/restart` | `403` |

There is no override file that turns `POST` on.

## Updating

`./update.sh` moves this checkout to the latest release tag and runs `docker compose up -d`. It refuses to cross a major version unattended, refuses to run over local changes, and names any variable that became required since your version before anything has moved. `./update.sh --dry-run` says what would happen.

## Supply chain trust

Three images pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block:

- [`ghcr.io/crazy-max/diun`](https://github.com/crazy-max/diun/pkgs/container/diun): the watcher
- [`ghcr.io/tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy): the only container that touches the socket
- [`alpine`](https://hub.docker.com/_/alpine): the backups sidecar

There is a pleasing circularity here: this stack watches every pin in every other stack, and its own pins are watched by the same daily freshness check that guards the rest of the fleet. `git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

## Backups and restore

The `backups` container archives `/data` on a loop — a 30-minute warm-up, a 24-hour interval, 7-day retention, all overridable in `.env`. That is one small database: what Diun has already seen.

Be clear about what this protects. Losing it costs nothing permanent — the next scan rebuilds it from what is running. What it costs is quiet, if first-check notification is on.

Each archive is written to a `.partial` name, **read back with `tar -tzf`**, and only then renamed. BusyBox tar returns exit code 1 both for "a file changed while I was reading it" and for "I could not write the output at all", and an archive truncated after tar exited still carries exit status 0.

```bash
chmod +x ./*.sh
./diun-restore-data.sh
```

It lists the backups and asks, or takes a file name as its argument; it reads every path from the running backups container, and CI runs it on every push.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/diun-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck and actionlint, Trivy scans of all three pinned images, a daily freshness check, and a deploy job that requires Diun to **discover images through the read-only proxy** (`added` greater than zero, and no `No image found`), **a notification to actually arrive**, the Diun container to have no Docker socket among its mounts, the proxy to answer `403` to a POST and `200` to a GET, eight backup and restore scenarios to pass, and Diun to come back healthy on the data directory the restore test replaced underneath it.

### The delivery test

`tests/webhook-sink.yml` is a receiver: a container that accepts a POST and logs it, with Diun pointed at it and first-check notification turned on so the first scan has something to say.

This is the test nobody writes, and it is the one that matters most for a notifier. A tool that discovers updates and cannot deliver them is, from the outside, indistinguishable from one that found nothing — both are silent, and silence is what you expect most days. The first time you learn the difference is the day it mattered.

```bash
docker compose -f diun-docker-compose.yml -f tests/webhook-sink.yml -p diun up -d
```

It serves one connection at a time, so the first notification arrives and the rest are refused while it restarts between accepts. That is the instrument's limit, not Diun's, and the file says so.

## Security notes

- `DIUN_WEBHOOK_URL` is read from `.env` at deploy time; `.env` is gitignored and compose fails fast without it.
- The Docker socket is held by a proxy that denies every write, and Diun does not have it.
- Diun never pulls, recreates or restarts anything. Nothing in this stack can change what is running.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
