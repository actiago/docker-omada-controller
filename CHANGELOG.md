# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This repository packages upstream TP-Link Omada Controller releases, so the
version numbers below refer to the **image tag** being packaged; entries grouped
under a release line mean "the packaging changed, not the bundled controller".

---

## [Unreleased] — `add-podman-deployment`

Rootless-Podman deployment of the controller for a small, non-AVX Fedora host.
This branch is **additive**: no image build, entrypoint or existing compose file
was modified.

### Added

* `podman/omada.container` — a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
  unit that runs the controller under systemd (`omada.service`) with:
  * rootless Podman, `Network=host` (needed for device discovery/adoption),
  * named volumes `omada-data` / `omada-logs`,
  * the compose file's `ulimits` (`nofile 4096:8192`) and `stop_grace_period`
    (60s) translated to `PodmanArgs=--ulimit ... --stop-timeout=60`,
  * `JAVA_MAX_HEAP_SIZE=512m` / `JAVA_MIN_HEAP_SIZE=128m` and
    `MONGOD_EXTRA_ARGS="--wiredTigerCacheSizeGB 0.25"` for low-memory hosts,
  * a cgroup guard rail (`MemoryHigh=1100M`, `MemoryMax=1500M`) so a runaway JVM
    cannot wedge the machine,
  * `WantedBy=default.target` for autostart at boot (with user lingering).
* `podman/open-firewall.sh` — idempotent firewalld helper for the `Network=host`
  case: opens 8088, 8043, 8843, 8044, 29811-29817 TCP and 27001, 29810, 19810
  UDP on the default zone (overridable via `OMADA_ZONE`).
* `podman/README.md` — full deployment guide: hardware/AVX constraints, install,
  operations, port matrix, firewall, tuning, verification evidence,
  troubleshooting and rollback.
* `CHANGELOG.md` — this file.
* `README.md` → new **Using Podman** subsection under *Example Usage*, pointing to
  `podman/`.

### Changed

* Nothing in the existing files' behaviour. `README.md` only gains a pointer to
  the new Podman path.

### Fixed

Issues found and resolved while building this deployment (all captured in
`podman/README.md`):

* **v6 image unusable on a non-AVX CPU.** `omada-controller:6.3` crash-loops
  because MongoDB 8 requires AVX. Pinned the deployment to `5.15.24.19`, whose
  embedded MongoDB 3.6.8 does not. Verified on the host: `mongo:4.4` starts,
  `mongo:7` dies with `SIGILL` (`trap invalid opcode`).
* **Quoted `MONGOD_EXTRA_ARGS` is mandatory.** An unquoted
  `Environment=MONGOD_EXTRA_ARGS=--wiredTigerCacheSizeGB 0.25` is split by
  systemd; mongod is invoked without a value and the controller dies with
  `Fail to start mongo DB server with exit code 2`. The unit now quotes the whole
  value (`Environment="MONGOD_EXTRA_ARGS=--wiredTigerCacheSizeGB 0.25"`).
* **v6-only env vars removed** from the unit (`UPGRADE_ES_HTTPS_PORT`,
  `PORT_DEVICE_MONITOR`) since the pinned v5 image does not use them; they are
  kept as comments for anyone moving to v6.
* **Firewall was silently blocking the controller.** With host networking on
  Fedora Server, the default zone only allows ssh/cockpit, so the UI was
  reachable on localhost but returned `000` from the LAN. `open-firewall.sh`
  closes that gap.

### Documentation of the deployed environment

| | |
| :-- | :-- |
| Host | Fedora Server 43, Intel Celeron N3350 (2 cores, no AVX), 3.6 GiB RAM |
| Podman | 5.8.8, rootless, netavark; user lingering already enabled |
| Image | `mbentley/omada-controller:5.15.24.19` (Java 17.0.15, MongoDB 3.6.8) |
| Supervision | `omada.service` (Quadlet), autostart at boot |
| Data | volumes `omada-data`, `omada-logs` |
| Verified | HTTP 200 on `:8043`, redirect `:8088` → `:8043`, all documented TCP/UDP ports bound, ~1.15 GiB RSS at idle, no SELinux denials |
| Not done | firewalld ports opened (needs root password at the time of writing) |

### Known limitations

* Cold start takes **~10-13 minutes** on this CPU (classpath/JAR scanning + C2
  JIT). It is slow, not hung — see the thread-dump evidence in
  `podman/README.md`.
* Co-locating Prometheus/Grafana on 3.6 GiB starves the startup (load ~11 on
  2 cores); the co-located monitoring stack was disabled
  (`systemctl --user disable --now monitoring-pod.service`).
* The host froze once during a heavy startup with **no OOM, thermal or MCE**
  entries in the kernel log, and came back with a corrupt journal plus a ~3h RTC
  drift. Root cause is hardware-side, not the controller. Cleanup for the
  `rsyslogd` journal churn is documented but requires root.
* v6 is not achievable on this hardware even with an external MongoDB, because
  MongoDB 8 itself requires AVX.

---

## Deployment timeline (2026-10-31)

Chronological record of the deployment that produced this branch. Times are the
host's local time; note that the host clock was ~3h off until NTP stepped it
after the reboot, so only the ordering is meaningful.

1. **Reconnaissance** — `fedora` host (192.168.0.103) reachable by SSH key;
   Fedora Server 43, rootless Podman 5.8.8, `podman-compose` present, Docker
   absent, lingering on, subuid/subgid mapped, no port conflicts.
2. **First deploy attempt** — Quadlet unit mirroring `docker-compose.yml`
   (`Network=host`, named volumes, `PUID`/`PGID=508`) with image `6.3`.
   Result: crash loop (14 restarts) on the AVX pre-flight check.
3. **CPU triage** — `grep -c avx /proc/cpuinfo` → `0`; Celeron N3350.
   Empirical MongoDB matrix run on the host: `mongo:4.4` OK, `mongo:7` SIGILL.
4. **Pivot to v5.15** — unit pinned to `5.15.24.19` (bundled MongoDB 3.6.8),
   volumes recreated for a clean first run.
5. **Second failure** — mongod exited with code 2 because
   `MONGOD_EXTRA_ARGS` was unquoted and systemd truncated it.
6. **Fix + redeploy** — value quoted; `MemoryHigh/MemoryMax` added; controller
   started, Java 17.0.15, MongoDB listening on 127.0.0.1:27217.
7. **Host hard freeze** — the machine dropped off the network ~90s after the JVM
   start, returned with an unclean-shutdown journal and a stepped clock. No OOM
   or hardware error logged. `omada.service` auto-started on the new boot,
   which incidentally proved the boot integration.
8. **Slow-boot diagnosis** — thread dump showed `main` `RUNNABLE` in
   `ZipFile$Source.getEntryPos` and C2 JIT burning CPU: startup was starved, not
   deadlocked. Load average ~11 caused by the co-located Prometheus/Grafana
   stack plus post-crash `rsyslogd` journal replaying.
9. **Monitoring stack disabled** — `systemctl --user disable --now
   monitoring-pod.service`; load dropped to ~0.09 and startup completed;
   `:8043` returned 200.
10. **Port verification** — discovery/adoption listeners (29810/udp, 27001/udp,
    19810/udp, 29811-29816/tcp) appeared minutes after the web UI, confirming a
    complete controller.
11. **Firewall** — confirmed blocked from the LAN (`curl` → `000`) and prepared
    `open-firewall.sh`, which requires the root password on the host and is left
    as the single remaining manual step.
