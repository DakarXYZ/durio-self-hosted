#!/usr/bin/env bash
# Move uploaded files between storages (SH-21) with mc mirror. Objects are copied as they are:
# autumn encrypted them with REVOLT__FILES__ENCRYPTION_KEY, which does not change.
#
#   scripts/migrate-storage.sh --to s3 --s3-endpoint URL --s3-region R --s3-bucket B [--s3-path-style true]
#                              (env S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY)
#   scripts/migrate-storage.sh --to minio [--minio-data-path /mnt/files/minio]
#                              (from s3 back to MinIO, or MinIO -> MinIO on another disk)
#
# Steps: (1) mirror while live; (2) stop autumn (uploads/downloads unavailable, chat works);
# (3) mirror again (delta); (4) compare object count and size; (5) generate_config.sh --overwrite
# --storage ...; up -d; (6) smoke.sh; (7) the OLD bucket/directory is NOT deleted — remove it by
# hand after a few days.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker jq
require_config
cd "$ROOT"

MC_IMAGE=docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z
SILO_IMAGE=docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z
TO='' NEW_MINIO_PATH='' YES=0
gen_args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --to) TO=${2:?}; shift ;;
        --minio-data-path) NEW_MINIO_PATH=${2:?}; shift ;;
        --s3-endpoint | --s3-region | --s3-bucket | --s3-path-style) gen_args+=("$1" "${2:?}"); shift ;;
        --yes | -y) YES=1 ;;
        -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done
[[ $TO == minio || $TO == s3 ]] || die "--to minio|s3 is required"

FROM=$(env_get FILES_STORAGE .env)
OLD_PATH=$(env_get MINIO_DATA_PATH .env)
NETWORK="$(compose config --format json | jq -r '.name')_default"
MINIO_USER=$(env_get MINIO_ROOT_USER secrets.env)
MINIO_PASS=$(env_get MINIO_ROOT_PASSWORD secrets.env)

# Source alias "src" and destination alias "dst" for mc, as MC_HOST_* (never on the command line).
mc_env=()
alias_minio() { # NAME HOST
    mc_env+=(-e "MC_HOST_$1=http://$MINIO_USER:$MINIO_PASS@$2:9000")
}
alias_s3() { # NAME ENDPOINT KEY SECRET  (keys must be URL-safe)
    local scheme=${2%%://*} host=${2#*://}
    mc_env+=(-e "MC_HOST_$1=$scheme://$3:$4@$host")
}
SRC_BUCKET=revolt-uploads DST_BUCKET=revolt-uploads
TEMP_MINIO=
OLD_ENDPOINT=

case "$FROM>$TO" in
    "minio>s3")
        [[ -n ${S3_ACCESS_KEY_ID:-} && -n ${S3_SECRET_ACCESS_KEY:-} ]] || die "export S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY"
        endpoint='' bucket=''
        for ((i = 0; i < ${#gen_args[@]}; i += 2)); do
            [[ ${gen_args[i]} == --s3-endpoint ]] && endpoint=${gen_args[i + 1]}
            [[ ${gen_args[i]} == --s3-bucket ]] && bucket=${gen_args[i + 1]}
        done
        [[ -n $endpoint && -n $bucket ]] || die "--s3-endpoint and --s3-bucket are required"
        alias_minio src minio
        alias_s3 dst "$endpoint" "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY"
        DST_BUCKET=$bucket
        ;;
    "s3>minio")
        SRC_BUCKET=$(env_get S3_BUCKET .env)
        OLD_ENDPOINT=$(env_get S3_ENDPOINT .env)
        alias_s3 src "$OLD_ENDPOINT" "$(env_get REVOLT__FILES__S3__ACCESS_KEY_ID secrets.env)" \
            "$(env_get REVOLT__FILES__S3__SECRET_ACCESS_KEY secrets.env)"
        [[ -z $NEW_MINIO_PATH ]] || env_set MINIO_DATA_PATH "$NEW_MINIO_PATH" .env
        info "starting MinIO"
        # the autumn service account is created later by createbuckets, with the new keys
        compose --profile minio up -d --wait minio
        alias_minio dst minio
        ;;
    "minio>minio")
        [[ -n $NEW_MINIO_PATH && $NEW_MINIO_PATH != "$OLD_PATH" ]] || die "--minio-data-path NEW_PATH required"
        mkdir -p "$NEW_MINIO_PATH"
        TEMP_MINIO=durio-minio-migrate
        info "temporary MinIO on $NEW_MINIO_PATH"
        export MINIO_ROOT_USER=$MINIO_USER MINIO_ROOT_PASSWORD=$MINIO_PASS
        docker run -d --rm --name "$TEMP_MINIO" --network "$NETWORK" -v "$NEW_MINIO_PATH:/data" \
            -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD "$SILO_IMAGE" server /data >/dev/null
        trap 'docker rm -f "$TEMP_MINIO" >/dev/null 2>&1 || true' EXIT
        alias_minio src minio
        alias_minio dst "$TEMP_MINIO"
        ;;
    *) die "nothing to do: storage is already $FROM (use --minio-data-path to move MinIO)" ;;
esac

mc() {
    docker run --rm --network "$NETWORK" "${mc_env[@]}" "$MC_IMAGE" "$@"
}
stats() { # ALIAS/BUCKET -> "objects bytes"
    local n size
    n=$(mc ls --recursive --json "$1" | grep -c '"type":"file"' || true)
    size=$(mc du --json "$1" | jq -r '.size' | tail -n 1)
    echo "$n $size"
}

[[ $YES -eq 1 ]] || {
    read -rp "Migrate files $FROM -> $TO? autumn will be stopped for the final sync. [y/N]: " reply
    [[ $reply == [yY] ]] || die "aborted"
}

if [[ $TO == minio ]]; then
    for _ in $(seq 60); do mc ready dst >/dev/null 2>&1 && break; sleep 2; done
fi
mc mb --ignore-existing "dst/$DST_BUCKET" >/dev/null 2>&1 || true

info "(1) mirror while live"
mc mirror --quiet --overwrite "src/$SRC_BUCKET" "dst/$DST_BUCKET"
info "(2) stop autumn"
compose stop autumn
info "(3) delta mirror"
mc mirror --quiet --overwrite "src/$SRC_BUCKET" "dst/$DST_BUCKET"
info "(4) verify"
src_stats=$(stats "src/$SRC_BUCKET")
dst_stats=$(stats "dst/$DST_BUCKET")
echo "    source: $src_stats   destination: $dst_stats   (objects bytes)"
if [[ $src_stats != "$dst_stats" ]]; then
    compose start autumn
    die "object count/size differ — autumn restarted on the OLD storage, nothing switched"
fi

info "(5) switch configuration"
if [[ -n $TEMP_MINIO ]]; then
    docker rm -f "$TEMP_MINIO" >/dev/null
    compose stop minio crond
    env_set MINIO_DATA_PATH "$NEW_MINIO_PATH" .env
    compose up -d --force-recreate minio createbuckets
else
    "$ROOT/scripts/generate_config.sh" --overwrite --yes --storage "$TO" "${gen_args[@]}" --skip-s3-check
fi
compose up -d --force-recreate "${BACKEND_SERVICES[@]}"
[[ $TO == s3 ]] && compose stop minio 2>/dev/null || true

info "(6) smoke test"
"$ROOT/scripts/smoke.sh" || warn "smoke test failed — check autumn logs"
info "(7) done. Download an OLD attachment to confirm. Keep the old storage for a few days, then remove it:"
case "$FROM>$TO" in
    "minio>s3") echo "    $OLD_PATH (MinIO data; container stopped)" ;;
    "s3>minio") echo "    bucket $SRC_BUCKET at $OLD_ENDPOINT" ;;
    "minio>minio") echo "    $OLD_PATH" ;;
esac
