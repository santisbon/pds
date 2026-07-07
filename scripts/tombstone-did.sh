#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <did> [release] [namespace]" >&2
  echo "  e.g. $0 did:plc:xxxx" >&2
  echo "  Permanently deactivates the DID. One-way - only do this if you want to retire it for good." >&2
  exit 1
fi

DID="$1"
RELEASE="${2:-pds}"
NAMESPACE="${3:-pds}"

PLC_ROTATION_KEY=$(k8s_secret plc-rotation-key "$RELEASE" "$NAMESPACE")

echo "Installing @atproto/crypto and @did-plc/lib in a scratch dir..." >&2
SCRATCH=$(npm_scratch_dir @atproto/crypto @did-plc/lib)

(cd "$SCRATCH" && PLC_KEY="$PLC_ROTATION_KEY" PLC_DID="$DID" node -e "
const { Secp256k1Keypair } = require('@atproto/crypto');
const { Client } = require('@did-plc/lib');
(async () => {
  const kp = await Secp256k1Keypair.import(process.env.PLC_KEY);
  const client = new Client('https://plc.directory');
  await client.tombstone(process.env.PLC_DID, kp);
  console.log('Tombstoned', process.env.PLC_DID);
})().catch(err => { console.error(err); process.exit(1); });
")

rm -rf "$SCRATCH"

echo "Verifying..." >&2
curl -s "https://plc.directory/${DID}"
echo
curl -s "https://plc.directory/${DID}/log/audit" | jq -r '.[-1].operation.type'
