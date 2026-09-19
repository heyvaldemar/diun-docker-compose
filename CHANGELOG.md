# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.4] - 2026-09-19

### Security

- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:365499d9dccb…` to `sha256:5291449c3df7…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.3] - 2026-09-18

### Security

- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:14358309a308…` to `sha256:365499d9dccb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.2] - 2026-09-12

### Fixed

- **The delivery test, properly this time.** v1.0.1 claimed the cause and was
  wrong, so the test went on failing. Two real faults, both found by capturing
  what actually crossed the wire instead of reasoning about it.

  Diun was posting before the sink could accept. `depends_on: service_started`
  means the container was launched, not that anything is listening, and Diun's
  first scan fires within a second of its own start. Every notification in that
  burst came back "connection refused", and because a first check happens once
  there was nothing to retry: the test then waited six minutes for a message
  that would never be sent again. The sink now has a healthcheck and Diun waits
  for `service_healthy`. The check reads the listening socket with `netstat`
  rather than connecting to it, because connecting to a listener that serves
  one request at a time consumes the accept the real notification needs.

  And the accepted request was reaching the sink whole but not reaching the
  log. Teeing nc's output to a file showed all 669 bytes of Diun's POST,
  headers and body, and the old `tr -d '\r' | sed 's/^/SINK /'` printed every
  line of that file. Live, with nc still holding the pipe open, only the
  request line ever appeared, so the step looked for a `Content-Type` that had
  arrived and been swallowed between two processes. A shell read loop writes
  each line as it reads it, and the whole request reaches the log.

  The `-w` removal from v1.0.1 stays. A listen timeout counts from the moment
  nc starts listening rather than from the moment a connection arrives, so it
  can cut an accepted request part way through. It was a real hazard; it was
  not this one.

## [1.0.1] - 2026-09-11

### Fixed

- **The delivery test could fail on a notification that had arrived
  perfectly well.** Two races, both in the test rather than in the template.

  The sink listened with `nc -l -w 5`, and that timeout counts from the moment
  nc starts listening rather than from the moment a connection arrives. A
  notification landing late in the window was cut off part way through being
  read: the request line reached the log and the headers never did. The loop
  restarts nc anyway and the CI step has its own timeout, so the only thing
  `-w` contributed was a way to truncate the evidence.

  And the step waited for `SINK POST` and then immediately asserted on
  `SINK Content-Type`. The sink's output reaches the log through a buffered
  pipeline, so the first line can be visible a moment before the ones that
  followed it. It now waits for the line it is going to assert on.

## [1.0.0] - 2026-09-11

First release. A production deployment of Diun, built to the fleet standard
established in
[keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

No Traefik and no certificate: Diun has no web interface.

### Added

- **Diun 4.33 with a read-only Docker socket proxy.** Three images pinned by
  `tag@sha256:<digest>` in the compose `x-images` block. Diun's job is to read
  what is running and report on it — it never pulls, recreates or restarts —
  so it has no business holding a socket that could do any of those, and `:ro`
  on a socket mount would not stop it. The proxy forwards `CONTAINERS` and
  `IMAGES` only, with `POST` denied.
- **A test that a notification actually leaves the building.**
  `tests/webhook-sink.yml` receives one, and CI asserts it arrived. This is the
  test nobody writes and the one that matters most here: a notifier that
  discovers updates and cannot deliver them is, from the outside,
  indistinguishable from one that found nothing. Both are silent, and silence
  is what you expect most days.
- **Watch-by-default, against upstream's own default.** Opt-in per container
  means a new stack is unwatched until somebody remembers to label it, and
  nobody remembers — coverage stays at zero for months while the tool reports
  itself healthy. Watching by default means coverage starts the moment a
  container does; exclude a noisy one with `diun.enable=false`.
- **First-check notification off.** With watch-by-default, the first scan
  discovers everything you run at once, and the alternative empties all of it
  into your chat in one go. Diun still records them; only real changes notify.
- **The four labels an exactly-pinned image needs**, documented with the
  reasoning rather than as a recipe. Digest-watching never reports a new
  version for an exact pin, because 10.11.12 is not a re-push of 10.11.11 — the
  pin keeps working and you simply stop hearing about releases.
- **A backup loop that reads its own archive back before naming it a backup**,
  an end-to-end suite requiring `diun.db` in the archive by name, a restore
  script, `update.sh`, `cap_drop: ALL`, resource limits and reservations, and
  OpenSSF Scorecard.

### Notes

- **`IMAGES` has to be on the proxy's allow-list, and leaving it off fails
  quietly.** Diun lists containers and then inspects each image to learn its
  digest. With `CONTAINERS` alone, the listing succeeds, every inspect gets a
  403, and the log says "No image found" — a stack that is healthy, running and
  watching nothing. Found by pointing the first draft at a proxy and reading
  what Diun made of it rather than what the proxy answered. CI asserts the
  discovery count is greater than zero for exactly this reason.
- **The first scan runs the instant Diun starts, and can beat the proxy to
  readiness.** On a stack coming up together that produces `added=0 failed=0` —
  a scan that found nothing because there was nothing to talk to yet. The first
  CI run judged that first scan and called it a defect. The check waits for a
  scan that discovers something instead: racing startup is expected, never
  discovering anything is not.
- **Diun ignores `DOCKER_HOST`.** Its own setting is
  `DIUN_PROVIDERS_DOCKER_ENDPOINT`, and a proxy configured the other way is
  silently bypassed in favour of a unix socket that is not mounted: every scan
  ends with "Cannot create Docker client".
- **`max_tags` must be 1 for an exactly-pinned image.** With a larger window
  Diun reports every tag in it, including versions older than the one running,
  each reading as an invitation to downgrade.
- **`watch_repo` on a rolling tag is wrong.** Its digest is already watched;
  the labels only add a card per tag in the window. On one host that produced
  twenty cards in a minute.
- **A shell pipeline cannot begin a line with `|`.** The webhook sink's command
  was first written across a folded YAML scalar with the pipes leading each
  continuation line. It died instantly, restarted forever, and dropped out of
  Docker's DNS as it went — so Diun reported "no such host" for the sink, which
  reads like a network problem and was a shell one. The command is one line
  now, in exec form.
- **The sink serves one connection at a time.** BusyBox `nc` has no
  concurrency, and the first scan posts one notification per image within the
  same second, so the rest are refused while it restarts between accepts. That
  is the instrument's limit rather than a defect in delivery, and the test
  asserts what it can honestly assert: a POST arrived, and it was JSON.
- **The healthcheck is a subcommand, not a flag.** `diun healthcheck`;
  `diun --healthcheck` is what people write and it is not a thing.

[Unreleased]: https://github.com/heyvaldemar/diun-docker-compose/compare/v1.0.4...HEAD
[1.0.4]: https://github.com/heyvaldemar/diun-docker-compose/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/heyvaldemar/diun-docker-compose/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/heyvaldemar/diun-docker-compose/releases/tag/v1.0.2
[1.0.1]: https://github.com/heyvaldemar/diun-docker-compose/releases/tag/v1.0.1
[1.0.0]: https://github.com/heyvaldemar/diun-docker-compose/releases/tag/v1.0.0
