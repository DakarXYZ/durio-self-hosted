# shellcheck shell=bash
# Shared helpers for the dur.io deployment scripts. Source it, do not run it:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
SECRETS_FILE="$ROOT/secrets.env"
LOCK_FILE="$ROOT/images.lock.env"

# shellcheck disable=SC2034 # used by the scripts that source this file
# Image tag used when nothing else is known (first install without --app-tag).
DEFAULT_APP_TAG="0.16.0-fork.1"
# shellcheck disable=SC2034
# Browser client image (durio-web, built in durio-for-web) used when nothing else is known.
DEFAULT_WEB_TAG="0.1.0"
# shellcheck disable=SC2034
DEFAULT_IMAGE_REGISTRY="ghcr.io/dakarxyz/"

# Backend services built from our fork (compose service names).
# shellcheck disable=SC2034
BACKEND_SERVICES=(api events autumn january crond pushd voice-ingress)

# Publicly known defaults from upstream crates/core/config/Revolt.toml. A server
# must never run with these (anyone could decrypt files / forge pushes).
PUBLIC_DEFAULT_FILES_KEY="qcuMA+ssxhMyKaNAKBGFfryfFtUH8NDlamQyDwGW6fU="
PUBLIC_DEFAULT_VAPID_PUBLIC="BGcvgR-i2z4IQ5Mw841vJvkLjt8wY-FjmWrw83jOLCY52qcGZS0OF7nfLzuYbjsQISwVO2HXrmf18gLWVX3Kwfw="

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

info() {
    printf '==> %s\n' "$*"
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# env_get KEY FILE — value of KEY in a dotenv file (last occurrence), surrounding quotes removed.
env_get() {
    local key=$1 file=$2 line val
    [[ -f $file ]] || return 0
    line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
    [[ -n $line ]] || return 0
    val=${line#*=}
    if [[ ${#val} -ge 2 && ( ($val == \'*\') || ($val == \"*\") ) ]]; then
        val=${val:1:${#val}-2}
    fi
    printf '%s' "$val"
}

# env_has KEY FILE — true if KEY is defined in the file.
env_has() {
    [[ -f $2 ]] && grep -qE "^$1=" "$2"
}

# env_set KEY VALUE FILE — replace or append KEY=VALUE, keeping the file's permissions.
env_set() {
    local key=$1 val=$2 file=$3 tmp
    tmp=$(mktemp)
    if [[ -f $file ]]; then
        KEY="$key" VAL="$val" awk '
            BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; done = 0 }
            index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
            { print }
            END { if (!done) print k "=" v }
        ' "$file" >"$tmp"
        cat "$tmp" >"$file"
    else
        printf '%s=%s\n' "$key" "$val" >"$file"
    fi
    rm -f "$tmp"
}

# compose ARGS... — docker compose with our env files (compose >= 2.24 for several --env-file).
compose() {
    local args=(--project-directory "$ROOT" -f "$ROOT/compose.yml")
    [[ -f $ROOT/compose.override.yml ]] && args+=(-f "$ROOT/compose.override.yml")
    args+=(--env-file "$ENV_FILE" --env-file "$SECRETS_FILE")
    [[ -f $LOCK_FILE ]] && args+=(--env-file "$LOCK_FILE")
    docker compose "${args[@]}" "$@"
}

# public_curl_opts DOMAIN LOCAL — fill the global CURL_OPTS array for requests to https://DOMAIN.
# LOCAL=1 resolves DOMAIN to 127.0.0.1 (on the server itself); in lan mode Caddy's local CA is trusted.
public_curl_opts() {
    local domain=$1 local_=$2 ca="$ROOT/data/caddy-data/caddy/pki/authorities/local/root.crt"
    CURL_OPTS=(-sS --max-time 15)
    [[ $local_ -eq 1 ]] && CURL_OPTS+=(--resolve "$domain:443:127.0.0.1" --resolve "$domain:80:127.0.0.1")
    if [[ $(env_get ADDRESS_MODE "$ENV_FILE") == lan && -f $ca ]]; then
        CURL_OPTS+=(--cacert "$ca")
    fi
    return 0
}

# Marker of a server where E2EE was switched on (scripts/e2ee-enable.sh): never switch it off again.
# shellcheck disable=SC2034
E2EE_MARKER="$ROOT/data/.e2ee-enabled"

# check_tag TAG — image tags are explicit releases: docker tag syntax, no 'latest'.
check_tag() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid tag: $1"
    [[ $1 != latest ]] || die "refusing 'latest': use a release tag"
}

# ensure_web_tag — installs from before the browser client have no WEB_TAG in .env: add the default.
ensure_web_tag() {
    env_has WEB_TAG "$ENV_FILE" && return 0
    env_set WEB_TAG "$DEFAULT_WEB_TAG" "$ENV_FILE"
    info "WEB_TAG was missing in .env: set to $DEFAULT_WEB_TAG"
}

# resolve_digest IMAGE_REF — "@sha256:..." of a registry image (for images.lock.env).
resolve_digest() {
    local digest
    digest=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$1" | jq -r '.digest')
    [[ $digest == sha256:* ]] || die "no digest for $1"
    printf '@%s' "$digest"
}

require_config() {
    [[ -f $ENV_FILE && -f $SECRETS_FILE ]] ||
        die ".env / secrets.env not found in $ROOT — run scripts/generate_config.sh first"
}

backups_enabled() {
    [[ "$(env_get BACKUP_ENABLED "$ENV_FILE")" == "true" ]]
}

warn_no_backups() {
    if ! backups_enabled; then
        warn "BACKUPS ARE DISABLED (BACKUP_ENABLED=false): losing this disk loses all data and secrets.env."
        warn "Enable them with scripts/backup-enable.sh --target ... (see README)."
    fi
}

# check_no_default_secrets — refuse to run with upstream's public default keys.
check_no_default_secrets() {
    local files_key vapid rabbit_pass s3_secret
    files_key=$(env_get REVOLT__FILES__ENCRYPTION_KEY "$SECRETS_FILE")
    vapid=$(env_get REVOLT__PUSHD__VAPID__PUBLIC_KEY "$SECRETS_FILE")
    rabbit_pass=$(env_get REVOLT__RABBIT__PASSWORD "$SECRETS_FILE")
    s3_secret=$(env_get REVOLT__FILES__S3__SECRET_ACCESS_KEY "$SECRETS_FILE")
    [[ -n $files_key ]] || die "REVOLT__FILES__ENCRYPTION_KEY is missing in secrets.env"
    [[ $files_key != "$PUBLIC_DEFAULT_FILES_KEY" ]] || die "secrets.env uses the public default file encryption key"
    [[ -n $vapid && $vapid != "$PUBLIC_DEFAULT_VAPID_PUBLIC" ]] || die "secrets.env has no own VAPID keys"
    [[ -n $rabbit_pass && $rabbit_pass != "rabbitpass" ]] || die "secrets.env uses the default RabbitMQ password"
    [[ $s3_secret != "minioautumn" ]] || die "secrets.env uses the default MinIO secret"
}

# container_state SERVICE — "healthy", "unhealthy", "starting", "running", "exited", ... or "missing".
container_state() {
    local id
    id=$(compose ps -a -q "$1" 2>/dev/null | head -n 1)
    [[ -n $id ]] || { echo missing; return 0; }
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id"
}

# wait_healthy TIMEOUT_SECONDS SERVICE... — wait until each service is healthy (or running without a healthcheck).
wait_healthy() {
    local timeout=$1 svc state deadline
    shift
    deadline=$((SECONDS + timeout))
    for svc in "$@"; do
        while :; do
            state=$(container_state "$svc")
            case $state in
                healthy | running) break ;;
                unhealthy | exited | dead | missing)
                    [[ $state == unhealthy && $SECONDS -lt $deadline ]] || {
                        warn "$svc is $state"
                        return 1
                    }
                    ;;
            esac
            if ((SECONDS >= deadline)); then
                warn "timeout waiting for $svc (state: $state)"
                return 1
            fi
            sleep 3
        done
    done
}

# mongo_eval JS — run JS as root against the local replica set member, print result.
mongo_eval() {
    # shellcheck disable=SC2016 # expanded inside the container
    compose exec -T -e JS="$1" database sh -c \
        'mongosh --quiet "mongodb://root:${MONGO_INITDB_ROOT_PASSWORD}@localhost:27017/admin?directConnection=true" --eval "$JS"'
}

# mongo_dump_to FILE — consistent online dump (replica set + --oplog) to a gzip archive.
mongo_dump_to() {
    local out=$1
    mkdir -p "$(dirname "$out")"
    # shellcheck disable=SC2016 # expanded inside the container
    compose exec -T database sh -c \
        'mongodump --quiet --uri "mongodb://root:${MONGO_INITDB_ROOT_PASSWORD}@localhost:27017/?authSource=admin&directConnection=true" --archive --gzip --oplog' \
        >"$out.partial"
    mv "$out.partial" "$out"
}

# mongo_restore_from FILE — restore a mongo_dump_to archive (drops existing collections).
mongo_restore_from() {
    # shellcheck disable=SC2016 # expanded inside the container
    compose exec -T database sh -c \
        'mongorestore --quiet --uri "mongodb://root:${MONGO_INITDB_ROOT_PASSWORD}@localhost:27017/?authSource=admin&directConnection=true" --archive --gzip --drop --oplogReplay' \
        <"$1"
}
