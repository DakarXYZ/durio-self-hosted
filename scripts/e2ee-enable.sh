#!/usr/bin/env bash
# Switches end-to-end encryption on for this server (SH-13). Idempotent; there is no way back.
#
#   scripts/e2ee-enable.sh [--local] [--yes]           enable E2EE (DMs and groups)
#   scripts/e2ee-enable.sh --default-for-new-dms       later step (O6): encrypt new DMs from the start
#   scripts/e2ee-enable.sh --check                     show the state, change nothing
#   scripts/e2ee-enable.sh --no-restart ...            only edit Revolt.overrides.toml (no checks, no restart)
#
# Steps: GET /api/ must expose features.e2ee and our version -> every running backend container runs the
# image compose expects for APP_TAG -> [features.e2ee] enabled = true in Revolt.overrides.toml (other content
# kept) -> restart ALL backend services -> GET /api/ must report features.e2ee.enabled -> marker
# data/.e2ee-enabled (smoke.sh then fails if E2EE is ever off again).
# Enable only after E2EE-capable clients are released. --local: as in smoke.sh (resolve to 127.0.0.1).
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERRIDES="$ROOT/Revolt.overrides.toml"
SECTION="features.e2ee"

refuse_disable() {
    cat >&2 <<'EOF'
error: E2EE cannot be switched off (Q59).
  With [features.e2ee] enabled = false the server rejects every encrypted message and key request:
  encrypted DMs and groups become read-only, devices stop receiving keys, key backups stop working.
  The channel encryption flag itself is irreversible, so the chats cannot fall back to plain text either.
  If E2EE misbehaves: keep it on, roll back the image tag (scripts/upgrade.sh <previous tag>) or fix forward.
  default_for_new_dms (O6) may be switched off safely: edit Revolt.overrides.toml and restart the backend.
EOF
    exit 1
}

MODE=enable LOCAL=0 YES=0 RESTART=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --default-for-new-dms) MODE=default-dms ;;
        --check) MODE=check ;;
        --disable | --off | --no-e2ee) refuse_disable ;;
        --no-restart) RESTART=0 ;;
        --local) LOCAL=1 ;;
        --yes | -y) YES=1 ;;
        -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done

require_config
[[ -f $OVERRIDES ]] || die "Revolt.overrides.toml missing — run scripts/generate_config.sh"
cd "$ROOT"

# ---------------------------------------------------------------------------- Revolt.overrides.toml

# toml_get KEY — value of KEY in [features.e2ee] (comment and spaces stripped), empty if absent.
toml_get() {
    SEC="$SECTION" KEY="$1" awk '
        BEGIN { sec = ENVIRON["SEC"]; key = ENVIRON["KEY"] }
        /^[[:space:]]*\[/ {
            h = $0; sub(/#.*/, "", h); gsub(/[[:space:]]/, "", h); gsub(/^\[+|\]+$/, "", h)
            insec = (h == sec); next
        }
        insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            v = $0; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit
        }
    ' "$OVERRIDES"
}

# toml_set KEY VALUE — set KEY in [features.e2ee]: replace the line, add it right after the section
# header, or append the section. Everything else in the file stays byte-for-byte.
toml_set() {
    local tmp
    tmp=$(mktemp)
    SEC="$SECTION" KEY="$1" VAL="$2" awk '
        BEGIN { sec = ENVIRON["SEC"]; key = ENVIRON["KEY"]; val = ENVIRON["VAL"]; pat = "^[[:space:]]*" key "[[:space:]]*=" }
        function header(line,  h) { h = line; sub(/#.*/, "", h); gsub(/[[:space:]]/, "", h); gsub(/^\[+|\]+$/, "", h); return h }
        NR == FNR {
            if ($0 ~ /^[[:space:]]*\[/) { insec = (header($0) == sec); if (insec) has_sec = 1; next }
            if (insec && $0 ~ pat) has_key = 1
            next
        }
        FNR == 1 { insec = 0 }
        /^[[:space:]]*\[/ {
            insec = (header($0) == sec); print
            if (insec && !has_key) print key " = " val
            next
        }
        insec && $0 ~ pat { print key " = " val; next }
        { print }
        END { if (!has_sec) printf "\n[%s]\n%s = %s\n", sec, key, val }
    ' "$OVERRIDES" "$OVERRIDES" >"$tmp"
    cat "$tmp" >"$OVERRIDES" # keeps owner and mode
    rm -f "$tmp"
}

# Other spellings (dotted keys, inline tables, env variables) would silently win over our line.
check_config_forms() {
    local n
    if grep -nE '^[[:space:]]*(features[[:space:]]*\.[[:space:]]*)?e2ee[[:space:]]*[.=]' "$OVERRIDES" >&2; then
        die "Revolt.overrides.toml sets e2ee as a dotted key or inline table (above): use a [features.e2ee] section"
    fi
    n=$(grep -cE '^[[:space:]]*\[[[:space:]]*features[[:space:]]*\.[[:space:]]*e2ee[[:space:]]*\]' "$OVERRIDES" || true)
    [[ $n -le 1 ]] || die "Revolt.overrides.toml has $n [features.e2ee] sections — merge them first"
    if grep -hE '^REVOLT__FEATURES__E2EE__' "$ENV_FILE" "$SECRETS_FILE" >&2; then
        die "REVOLT__FEATURES__E2EE__* in .env/secrets.env (above) overrides Revolt.overrides.toml — remove it"
    fi
    return 0
}

# ---------------------------------------------------------------------------- running server

DOMAIN=$(env_get STOAT_DOMAIN "$ENV_FILE")
APP_TAG=$(env_get APP_TAG "$ENV_FILE")

api_root() {
    public_curl_opts "$DOMAIN" "$LOCAL"
    curl "${CURL_OPTS[@]}" "https://$DOMAIN/api/" 2>/dev/null || true
}

api_flag() { # KEY -> true | false | absent
    jq -r --arg k "$1" '.features.e2ee | if type == "object" and has($k) then .[$k] | tostring else "absent" end' \
        <<<"$2" 2>/dev/null || echo absent
}

# Every running backend container must run exactly the image compose resolves for APP_TAG
# (same tag and, after a pull, the same image id): mixed versions break the E2EE event flow (C19, C20).
check_images() {
    local svc id want got want_id got_id tag bad=0 config
    config=$(compose config --format json)
    for svc in "${BACKEND_SERVICES[@]}" gifbox; do
        id=$(compose ps -q "$svc" 2>/dev/null | head -n 1)
        if [[ -z $id ]]; then
            [[ $svc == gifbox ]] && continue
            warn "$svc is not running"
            bad=1
            continue
        fi
        want=$(jq -r --arg s "$svc" '.services[$s].image // empty' <<<"$config")
        tag=${want%%@*}
        tag=${tag##*:}
        got=$(docker inspect -f '{{.Config.Image}}' "$id")
        got_id=$(docker inspect -f '{{.Image}}' "$id")
        want_id=$(docker image inspect -f '{{.Id}}' "$want" 2>/dev/null || true)
        if [[ $tag != "$APP_TAG" ]]; then
            warn "$svc: compose resolves $want, not APP_TAG $APP_TAG (compose.override.yml?)"
            bad=1
        elif [[ $got != "$want" || $got_id != "$want_id" ]]; then
            warn "$svc runs $got ($got_id), expected $want ($want_id): recreate it (scripts/compose up -d)"
            bad=1
        else
            echo "ok   $svc -> $got"
        fi
    done
    [[ $bad -eq 0 ]] || die "backend services do not all run $APP_TAG — finish the upgrade first (scripts/upgrade.sh $APP_TAG)"
}

check_root() { # ROOT_JSON
    local version expect
    jq -e '.features.e2ee | type == "object"' <<<"$1" >/dev/null 2>&1 ||
        die "GET https://$DOMAIN/api/ has no features.e2ee: the backend is unreachable or too old for E2EE"
    version=$(jq -r '.revolt // empty' <<<"$1")
    expect=${APP_TAG/-fork/+fork}
    if [[ $expect == *+fork* && $version != "$expect" ]]; then
        die "GET /api/ reports revolt $version, .env APP_TAG is $APP_TAG — finish the upgrade first"
    fi
    echo "ok   /api/ -> revolt $version, e2ee enabled: $(api_flag enabled "$1"), default_for_new_dms: $(api_flag default_for_new_dms "$1")"
}

restart_and_verify() { # KEY
    local root i
    info "restarting all backend services: ${BACKEND_SERVICES[*]}"
    compose up -d --force-recreate "${BACKEND_SERVICES[@]}"
    wait_healthy 300 "${BACKEND_SERVICES[@]}" || die "backend services did not come up — scripts/compose logs api"
    for i in $(seq 1 20); do
        root=$(api_root)
        [[ $(api_flag "$1" "$root") == true ]] && break
        [[ $i -lt 20 ]] && sleep 3
    done
    [[ $(api_flag "$1" "$root") == true ]] ||
        die "GET /api/ still reports features.e2ee.$1 = $(api_flag "$1" "$root") — check scripts/compose logs api"
    echo "ok   /api/ -> features.e2ee.$1 = true"
}

confirm() { # PROMPT
    [[ $YES -eq 1 ]] && return 0
    [[ -t 0 ]] || die "not a terminal: re-run with --yes after reading the warnings above"
    local reply
    read -rp "$1 Type 'yes' to continue: " reply
    [[ $reply == yes ]] || die "aborted"
}

# ---------------------------------------------------------------------------- modes

check_config_forms
file_enabled=$(toml_get enabled)
file_dms=$(toml_get default_for_new_dms)

if [[ $MODE == check ]]; then
    echo "Revolt.overrides.toml: enabled = ${file_enabled:-<unset, default false>}, default_for_new_dms = ${file_dms:-<unset, default false>}"
    if [[ -f $E2EE_MARKER ]]; then
        echo "marker: $(tr '\n' ' ' <"$E2EE_MARKER")"
    else
        echo "marker: none (E2EE was never enabled by this script)"
    fi
    root=$(api_root)
    if jq -e '.features.e2ee' <<<"$root" >/dev/null 2>&1; then
        echo "GET /api/: revolt $(jq -r '.revolt' <<<"$root"), enabled: $(api_flag enabled "$root"), default_for_new_dms: $(api_flag default_for_new_dms "$root")"
    else
        echo "GET /api/: no features.e2ee (unreachable or old backend)"
    fi
    exit 0
fi

if [[ $MODE == default-dms ]]; then
    KEY=default_for_new_dms
    if [[ $RESTART -eq 1 ]]; then
        [[ $(api_flag enabled "$(api_root)") == true ]] ||
            die "E2EE is not enabled on the running server: run scripts/e2ee-enable.sh first, this step comes 1–2 months later"
    fi
    [[ $file_enabled == true ]] || die "[features.e2ee] enabled is not true in Revolt.overrides.toml: enable E2EE first"
    cat <<'EOF'
New direct messages will be encrypted from the start (O6). Do this 1–2 months after the E2EE release,
once the active users run E2EE-capable clients: a DM with someone on an old client cannot be read there
("update the app"). Groups stay manual. Switching this back to false later is safe (new DMs only).
EOF
else
    KEY=enabled
    cat <<EOF
Enabling end-to-end encryption on $DOMAIN (tag $APP_TAG).
  * Only after the E2EE-capable clients are RELEASED: old clients see "Encrypted message, update the app".
  * IRREVERSIBLE: never set enabled = false again (encrypted chats would become read-only, Q59).
  * All backend services restart now or (--no-restart) on the next restart; clients reconnect.
EOF
fi

if [[ $RESTART -eq 1 ]]; then
    require_cmd docker jq curl
    [[ -n $DOMAIN ]] || die "no STOAT_DOMAIN in .env"
    root=$(api_root)
    check_root "$root"
    if [[ $(api_flag "$KEY" "$root") == true && $(toml_get "$KEY") == true ]]; then
        info "features.e2ee.$KEY is already on — nothing to do"
        if [[ $KEY == enabled && ! -f $E2EE_MARKER ]]; then
            mkdir -p "$(dirname "$E2EE_MARKER")"
            printf 'enabled_at=%s\ntag=%s\n' "$(date -u +%FT%TZ)" "$APP_TAG" >"$E2EE_MARKER"
        fi
        exit 0
    fi
    check_images
else
    warn "--no-restart: services and versions are NOT checked; the next restart of the backend applies the change"
fi

confirm "Turn on features.e2ee.$KEY?"
if [[ $(toml_get "$KEY") != true ]]; then
    before=$(mktemp)
    cp "$OVERRIDES" "$before"
    toml_set "$KEY" true
    [[ $(toml_get "$KEY") == true ]] || die "could not set $KEY in Revolt.overrides.toml"
    info "Revolt.overrides.toml:"
    diff "$before" "$OVERRIDES" || true
    rm -f "$before"
else
    info "Revolt.overrides.toml already has $KEY = true"
fi

if [[ $RESTART -eq 0 ]]; then
    info "restart ALL backend services to apply: scripts/compose up -d --force-recreate ${BACKEND_SERVICES[*]}"
    exit 0
fi

restart_and_verify "$KEY"
if [[ $KEY == enabled ]]; then
    mkdir -p "$(dirname "$E2EE_MARKER")"
    printf 'enabled_at=%s\ntag=%s\n' "$(date -u +%FT%TZ)" "$APP_TAG" >"$E2EE_MARKER"
    info "E2EE enabled. Keep it on; the default for new DMs (O6) comes later: scripts/e2ee-enable.sh --default-for-new-dms"
else
    info "new DMs are now encrypted by default"
fi
