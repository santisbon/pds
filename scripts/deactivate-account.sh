#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <identifier> [delete-after-iso8601]" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com" >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  echo "  Reversible: stops serving the repo and blocks writes until reactivated with reactivate-account.sh" >&2
  echo "  [delete-after-iso8601] is only a recommendation to the server, not a guarantee" >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"
DELETE_AFTER="${3:-}"

read -rsp "Account password: " PASSWORD
echo >&2

ACCESS_JWT=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${IDENTIFIER}\", \"password\": \"${PASSWORD}\"}" \
  | jq -r '.accessJwt')

BODY="{}"
if [[ -n "$DELETE_AFTER" ]]; then
  BODY="{\"deleteAfter\": \"${DELETE_AFTER}\"}"
fi

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.deactivateAccount" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -d "$BODY"

echo
echo "Deactivated. Repo is no longer served and writes are blocked until you run reactivate-account.sh."
