#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [expected-did-key]" >&2
  echo "  Prompts for a private key hex, derives its public did:key, and prints it." >&2
  echo "  If <expected-did-key> is given, compares against it and exits non-zero on mismatch." >&2
  echo "  e.g. $0 did:key:zQ3sh..." >&2
  exit 1
fi

EXPECTED="${1:-}"

read -rsp "Private key hex: " PRIV_HEX
echo >&2

echo "Deriving did:key (installing @atproto/crypto in a scratch dir)..." >&2
SCRATCH=$(npm_scratch_dir @atproto/crypto)
DERIVED=$(cd "$SCRATCH" && PRIV_HEX="$PRIV_HEX" node -e "
const { Secp256k1Keypair } = require('@atproto/crypto');
Secp256k1Keypair.import(process.env.PRIV_HEX).then(kp => console.log(kp.did()));
")
rm -rf "$SCRATCH"

echo "did:key => ${DERIVED}"

if [[ -n "$EXPECTED" ]]; then
  if [[ "$DERIVED" == "$EXPECTED" ]]; then
    echo "MATCH" >&2
  else
    echo "MISMATCH (expected ${EXPECTED})" >&2
    exit 1
  fi
fi
