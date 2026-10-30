#!/usr/bin/env bash
#
# pg_dump_files.sh
#
# Dumps all Dokku PostgreSQL databases to /var/dump/pg.
# Each database is always written to the same file (overwritten); restic
# keeps the history.
# If an export fails, the others are still dumped and the previous file is
# kept; the exit code is then 1 so backup.sh reports a failure.

set -uo pipefail

BACKUP_DIR="/var/dump/pg"
FAIL=0

mkdir -p "$BACKUP_DIR"

mapfile -t SERVICES < <(dokku postgres:list 2>/dev/null | tail -n +2)

for SERVICE in "${SERVICES[@]}"; do
    [ -z "$SERVICE" ] && continue

    DEST_FILE="${BACKUP_DIR}/${SERVICE}.dump"

    echo "Dumping '${SERVICE}' to ${DEST_FILE} ..."
    if dokku postgres:export "$SERVICE" > "${DEST_FILE}.tmp" && [ -s "${DEST_FILE}.tmp" ]; then
        mv "${DEST_FILE}.tmp" "$DEST_FILE"
    else
        echo "ERROR: export of '${SERVICE}' failed" >&2
        rm -f "${DEST_FILE}.tmp"
        FAIL=1
    fi
done

exit $FAIL
