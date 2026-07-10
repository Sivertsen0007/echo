#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity for Echo.
#
# Why: build.sh previously ad-hoc signed (`codesign -s -`), which produces a new
# code identity on every build. macOS ties Accessibility/Microphone (TCC) grants
# to the code identity, so every rebuild lost the permissions. Signing with a
# stable self-signed certificate keeps one identity across rebuilds, so you grant
# permissions once and they persist. Local, self-signed, this machine only - no
# Apple Developer account involved.
#
# Run once:  bash scripts/setup-signing.sh
set -euo pipefail

CERT_NAME="Echo Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Signing identity '$CERT_NAME' already exists - nothing to do."
  security find-identity -p codesigning | grep "$CERT_NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Echo Local Signing
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CERT_NAME" -out "$TMP/echo.p12" -passout pass:echo

# -A lets codesign use the key without a per-run keychain prompt.
security import "$TMP/echo.p12" -k "$KEYCHAIN" -P echo -A

echo ""
echo "Done. Signing identities:"
security find-identity -p codesigning | grep "$CERT_NAME"
echo ""
echo "Next: ./install.sh   (builds, signs with this identity, installs to /Applications/Echo.app)"
