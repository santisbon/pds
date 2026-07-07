#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <hostname> <identifier> <old-server-did-key> <new-server-did-key>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com did:key:zOLD... did:key:zNEW..." >&2
  echo "  Step 2 of rotating credentials.plcRotationKey - run this ONCE PER ACCOUNT," >&2
  echo "  while the server is still running <old-server-did-key>. ADDS" >&2
  echo "  <new-server-did-key> to the account's DID's rotationKeys, right next to the" >&2
  echo "  old server key (does NOT remove the old key - the PDS itself refuses any" >&2
  echo "  operation that would drop its own currently-configured key, see" >&2
  echo "  submitPlcOperation.ts upstream). Run scripts/deauthorize-plc-rotation-key.sh" >&2
  echo "  afterward, once the chart's credential has been rotated to the new key, to" >&2
  echo "  remove the old one. Leaves every other key (e.g. a personal key added via" >&2
  echo "  add-rotation-key.sh) untouched." >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  echo "  <new-server-did-key> comes from scripts/generate-plc-rotation-key.sh" >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"
OLD_SERVER_DID_KEY="$3"
NEW_SERVER_DID_KEY="$4"

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
  echo "${OLD_SERVER_DID_KEY} not found in ${DID}'s current rotationKeys (${CURRENT_KEYS})." >&2
  echo "Double check with: curl -s https://plc.directory/${DID}/data | jq .rotationKeys" >&2
  exit 1
fi

if echo "$CURRENT_KEYS" | jq -e --arg new "$NEW_SERVER_DID_KEY" 'index($new) != null' >/dev/null; then
  echo "${NEW_SERVER_DID_KEY} is already in ${DID}'s rotationKeys - nothing to do." >&2
  exit 0
fi

# Insert the new key immediately after the old key's position (not a replace: the PDS
# rejects any operation whose rotationKeys drops its own currently-configured key). This
# also means the new key naturally lands in the old key's slot once it's later removed by
# deauthorize-plc-rotation-key.sh, preserving priority relative to any other keys present.
NEW_KEYS=$(echo "$CURRENT_KEYS" | jq -c --arg old "$OLD_SERVER_DID_KEY" --arg new "$NEW_SERVER_DID_KEY" \
  '. as $keys | ($keys | index($old)) as $i | $keys[0:($i+1)] + [$new] + $keys[($i+1):]')

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
echo "${DID} should now list BOTH ${OLD_SERVER_DID_KEY} and ${NEW_SERVER_DID_KEY}." >&2
echo "Once every account confirms both keys and the chart's credential is rotated," >&2
echo "run scripts/deauthorize-plc-rotation-key.sh to remove the old key." >&2
