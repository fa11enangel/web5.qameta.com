# web5.qameta.com

Ops notes and config for `web5.qameta.com`, a small Hetzner Cloud VM running Ubuntu
22.04 with Dokku. It hosts one app, **ikos** (`www.iko-datenbank.de`, Rails), with its
Postgres and Redis services.

## Contents

- [`AGENTS.md`](AGENTS.md): the full guide. It covers access, ground rules, the system
  and services, expected ports, backups, common tasks, gotchas and the TODO list. It is
  written for AI agents, and people can use it too.
- [`server/`](server): config files that differ from the package defaults, stored at
  their real paths under `/`:

  | File | Purpose |
  |---|---|
  | `etc/docker/daemon.json` | `live-restore` |
  | `etc/systemd/timesyncd.conf` | Hetzner NTP |
  | `etc/nginx/conf.d/server_names_hash_bucket_size.conf` | Long server names for Dokku vhosts |
  | `etc/restic/backup.txt` | Paths for the restic backup (`/var/dump`, `/etc`) |
  | `var/www/html/index.html` | "Welcome to a Qameta System!" page of the nginx default site |
  | `root/bin/backup.sh` | Nightly backup: dumps, restic, forget, healthchecks.io ping (URL in root-only `/etc/restic/healthchecks-url`) |
  | `root/bin/pg_dump_files.sh` | Dump every Dokku Postgres service to `/var/dump/pg/` (new services are found automatically) |

- [`tools/`](tools): one-time root scripts, e.g. `restic_password_file.sh` (moves the
  restic password into `/root/.restic-password`).

## Workflow

- Root commands are run by hand on the server. `sudo` needs a password, so agents only
  read.
- After you change a tracked file on the server, copy it back into `server/`, update
  `AGENTS.md` and commit.
- Check that the repo matches the server (read-only, no root). `root/bin/` is root-only,
  so it always shows as DIFF here; compare it as root with `diff`:

  ```sh
  cd server && for f in $(find . -type f | sed 's|^\.||'); do
    ssh web5.qameta.com "cat $f" | diff -q - ".$f" >/dev/null && echo "same $f" || echo "DIFF $f"
  done
  ```

Secrets and root-only files (app env, Dokku service passwords, restic password) are not
in this repo on purpose.
