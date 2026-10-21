#!/usr/bin/env bash
# Upgrade only the browser client (durio-web, served at /web/app/), backend and database untouched:
#
#   scripts/web-upgrade.sh <tag> [--skip-smoke] [--yes]     e.g. 0.1.1
#
# WEB_TAG in .env (+ WEB_DIGEST in images.lock.env if the lock exists) -> pull web -> up web ->
# health -> caddy recreated only if it still runs an old Caddyfile -> smoke.sh.
# On failure WEB_TAG (and the lock) go back and the previous client is started again.
# Upgrading the backend as well: scripts/upgrade.sh <tag> --web-tag <tag>.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker jq
require_config

NEW_TAG='' SKIP_SMOKE=0 YES=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-smoke) SKIP_SMOKE=1 ;;
        --yes | -y) YES=1 ;;
        -h | --help) sed -n '2,9p' "$0"; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) NEW_TAG=$1 ;;
    esac
    shift
done
[[ -n $NEW_TAG ]] || die "usage: $0 <tag> [--skip-smoke] [--yes]"
check_tag "$NEW_TAG"
cd "$ROOT"

DATE=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p logs
LOG="logs/web-upgrade-$DATE.log"
exec > >(tee -a "$LOG") 2>&1

ensure_web_tag
OLD_TAG=$(env_get WEB_TAG .env)
REGISTRY=$(env_get IMAGE_REGISTRY .env)
info "browser client $OLD_TAG -> $NEW_TAG (log: $LOG)"
if [[ $YES -eq 0 && -t 0 ]]; then
    read -rp "Continue? [y/N]: " reply
    [[ $reply == [yY] ]] || die "aborted"
fi

# Resolve the digest before anything changes: a typo in the tag fails here, with nothing to undo.
digest=
if [[ -f images.lock.env ]]; then
    [[ -n $REGISTRY ]] || die "images.lock.env needs a registry (IMAGE_REGISTRY in .env)"
    info "resolving digest for durio-web:$NEW_TAG"
    digest=$(resolve_digest "${REGISTRY}durio-web:$NEW_TAG")
fi

rollback() {
    warn "browser client upgrade failed: rolling back to $OLD_TAG"
    cp -p ".env.$DATE.bak" .env
    [[ -f images.lock.env.$DATE.bak ]] && cp -p "images.lock.env.$DATE.bak" images.lock.env
    compose up -d web || true
    die "rolled back to $OLD_TAG — see $LOG"
}

cp -p .env ".env.$DATE.bak"
env_set WEB_TAG "$NEW_TAG" .env
if [[ -n $digest ]]; then
    cp -p images.lock.env "images.lock.env.$DATE.bak"
    env_set WEB_DIGEST "$digest" images.lock.env
fi

compose pull --quiet web || rollback
compose up -d web || rollback
wait_healthy 120 web || rollback
# The Caddyfile is a single-file bind mount: after a git checkout the running caddy keeps the old
# file (and its routes) until it is recreated. Recreate only then: it drops every WebSocket.
if ! compose exec -T caddy cat /etc/caddy/Caddyfile | cmp -s - Caddyfile; then
    info "caddy runs an older Caddyfile: recreating it"
    compose up -d --force-recreate caddy || rollback
    wait_healthy 120 caddy || rollback
fi

if [[ $SKIP_SMOKE -eq 0 ]]; then
    "$ROOT/scripts/smoke.sh" || rollback
fi
info "browser client $NEW_TAG done: https://$(env_get STOAT_DOMAIN .env)/web/app/"
