#!/usr/bin/env bash
# Fails if a public IPv4 literal appears in tracked files: the server IP lives only in .env.
#
#   scripts/check-no-ip.sh            all tracked files (CI)
#   scripts/check-no-ip.sh --staged   staged content only (pre-commit hook, see .githooks/)
#
# Allowed: files named *.example; loopback, unspecified, private (RFC 1918), link-local, CGNAT,
# documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and masks 255.x;
# a line containing the marker "ip-check: allow".
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=tracked
case ${1:-} in
    --staged) MODE=staged ;;
    "") ;;
    *) die "usage: $0 [--staged]" ;;
esac

cd "$ROOT"

allowed_ip() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    for o in "$a" "$b" "$c" "$d"; do
        ((10#$o <= 255)) || return 0 # not an IP (e.g. a version string)
    done
    a=$((10#$a)) b=$((10#$b)) c=$((10#$c))
    ((a == 0 || a == 10 || a == 127 || a == 255)) && return 0
    ((a == 169 && b == 254)) && return 0
    ((a == 172 && b >= 16 && b <= 31)) && return 0
    ((a == 192 && b == 168)) && return 0
    ((a == 100 && b >= 64 && b <= 127)) && return 0
    ((a == 192 && b == 0 && c == 2)) && return 0
    ((a == 198 && b == 51 && c == 100)) && return 0
    ((a == 203 && b == 0 && c == 113)) && return 0
    return 1
}

if [[ $MODE == staged ]]; then
    mapfile -d '' files < <(git diff --cached --name-only --diff-filter=ACMR -z)
else
    mapfile -d '' files < <(git ls-files -z)
fi

found=0
for f in "${files[@]}"; do
    [[ $f == *.example ]] && continue
    if [[ $MODE == staged ]]; then
        content=$(git show ":$f" 2>/dev/null | LC_ALL=C grep -nIoE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' || true)
        lines=$(git show ":$f" 2>/dev/null || true)
    else
        [[ -f $f ]] || continue
        content=$(LC_ALL=C grep -nIoE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' "$f" || true)
        lines=$(cat "$f")
    fi
    [[ -n $content ]] || continue
    while IFS= read -r hit; do
        lineno=${hit%%:*}
        ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"${hit#*:}" | head -n 1)
        allowed_ip "$ip" && continue
        sed -n "${lineno}p" <<<"$lines" | grep -q 'ip-check: allow' && continue
        printf '%s:%s: public IPv4 literal %s — keep server IPs in .env (SERVER_IP) only\n' "$f" "$lineno" "$ip" >&2
        found=1
    done <<<"$content"
done

if [[ $found -ne 0 ]]; then
    die "IPv4 addresses found in $MODE files (see above). Use \$SERVER_IP / documentation ranges instead."
fi
echo "check-no-ip: OK ($MODE files)"
