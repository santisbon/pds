#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <hostname> <username> <email> <invite-code> [password]" >&2
  echo "  e.g. $0 yourdomain.com alice alice@example.com ABCD1-EFGH2" >&2
  echo "  password is generated randomly if omitted" >&2
  exit 1
fi

HOSTNAME="$1"
USERNAME="$2"
EMAIL="$3"
INVITE_CODE="$4"
PASSWORD="${5:-$(openssl rand -hex 8)}"
HANDLE="${USERNAME}.${HOSTNAME}"

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createAccount" \
  -H "Content-Type: application/json" \
  -d "{
    \"handle\": \"${HANDLE}\",
    \"email\": \"${EMAIL}\",
    \"password\": \"${PASSWORD}\",
    \"inviteCode\": \"${INVITE_CODE}\"
  }"

echo
echo "Handle: @${HANDLE}"
echo "Password: ${PASSWORD}"
echo "Server address: https://${HOSTNAME}"
