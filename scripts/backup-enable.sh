#!/usr/bin/env bash
# Turns backups on (or off) with one command (SH-06). Run as root on the server.
#
#   scripts/backup-enable.sh --target local:/srv/backup [--hc-url https://hc-ping.com/<uuid>]
#   scripts/backup-enable.sh --target s3:https://<endpoint>/<bucket>   (env AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
#   scripts/backup-enable.sh --target rclone:<remote>:<path>
#   scripts/backup-enable.sh --disable
#
# Steps: restic repo init, /root/.config/restic/env (0600), durio-backup.service + .timer,
# BACKUP_ENABLED=true in .env, first backup and a restore dry run.
# The restic password is generated into /root/.config/restic/password unless RESTIC_PASSWORD is set:
# COPY IT OFF THE SERVER (password manager) — without it the backups are useless.
# A local target protects against admin mistakes and failed upgrades, NOT against losing the disk.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_config

TARGET='' HC_URL='' DISABLE=0 NO_TIMER=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --target) TARGET=${2:?}; shift ;;
        --hc-url) HC_URL=${2:?}; shift ;;
        --disable) DISABLE=1 ;;
        --no-timer) NO_TIMER=1 ;;
        -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done

[[ $(id -u) -eq 0 ]] || die "run as root (installs systemd units and /root/.config/restic)"
UNIT_DIR=/etc/systemd/system

if [[ $DISABLE -eq 1 ]]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now durio-backup.timer 2>/dev/null || true
    fi
    env_set BACKUP_ENABLED false "$ENV_FILE"
    warn_no_backups
    info "backups disabled (restic repository and its env are left untouched)"
    exit 0
fi

[[ -n $TARGET ]] || die "--target is required (local:/path | s3:https://endpoint/bucket | rclone:remote:path)"
require_cmd restic
case $TARGET in
    local:/*) REPO=${TARGET#local:}; mkdir -p "$REPO"; chmod 700 "$REPO" ;;
    s3:*)
        REPO=$TARGET
        [[ -n ${AWS_ACCESS_KEY_ID:-} && -n ${AWS_SECRET_ACCESS_KEY:-} ]] ||
            die "s3 target: export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
        ;;
    rclone:*) REPO=$TARGET; require_cmd rclone ;;
    *) die "unsupported target: $TARGET" ;;
esac
if [[ $TARGET == local:* ]]; then
    data_dev=$(df -P "$ROOT/data" | awk 'NR==2 {print $1}')
    repo_dev=$(df -P "$REPO" | awk 'NR==2 {print $1}')
    [[ $data_dev != "$repo_dev" ]] ||
        warn "backup target is on the same disk as data/: protects from mistakes, not from disk loss"
fi

CONF_DIR=/root/.config/restic
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
if [[ ! -s $CONF_DIR/password ]]; then
    (umask 077 && printf '%s\n' "${RESTIC_PASSWORD:-$(openssl rand -base64 33)}" >"$CONF_DIR/password")
    warn "restic password written to $CONF_DIR/password — copy it to your password manager NOW"
fi
(
    umask 077
    {
        echo "RESTIC_REPOSITORY=$REPO"
        echo "RESTIC_PASSWORD_FILE=$CONF_DIR/password"
        [[ -n ${AWS_ACCESS_KEY_ID:-} ]] && echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
        [[ -n ${AWS_SECRET_ACCESS_KEY:-} ]] && echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"
        [[ -n $HC_URL ]] && echo "BACKUP_HC_URL=$HC_URL"
        true
    } >"$CONF_DIR/env"
)

set -a
# shellcheck source=/dev/null
. "$CONF_DIR/env"
set +a
if ! restic cat config >/dev/null 2>&1; then
    info "restic init $REPO"
    restic init
fi

env_set BACKUP_ENABLED true "$ENV_FILE"

if [[ $NO_TIMER -eq 0 ]]; then
    require_cmd systemctl
    cat >"$UNIT_DIR/durio-backup.service" <<EOF
[Unit]
Description=dur.io backup (restic)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
WorkingDirectory=$ROOT
ExecStart=$ROOT/scripts/backup.sh
Nice=10
IOSchedulingClass=idle
EOF
    cat >"$UNIT_DIR/durio-backup.timer" <<'EOF'
[Unit]
Description=Daily dur.io backup

[Timer]
OnCalendar=*-*-* 03:30
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now durio-backup.timer
fi

info "first backup..."
"$ROOT/scripts/backup.sh"
info "restore dry run..."
"$ROOT/scripts/restore.sh" --dry-run
info "backups enabled: $REPO (daily 03:30 UTC)"
