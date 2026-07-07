#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <handle> [output-file]" >&2
  echo "  e.g. $0 yourdomain.com you.yourdomain.com" >&2
  echo "  output-file defaults to <handle>.car" >&2
  exit 1
fi

HOSTNAME="$1"
HANDLE="$2"
OUTPUT_FILE="${3:-${HANDLE}.car}"

DID=$(curl -s "https://${HOSTNAME}/xrpc/com.atproto.identity.resolveHandle?handle=${HANDLE}" \
  | jq -r '.did')

curl -s "https://${HOSTNAME}/xrpc/com.atproto.sync.getRepo?did=${DID}" \
  -o "$OUTPUT_FILE"

echo "Backed up ${HANDLE} (${DID}) to ${OUTPUT_FILE}"
