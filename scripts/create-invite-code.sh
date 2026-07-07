#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <hostname> [use-count] [release] [namespace]" >&2
  echo "  e.g. $0 yourdomain.com 1" >&2
  exit 1
fi

HOSTNAME="$1"
USE_COUNT="${2:-1}"
RELEASE="${3:-pds}"
NAMESPACE="${4:-pds}"

ADMIN_PASSWORD=$(k8s_secret admin-password "$RELEASE" "$NAMESPACE")

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createInviteCode" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n "admin:${ADMIN_PASSWORD}" | base64)" \
  -d "{\"useCount\": ${USE_COUNT}}" \
  | jq -r '.code'
