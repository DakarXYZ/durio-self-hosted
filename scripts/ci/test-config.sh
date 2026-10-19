#!/usr/bin/env bash
# CI: generate a throw-away configuration for one address mode × storage combination in a temp
# copy of the repo, then check it:
#   generate_config.sh -> docker compose config -q -> check-ports.sh -> caddy validate
#   -> upload size / admins / hCaptcha in Revolt.toml -> re-run without --overwrite must fail -> --overwrite keeps secrets.env and overrides byte-for-byte
#   -> e2ee-enable.sh --no-restart edits only [features.e2ee], is idempotent, refuses --disable
#
# Usage: scripts/ci/test-config.sh <duckdns|duckdns-noddns|sslip|domain|ip|lan|behind-proxy> <minio|s3>
# Uses only test values (documentation IP range, fake tokens). Needs docker, jq, openssl.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_cmd docker jq openssl

MODE=${1:?mode}
STORAGE=${2:?storage}
CADDY_IMAGE=docker.io/library/caddy:2.10.2-alpine
TEST_IP=203.0.113.10

work=$(mktemp -d)
cleanup() {
    rm -rf "$work"
    docker rm -f "durio-caddy-validate-$$" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Tracked files only, as in a fresh clone.
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$work"

args=(--yes --acme-email admin@example.org --app-tag 0.16.0-fork.0)
export DUCKDNS_TOKEN=00000000-0000-0000-0000-000000000000
case $MODE in
    duckdns) args+=(--address-mode duckdns --address durio-test) ;;
    duckdns-noddns) args+=(--address-mode duckdns --address durio-test.duckdns.org --no-ddns); unset DUCKDNS_TOKEN ;;
    sslip) args+=(--address-mode sslip --server-ip "$TEST_IP") ;;
    domain) args+=(--address-mode domain --address chat.example.org) ;;
    ip) args+=(--address-mode ip --server-ip "$TEST_IP") ;;
    lan) args+=(--address-mode lan --dev --local-images) ;;
    behind-proxy) args+=(--address-mode domain --address chat.example.org --behind-proxy) ;;
    *) die "unknown mode $MODE" ;;
esac
case $STORAGE in
    minio) args+=(--storage minio) ;;
    s3)
        args+=(--storage s3 --s3-endpoint https://s3.eu-central-003.backblazeb2.com --s3-region eu-central-003
            --s3-bucket durio-test --s3-path-style true --skip-s3-check)
        export S3_ACCESS_KEY_ID=testkeyid S3_SECRET_ACCESS_KEY=testsecretkey
        ;;
    *) die "unknown storage $STORAGE" ;;
esac

info "[$MODE/$STORAGE] generate_config.sh ${args[*]}"
"$work/scripts/generate_config.sh" "${args[@]}" >/dev/null

info "[$MODE/$STORAGE] docker compose config -q"
"$work/scripts/compose" config -q
profiles=$(env_get COMPOSE_PROFILES "$work/.env")
services=$("$work/scripts/compose" config --services | LC_ALL=C sort | tr '\n' ' ')
echo "    profiles: ${profiles:-none}; services: $services"
case $STORAGE in
    minio) [[ $services == *" minio "* ]] || die "minio service missing with --storage minio" ;;
    s3) [[ $services != *" minio "* ]] || die "minio service active with --storage s3" ;;
esac
if [[ $MODE == duckdns ]]; then
    [[ $services == duckdns* || $services == *" duckdns "* ]] || die "duckdns updater missing"
else
    [[ $services != *duckdns* ]] || die "duckdns updater active in mode $MODE"
fi

info "[$MODE/$STORAGE] check-ports.sh"
"$work/scripts/check-ports.sh" >/dev/null

info "[$MODE/$STORAGE] caddy validate"
docker create --name "durio-caddy-validate-$$" \
    -e STOAT_DOMAIN="$(env_get STOAT_DOMAIN "$work/.env")" \
    -e CADDY_SITE="$(env_get CADDY_SITE "$work/.env")" \
    "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
docker cp "$work/Caddyfile" "durio-caddy-validate-$$:/etc/caddy/Caddyfile"
docker cp "$work/config/caddy/." "durio-caddy-validate-$$:/etc/caddy/durio/"
docker start -a "durio-caddy-validate-$$" >"$work/caddy.log" 2>&1 || {
    cat "$work/caddy.log" >&2
    die "caddy validate failed"
}

info "[$MODE/$STORAGE] Revolt.toml: upload size, admins, hCaptcha off"
toml_check() { # EXPECTED_BYTES EXPECTED_ADMINS_JSON
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$work/Revolt.toml" "$1" "$2" <<'EOF' || die "Revolt.toml: unexpected upload size, admins or captcha"
import json, sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
size, admins = int(sys.argv[2]), json.loads(sys.argv[3])
limits = c["features"]["limits"]
for group in ("new_user", "default"):
    assert limits[group]["file_upload_size_limit"]["attachments"] == size, group
assert limits["global"]["body_limit_size"] > size
assert c["api"]["admins"]["users"] == admins, c["api"]["admins"]
assert c["api"]["security"]["captcha"] == {"hcaptcha_key": "", "hcaptcha_sitekey": ""}
EOF
}
toml_check 100000000 '[]'
admin_id=01ARZ3NDEKTSV4RRFFQ69G5FAV
"$work/scripts/generate_config.sh" "${args[@]}" --overwrite --max-file-size 250 --admins "${admin_id,,}" >/dev/null
toml_check 250000000 "[\"$admin_id\"]"
[[ $(env_get ADMIN_USER_IDS "$work/.env") == "$admin_id" ]] || die "ADMIN_USER_IDS not kept in .env"
"$work/scripts/generate_config.sh" "${args[@]}" --overwrite >/dev/null
toml_check 250000000 "[\"$admin_id\"]"
"$work/scripts/generate_config.sh" "${args[@]}" --overwrite --max-file-size 100 --admins '' >/dev/null
toml_check 100000000 '[]'
if "$work/scripts/generate_config.sh" "${args[@]}" --overwrite --admins not-an-id >/dev/null 2>&1; then
    die "generator accepted an invalid admin id"
fi
cp "$work/Revolt.overrides.toml" "$work/overrides.captcha"
printf '\n[api.security.captcha]\nhcaptcha_key = "0x123"\n' >>"$work/Revolt.overrides.toml"
if "$work/scripts/generate_config.sh" "${args[@]}" --overwrite >/dev/null 2>&1; then
    die "generator accepted an hCaptcha key in Revolt.overrides.toml"
fi
cp "$work/overrides.captcha" "$work/Revolt.overrides.toml"

info "[$MODE/$STORAGE] re-run without --overwrite must refuse"
if "$work/scripts/generate_config.sh" "${args[@]}" >/dev/null 2>&1; then
    die "generator overwrote an existing configuration without --overwrite"
fi

info "[$MODE/$STORAGE] --overwrite keeps secrets.env and Revolt.overrides.toml"
cp "$work/secrets.env" "$work/secrets.before"
cp "$work/Revolt.overrides.toml" "$work/overrides.before"
"$work/scripts/generate_config.sh" "${args[@]}" --overwrite >/dev/null
cmp -s "$work/secrets.env" "$work/secrets.before" || die "--overwrite changed secrets.env"
cmp -s "$work/Revolt.overrides.toml" "$work/overrides.before" || die "--overwrite changed Revolt.overrides.toml"
"$work/scripts/compose" config -q

info "[$MODE/$STORAGE] e2ee-enable.sh --no-restart: one line changes, idempotent, no way back"
"$work/scripts/e2ee-enable.sh" --no-restart --yes >/dev/null 2>&1
sed 's/^enabled = false$/enabled = true/' "$work/overrides.before" | cmp -s - "$work/Revolt.overrides.toml" ||
    die "e2ee-enable.sh changed more than [features.e2ee] enabled"
cp "$work/Revolt.overrides.toml" "$work/overrides.enabled"
"$work/scripts/e2ee-enable.sh" --no-restart --yes >/dev/null 2>&1
cmp -s "$work/Revolt.overrides.toml" "$work/overrides.enabled" || die "e2ee-enable.sh is not idempotent"
if "$work/scripts/e2ee-enable.sh" --disable >/dev/null 2>&1; then
    die "e2ee-enable.sh --disable must refuse"
fi
"$work/scripts/e2ee-enable.sh" --default-for-new-dms --no-restart --yes >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
    python3 - "$work/Revolt.overrides.toml" <<'EOF' || die "Revolt.overrides.toml after e2ee-enable.sh is not the expected TOML"
import sys, tomllib
e2ee = tomllib.load(open(sys.argv[1], "rb"))["features"]["e2ee"]
assert e2ee == {"enabled": True, "default_for_new_dms": True}, e2ee
EOF
fi
cp "$work/Revolt.overrides.toml" "$work/overrides.before"
"$work/scripts/generate_config.sh" "${args[@]}" --overwrite >/dev/null
cmp -s "$work/Revolt.overrides.toml" "$work/overrides.before" || die "--overwrite changed the E2EE settings"
"$work/scripts/compose" config -q

echo "test-config: OK ($MODE/$STORAGE)"
