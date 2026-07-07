#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <hostname>" >&2
  echo "  e.g. $0 yourdomain.com" >&2
  exit 1
fi

HOSTNAME="$1"

cursor=""
while :; do
  url="https://${HOSTNAME}/xrpc/com.atproto.sync.listRepos?limit=100"
  if [[ -n "$cursor" ]]; then
    url="${url}&cursor=${cursor}"
  fi

  page=$(curl -s "$url")
  cursor=$(echo "$page" | jq -r '.cursor // empty')

  # active/status/rev come from this same listRepos response, no extra call
  # needed; handle still requires a separate describeRepo lookup per account.
  echo "$page" | jq -c '.repos[]' | while read -r repo; do
    did=$(echo "$repo" | jq -r '.did')
    active=$(echo "$repo" | jq -r '.active // false')
    rev=$(echo "$repo" | jq -r '.rev')

    # `status` is only populated by the server for inactive accounts, so an
    # absent value is ambiguous between "active" and "inactive, no reason
    # given" - disambiguate explicitly rather than printing a bare "-" for both.
    if [[ "$active" == "true" ]]; then
      status="active"
    else
      status=$(echo "$repo" | jq -r '.status // "unspecified"')
    fi

    handle=$(curl -s "https://${HOSTNAME}/xrpc/com.atproto.repo.describeRepo?repo=${did}" \
      | jq -r '.handle')

    echo "${handle}  ${did}  active=${active}  status=${status}  rev=${rev}"
  done

  [[ -z "$cursor" ]] && break
done
