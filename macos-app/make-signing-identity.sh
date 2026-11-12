#!/usr/bin/env bash
# Run once: makes a local code-signing identity, so rebuilds keep Keychain access and Start at Login.
set -euo pipefail
# System tools only, so nothing earlier on a caller's PATH can stand in for openssl or security.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

NAME="AI Meter Bar Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"${NAME}\" already exists; build.sh signs with it."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "${WORK}/identity.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> Making a self-signed code-signing certificate, valid 10 years"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "${WORK}/identity.conf" \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null
# The bundle password lives only for this run; the key ends up in the login keychain.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -name "$NAME" -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
  -out "${WORK}/identity.p12" -passout "pass:${PASS}"

echo "==> Adding it to the login keychain, usable by codesign only"
security import "${WORK}/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "==> Trusting it for code signing (macOS asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "${WORK}/cert.pem"

echo "Done. Rebuild with ./build.sh --no-dmg --install, answer the Keychain prompt once with Always Allow,"
echo "then turn Start at Login on again in Settings, General. Later rebuilds keep both."
