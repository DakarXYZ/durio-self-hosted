#!/usr/bin/env bash
# Backup of a dur.io server with restic (SH-06). DISABLED by default (BACKUP_ENABLED=false):
# then it only prints a warning and exits 0. Enable with scripts/backup-enable.sh.
#
#   scripts/backup.sh                    full backup (systemd timer durio-backup.timer runs this)
#   scripts/backup.sh --mongo-dump FILE  only a local consistent mongodump archive (works always;
#                                        used by upgrade.sh)
#
# Contents: mongodump --oplog, MinIO bucket mirror (storage minio only; with s3 the provider
# versions the bucket), secrets.env, .env, Revolt*.toml, livekit.yml, stoat.json, config/,
# data/caddy-data (ACME account + certificates). RabbitMQ and Valkey are ephemeral: not saved.
# Restic settings: /root/.config/restic/env (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, provider keys,
# optional BACKUP_HC_URL for healthchecks.io pings) — written by backup-enable.sh.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_config
cd "$ROOT"

if [[ ${1:-} == --mongo-dump ]]; then
    [[ -n ${2:-} ]] || die "usage: $0 --mongo-dump FILE"
    info "mongodump --oplog -> $2"
    mongo_dump_to "$2"
    exit 0
fi
[[ $# -eq 0 ]] || die "usage: $0 [--mongo-dump FILE]"

if ! backups_enabled; then
    warn_no_backups
    exit 0
fi

require_cmd restic flock
RESTIC_ENV=${DURIO_RESTIC_ENV:-/root/.config/restic/env}
[[ -r $RESTIC_ENV ]] || die "BACKUP_ENABLED=true but $RESTIC_ENV is missing — run scripts/backup-enable.sh"
set -a
# shellcheck source=/dev/null
. "$RESTIC_ENV"
set +a

ping_hc() {
    if [[ -n ${BACKUP_HC_URL:-} ]]; then
        curl -fsS -m 10 --retry 3 -o /dev/null "$BACKUP_HC_URL$1" || true
    fi
}
trap 'ping_hc /fail' ERR

exec 9>"$ROOT/data/.backup.lock"
flock -n 9 || die "another backup is running"
ping_hc /start

STAGING=${BACKUP_STAGING:-$ROOT/backups/staging}
mkdir -p "$STAGING"
TAG=durio

# 1. Mongo first (consistent with --oplog), streamed straight into restic.
info "mongodump -> restic"
# shellcheck disable=SC2016 # expanded inside the container
compose exec -T database sh -c \
    'mongodump --quiet --uri "mongodb://root:${MONGO_INITDB_ROOT_PASSWORD}@localhost:27017/?authSource=admin&directConnection=true" --archive --gzip --oplog' |
    restic backup --quiet --tag "$TAG" --tag mongo --stdin --stdin-filename mongo.archive.gz

# 2. Files: mirror of the bucket (never the raw MinIO directory: xl.meta, partial objects).
paths=(secrets.env .env Revolt.toml Revolt.overrides.toml livekit.yml stoat.json config data/caddy-data)
[[ -f images.lock.env ]] && paths+=(images.lock.env)
if [[ $(env_get FILES_STORAGE .env) == minio ]]; then
    info "mc mirror minio/revolt-uploads -> $STAGING/minio-mirror"
    mkdir -p "$STAGING/minio-mirror"
    compose run --rm --no-deps -T -v "$STAGING/minio-mirror:/mirror" --entrypoint mc createbuckets \
        mirror --quiet --overwrite --remove minio/revolt-uploads /mirror
    paths+=("$STAGING/minio-mirror")
fi

info "restic backup: ${paths[*]}"
restic backup --quiet --tag "$TAG" --tag files "${paths[@]}"

info "restic forget --prune"
restic forget --quiet --tag "$TAG" --group-by tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# Monthly integrity check of a sample of the data.
if [[ $(date +%d) == 01 ]]; then
    restic check --read-data-subset=5%
fi

ping_hc ""
info "backup done"
