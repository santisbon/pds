#!/usr/bin/env bash
# Shared helpers for the scripts in this directory. Not meant to be run
# directly - source it from another script.

# Read a single key out of the chart's generated Secret.
# Usage: k8s_secret <key> [release] [namespace]
k8s_secret() {
  local key="$1" release="${2:-pds}" namespace="${3:-pds}"
  kubectl get secret "$release" -n "$namespace" -o jsonpath="{.data.${key}}" | base64 -d
}

# Create a throwaway npm project with the given packages installed, and print
# its path. @atproto/crypto / @did-plc/lib ship with neither the chart nor the
# PDS image, so scripts needing AT Protocol-specific crypto (did:key encoding,
# PLC operation signing) install them fresh here. Caller is responsible for
# `cd`-ing into the returned directory before requiring the packages, and for
# cleaning it up afterward.
npm_scratch_dir() {
  local dir
  dir=$(mktemp -d)
  (cd "$dir" && npm init -y >/dev/null && npm install --loglevel=error "$@" >/dev/null)
  echo "$dir"
}
