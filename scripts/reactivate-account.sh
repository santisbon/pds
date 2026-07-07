#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <identifier>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com" >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  echo "  Deactivated accounts can still log in, so this works even while deactivated" >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"

read -rsp "Account password: " PASSWORD
echo >&2

ACCESS_JWT=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${IDENTIFIER}\", \"password\": \"${PASSWORD}\"}" \
  | jq -r '.accessJwt')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.activateAccount" \
  -H "Authorization: Bearer ${ACCESS_JWT}"

echo
echo "Reactivated. Repo is being served and writes are allowed again."
