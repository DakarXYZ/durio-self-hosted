#!/usr/bin/env bash
# Generates the machine-specific configuration of a dur.io server:
#
#   .env                     non-secret settings (address, storage, profiles, image tags)  rewritten by --overwrite
#   secrets.env              REVOLT__... secrets, passwords, keys (0600)                   append-only, never rewritten
#   Revolt.toml              derived from address + storage only                           rewritten by --overwrite
#   Revolt.overrides.toml    manual policies (invite_only, e2ee, ...)                      created once, never touched
#   livekit.yml, stoat.json, config/caddy/{global,site}.caddy                              rewritten by --overwrite
#
# Run scripts/generate_config.sh --help for options.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat <<'EOF'
Usage: scripts/generate_config.sh [options]

Address (SH-20):
  --address-mode MODE     duckdns (default) | sslip | domain | ip | lan
  --address VALUE         duckdns: <name> or <name>.duckdns.org; domain: FQDN; lan: host name
                          (default durio.lan); sslip/ip: derived from --server-ip. Alias: --domain
  --server-ip IPV4        public IP (or env SERVER_IP); stored only in .env, never in git
  --no-ddns               duckdns mode without the IP updater container (static IP)
  --behind-proxy          Caddy serves plain :80 behind another TLS proxy (trusts private ranges)
  --dev                   required for --address-mode lan (self-signed TLS, development only)

Storage (SH-21):
  --storage minio|s3      minio (default): local MinIO; s3: external S3-compatible bucket
  --minio-data-path PATH  MinIO data directory on the host (default ./data/minio)
  --s3-endpoint URL --s3-region REGION --s3-bucket NAME [--s3-path-style true|false]
                          s3 keys are read from env S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY
  --skip-s3-check         do not verify bucket access with a throw-away mc container

Other:
  --name NAME             display name in /.well-known/stoat (default dur.io)
  --acme-email EMAIL      Let's Encrypt account email
  --video | --no-video    camera / screen sharing limits (default: video on, up to 1920x1080)
  --max-file-size MB      attachment size limit in MB (default 100); the upload body limit follows
  --admins ID[,ID...]     user ids of instance admins: they end sessions of any user from the
                          client (lost phone); an empty value removes all
  --fcm-json FILE         Firebase service account JSON -> REVOLT__PUSHD__FCM__* in secrets.env
  --app-tag TAG           image tag (default: current .env value or the release this repo targets)
  --web-tag TAG           browser client image tag, durio-web (default: current .env value or
                          the web release this repo targets)
  --image-registry PFX    image prefix (default ghcr.io/dakarxyz/); empty for locally built images
  --local-images          shorthand for --image-registry '' --app-tag local --web-tag local
  --overwrite             regenerate .env/Revolt.toml/... (backups *.<date>.bak); secrets and
                          overrides are never rewritten
  --confirm-address-change  allow --overwrite to change STOAT_DOMAIN (users re-add accounts!)
  --yes                   non-interactive, no questions
  -h, --help              this help

Secrets from env (never from arguments): DUCKDNS_TOKEN, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY.
EOF
}

# ---------------------------------------------------------------------------- arguments

ARG_MODE='' ARG_ADDRESS='' ARG_SERVER_IP='' ARG_NAME='' ARG_EMAIL='' ARG_STORAGE='' ARG_MINIO_PATH=''
ARG_S3_ENDPOINT='' ARG_S3_REGION='' ARG_S3_BUCKET='' ARG_S3_PATH_STYLE='' ARG_APP_TAG='' ARG_WEB_TAG='' ARG_VIDEO=''
ARG_BEHIND_PROXY='' ARG_DDNS='' ARG_FCM_JSON='' ARG_MAX_FILE_MB=''
ARG_ADMINS_SET=0 ARG_ADMINS=
ARG_IMAGE_REGISTRY_SET=0 ARG_IMAGE_REGISTRY=
DEV=0 OVERWRITE=0 CONFIRM_ADDRESS_CHANGE=0 YES=0 SKIP_S3_CHECK=0

need_value() {
    [[ $# -ge 2 && $2 != --* ]] || die "option $1 needs a value"
}

if [[ $# -eq 0 && ! -t 0 ]]; then
    usage >&2
    exit 2
fi
INTERACTIVE=0
[[ $# -eq 0 ]] && INTERACTIVE=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --address-mode) need_value "$@"; ARG_MODE=$2; shift ;;
        --address | --domain) need_value "$@"; ARG_ADDRESS=$2; shift ;;
        --server-ip) need_value "$@"; ARG_SERVER_IP=$2; shift ;;
        --name) need_value "$@"; ARG_NAME=$2; shift ;;
        --acme-email) need_value "$@"; ARG_EMAIL=$2; shift ;;
        --storage) need_value "$@"; ARG_STORAGE=$2; shift ;;
        --minio-data-path) need_value "$@"; ARG_MINIO_PATH=$2; shift ;;
        --s3-endpoint) need_value "$@"; ARG_S3_ENDPOINT=$2; shift ;;
        --s3-region) need_value "$@"; ARG_S3_REGION=$2; shift ;;
        --s3-bucket) need_value "$@"; ARG_S3_BUCKET=$2; shift ;;
        --s3-path-style) need_value "$@"; ARG_S3_PATH_STYLE=$2; shift ;;
        --skip-s3-check) SKIP_S3_CHECK=1 ;;
        --fcm-json) need_value "$@"; ARG_FCM_JSON=$2; shift ;;
        --app-tag) need_value "$@"; ARG_APP_TAG=$2; shift ;;
        --web-tag) need_value "$@"; ARG_WEB_TAG=$2; shift ;;
        --image-registry) [[ $# -ge 2 ]] || die "option $1 needs a value"; ARG_IMAGE_REGISTRY_SET=1; ARG_IMAGE_REGISTRY=$2; shift ;;
        --local-images) ARG_IMAGE_REGISTRY_SET=1; ARG_IMAGE_REGISTRY=; ARG_APP_TAG=local; ARG_WEB_TAG=local ;;
        --video) ARG_VIDEO=true ;;
        --no-video) ARG_VIDEO=false ;;
        --max-file-size) need_value "$@"; ARG_MAX_FILE_MB=$2; shift ;;
        --admins) [[ $# -ge 2 ]] || die "option $1 needs a value"; ARG_ADMINS_SET=1; ARG_ADMINS=$2; shift ;;
        --behind-proxy) ARG_BEHIND_PROXY=true ;;
        --no-behind-proxy) ARG_BEHIND_PROXY=false ;;
        --no-ddns) ARG_DDNS=false ;;
        --ddns) ARG_DDNS=true ;;
        --dev) DEV=1 ;;
        --overwrite) OVERWRITE=1 ;;
        --confirm-address-change) CONFIRM_ADDRESS_CHANGE=1 ;;
        --yes | -y) YES=1 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

require_cmd openssl jq awk

cd "$ROOT"

# ---------------------------------------------------------------------------- previous state

HAVE_ENV=0
[[ -f .env ]] && HAVE_ENV=1
if [[ -f Revolt.toml || $HAVE_ENV -eq 1 ]] && [[ $OVERWRITE -eq 0 ]]; then
    die "existing configuration found (.env / Revolt.toml). Re-run with --overwrite to regenerate it
       (secrets.env and Revolt.overrides.toml are kept as they are)."
fi
if [[ $OVERWRITE -eq 1 && -f Revolt.toml && ! -f secrets.env ]]; then
    die "--overwrite without secrets.env: restore secrets.env first, otherwise ALL stored files become unreadable"
fi

prev() { env_get "$1" .env; }

# Values: flag > previous .env > default.
MODE=${ARG_MODE:-$(prev ADDRESS_MODE)}
SERVER_IP=${ARG_SERVER_IP:-${SERVER_IP:-$(prev SERVER_IP)}}
SERVER_NAME=${ARG_NAME:-$(prev SERVER_NAME)}
ACME_EMAIL=${ARG_EMAIL:-$(prev ACME_EMAIL)}
STORAGE=${ARG_STORAGE:-$(prev FILES_STORAGE)}
MINIO_DATA_PATH=${ARG_MINIO_PATH:-$(prev MINIO_DATA_PATH)}
S3_ENDPOINT=${ARG_S3_ENDPOINT:-$(prev S3_ENDPOINT)}
S3_REGION=${ARG_S3_REGION:-$(prev S3_REGION)}
S3_BUCKET=${ARG_S3_BUCKET:-$(prev S3_BUCKET)}
S3_PATH_STYLE=${ARG_S3_PATH_STYLE:-$(prev S3_PATH_STYLE)}
VIDEO_ENABLED=${ARG_VIDEO:-$(prev VIDEO_ENABLED)}
MAX_FILE_SIZE_MB=${ARG_MAX_FILE_MB:-$(prev MAX_FILE_SIZE_MB)}
if [[ $ARG_ADMINS_SET -eq 1 ]]; then
    ADMIN_USER_IDS=$ARG_ADMINS
else
    ADMIN_USER_IDS=$(prev ADMIN_USER_IDS)
fi
BEHIND_PROXY=${ARG_BEHIND_PROXY:-$(prev BEHIND_PROXY)}
DDNS_ENABLED=${ARG_DDNS:-$(prev DDNS_ENABLED)}
APP_TAG=${ARG_APP_TAG:-$(prev APP_TAG)}
WEB_TAG=${ARG_WEB_TAG:-$(prev WEB_TAG)}
PREV_DOMAIN=$(prev STOAT_DOMAIN)
PREV_STORAGE=$(prev FILES_STORAGE)
if [[ $ARG_IMAGE_REGISTRY_SET -eq 1 ]]; then
    IMAGE_REGISTRY=$ARG_IMAGE_REGISTRY
elif env_has IMAGE_REGISTRY .env; then
    IMAGE_REGISTRY=$(prev IMAGE_REGISTRY)
else
    IMAGE_REGISTRY=$DEFAULT_IMAGE_REGISTRY
fi
ADDRESS=$ARG_ADDRESS
if [[ -z $ADDRESS && -z $ARG_MODE ]]; then
    ADDRESS=$PREV_DOMAIN
fi

ask() { # ask VAR "question" default
    local reply
    read -rp "$2 [$3]: " reply
    printf -v "$1" '%s' "${reply:-$3}"
}

if [[ $INTERACTIVE -eq 1 ]]; then
    ask MODE "Address mode (duckdns|sslip|domain|ip|lan)" "${MODE:-duckdns}"
    case $MODE in
        duckdns) ask ADDRESS "DuckDNS subdomain (<name> or <name>.duckdns.org)" "$ADDRESS" ;;
        domain) ask ADDRESS "Domain name" "$ADDRESS" ;;
        lan) ask ADDRESS "Local host name" "${ADDRESS:-durio.lan}"; DEV=1 ;;
        sslip | ip) ask SERVER_IP "Public IPv4 of this server" "$SERVER_IP" ;;
    esac
    ask STORAGE "File storage (minio|s3)" "${STORAGE:-minio}"
    [[ $MODE == lan ]] || ask ACME_EMAIL "Email for Let's Encrypt" "$ACME_EMAIL"
fi

MODE=${MODE:-duckdns}
STORAGE=${STORAGE:-minio}
SERVER_NAME=${SERVER_NAME:-dur.io}
MINIO_DATA_PATH=${MINIO_DATA_PATH:-./data/minio}
VIDEO_ENABLED=${VIDEO_ENABLED:-true}
MAX_FILE_SIZE_MB=${MAX_FILE_SIZE_MB:-100}
BEHIND_PROXY=${BEHIND_PROXY:-false}
DDNS_ENABLED=${DDNS_ENABLED:-true}
APP_TAG=${APP_TAG:-$DEFAULT_APP_TAG}
WEB_TAG=${WEB_TAG:-$DEFAULT_WEB_TAG}

is_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
is_hostname() {
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

[[ -z $SERVER_IP ]] || is_ipv4 "$SERVER_IP" || die "--server-ip: not an IPv4 address: $SERVER_IP"
[[ $SERVER_NAME != *[\'\"$'\n'\\]* ]] || die "--name must not contain quotes, backslashes or newlines"
[[ -z $ACME_EMAIL || $ACME_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || die "--acme-email: invalid address"
[[ $VIDEO_ENABLED == true || $VIDEO_ENABLED == false ]] || die "VIDEO_ENABLED must be true|false"
[[ $MAX_FILE_SIZE_MB =~ ^[1-9][0-9]{0,3}$ ]] || die "--max-file-size: whole number of MB, 1..9999"
check_tag "$WEB_TAG"

# Admin ids: comma separated user ids (ULID), stored upper case without spaces.
ADMIN_USER_IDS=${ADMIN_USER_IDS//[[:space:]]/}
ADMIN_USER_IDS=${ADMIN_USER_IDS^^}
ADMINS_TOML=
if [[ -n $ADMIN_USER_IDS ]]; then
    IFS=, read -ra admin_ids <<<"$ADMIN_USER_IDS"
    for id in "${admin_ids[@]}"; do
        [[ $id =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || die "--admins: not a user id: '$id'"
        ADMINS_TOML+="${ADMINS_TOML:+, }\"$id\""
    done
fi

# ---------------------------------------------------------------------------- address

DUCKDNS_SUBDOMAIN=
LIVEKIT_NODE_IP=
LIVEKIT_EXTERNAL_IP=true
ADDRESS=${ADDRESS,,}
case $MODE in
    duckdns)
        ADDRESS=${ADDRESS%.duckdns.org}
        [[ -n $ADDRESS ]] || die "duckdns mode needs --address <name> (e.g. --address myserver)"
        [[ $ADDRESS =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid DuckDNS subdomain: $ADDRESS"
        DUCKDNS_SUBDOMAIN=$ADDRESS
        STOAT_DOMAIN="$ADDRESS.duckdns.org"
        [[ $DDNS_ENABLED == true || $DDNS_ENABLED == false ]] || die "DDNS_ENABLED must be true|false"
        ;;
    sslip)
        if [[ -z $ADDRESS || $ADDRESS == "$PREV_DOMAIN" ]]; then
            [[ -n $SERVER_IP ]] || die "sslip mode needs --server-ip (or SERVER_IP in env/.env)"
            STOAT_DOMAIN="${SERVER_IP//./-}.sslip.io"
        else
            [[ $ADDRESS == *.sslip.io ]] || die "sslip mode: --address must end with .sslip.io"
            STOAT_DOMAIN=$ADDRESS
        fi
        LIVEKIT_NODE_IP=$SERVER_IP
        ;;
    domain)
        [[ -n $ADDRESS ]] || die "domain mode needs --address <fqdn>"
        if ! is_hostname "$ADDRESS" || [[ $ADDRESS != *.* ]]; then
            die "invalid domain: $ADDRESS"
        fi
        STOAT_DOMAIN=$ADDRESS
        ;;
    ip)
        if [[ -z $SERVER_IP ]] && is_ipv4 "$ADDRESS"; then SERVER_IP=$ADDRESS; fi
        [[ -n $SERVER_IP ]] || die "ip mode needs --server-ip (or SERVER_IP in env/.env)"
        STOAT_DOMAIN=$SERVER_IP
        LIVEKIT_NODE_IP=$SERVER_IP
        warn "ip mode: Let's Encrypt IP certificates (shortlived profile) are NOT verified with our Caddy yet"
        ;;
    lan)
        [[ $DEV -eq 1 || $PREV_DOMAIN != "" && $(prev ADDRESS_MODE) == lan ]] ||
            die "lan mode is for development only (self-signed TLS); pass --dev to confirm"
        ADDRESS=${ADDRESS:-durio.lan}
        is_hostname "$ADDRESS" || is_ipv4 "$ADDRESS" || die "invalid lan address: $ADDRESS"
        STOAT_DOMAIN=$ADDRESS
        if is_ipv4 "$ADDRESS" && [[ -z $SERVER_IP ]]; then SERVER_IP=$ADDRESS; fi
        LIVEKIT_NODE_IP=$SERVER_IP
        LIVEKIT_EXTERNAL_IP=false
        [[ -n $SERVER_IP ]] || warn "lan mode without --server-ip: voice/video will not reach other devices"
        ;;
    *) die "unknown --address-mode: $MODE (duckdns|sslip|domain|ip|lan)" ;;
esac
[[ $MODE == duckdns ]] || DDNS_ENABLED=false

if [[ -n $PREV_DOMAIN && $PREV_DOMAIN != "$STOAT_DOMAIN" && $CONFIRM_ADDRESS_CHANGE -eq 0 ]]; then
    die "the server address changes from $PREV_DOMAIN to $STOAT_DOMAIN.
       All users will have to add their account again. Pass --confirm-address-change if this is intended."
fi

if [[ $BEHIND_PROXY == true ]]; then
    CADDY_SITE=":80"
else
    CADDY_SITE=$STOAT_DOMAIN
fi
CADDY_NETWORK_ALIAS=caddy
is_ipv4 "$STOAT_DOMAIN" || CADDY_NETWORK_ALIAS=$STOAT_DOMAIN

if [[ $MODE != lan && $BEHIND_PROXY != true && -z $ACME_EMAIL ]]; then
    warn "no --acme-email: Let's Encrypt will not be able to warn about expiring certificates"
fi

# ---------------------------------------------------------------------------- storage

case $STORAGE in
    minio)
        S3_ENDPOINT="http://minio:9000"
        S3_REGION=minio
        S3_BUCKET=revolt-uploads
        S3_PATH_STYLE=false
        ;;
    s3)
        [[ $S3_ENDPOINT == http://* || $S3_ENDPOINT == https://* ]] ||
            die "--storage s3 needs --s3-endpoint https://..."
        [[ $S3_ENDPOINT != "http://minio:9000" ]] || die "--s3-endpoint must be the external provider"
        [[ -n $S3_BUCKET && $S3_BUCKET != revolt-uploads || -n $ARG_S3_BUCKET ]] ||
            die "--storage s3 needs --s3-bucket"
        S3_REGION=${S3_REGION:-us-east-1}
        [[ $S3_REGION != minio ]] || S3_REGION=us-east-1
        S3_PATH_STYLE=${S3_PATH_STYLE:-true}
        [[ $S3_PATH_STYLE == true || $S3_PATH_STYLE == false ]] || die "--s3-path-style must be true|false"
        ;;
    *) die "unknown --storage: $STORAGE (minio|s3)" ;;
esac
STORAGE_CHANGED=0
[[ -n $PREV_STORAGE && $PREV_STORAGE != "$STORAGE" ]] && STORAGE_CHANGED=1

if [[ $STORAGE == minio && $MINIO_DATA_PATH == /* && ! -d $MINIO_DATA_PATH ]]; then
    warn "MINIO_DATA_PATH $MINIO_DATA_PATH does not exist yet: mount/create it before starting the stack"
fi

# ---------------------------------------------------------------------------- secrets.env

DATE=$(date -u +%Y%m%dT%H%M%SZ)
NEW_SECRETS=()
SECRETS_BACKED_UP=0
FRESH_INSTALL=0

if [[ ! -f secrets.env ]]; then
    FRESH_INSTALL=1
    (
        umask 077
        cat >secrets.env <<'EOF'
# dur.io secrets. Managed by scripts/generate_config.sh: new keys are appended, existing ones are
# never changed. Keep an encrypted copy OUTSIDE the server (age -r <key> secrets.env > secrets.env.age):
# without REVOLT__FILES__ENCRYPTION_KEY every stored file is unreadable.
EOF
    )
fi
chmod 600 secrets.env

secret_add() { # KEY VALUE — append if missing, value single-quoted
    env_has "$1" secrets.env && return 0
    printf "%s='%s'\n" "$1" "$2" >>secrets.env
    NEW_SECRETS+=("$1")
}

secret_replace() { # KEY VALUE — only for storage switches; backs secrets.env up once
    if [[ $SECRETS_BACKED_UP -eq 0 ]]; then
        (umask 077 && cp -p secrets.env "secrets.env.$DATE.bak")
        SECRETS_BACKED_UP=1
    fi
    local tmp
    tmp=$(mktemp)
    grep -vE "^$1=" secrets.env >"$tmp" || true
    printf "%s='%s'\n" "$1" "$2" >>"$tmp"
    cat "$tmp" >secrets.env
    rm -f "$tmp"
    NEW_SECRETS+=("$1 (replaced)")
}

rand_hex() { openssl rand -hex "$1"; }

if ! env_has REVOLT__FILES__ENCRYPTION_KEY secrets.env && [[ -f Revolt.toml || -d data/db ]]; then
    warn "existing installation without REVOLT__FILES__ENCRYPTION_KEY in secrets.env: a NEW key is"
    warn "generated and files uploaded before cannot be decrypted. Abort now (Ctrl+C) if that is wrong."
    [[ $YES -eq 1 ]] || { read -rp "Continue? [y/N]: " reply; [[ $reply == [yY] ]] || exit 1; }
fi

secret_add REVOLT__FILES__ENCRYPTION_KEY "$(openssl rand -base64 32)"

if ! env_has REVOLT__PUSHD__VAPID__PRIVATE_KEY secrets.env; then
    env_has REVOLT__PUSHD__VAPID__PUBLIC_KEY secrets.env &&
        die "secrets.env has a VAPID public key without the private key"
    vapid_tmp=$(mktemp)
    openssl ecparam -name prime256v1 -genkey -noout -out "$vapid_tmp"
    vapid_private=$(openssl base64 -A -in "$vapid_tmp" | tr -d '=')
    vapid_public=$(openssl ec -in "$vapid_tmp" -outform DER 2>/dev/null | tail -c 65 | openssl base64 -A | tr '/+' '_-' | tr -d '=')
    rm -f "$vapid_tmp"
    secret_add REVOLT__PUSHD__VAPID__PRIVATE_KEY "$vapid_private"
    secret_add REVOLT__PUSHD__VAPID__PUBLIC_KEY "$vapid_public"
fi

if ! env_has REVOLT__API__LIVEKIT__NODES__WORLDWIDE__KEY secrets.env; then
    env_has REVOLT__API__LIVEKIT__NODES__WORLDWIDE__SECRET secrets.env &&
        die "secrets.env has a LiveKit secret without the key"
    secret_add REVOLT__API__LIVEKIT__NODES__WORLDWIDE__KEY "$(rand_hex 6)"
fi
secret_add REVOLT__API__LIVEKIT__NODES__WORLDWIDE__SECRET "$(rand_hex 24)"

rabbit_was_set=0
env_has REVOLT__RABBIT__PASSWORD secrets.env && rabbit_was_set=1
secret_add REVOLT__RABBIT__USERNAME "durio"
secret_add REVOLT__RABBIT__PASSWORD "$(rand_hex 24)"
if [[ $rabbit_was_set -eq 0 && -d data/rabbit && -n "$(ls -A data/rabbit 2>/dev/null)" ]]; then
    warn "data/rabbit is already initialised: the new RabbitMQ login is NOT applied automatically."
    warn "Rotate it with rabbitmqctl change_password, or reset data/rabbit."
fi

# MinIO root login is generated in every mode, so compose can require it (${VAR:?}).
secret_add MINIO_ROOT_USER "durio-$(rand_hex 4)"
secret_add MINIO_ROOT_PASSWORD "$(rand_hex 24)"

# Mongo (SH-15): root for admin/backups, `revolt` for the backend, keyFile for the replica set.
secret_add MONGO_ROOT_PASSWORD "$(rand_hex 24)"
secret_add MONGO_REVOLT_PASSWORD "$(rand_hex 24)"
secret_add MONGO_KEYFILE "$(rand_hex 256)"
if ! env_has REVOLT__DATABASE__MONGODB secrets.env; then
    secret_add REVOLT__DATABASE__MONGODB \
        "mongodb://revolt:$(env_get MONGO_REVOLT_PASSWORD secrets.env)@database:27017/revolt?authSource=admin&replicaSet=rs0"
fi
secret_add REVOLT__DATABASE__REDIS "redis://redis/"

# Files: MinIO service account for autumn, or the external provider's keys.
if [[ $STORAGE == minio ]]; then
    if [[ $STORAGE_CHANGED -eq 1 ]]; then
        secret_replace REVOLT__FILES__S3__ACCESS_KEY_ID "autumn$(rand_hex 7)"
        secret_replace REVOLT__FILES__S3__SECRET_ACCESS_KEY "$(rand_hex 20)"
    else
        secret_add REVOLT__FILES__S3__ACCESS_KEY_ID "autumn$(rand_hex 7)"
        secret_add REVOLT__FILES__S3__SECRET_ACCESS_KEY "$(rand_hex 20)"
    fi
else
    if [[ -n ${S3_ACCESS_KEY_ID:-} || -n ${S3_SECRET_ACCESS_KEY:-} ]]; then
        [[ -n ${S3_ACCESS_KEY_ID:-} && -n ${S3_SECRET_ACCESS_KEY:-} ]] ||
            die "set both S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY"
        [[ $S3_ACCESS_KEY_ID$S3_SECRET_ACCESS_KEY != *[\'$'\n']* ]] || die "S3 keys must not contain quotes"
        if [[ $STORAGE_CHANGED -eq 1 ]] ||
            { env_has REVOLT__FILES__S3__ACCESS_KEY_ID secrets.env &&
                [[ $(env_get REVOLT__FILES__S3__ACCESS_KEY_ID secrets.env) != "$S3_ACCESS_KEY_ID" ]]; }; then
            secret_replace REVOLT__FILES__S3__ACCESS_KEY_ID "$S3_ACCESS_KEY_ID"
            secret_replace REVOLT__FILES__S3__SECRET_ACCESS_KEY "$S3_SECRET_ACCESS_KEY"
        else
            secret_add REVOLT__FILES__S3__ACCESS_KEY_ID "$S3_ACCESS_KEY_ID"
            secret_add REVOLT__FILES__S3__SECRET_ACCESS_KEY "$S3_SECRET_ACCESS_KEY"
        fi
    elif [[ $STORAGE_CHANGED -eq 1 ]] || ! env_has REVOLT__FILES__S3__ACCESS_KEY_ID secrets.env; then
        die "--storage s3 needs the bucket keys in env: S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY"
    fi
fi

# DuckDNS token: only needed when the updater container runs.
if [[ -n ${DUCKDNS_TOKEN:-} ]]; then
    [[ $DUCKDNS_TOKEN =~ ^[A-Za-z0-9-]+$ ]] || die "DUCKDNS_TOKEN has unexpected characters"
    secret_add DUCKDNS_TOKEN "$DUCKDNS_TOKEN"
fi
if [[ $MODE == duckdns && $DDNS_ENABLED == true ]] && ! env_has DUCKDNS_TOKEN secrets.env; then
    die "duckdns mode starts the IP updater: export DUCKDNS_TOKEN=... (or pass --no-ddns for a static IP)"
fi

# FCM service account (SH-08): field names 1:1 with the JSON, `type` -> key_type.
if [[ -n $ARG_FCM_JSON ]]; then
    [[ -f $ARG_FCM_JSON ]] || die "--fcm-json: file not found: $ARG_FCM_JSON"
    if env_has REVOLT__PUSHD__FCM__PRIVATE_KEY secrets.env; then
        warn "FCM key already in secrets.env — not changed (edit secrets.env by hand to rotate it)"
    else
        for field in type project_id private_key_id client_email client_id auth_uri token_uri \
            auth_provider_x509_cert_url client_x509_cert_url; do
            value=$(jq -er --arg f "$field" '.[$f]' "$ARG_FCM_JSON") || die "--fcm-json: field $field missing"
            key=REVOLT__PUSHD__FCM__$(printf '%s' "$field" | tr '[:lower:]' '[:upper:]')
            [[ $field == type ]] && key=REVOLT__PUSHD__FCM__KEY_TYPE
            secret_add "$key" "$value"
        done
        # Multi-line key: double quotes + \n (compose expands escapes only in double quotes).
        pk=$(jq -r '.private_key' "$ARG_FCM_JSON" | awk 'BEGIN { ORS = "\\n" } { print }')
        printf '%s="%s"\n' REVOLT__PUSHD__FCM__PRIVATE_KEY "$pk" >>secrets.env
        NEW_SECRETS+=(REVOLT__PUSHD__FCM__PRIVATE_KEY)
    fi
fi

check_no_default_secrets

# hCaptcha must stay off (desktop client CSP): refuse a key added behind the generator's back.
if [[ -n $(env_get REVOLT__API__SECURITY__CAPTCHA__HCAPTCHA_KEY secrets.env) ]] ||
    { [[ -f Revolt.overrides.toml ]] &&
        grep -Eq '^[[:space:]]*hcaptcha_key[[:space:]]*=[[:space:]]*"[^"]' Revolt.overrides.toml; }; then
    die "hCaptcha key in secrets.env or Revolt.overrides.toml: remove it, the desktop client cannot show hCaptcha"
fi

# External bucket must be reachable before we point autumn at it.
if [[ $STORAGE == s3 && $SKIP_S3_CHECK -eq 0 ]]; then
    require_cmd docker
    info "checking access to $S3_ENDPOINT bucket $S3_BUCKET ..."
    path_flag=off
    [[ $S3_PATH_STYLE == true ]] && path_flag=on
    # shellcheck disable=SC2016 # expanded inside the container
    AK=$(env_get REVOLT__FILES__S3__ACCESS_KEY_ID secrets.env) \
        SK=$(env_get REVOLT__FILES__S3__SECRET_ACCESS_KEY secrets.env) \
        docker run --rm -e AK -e SK -e EP="$S3_ENDPOINT" -e B="$S3_BUCKET" -e PS="$path_flag" \
        --entrypoint /bin/sh docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z -c \
        'mc alias set target "$EP" "$AK" "$SK" --path "$PS" >/dev/null && mc ls target/"$B" >/dev/null' ||
        die "cannot list bucket $S3_BUCKET at $S3_ENDPOINT with the given keys (or pass --skip-s3-check)"
fi

# ---------------------------------------------------------------------------- generated files

backup_file() {
    if [[ -e $1 ]]; then
        cp -p "$1" "$1.$DATE.bak"
    fi
}
if [[ $OVERWRITE -eq 1 ]]; then
    for f in .env Revolt.toml livekit.yml stoat.json config/caddy/global.caddy config/caddy/site.caddy; do
        backup_file "$f"
    done
fi

PROFILES=()
[[ $STORAGE == minio ]] && PROFILES+=(minio)
[[ $MODE == duckdns && $DDNS_ENABLED == true ]] && PROFILES+=(duckdns)
COMPOSE_PROFILES=$(
    IFS=,
    printf '%s' "${PROFILES[*]}"
)

# .env — keys we manage, then any other keys from the previous .env (BACKUP_*, digests, ...).
new_env=$(mktemp)
{
    echo "# Generated by scripts/generate_config.sh — machine-specific, NOT in git."
    echo "# Re-run the generator with --overwrite instead of editing the managed keys."
    echo "ADDRESS_MODE=$MODE"
    echo "STOAT_DOMAIN=$STOAT_DOMAIN"
    echo "SERVER_IP=$SERVER_IP"
    echo "SERVER_NAME='$SERVER_NAME'"
    echo "ACME_EMAIL=$ACME_EMAIL"
    echo "CADDY_SITE=$CADDY_SITE"
    echo "CADDY_NETWORK_ALIAS=$CADDY_NETWORK_ALIAS"
    echo "BEHIND_PROXY=$BEHIND_PROXY"
    echo "DDNS_ENABLED=$DDNS_ENABLED"
    echo "DUCKDNS_SUBDOMAIN=$DUCKDNS_SUBDOMAIN"
    echo "LIVEKIT_NODE_IP=$LIVEKIT_NODE_IP"
    echo "VIDEO_ENABLED=$VIDEO_ENABLED"
    echo "MAX_FILE_SIZE_MB=$MAX_FILE_SIZE_MB"
    echo "ADMIN_USER_IDS=$ADMIN_USER_IDS"
    echo "FILES_STORAGE=$STORAGE"
    echo "MINIO_DATA_PATH=$MINIO_DATA_PATH"
    echo "S3_ENDPOINT=$S3_ENDPOINT"
    echo "S3_REGION=$S3_REGION"
    echo "S3_BUCKET=$S3_BUCKET"
    echo "S3_PATH_STYLE=$S3_PATH_STYLE"
    echo "COMPOSE_PROFILES=$COMPOSE_PROFILES"
    echo "IMAGE_REGISTRY=$IMAGE_REGISTRY"
    echo "APP_TAG=$APP_TAG"
    echo "WEB_TAG=$WEB_TAG"
    if [[ -f .env ]]; then
        grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | while IFS= read -r line; do
            k=${line%%=*}
            case $k in
                ADDRESS_MODE | STOAT_DOMAIN | SERVER_IP | SERVER_NAME | ACME_EMAIL | CADDY_SITE | \
                    CADDY_NETWORK_ALIAS | BEHIND_PROXY | DDNS_ENABLED | DUCKDNS_SUBDOMAIN | LIVEKIT_NODE_IP | \
                    VIDEO_ENABLED | MAX_FILE_SIZE_MB | ADMIN_USER_IDS | FILES_STORAGE | MINIO_DATA_PATH | S3_ENDPOINT | S3_REGION | S3_BUCKET | \
                    S3_PATH_STYLE | COMPOSE_PROFILES | IMAGE_REGISTRY | APP_TAG | WEB_TAG) ;;
                *) printf '%s\n' "$line" ;;
            esac
        done
    fi
} >"$new_env"
env_has BACKUP_ENABLED "$new_env" || echo "BACKUP_ENABLED=false" >>"$new_env"
cat "$new_env" >.env
rm -f "$new_env"
chmod 600 .env

# Revolt.toml — only what derives from address and storage. No secrets (the file is 0644).
{
    cat <<EOF
# Generated by scripts/generate_config.sh from .env — do not edit, --overwrite rewrites it.
# Manual settings: Revolt.overrides.toml. Secrets: secrets.env (REVOLT__... variables).
# production = true is never used: it brands e-mails as Stoat and enables Discover routes.
production = false

[hosts]
app = "https://$STOAT_DOMAIN"
api = "https://$STOAT_DOMAIN/api"
events = "wss://$STOAT_DOMAIN/ws"
autumn = "https://$STOAT_DOMAIN/autumn"
january = "https://$STOAT_DOMAIN/january"

[hosts.livekit]
worldwide = "wss://$STOAT_DOMAIN/livekit"

[api.livekit.nodes.worldwide]
url = "http://livekit:7880"
lat = 0.0
lon = 0.0

[files.s3]
endpoint = "$S3_ENDPOINT"
path_style_buckets = $S3_PATH_STYLE
region = "$S3_REGION"
default_bucket = "$S3_BUCKET"

# Instance admins (ADMIN_USER_IDS in .env, --admins): they can end the sessions of any user
# from the client. Users with \`privileged\` set in the database are admins as well.
[api.admins]
users = [$ADMINS_TOML]

# hCaptcha stays OFF. Do not enable it: the desktop client's CSP blocks hCaptcha,
# so sign-up and login would fail there.
[api.security.captcha]
hcaptcha_key = ""
hcaptcha_sitekey = ""

# Uploads (MAX_FILE_SIZE_MB in .env, --max-file-size): attachments up to $MAX_FILE_SIZE_MB MB,
# the request body may carry 5 MB of multipart overhead on top.
[features.limits.global]
body_limit_size = $(((MAX_FILE_SIZE_MB + 5) * 1000000))
EOF
    if [[ $VIDEO_ENABLED == true ]]; then
        cat <<'EOF'

[features.limits.new_user]
video_resolution = [1920, 1080]
video_aspect_ratio = [0.3, 10]

[features.limits.default]
video_resolution = [1920, 1080]
video_aspect_ratio = [0.3, 10]
EOF
    fi
    cat <<EOF

[features.limits.new_user.file_upload_size_limit]
attachments = $((MAX_FILE_SIZE_MB * 1000000))

[features.limits.default.file_upload_size_limit]
attachments = $((MAX_FILE_SIZE_MB * 1000000))
EOF
} >Revolt.toml
chmod 644 Revolt.toml

# Revolt.overrides.toml — created once; must exist or docker would create a directory instead.
if [[ ! -e Revolt.overrides.toml ]]; then
    cat >Revolt.overrides.toml <<'EOF'
# Manual settings of this server. scripts/generate_config.sh never touches this file.
# No secrets here (the file is world-readable inside the containers) — use secrets.env.
# Changes apply only after restarting ALL backend services:
#   scripts/compose up -d --force-recreate api events autumn january crond pushd voice-ingress

[api.registration]
# Invite codes: db.account_invites (see README)
invite_only = true

[api.security]
# Caddy sets CF-Connecting-IP to the real client IP on every request (per-IP rate limits).
trust_cloudflare = true

[features.e2ee]
# Enable only when every service and client runs an E2EE-capable version: scripts/e2ee-enable.sh
# Never switch it off again in production: encrypted chats become read-only.
enabled = false
EOF
    chmod 644 Revolt.overrides.toml
elif [[ -d Revolt.overrides.toml ]]; then
    die "Revolt.overrides.toml is a directory (created by docker?) — remove it and re-run"
fi

# livekit.yml — no secrets: API keys reach LiveKit as LIVEKIT_KEYS from secrets.env.
cat >livekit.yml <<EOF
# Generated by scripts/generate_config.sh — do not edit, --overwrite rewrites it.
port: 7880
rtc:
  tcp_port: 7881
  # one multiplexed UDP port instead of a range: simpler firewall
  udp_port: 7882
  use_external_ip: $LIVEKIT_EXTERNAL_IP
redis:
  address: redis:6379
turn:
  enabled: false
logging:
  level: info
webhook:
  api_key: $(env_get REVOLT__API__LIVEKIT__NODES__WORLDWIDE__KEY secrets.env)
  urls:
    - http://voice-ingress:8500/worldwide
EOF
chmod 644 livekit.yml

# stoat.json — discovery document served at /.well-known/stoat.
jq -n --arg api "https://$STOAT_DOMAIN/api" --arg name "$SERVER_NAME" '{api: $api, name: $name}' >stoat.json
chmod 644 stoat.json

# Caddy snippets.
mkdir -p config/caddy
{
    echo "# Generated by scripts/generate_config.sh (global options)."
    [[ -n $ACME_EMAIL ]] && echo "email $ACME_EMAIL"
    if [[ $BEHIND_PROXY == true ]]; then
        echo "servers {"
        echo "	trusted_proxies static private_ranges"
        echo "}"
    fi
    [[ $MODE == lan ]] && echo "skip_install_trust"
    true
} >config/caddy/global.caddy
{
    echo "# Generated by scripts/generate_config.sh (site: TLS and HSTS for mode $MODE)."
    if [[ $BEHIND_PROXY == true ]]; then
        echo "# behind another proxy: TLS and HSTS are its job"
    else
        case $MODE in
            lan) echo "tls internal" ;;
            ip)
                echo "tls {"
                echo "	issuer acme {"
                echo "		profile shortlived"
                echo "	}"
                echo "}"
                ;;
            *)
                # no preload / includeSubDomains: the zone (duckdns.org, sslip.io) is not ours
                echo "header Strict-Transport-Security \"max-age=31536000\""
                ;;
        esac
    fi
} >config/caddy/site.caddy
chmod 644 config/caddy/global.caddy config/caddy/site.caddy

mkdir -p data
# Fresh install: nothing to migrate — mark existing migrations as applied for upgrade.sh.
if [[ $FRESH_INSTALL -eq 1 && ! -f data/.applied-migrations ]]; then
    : >data/.applied-migrations
    for m in migrations/[0-9]*.sh; do
        [[ -e $m ]] && basename "$m" >>data/.applied-migrations
    done
fi

# ---------------------------------------------------------------------------- summary

echo
info "dur.io configuration written to $ROOT"
echo "    address:  https://$STOAT_DOMAIN  (mode $MODE$([[ $BEHIND_PROXY == true ]] && echo ', behind proxy'))"
echo "    storage:  $STORAGE$([[ $STORAGE == minio ]] && echo " ($MINIO_DATA_PATH)" || echo " ($S3_ENDPOINT, bucket $S3_BUCKET)")"
echo "    profiles: ${COMPOSE_PROFILES:-(none)}"
echo "    images:   ${IMAGE_REGISTRY}durio-*:$APP_TAG"
echo "    web:      ${IMAGE_REGISTRY}durio-web:$WEB_TAG  (https://$STOAT_DOMAIN/web/app/)"
echo "    files:    attachments up to $MAX_FILE_SIZE_MB MB"
echo "    admins:   ${ADMIN_USER_IDS:-(none)}"
if [[ ${#NEW_SECRETS[@]} -gt 0 ]]; then
    echo "    new in secrets.env: ${NEW_SECRETS[*]}"
fi
[[ $SECRETS_BACKED_UP -eq 1 ]] && echo "    previous secrets.env saved as secrets.env.$DATE.bak"
echo
warn "BACKUPS ARE DISABLED: losing this disk loses all data. Enable later: scripts/backup-enable.sh"
if [[ ${#NEW_SECRETS[@]} -gt 0 ]]; then
    warn "secrets.env changed: store an encrypted copy OUTSIDE this server now, e.g."
    warn "  age -r <your-age-public-key> secrets.env > secrets.env.age   (then move it off the server)"
fi
[[ $MODE == lan ]] && warn "lan mode: install data/caddy-data/caddy/pki/authorities/local/root.crt on test devices"
echo
echo "Next: scripts/compose pull && scripts/compose up -d && scripts/compose ps"
