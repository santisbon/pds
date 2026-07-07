#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <identifier>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com" >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  echo "  Sends a confirmation email to the account's address on file (rate-limited: 5/hour, 15/day)" >&2
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

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.requestEmailConfirmation" \
  -H "Authorization: Bearer ${ACCESS_JWT}"

echo
echo "Confirmation email requested. Check the address on file for the account."
