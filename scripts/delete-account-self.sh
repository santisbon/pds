#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <identifier>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com" >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  echo "  Self-service, requires an emailed confirmation token." >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"

read -rsp "Account password: " PASSWORD
echo >&2

SESSION=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${IDENTIFIER}\", \"password\": \"${PASSWORD}\"}")
ACCESS_JWT=$(echo "$SESSION" | jq -r '.accessJwt')
DID=$(echo "$SESSION" | jq -r '.did')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.requestAccountDelete" \
  -H "Authorization: Bearer ${ACCESS_JWT}" >/dev/null

echo "A confirmation token has been emailed to the account." >&2
read -rp "Enter the emailed token: " EMAIL_TOKEN

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.deleteAccount" \
  -H "Content-Type: application/json" \
  -d "{\"did\": \"${DID}\", \"password\": \"${PASSWORD}\", \"token\": \"${EMAIL_TOKEN}\"}"

echo
echo "Deleted ${DID} from this PDS. The did:plc document is untouched." >&2
