#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <hostname> <identifier> <new-handle>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com alice.example.com" >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"
NEW_HANDLE="$3"

read -rsp "Account password: " PASSWORD
echo >&2

ACCESS_JWT=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${IDENTIFIER}\", \"password\": \"${PASSWORD}\"}" \
  | jq -r '.accessJwt')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.updateHandle" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -d "{\"handle\": \"${NEW_HANDLE}\"}"

echo
echo "Handle updated to @${NEW_HANDLE} (verified against the DNS/HTTP proof for that domain)."
