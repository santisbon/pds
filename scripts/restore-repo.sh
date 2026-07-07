#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <new-hostname> <new-identifier> <car-file>" >&2
  echo "  e.g. $0 newdomain.com you.newdomain.com you.yourdomain.com.car" >&2
  echo "  <new-identifier> is the account's handle or email on the new PDS; you'll be prompted for its password" >&2
  echo "  The account must already exist on the new PDS before importing" >&2
  exit 1
fi

NEW_HOSTNAME="$1"
NEW_IDENTIFIER="$2"
CAR_FILE="$3"

if [[ ! -f "$CAR_FILE" ]]; then
  echo "Error: ${CAR_FILE} not found" >&2
  exit 1
fi

read -rsp "Account password: " PASSWORD
echo >&2

ACCESS_JWT=$(curl -sX POST "https://${NEW_HOSTNAME}/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"${NEW_IDENTIFIER}\", \"password\": \"${PASSWORD}\"}" \
  | jq -r '.accessJwt')

curl -sX POST "https://${NEW_HOSTNAME}/xrpc/com.atproto.repo.importRepo" \
  -H "Authorization: Bearer ${ACCESS_JWT}" \
  -H "Content-Type: application/vnd.ipld.car" \
  --data-binary "@${CAR_FILE}"

echo "Imported ${CAR_FILE} into ${NEW_IDENTIFIER} on ${NEW_HOSTNAME}"
echo "Note: this restores repo records (posts, likes, follows, etc.) only. Blobs (avatars, media) referenced by those records are not included in the CAR file and must be re-uploaded separately — see scripts/upload-missing-blobs.sh." >&2
