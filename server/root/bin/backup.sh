#!/bin/bash
#
# Daily backup: dump all Dokku Postgres services, then restic to the Hetzner
# Storage Box, then forget old snapshots. Reports to healthchecks.io: /start,
# then success, or /fail (exit 1) when any step fails.
#
# restic here is 0.12.1 (Ubuntu package): no --retry-lock.

# root-only file, kept out of the git repo
PING_URL="$(cat /etc/restic/healthchecks-url)"
FAIL=0

curl -fsS -m 10 --retry 5 "${PING_URL}/start"

# backup postgres dbs to /var/dump/pg/
/root/bin/pg_dump_files.sh || FAIL=1

/usr/bin/restic backup --exclude-file /etc/restic/excludes.txt --files-from /etc/restic/backup.txt || FAIL=1

if [ $FAIL -eq 0 ]; then
    curl -fsS -m 10 --retry 5 "$PING_URL"
else
    curl -fsS -m 10 --retry 5 "${PING_URL}/fail"
    exit 1
fi

# forget old backups (no prune: data stays in the repository)
sleep 10
/usr/bin/restic forget --keep-daily 90 --keep-weekly 20 --keep-monthly 12 --keep-yearly 75
