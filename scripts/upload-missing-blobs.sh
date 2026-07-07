#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <new-hostname> <new-identifier> <old-hostname>" >&2
  echo "  e.g. $0 newdomain.com you.newdomain.com yourdomain.com" >&2
  echo "  <new-identifier> is the account's handle or email on the new PDS; you'll be prompted for its password" >&2
  echo "  Run this after scripts/restore-repo.sh has imported the repo. The old account/PDS must still be reachable." >&2
  exit 1
fi

NEW_HOSTNAME="$1"
NEW_IDENTIFIER="$2"
OLD_HOSTNAME="$3"

read -rsp "New account password: " PASSWORD
echo >&2

SESSION=$(curl -sX POST "https://${NEW_HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${NEW_IDENTIFIER}\", \"password\": \"${PASSWORD}\"}")
ACCESS_JWT=$(echo "$SESSION" | jq -r '.accessJwt')
DID=$(echo "$SESSION" | jq -r '.did')

if [[ -z "$ACCESS_JWT" || "$ACCESS_JWT" == "null" ]]; then
  echo "Error: login failed: $(echo "$SESSION" | jq -r '.message // .')" >&2
  exit 1
fi

COUNT=0
CURSOR=""
while true; do
  URL="https://${NEW_HOSTNAME}/xrpc/com.atproto.repo.listMissingBlobs?limit=500"
  [[ -n "$CURSOR" ]] && URL="${URL}&cursor=${CURSOR}"

  PAGE=$(curl -s "$URL" -H "Authorization: Bearer ${ACCESS_JWT}")
  CIDS=$(echo "$PAGE" | jq -r '.blobs[].cid')

  if [[ -z "$CIDS" ]]; then
    break
  fi

  while IFS= read -r CID; do
    TMPFILE=$(mktemp)
    HEADERS=$(mktemp)

    curl -s -D "$HEADERS" \
      "https://${OLD_HOSTNAME}/xrpc/com.atproto.sync.getBlob?did=${DID}&cid=${CID}" \
      -o "$TMPFILE"

    CONTENT_TYPE=$(grep -i '^content-type:' "$HEADERS" | tail -1 | cut -d' ' -f2- | tr -d '\r')
    CONTENT_TYPE="${CONTENT_TYPE:-application/octet-stream}"

    curl -sX POST "https://${NEW_HOSTNAME}/xrpc/com.atproto.repo.uploadBlob" \
      -H "Authorization: Bearer ${ACCESS_JWT}" \
      -H "Content-Type: ${CONTENT_TYPE}" \
      --data-binary "@${TMPFILE}" >/dev/null

    rm -f "$TMPFILE" "$HEADERS"
    COUNT=$((COUNT + 1))
    echo "Uploaded blob ${CID} (${CONTENT_TYPE})" >&2
  done <<< "$CIDS"

  CURSOR=$(echo "$PAGE" | jq -r '.cursor // empty')
  [[ -z "$CURSOR" ]] && break
done

echo "Done. Uploaded ${COUNT} missing blob(s) for ${DID}."
