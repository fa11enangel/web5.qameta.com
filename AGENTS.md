# web5.qameta.com — Agent Guide

Operational notes for working on `web5.qameta.com`. Facts below were observed on
2026-10-30 over SSH without root; re-verify before acting on them.

## Access

- `ssh web5.qameta.com` — key auth, logs in as `konstantin` (uid 1000, in `sudo` only).
- `sudo` **requires a password**. Agents cannot use it non-interactively.
- `konstantin` is **not** in `docker` or `adm`, so `docker …`, `dokku …`, `/var/log/*`
  and the system journal need root. Most files under `/var/lib/dokku/config` and
  `/home/dokku` are not readable either.
- When a command needs root, hand the user a plain command to run in their root shell on
  the server (no `ssh -t … 'sudo …'` wrapping) and ask them to paste the output.
- Use `-o BatchMode=yes` for non-interactive checks so ssh fails instead of hanging.

## Ground rules

- Production host for a customer app. Default to **read-only** investigation.
- Never restart, rebuild or redeploy the app, or restart nginx/docker, without the user's
  explicit go-ahead.
- Apps are deployed with **Dokku**. Change app config through `dokku …` commands, not by
  editing files under `/home/dokku` or running `docker` against Dokku containers.
- App containers run as uid 1000, so their `/proc/<pid>/environ` is readable by
  `konstantin`. It holds secrets (`DATABASE_URL`, `REDIS_URL`, `SECRET_KEY_BASE`, …). Filter
  to the exact variable names you need, never dump it.

## System

| Item | Value |
|---|---|
| Hosting | Hetzner Cloud VM (QEMU), IPv4 `116.203.76.209`, IPv6 `2a01:4f8:1c1e:9eee::1/64`, PTR `web5.qameta.com` |
| OS | **Ubuntu 22.04.5 LTS** (jammy), kernel 5.15.0-198, EFI boot |
| CPU / RAM / swap | 2 vCPU / 1.9 GB / 2 GB (about 700 MB used, 1 GB available) |
| Disk | 38 GB `/dev/sda1` ext4, 65 % used (23 GB). No RAID (cloud volume) |
| Apt sources | Hetzner Ubuntu mirror, Docker CE repo, Dokku packagecloud repo |
| Firewall | **none**: `ufw` installed but `ENABLED=no`, `nftables.service` disabled (stock `flush ruleset` file — do not enable it as-is, see Gotchas). Only 22/80/443 listen publicly |
| Time | UTC, timesyncd with `ntp.hetzner.com`, synced |
| Mail | **no MTA** (no postfix, no `sendmail`, no `/etc/aliases`): cron output and alerts go nowhere |

Unlike web1/web2 this host is still on Ubuntu, not Debian 13. No ISPConfig.

## Services

- **nginx** 1.18 — front proxy for Dokku (`/etc/nginx/conf.d/dokku.conf` includes
  `/home/dokku/*/nginx.conf`, rewritten by Dokku on 2026-10-30 14:01). HTTP redirects
  to HTTPS. The stock `default` site is still enabled on :80 and serves
  `/var/www/html/index.html` ("Welcome to a Qameta System!") for unknown hosts.
- **Docker + Dokku** (Docker 29.9, Dokku 0.38.34, `dokku-update`, `dokku-event-listener`).
  `/etc/docker/daemon.json`: `live-restore: true`, no default log limits.
- **Caddy container** (`/bin/caddy docker-proxy`, started at boot) — Dokku's caddy proxy,
  probably a leftover from 2023 (`/var/lib/dokku/config/caddy` dates from then). It
  listens only on `127.0.0.1:2019` (admin API) in its own network namespace and serves
  no traffic. See TODO.
- **Timers:** `dokku-retire`, `docker-builder-prune`, apt/unattended-upgrades, sysstat
  (`/etc/cron.d/sysstat`).
- **unattended-upgrades** — on, Ubuntu defaults (`jammy`, `jammy-security`; Docker and
  Dokku repos are not auto-updated). needrestart with defaults. No mail on failure (no MTA).
- **Backups:** daily restic run with dumps of all Dokku Postgres databases, see
  [Backups](#backups).

### Dokku app and services

| App / service | Notes |
|---|---|
| `ikos` | Rails (Puma 7.2, Ruby 4.0.9, herokuish), `RAILS_ENV=production`, 2 web dynos on :5000, plus `resque:work` worker and `resque:scheduler`. Domain `www.iko-datenbank.de` (CNAME → `web5.qameta.com`), Let's Encrypt cert valid to 2026-12-23 |
| `ikos-18` | Dokku Postgres service (PG 18), linked. The unlinked leftover `ikos-16` was destroyed on 2026-10-30; its last dump is only in older restic snapshots |
| `ikos-redis` | Dokku Redis service (Resque queue), linked |

`/var/lib/dokku/data/storage` is empty: the app has no persistent volumes.

The apex `iko-datenbank.de` is **not** on web5: it points to IONOS (`217.160.0.7`),
redirects HTTP to `https://www.iko-datenbank.de/`, but its HTTPS fails with a TLS
error. Fix at IONOS if apex HTTPS matters.

### Expected listening ports

| Port | Bind | Service |
|---|---|---|
| 22 | public | ssh |
| 80, 443 | public | nginx |
| 53 | 127.0.0.53 | systemd-resolved |

Container ports (Postgres 5432, Redis 6379, Puma 5000, Caddy 2019) stay inside Docker
networks and are not published. Anything else on a public interface — especially
`32768+` mapped to container port 5000 — is a misconfiguration (see Gotchas).

## Backups

`/etc/cron.d/backup` (root, 0600 since 2026-10-30, unchanged since 2023-06-22) runs
`nice -n 19 /root/bin/backup.sh` **every hour at :28** (`28 * * * *`). It also sets
`RESTIC_REPOSITORY` (`sftp:u230071-sub7@u230071.your-storagebox.de:/restic-repo`, a
Hetzner Storage Box sub-account) and `RESTIC_PASSWORD_FILE=/root/.restic-password`. The password lives only in that file
(root, 0600, since 2026-10-30, like eltern.server); `/root/.bashrc` exports the same two
variables, so `restic` works directly in a root shell. **Never copy the password into
this repo.** No `MAILTO`, and there is no MTA
anyway. **Never copy the password into this
repo.** The scripts are tracked in `server/root/bin/` (rewritten 2026-10-30 after web1):

1. `/root/bin/backup.sh`:
   - runs `pg_dump_files.sh`, then
     `restic backup --exclude-file /etc/restic/excludes.txt --files-from /etc/restic/backup.txt`;
   - pings healthchecks.io (so the check expects a ping every hour): `/start` first, then a plain ping when both steps succeed,
     or `<ping-url>/fail` (and exit 1) when either fails. restic still runs if a dump
     failed, so the other dumps are still saved;
   - then (every hour) `restic forget --keep-daily 90 --keep-weekly 20 --keep-monthly 12
     --keep-yearly 75`, **without `--prune`**, so forgotten data stays in the repository
     (see TODO);
   - the ping URL lives in `/etc/restic/healthchecks-url` (root, 0600), not in the
     script. Don't copy it into this repo.
2. `/root/bin/pg_dump_files.sh` (same as web1): for every service in
   `dokku postgres:list`, runs `dokku postgres:export <svc>` to
   `/var/dump/pg/<svc>.dump.tmp`, then renames it to `<svc>.dump`. A failed or empty
   export keeps the previous file and makes the script exit 1. Today that is
   `ikos-18`; new services are picked up automatically.

Before 2026-10-30 the script exported only `ikos-18` to `/var/dump/pg/ikos-postgres.dump`
(597 KB on 2026-10-30) and pinged `/fail` only if that dump failed.

`/etc/restic/backup.txt` lists `/var/dump` and `/etc`; `excludes.txt` is empty.
`ikos-redis` (Resque queue) is not dumped.

restic is the Ubuntu package 0.12.1: repository format v1 only (no compression) and no
`--retry-lock` (web1 and web2 use format v2, which needs ≥ 0.14).

`/etc/cron.d/ikos-postgres.dump` is an empty file (2024-08-09), most likely created by a
mistyped redirect. Cron ignores it.

Restore (as root; after the password-file move a root shell has `RESTIC_REPOSITORY` and
`RESTIC_PASSWORD_FILE` from `/root/.bashrc`, so `restic` works directly):

```sh
restic snapshots | tail -5
restic restore latest --target /tmp/restore --include /var/dump/pg/ikos-18.dump
dokku postgres:import ikos-18 < /tmp/restore/var/dump/pg/ikos-18.dump     # overwrites the db!
```

## This repo

`server/` mirrors the readable config files that differ from package defaults (Docker,
timesyncd, nginx, restic path list, default page) and the backup scripts in `root/bin/`. When you change one of them on the
server, copy it back here and commit. `tools/` holds one-time root scripts. Not included: `/etc/cron.d/backup` (holds the
restic password) and `/etc/restic/healthchecks-url`.

## Common tasks

### Health check (no sudo)

```sh
ssh web5.qameta.com 'uptime; df -h /; free -m; systemctl --failed --no-pager'
ssh web5.qameta.com 'ss -tlnH | awk "{print \$4}" | sort -u'          # compare with table above
ssh web5.qameta.com '/usr/lib/update-notifier/apt-check --human-readable; ls /var/run/reboot-required 2>/dev/null'
curl -sI https://www.iko-datenbank.de/ | head -1
```

### Dokku (root, run by the user)

```sh
dokku apps:list
dokku ps:report ikos
dokku proxy:report ikos; dokku ports:report ikos
dokku network:report ikos
dokku logs ikos --tail 100
dokku postgres:list; dokku redis:list
dokku ps:rebuild ikos                        # needs user approval
dokku postgres:export ikos-18 > ikos-18.dump # backup one database
```

## Gotchas

- **No host firewall.** Fine today because nothing else listens publicly, but any new
  service binding `0.0.0.0` is exposed at once. A firewall would not cover
  Docker-published ports anyway (they are DNAT'd through the forward chain).
- **`bind-all-interfaces` exposes apps.** With `dokku network:set ikos
  bind-all-interfaces true`, Dokku publishes the app on random public ports (32768+),
  bypassing nginx and TLS. Checked 2026-10-30: no `docker-proxy` processes, so nothing
  is published.
- **Never enable `nftables.service` with the stock `/etc/nftables.conf`.** It starts with
  `flush ruleset`, which wipes Docker's NAT/forward rules and breaks all container
  networking. If a firewall is added, use a separate `table inet hostfw` and the
  no-flush drop-in, as on web1.
- **Unknown SNI on :443 gets the ikos certificate** (`www.iko-datenbank.de`), and unknown
  hosts on :80 get the Qameta default page. web1 rejects both with a catch-all.
- **Small VM.** 1.9 GB RAM for two Puma dynos, two workers, two Postgres and Redis. Watch
  memory before adding dynos or services.
- `/var/log/journal` is 3.8 GB (10 % of the disk); journald has no size limit set.

## TODO

Audit of 2026-10-30 (read-only, no root). Root commands are for the user to run on web5.

- [ ] **Backups — new scripts** installed 2026-10-30 14:29 (see [Backups](#backups); old
  script kept as `/root/bin/backup.sh.bak-2026-10-30`). `pg_dump_files.sh` tested by
  hand: `ikos-16.dump` (595 KB) and `ikos-18.dump` (598 KB) written; `ikos-18.dump` is the
  same size as the old `ikos-postgres.dump`, so the app's db is `ikos-18`. Full
  `backup.sh` run by hand at 14:34: dump, snapshot `9ccf6e8c` (`/etc` + `/var/dump`),
  forget all fine. Old `/var/dump/pg/ikos-postgres.dump` deleted at 14:37 (restic keeps
  its history). Still to do: confirm the 15:28 cron run pings start + success on
  healthchecks.io.
- [x] One restic password file (2026-10-30 14:41, `tools/restic_password_file.sh`):
  `/root/.restic-password` (0600); `/etc/cron.d/backup` (0600) and `/root/.bashrc` use
  `RESTIC_PASSWORD_FILE`. Tested with `restic snapshots --latest 1` in a root shell;
  backup copies of the old files deleted.
- [ ] Make sure the restic password is also stored outside web5 (password manager). It
  is needed for any restore and is not in the backup.
- [ ] `/root/ikos-16-2026-08-23.dump` and `/root/ikos-16-datadir-2026-08-23.tar.gz`
  (from the PG 16 → 18 upgrade) are not backed up (`/root` is not in `backup.txt`). Delete
  them, or move them to `/var/dump` if they must be kept.
- [ ] Repository has 29,434 index files (loading them takes ~30 s per run): one per hourly
  run since 2023 (~8,760 a year), never pruned. The first `prune` will consolidate them.
- [ ] Since `/etc` was added, snapshots have the paths `/etc` + `/var/dump`, a new group
  for `forget`. The 108 old `/var/dump`-only snapshots are no longer thinned out; forget
  them by hand once the new group has enough history.
- [ ] Retention: `forget` runs without `--prune`, so the repository only grows. Move it to
  a weekly `forget_backup.sh` with `--prune` + `check` and its own healthchecks.io check,
  like web1. Do it after the restic upgrade (prune in 0.12 is slow).
- [ ] Install restic ≥ 0.14 (upstream binary or `restic self-update`) and migrate the
  repository to format v2 once the backup works.
- [ ] Delete the empty `/etc/cron.d/ikos-postgres.dump`.
- [ ] **Mail:** install postfix as a loopback-only relay via `web2.qameta.com`, `root` →
  `serverservice@qameta.com`, like web1. Until then cron and unattended-upgrades errors
  are silent (backups at least ping healthchecks.io).
- [x] `ikos-16` destroyed (2026-10-30, no linked apps). Its final dump
  `/var/dump/pg/ikos-16.dump` (2026-10-30 14:29) was deleted at 14:33; older restic
  snapshots still have it.
- [ ] Remove the leftover Caddy proxy container (`dokku caddy:stop`, after checking
  `dokku proxy:report ikos` shows `nginx`).
- [ ] Pending updates (2026-10-30): 3 security updates incl. kernel 5.15.0-202
  (`linux-image-virtual`). unattended-upgrades should install them; reboot by hand
  afterwards. Old kernel 5.15.0-190 is still installed (`apt autoremove --purge`).
  140 packages in `rc` state (`apt purge '~c'`).
- [ ] Ubuntu 22.04 standard support ends 2027-04. Plan a move to Debian 13 like web1/web2
  (new VM + Dokku app migration is probably easier than an in-place upgrade).
- [ ] nginx catch-all like web1 (`etc/nginx/sites-available/catchall`, `return 444`,
  `ssl_reject_handshake on`) instead of the stock `default` site.
- [ ] Host firewall (`table inet hostfw` + no-flush drop-in, copy from web1) — optional
  while only 22/80/443 listen.
- [ ] SSH hardening: no `sshd_config.d` drop-ins, `X11Forwarding yes`. Same plan as web1
  (keys only except `konstantin`, fail2ban).
- [ ] Limit journald (`SystemMaxUse=500M` in `/etc/systemd/journald.conf.d/`).
- [ ] Docker default log limits in `/etc/docker/daemon.json` (Dokku already caps app
  containers; check `dokku logs:report --global`).
- [ ] Review login-shell user `github` (uid 1002) — purpose unknown.
- [ ] Add `konstantin` to `adm` so agents can read logs without root
  (`usermod -aG adm konstantin`).

Good: no failed units; NTP synced; Let's Encrypt cert valid to 2026-12-23; TLS 1.3
works; no app ports published; uptime 16 days (last reboot 2026-10-13).
