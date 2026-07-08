#!/usr/bin/env bash
# Sync Technitium's Allow List (whitelist for over-blocked domains) across all 4
# cluster nodes. Allow-list entries are per-node config and are NOT replicated by
# Technitium's DNS Cluster feature (unlike regular/forwarder zones), so this script
# is the one-command way to keep them consistent.
#
# Usage:
#   ./technitium-allow-sync.sh add <domain>
#   ./technitium-allow-sync.sh remove <domain>
#   ./technitium-allow-sync.sh list
#
# Requires: SSH key-based root access to DNS-A/DNS-B/DNS-C/DNS-D (already configured
# as SSH aliases), and the Technitium admin password in $TECH_PASS, e.g.:
#   TECH_PASS='...' ./technitium-allow-sync.sh add somedomain.com

set -euo pipefail

NODES=(DNS-A DNS-B DNS-C DNS-D)
TECH_USER="admin"
: "${TECH_PASS:?Set TECH_PASS to your Technitium admin password, e.g. TECH_PASS='...' $0 add <domain>}"

action="${1:-}"
domain="${2:-}"

usage() {
  echo "Usage: $0 add <domain>" >&2
  echo "       $0 remove <domain>" >&2
  echo "       $0 list" >&2
  exit 1
}

case "$action" in
  add|remove)
    [[ -n "$domain" ]] || usage
    ;;
  list)
    ;;
  *)
    usage
    ;;
esac

remote_cmd() {
  local endpoint="$1"
  local extra="$2"
  cat <<EOF
TOKEN=\$(curl -s "http://127.0.0.1:5380/api/user/login?user=${TECH_USER}&pass=${TECH_PASS}&includeInfo=false" | jq -r '.token')
curl -s -G "http://127.0.0.1:5380/${endpoint}" --data-urlencode "token=\${TOKEN}" ${extra}
EOF
}

# A previously-cached answer (e.g. a domain allowed then re-blocked) will keep being
# served to clients until its TTL expires unless we flush the cache, so add/remove
# both flush the cache on that node right after the config change.
flush_cache() {
  local node="$1"
  ssh "$node" '
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user='"${TECH_USER}"'&pass='"${TECH_PASS}"'&includeInfo=false" | jq -r ".token")
curl -s -G "http://127.0.0.1:5380/api/cache/flush" --data-urlencode "token=${TOKEN}" > /dev/null
'
}

overall_ok=true

for node in "${NODES[@]}"; do
  echo "=== ${node} ==="
  case "$action" in
    add)
      result=$(ssh "$node" "$(remote_cmd "api/allowed/add" "--data-urlencode 'domain=${domain}'")")
      status=$(echo "$result" | jq -r '.status')
      echo "  add ${domain}: ${status}"
      if [[ "$status" == "ok" ]]; then
        flush_cache "$node"
      else
        overall_ok=false; echo "  $(echo "$result" | jq -r '.errorMessage // empty')"
      fi
      ;;
    remove)
      result=$(ssh "$node" "$(remote_cmd "api/allowed/delete" "--data-urlencode 'domain=${domain}'")")
      status=$(echo "$result" | jq -r '.status')
      echo "  remove ${domain}: ${status}"
      if [[ "$status" == "ok" ]]; then
        flush_cache "$node"
      else
        overall_ok=false; echo "  $(echo "$result" | jq -r '.errorMessage // empty')"
      fi
      ;;
    list)
      # The /api/allowed/list API groups results inconsistently depending on how many
      # entries share a parent domain, so we read the underlying config file directly
      # instead -- it's the authoritative, unambiguous source.
      entries=$(ssh "$node" "grep -a -oE '[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+' /etc/dns/allowed.config 2>/dev/null" || true)
      if [[ -n "$entries" ]]; then
        echo "$entries" | sed 's/^/  /'
      else
        echo "  (none)"
      fi
      ;;
  esac
done

if [[ "$overall_ok" == "true" ]]; then
  echo
  echo "Done. All 4 nodes in sync."
else
  echo
  echo "WARNING: at least one node failed — nodes are now OUT OF SYNC. Re-run or investigate above." >&2
  exit 1
fi
