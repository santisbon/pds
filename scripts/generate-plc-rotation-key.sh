#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [output-file]" >&2
  echo "  Step 1 of rotating credentials.plcRotationKey (the server's key - not a" >&2
  echo "  personal account key, which is add-rotation-key.sh instead)." >&2
  echo "  Generates a new secp256k1 keypair and writes {didKey, privHex} to" >&2
  echo "  <output-file> (default: ~/new-plc-key.json). The private key hex is" >&2
  echo "  written to disk only - never printed to this transcript." >&2
  exit 1
fi

OUT="${1:-$HOME/new-plc-key.json}"

if [[ -f "$OUT" ]]; then
  echo "$OUT already exists - remove it first if you really want to generate a new one." >&2
  exit 1
fi

echo "Generating a secp256k1 keypair (installing @atproto/crypto in a scratch dir)..." >&2
SCRATCH=$(npm_scratch_dir @atproto/crypto)
(cd "$SCRATCH" && OUT="$OUT" node -e "
const { Secp256k1Keypair } = require('@atproto/crypto');
const fs = require('fs');
Secp256k1Keypair.create({ exportable: true }).then(async kp => {
  fs.writeFileSync(process.env.OUT, JSON.stringify({
    didKey: kp.did(),
    privHex: Buffer.from(await kp.export()).toString('hex')
  }));
});
")
rm -rf "$SCRATCH"

echo "New server key written to ${OUT}." >&2
echo "did:key => $(jq -r .didKey "$OUT")"
echo >&2
echo "Next: for EACH existing account, run scripts/authorize-plc-rotation-key.sh" >&2
echo "while the server is still signing with the OLD key. Only once every account" >&2
echo "confirms the new key, run scripts/rotate-plc-rotation-key.sh to swap it in." >&2
