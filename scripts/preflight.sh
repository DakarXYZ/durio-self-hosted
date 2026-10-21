#!/usr/bin/env bash
# Checks before starting/upgrading the stack: config present, no public default keys,
# storage path mounted, compose file valid, port policy. Exit code != 0 = do not start.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker jq
require_config
cd "$ROOT"

# compose >= 2.24 (several --env-file, depends_on.required)
ver=$(docker compose version --short 2>/dev/null | sed 's/^v//; s/-.*//')
IFS=. read -r major minor _ <<<"$ver"
((major > 2 || (major == 2 && minor >= 24))) || die "docker compose >= 2.24 required (found ${ver:-none})"

perm=$(stat -c %a secrets.env 2>/dev/null || stat -f %Lp secrets.env)
[[ $perm == 600 || $perm == 400 ]] || warn "secrets.env has mode $perm — run: chmod 600 secrets.env"
[[ -f Revolt.toml ]] || die "Revolt.toml missing — run scripts/generate_config.sh"
[[ -f Revolt.overrides.toml ]] || die "Revolt.overrides.toml missing or not a file"
[[ -f livekit.yml && -f stoat.json ]] || die "livekit.yml / stoat.json missing — run scripts/generate_config.sh --overwrite"

check_no_default_secrets

if [[ $(env_get FILES_STORAGE .env) == minio ]]; then
    path=$(env_get MINIO_DATA_PATH .env)
    path=${path:-./data/minio}
    if [[ $path == /* ]]; then
        [[ -d $path ]] || die "MINIO_DATA_PATH $path does not exist (disk not mounted?)"
        # A separate disk/NAS must be mounted, otherwise MinIO silently writes to the system disk.
        if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$path"; then
            if [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then
                warn "MINIO_DATA_PATH $path is an empty directory and not a mount point — is the disk mounted?"
            fi
        fi
    fi
fi

# Installs from before the browser client: compose refuses to start without WEB_TAG.
env_has WEB_TAG .env ||
    die "WEB_TAG missing in .env: scripts/upgrade.sh and scripts/web-upgrade.sh add it (or: generate_config.sh --overwrite)"
compose config -q
"$ROOT/scripts/check-ports.sh" >/dev/null
echo "preflight: OK"
