#!/bin/bash
#
# One-time, as root: move the restic password out of /etc/cron.d/backup and
# /root/.bashrc into /root/.restic-password (0600). Both then use
# RESTIC_PASSWORD_FILE. Never prints the password.
#
# Stops without changing anything if the password file exists, the two
# passwords differ, or the repository can't be opened with the new file.
# Copies of the old files go to /root/restic-migration-bak-<date>/ (they still
# contain the password: delete them once cron and a root shell work).

set -euo pipefail

CRON=/etc/cron.d/backup
BASHRC=/root/.bashrc
PWFILE=/root/.restic-password
BAKDIR=/root/restic-migration-bak-$(date +%F-%H%M)

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -e "$PWFILE" ] && die "$PWFILE exists already"

# value of NAME=... from the cron file, surrounding quotes removed like cron does
cron_value() {
    local line
    [ "$(grep -cE "^[[:space:]]*$1=" "$CRON")" -eq 1 ] || die "need exactly one $1 line in $CRON"
    line=$(grep -E "^[[:space:]]*$1=" "$CRON")
    line=${line#*=}
    line=${line%"${line##*[![:space:]]}"}
    if [[ $line == \"*\" || $line == \'*\' ]]; then line=${line:1:-1}; fi
    printf '%s' "$line"
}

PW=$(cron_value RESTIC_PASSWORD)
REPO=$(cron_value RESTIC_REPOSITORY)
[ -n "$PW" ] || die "empty RESTIC_PASSWORD in $CRON"

# password in .bashrc (if any) must be the same
BASHRC_PW_LINES=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?RESTIC_PASSWORD=' "$BASHRC" || true)
if [ "$BASHRC_PW_LINES" -gt 0 ]; then
    BPW=$(env -i bash -c 'eval "$(grep -E "^[[:space:]]*(export[[:space:]]+)?RESTIC_PASSWORD=" "$1")"; printf "%s" "${RESTIC_PASSWORD-}"' _ "$BASHRC")
    [ "$BPW" = "$PW" ] || die "RESTIC_PASSWORD in $BASHRC differs from $CRON"
fi

# write the password file and test it before touching anything else
(umask 077; printf '%s\n' "$PW" > "$PWFILE")
if ! RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PWFILE" /usr/bin/restic cat config >/dev/null; then
    rm -f "$PWFILE"
    die "restic can't open the repository with $PWFILE, nothing changed"
fi
echo "OK: $PWFILE (0600) opens the repository"

mkdir -m 700 "$BAKDIR"
cp -a "$CRON" "$BAKDIR/cron.d-backup"
cp -a "$BASHRC" "$BAKDIR/bashrc"

sed -i -E "s|^[[:space:]]*RESTIC_PASSWORD=.*|RESTIC_PASSWORD_FILE=$PWFILE|" "$CRON"
chmod 600 "$CRON"

if [ "$BASHRC_PW_LINES" -gt 0 ]; then
    sed -i -E "s|^[[:space:]]*(export[[:space:]]+)?RESTIC_PASSWORD=.*|export RESTIC_PASSWORD_FILE=$PWFILE|" "$BASHRC"
else
    printf '\nexport RESTIC_PASSWORD_FILE=%s\n' "$PWFILE" >> "$BASHRC"
fi
grep -qE '^[[:space:]]*(export[[:space:]]+)?RESTIC_REPOSITORY=' "$BASHRC" \
    || printf 'export RESTIC_REPOSITORY="%s"\n' "$REPO" >> "$BASHRC"

# nothing may still hold the password
! grep -qE 'RESTIC_PASSWORD=' "$CRON" "$BASHRC" || die "RESTIC_PASSWORD still present"
! grep -qF -- "$PW" "$CRON" "$BASHRC" || die "password still present"

echo "OK: $CRON and $BASHRC now use RESTIC_PASSWORD_FILE"
echo
grep -E '^[[:space:]]*RESTIC_' "$CRON"
grep -E '^[[:space:]]*(export[[:space:]]+)?RESTIC_' "$BASHRC"
ls -la "$PWFILE" "$CRON"
echo
echo "Old copies (contain the password): $BAKDIR"
