#!/usr/bin/env bash
# Ensures only caddy (80/tcp, 443/tcp, 443/udp) and livekit (7881/tcp, 7882/udp) publish ports
# and no service uses the host network. Docker bypasses ufw for published ports, so this list
# IS the firewall for containers (SH-09). Needs a generated .env/secrets.env (CI uses test ones).
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker jq
require_config

expected=$'caddy 443/tcp\ncaddy 443/udp\ncaddy 80/tcp\nlivekit 7881/tcp\nlivekit 7882/udp'

json=$(compose --profile '*' config --format json)

actual=$(jq -r '.services | to_entries[] | .key as $s | (.value.ports // [])[]
    | "\($s) \(.published)/\(.protocol // "tcp")"' <<<"$json" | LC_ALL=C sort -u)
host_net=$(jq -r '.services | to_entries[] | select(.value.network_mode == "host") | .key' <<<"$json")

status=0
if [[ $actual != "$(LC_ALL=C sort <<<"$expected")" ]]; then
    printf 'published ports differ from the allowed list.\nexpected:\n%s\nactual:\n%s\n' \
        "$(LC_ALL=C sort <<<"$expected")" "$actual" >&2
    status=1
fi
if [[ -n $host_net ]]; then
    printf 'services on the host network (bypass the port list): %s\n' "$host_net" >&2
    status=1
fi
[[ $status -eq 0 ]] || die "port policy violated"
echo "check-ports: OK"
