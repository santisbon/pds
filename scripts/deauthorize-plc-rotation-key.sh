#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <hostname> <identifier> <old-server-did-key>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com did:key:zOLD..." >&2
  echo "  Final step of rotating credentials.plcRotationKey - run this ONCE PER ACCOUNT," >&2
  echo "  only AFTER the chart's credential has been rotated to the new key (via" >&2
  echo "  scripts/rotate-plc-rotation-key.sh). Removes <old-server-did-key> from the" >&2
  echo "  account's DID's rotationKeys. Must be run after scripts/authorize-plc-rotation-key.sh" >&2
  echo "  added the new key alongside it - the PDS refuses any operation whose" >&2
  echo "  rotationKeys doesn't include its own currently-configured key, so this only" >&2
  echo "  works once the new key is both on the account AND live in the chart." >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"
OLD_SERVER_DID_KEY="$3"

read -rsp "Account password: " PASSWORD
echo >&2

SESSION=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${IDENTIFIER}\", \"password\": \"${PASSWORD}\"}")
ACCESS_JWT=$(echo "$SESSION" | jq -r '.accessJwt')
DID=$(echo "$SESSION" | jq -r '.did')

if [[ "$ACCESS_JWT" == "null" ]]; then
  echo "Login failed: $(echo "$SESSION" | jq -r '.message // .error // .')" >&2
  exit 1
fi

CURRENT_KEYS=$(curl -s "https://plc.directory/${DID}/data" | jq -c '.rotationKeys')

if ! echo "$CURRENT_KEYS" | jq -e --arg old "$OLD_SERVER_DID_KEY" 'index($old) != null' >/dev/null; then
  echo "${OLD_SERVER_DID_KEY} already not in ${DID}'s rotationKeys (${CURRENT_KEYS}) - nothing to do." >&2
  exit 0
fi

NEW_KEYS=$(echo "$CURRENT_KEYS" | jq -c --arg old "$OLD_SERVER_DID_KEY" 'map(select(. != $old))')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.requestPlcOperationSignature" \
  -H "Authorization: Bearer ${ACCESS_JWT}" >/dev/null

echo "A confirmation token has been emailed to the account." >&2
read -rp "Enter the emailed token: " EMAIL_TOKEN

OPERATION=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.signPlcOperation" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -d "{\"token\": \"${EMAIL_TOKEN}\", \"rotationKeys\": ${NEW_KEYS}}" \
  | jq '.operation')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.submitPlcOperation" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -d "{\"operation\": ${OPERATION}}"

echo
echo "Verifying..." >&2
curl -s "https://plc.directory/${DID}/data" | jq '.rotationKeys'
echo "${DID} should no longer list ${OLD_SERVER_DID_KEY}." >&2
