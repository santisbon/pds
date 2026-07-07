#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <handle-or-did>" >&2
  echo "  e.g. $0 bsky.social jay.bsky.team" >&2
  echo "  e.g. $0 yourdomain.com did:plc:xxxx" >&2
  echo "  Works against any PDS/entryway (e.g. bsky.social), unauthenticated." >&2
  exit 1
fi

HOSTNAME="$1"
IDENTIFIER="$2"

DESCRIBE=$(curl -s "https://${HOSTNAME}/xrpc/com.atproto.repo.describeRepo?repo=${IDENTIFIER}")
ERROR=$(echo "$DESCRIBE" | jq -r '.error // empty')

if [[ -n "$ERROR" ]]; then
  case "$ERROR" in
    RepoNotFound) STATUS="not found" ;;
    RepoTakendown) STATUS="takendown" ;;
    RepoDeactivated) STATUS="deactivated" ;;
    *) STATUS="error: $(echo "$DESCRIBE" | jq -r '.message // .error')" ;;
  esac
  echo "${IDENTIFIER}  status=${STATUS}"
  exit 0
fi

DID=$(echo "$DESCRIBE" | jq -r '.did')
HANDLE=$(echo "$DESCRIBE" | jq -r '.handle')
HANDLE_OK=$(echo "$DESCRIBE" | jq -r '.handleIsCorrect')
NUM_COLLECTIONS=$(echo "$DESCRIBE" | jq -r '.collections | length')

# Best-effort extra detail (rev). com.atproto.sync.getRepoStatus gives a more
# explicit status enum and the repo's current rev, but some servers require
# auth for it (e.g. bsky.social's own entryway) even though describeRepo above
# doesn't - so this is opportunistic, not required.
REV=$(curl -s "https://${HOSTNAME}/xrpc/com.atproto.sync.getRepoStatus?did=${DID}" | jq -r '.rev // empty')

echo "${HANDLE}  ${DID}  active=true  status=active  handleIsCorrect=${HANDLE_OK}  collections=${NUM_COLLECTIONS}${REV:+  rev=${REV}}"
