#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <hostname> [sort] [release] [namespace]" >&2
  echo "  e.g. $0 yourdomain.com recent" >&2
  echo "  sort is 'recent' (default) or 'usage'" >&2
  exit 1
fi

HOSTNAME="$1"
SORT="${2:-recent}"
RELEASE="${3:-pds}"
NAMESPACE="${4:-pds}"

ADMIN_PASSWORD=$(k8s_secret admin-password "$RELEASE" "$NAMESPACE")
AUTH_HEADER="Authorization: Basic $(echo -n "admin:${ADMIN_PASSWORD}" | base64)"

cursor=""
while :; do
  url="https://${HOSTNAME}/xrpc/com.atproto.admin.getInviteCodes?sort=${SORT}&limit=100"
  if [[ -n "$cursor" ]]; then
    url="${url}&cursor=${cursor}"
  fi

  page=$(curl -s "$url" -H "$AUTH_HEADER")
  cursor=$(echo "$page" | jq -r '.cursor // empty')

  # .available is the code's original use quota, not a live remaining count -
  # it never changes after creation, even once the code is fully used up or
  # its account is deleted. Compare it against the actual use count to tell
  # whether the code is really still usable.
  echo "$page" | jq -r '.codes[] | "\(.code)  quota=\(.available)  uses=\(.uses | length)  exhausted=\((.uses | length) >= .available)  disabled=\(.disabled)  createdBy=\(.createdBy)  createdAt=\(.createdAt)"'

  [[ -z "$cursor" ]] && break
done
