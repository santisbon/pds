#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <identifier>" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com" >&2
  echo "  <identifier> is the account's current handle or email; you'll be prompted for the password" >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"

read -rsp "Account password: " PASSWORD
echo >&2

echo "Generating a secp256k1 keypair (installing @atproto/crypto in a scratch dir)..." >&2
SCRATCH=$(npm_scratch_dir @atproto/crypto)
KEYPAIR_JSON=$(cd "$SCRATCH" && node -e "
const { Secp256k1Keypair } = require('@atproto/crypto');
Secp256k1Keypair.create({ exportable: true }).then(async kp => {
  const priv = Buffer.from(await kp.export()).toString('hex');
  console.log(JSON.stringify({ didKey: kp.did(), privHex: priv }));
});
")
rm -rf "$SCRATCH"

USER_DID_KEY=$(echo "$KEYPAIR_JSON" | jq -r '.didKey')
USER_PRIV_HEX=$(echo "$KEYPAIR_JSON" | jq -r '.privHex')

echo >&2
echo "New rotation key generated. Store the private key hex somewhere safe (password manager, hardware key) — it will not be shown again:" >&2
echo "  did:key  => ${USER_DID_KEY}" >&2
echo "  priv hex => ${USER_PRIV_HEX}" >&2
echo >&2

SESSION=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${IDENTIFIER}\", \"password\": \"${PASSWORD}\"}")
ACCESS_JWT=$(echo "$SESSION" | jq -r '.accessJwt')
DID=$(echo "$SESSION" | jq -r '.did')

SERVER_KEY=$(curl -s "https://plc.directory/${DID}/data" | jq -r '.rotationKeys[0]')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.requestPlcOperationSignature" \
  -H "Authorization: Bearer ${ACCESS_JWT}" >/dev/null

echo "A confirmation token has been emailed to the account." >&2
read -rp "Enter the emailed token: " EMAIL_TOKEN

OPERATION=$(curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.signPlcOperation" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -d "{\"token\": \"${EMAIL_TOKEN}\", \"rotationKeys\": [\"${USER_DID_KEY}\", \"${SERVER_KEY}\"]}" \
  | jq '.operation')

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.identity.submitPlcOperation" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -d "{\"operation\": ${OPERATION}}"

echo
echo "Verifying..." >&2
curl -s "https://plc.directory/${DID}/data" | jq '.rotationKeys'
echo "Your did:key (${USER_DID_KEY}) should now be rotationKeys[0] for ${DID}." >&2
