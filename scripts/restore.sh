#!/usr/bin/env bash
# Restore (SH-06).
#
#   scripts/restore.sh --from-archive backups/pre-upgrade/<file>.archive.gz [--yes]
#       Mongo only, from a local dump (rollback of a failed upgrade with migrations).
#   scripts/restore.sh [--snapshot latest|<id>] [--with-config] [--yes]
#       Full restore from restic onto this machine (clean machine: clone repo, install docker, restic,
#       put /root/.config/restic/{env,password} back, then run this with --with-config).
#   scripts/restore.sh --dry-run [--snapshot ...]
#       Check that the latest snapshots exist and the Mongo archive is readable. Changes nothing.
#
# Criterion of success: old attachment downloads and opens, login with an old account works.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARCHIVE='' SNAPSHOT=latest DRY_RUN=0 WITH_CONFIG=0 YES=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --from-archive) ARCHIVE=${2:?}; shift ;;
        --snapshot) SNAPSHOT=${2:?}; shift ;;
        --dry-run) DRY_RUN=1 ;;
        --with-config) WITH_CONFIG=1 ;;
        --yes | -y) YES=1 ;;
        -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done
cd "$ROOT"

confirm() {
    [[ $YES -eq 1 ]] && return 0
    local reply
    read -rp "$1 [y/N]: " reply
    [[ $reply == [yY] ]] || die "aborted"
}

BACKEND_AND_PROXY=("${BACKEND_SERVICES[@]}" gifbox caddy)

# ---------------------------------------------------------------- local archive (pre-upgrade dumps)
if [[ -n $ARCHIVE ]]; then
    require_config
    [[ -f $ARCHIVE ]] || die "archive not found: $ARCHIVE"
    gzip -t "$ARCHIVE" || die "archive is corrupt: $ARCHIVE"
    [[ $DRY_RUN -eq 1 ]] && { echo "archive OK: $ARCHIVE"; exit 0; }
    confirm "Stop the backend and replace the database with $ARCHIVE?"
    compose stop "${BACKEND_AND_PROXY[@]}" || true
    compose up -d --wait database
    compose up database-init
    info "mongorestore --drop --oplogReplay"
    mongo_restore_from "$ARCHIVE"
    info "database restored; start the stack with the image tag that matches this dump:"
    echo "    scripts/compose up -d && scripts/smoke.sh"
    exit 0
fi

# ---------------------------------------------------------------- restic
require_cmd restic
RESTIC_ENV=${DURIO_RESTIC_ENV:-/root/.config/restic/env}
[[ -r $RESTIC_ENV ]] || die "$RESTIC_ENV not found (restore it from your password manager / notes)"
set -a
# shellcheck source=/dev/null
. "$RESTIC_ENV"
set +a

snap_of() { # TAG -> snapshot id
    if [[ $SNAPSHOT == latest ]]; then
        restic snapshots --json --tag durio --tag "$1" --latest 1 | jq -r 'last.short_id // empty'
    else
        printf '%s' "$SNAPSHOT"
    fi
}
require_cmd jq
mongo_snap=$(snap_of mongo)
files_snap=$(snap_of files)
[[ -n $mongo_snap && -n $files_snap ]] || die "no snapshots with tags durio+mongo / durio+files"
info "snapshots: mongo $mongo_snap, files $files_snap"

if [[ $DRY_RUN -eq 1 ]]; then
    restic dump "$mongo_snap" /mongo.archive.gz | gzip -t
    restic ls "$files_snap" | grep -q '/secrets.env$' || die "secrets.env missing in snapshot $files_snap"
    echo "restore dry run: OK"
    exit 0
fi

confirm "Restore snapshots onto $ROOT? Running services will be stopped and the database replaced."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
restic restore "$files_snap" --target "$TMP"
SRC="$TMP$ROOT"
[[ -d $SRC ]] || SRC=$(dirname "$(find "$TMP" -name secrets.env -print -quit)")

if [[ $WITH_CONFIG -eq 1 ]]; then
    info "restoring configuration and caddy data"
    for f in secrets.env .env Revolt.toml Revolt.overrides.toml livekit.yml stoat.json images.lock.env; do
        [[ -f $SRC/$f ]] && cp -p "$SRC/$f" "$ROOT/$f"
    done
    [[ -d $SRC/config ]] && cp -a "$SRC/config/." "$ROOT/config/"
    mkdir -p "$ROOT/data"
    [[ -d $SRC/data/caddy-data ]] && cp -a "$SRC/data/caddy-data" "$ROOT/data/"
fi
require_config

compose stop "${BACKEND_AND_PROXY[@]}" 2>/dev/null || true
compose up -d --wait database
compose up database-init

info "mongorestore from snapshot $mongo_snap"
restic dump "$mongo_snap" /mongo.archive.gz >"$TMP/mongo.archive.gz"
mongo_restore_from "$TMP/mongo.archive.gz"

if [[ $(env_get FILES_STORAGE .env) == minio ]]; then
    mirror=$(find "$TMP" -type d -name minio-mirror -print -quit)
    if [[ -n $mirror ]]; then
        info "mc mirror back into minio/revolt-uploads"
        compose up -d --wait minio
        compose up createbuckets
        compose run --rm --no-deps -T -v "$mirror:/mirror:ro" --entrypoint mc createbuckets \
            mirror --quiet --overwrite /mirror minio/revolt-uploads
    else
        warn "no minio-mirror in snapshot $files_snap — files not restored"
    fi
fi

compose up -d
wait_healthy 300 api || warn "api not healthy yet — check: scripts/compose logs api"
"$ROOT/scripts/smoke.sh" || warn "smoke test failed"
info "restore finished: check that an old attachment opens and an old account can log in"
