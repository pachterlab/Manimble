#!/bin/bash
# Create a self-signed "Manimble Local Signing" code-signing identity in the
# login keychain. build_app.sh signs with it so macOS keeps folder-access
# permissions across rebuilds instead of asking again after each one.
set -euo pipefail
NAME="${MANIMBLE_SIGN_IDENTITY:-Manimble Local Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "identity \"$NAME\" already exists"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:manimble 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/id.p12" -passout pass:manimble
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P manimble -T /usr/bin/codesign >/dev/null
echo "created identity \"$NAME\""
