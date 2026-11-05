#!/usr/bin/env bash
#
# Shows the captive portal's login form. Run it on the WiFi while logged out of the portal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"
HOST=""
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  HOST="${PORTAL_HOST:-}"
fi

PROBE_URL="http://captive.apple.com/hotspot-detect.html"
OUT="${SCRIPT_DIR}/portal.html"

echo "== 1. Following captive-portal redirect from the probe =="
redirect="$(curl -s -o /dev/null -w '%{redirect_url}' "$PROBE_URL")"
if [[ -n "$redirect" ]]; then
  echo "Portal redirects you to: $redirect"
  if [[ -z "$HOST" ]]; then
    HOST="${redirect#*://}"
    HOST="${HOST%%/*}"
  fi
else
  echo "No redirect seen - you may already be logged in, or the portal uses JS/meta refresh."
fi

if [[ -z "$HOST" ]]; then
  echo "Set PORTAL_HOST in $CONFIG_FILE to the portal's address and run again."
  exit 1
fi

echo
echo "== 2. Downloading portal page http://${HOST}/ =="
if curl -sL -m 8 "http://${HOST}/" -o "$OUT" && [[ -s "$OUT" ]]; then
  echo "Saved to $OUT"
else
  echo "WARNING: could not download http://${HOST}/ - the portal may be"
  echo "         unreachable or you may not be on this network. The analysis"
  echo "         below will be empty or stale."
fi

echo
echo "== 3. Form actions found =="
{ grep -oiE '<form[^>]*action="[^"]*"[^>]*>' "$OUT" || echo "(none - open $OUT manually)"; } | cat -v

echo
echo "== 4. Input / hidden fields found =="
{ grep -oiE '<input[^>]*name="[^"]*"[^>]*>' "$OUT" || echo "(none found)"; } | cat -v

echo
if grep -qiE 'name="(challenge|chap-id|chap-challenge)"' "$OUT"; then
  echo "!! This looks like a MikroTik CHAP (MD5 challenge) portal."
  echo "   The password must be hashed as md5(chap-id + password + challenge)."
  echo "   The app does not support this yet."
else
  echo "Looks like a plain POST login (username/password sent directly)."
fi

echo
echo "Next: open the app's Settings, choose Portal, and set Login URL to the form action"
echo "as an absolute URL. Hidden fields go in the advanced Extra form fields."
