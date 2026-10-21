#!/usr/bin/env bash
# External smoke test of a running server (SH-05/SH-07).
#
#   scripts/smoke.sh [--domain D] [--expect-version 0.16.0+fork.N] [--local]
#
# --local   resolve the domain to 127.0.0.1 (server itself, lan mode, DNS not ready yet)
# In lan mode Caddy's local CA (data/caddy-data/...) is trusted automatically.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd curl jq

DOMAIN=$(env_get STOAT_DOMAIN "$ENV_FILE")
EXPECT=
LOCAL=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN=$2; shift ;;
        --expect-version) EXPECT=$2; shift ;;
        --local) LOCAL=1 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done
[[ -n $DOMAIN ]] || die "no domain (.env STOAT_DOMAIN or --domain)"

public_curl_opts "$DOMAIN" "$LOCAL"
curl_opts=("${CURL_OPTS[@]}")
base="https://$DOMAIN"
failed=0
tmp_body=$(mktemp)
trap 'rm -f "$tmp_body"' EXIT

check_code() { # PATH EXPECTED_CODE [extra curl args...]
    local path=$1 want=$2 got
    shift 2
    got=$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' "$@" "$base$path" || true)
    if [[ $got == "$want" ]]; then
        echo "ok   $path -> $got"
    else
        echo "FAIL $path -> $got (want $want)"
        failed=1
    fi
}

check_redirect() { # PATH EXPECTED_CODE EXPECTED_LOCATION
    local path=$1 want=$2 location=$3 got
    got=$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "$base$path" || true)
    if [[ $got == "$want $base$location" ]]; then
        echo "ok   $path -> $want $location"
    else
        echo "FAIL $path -> $got (want $want $base$location)"
        failed=1
    fi
}

check_redirect / 302 /web/info
check_code /web/info 200
check_redirect /web/app 308 /web/app/
check_code /e2ee.html 200
check_code /invite/smoke 200
check_code /ingress 404
check_code /ingress/worldwide 404
check_code /autumn/ 200
check_code /january/ 200

# Browser client (web service behind Caddy): the HTML shell, and Caddy's CSP on it.
headers=$(curl "${curl_opts[@]}" -D - -o "$tmp_body" "$base/web/app/" || true)
code=$(printf '%s\n' "$headers" | awk 'NR == 1 { print $2 }')
if [[ $code != 200 ]]; then
    echo "FAIL /web/app/ -> ${code:-000} (want 200; scripts/compose ps web)"
    failed=1
elif ! grep -qi '<html' "$tmp_body"; then
    echo "FAIL /web/app/ -> 200 but no HTML"
    failed=1
elif ! grep -qi "^content-security-policy:.*'wasm-unsafe-eval'" <<<"$headers"; then
    echo "FAIL /web/app/ -> no Content-Security-Policy from Caddy"
    failed=1
else
    echo "ok   /web/app/ -> 200 html"
fi

discovery=$(curl "${curl_opts[@]}" "$base/.well-known/stoat" || true)
if jq -e --arg api "$base/api" '.api == $api' <<<"$discovery" >/dev/null 2>&1; then
    echo "ok   /.well-known/stoat -> api $base/api"
else
    echo "FAIL /.well-known/stoat -> $discovery"
    failed=1
fi

root=$(curl "${curl_opts[@]}" "$base/api/" || true)
version=$(jq -r '.revolt // empty' <<<"$root" 2>/dev/null || true)
if [[ -z $version ]]; then
    echo "FAIL /api/ -> no \"revolt\" version"
    failed=1
elif [[ -n $EXPECT && $version != "$EXPECT" ]]; then
    echo "FAIL /api/ -> revolt $version (want $EXPECT)"
    failed=1
else
    echo "ok   /api/ -> revolt $version"
fi

# E2EE (SH-13): once switched on with scripts/e2ee-enable.sh it must stay on (Q59).
e2ee=$(jq -r '.features.e2ee | if type == "object" and has("enabled") then .enabled | tostring else "absent" end' \
    <<<"$root" 2>/dev/null || echo absent)
if [[ -f $E2EE_MARKER && $e2ee != true ]]; then
    echo "FAIL /api/ -> e2ee $e2ee, but E2EE was enabled here ($E2EE_MARKER): never disable it, run scripts/e2ee-enable.sh"
    failed=1
else
    echo "ok   /api/ -> e2ee enabled: $e2ee"
fi

# A 3 MiB body must reach the API, i.e. Caddy must not cut it. Rocket itself rejects JSON bodies
# over 1 MiB with 413, so a 413 is fine as long as it came from the API (it sets x-ratelimit-*).
headers=$(head -c 3145728 /dev/zero | curl "${curl_opts[@]}" -o /dev/null -D - \
    -X POST -H 'Content-Type: application/json' --data-binary @- "$base/api/auth/session/login" || true)
code=$(printf '%s\n' "$headers" | awk 'NR == 1 { print $2 }')
if [[ -z $code ]] || ! grep -qi '^x-ratelimit-limit:' <<<"$headers"; then
    echo "FAIL POST 3 MiB /api -> ${code:-000} (did not reach the API)"
    failed=1
else
    echo "ok   POST 3 MiB /api -> $code from the API"
fi

# WebSocket endpoint: upgrade must reach events (101/4xx from bonfire), not 404/502 from Caddy.
code=$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: ZHVyaW8tc21va2UtdGVzdA==' "$base/ws" || true)
if [[ $code == 404 || $code == 502 || $code == 000 ]]; then
    echo "FAIL /ws -> $code"
    failed=1
else
    echo "ok   /ws -> $code"
fi

# Certificate lifetime (not for lan): > 3 days, > 1 day in ip mode.
if [[ $(env_get ADDRESS_MODE "$ENV_FILE") != lan ]] && command -v openssl >/dev/null 2>&1; then
    min=259200
    [[ $(env_get ADDRESS_MODE "$ENV_FILE") == ip ]] && min=86400
    connect=$DOMAIN:443
    [[ $LOCAL -eq 1 ]] && connect=127.0.0.1:443
    if echo | openssl s_client -connect "$connect" -servername "$DOMAIN" 2>/dev/null |
        openssl x509 -noout -checkend "$min" >/dev/null; then
        echo "ok   certificate valid > $((min / 86400)) days"
    else
        echo "FAIL certificate expires within $((min / 86400)) days (or no TLS)"
        failed=1
    fi
fi

[[ $failed -eq 0 ]] || die "smoke test failed"
echo "smoke: OK"
