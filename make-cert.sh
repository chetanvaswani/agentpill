#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate, "AgentPill Local Signing",
# in your login keychain. build.sh signs with it from then on, so every rebuild keeps the same
# identity and macOS stops forgetting the Accessibility permission.
#
# Run it yourself, once:  ./make-cert.sh
# It asks for your login (keychain) password once, so codesign can use the key without a
# dialog on every build. Nothing leaves this Mac, and the certificate is not added as a trusted
# root: macOS matches the app by the certificate's fingerprint, which needs no trust.
#
# To remove it later: Keychain Access → login → My Certificates → delete "AgentPill Local Signing".
set -euo pipefail

NAME="AgentPill Local Signing"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
KC_PASS="${KC_PASS:-}"              # testing aid: keychain password, instead of asking

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in $(basename "$KEYCHAIN"); nothing to do."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=$(/usr/bin/openssl rand -hex 16)

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# /usr/bin/openssl (LibreSSL) writes a .p12 that `security import` accepts; Homebrew's OpenSSL 3 doesn't by default.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PASS" -out "$WORK/cert.p12"

# -T: codesign may use the key without a keychain prompt on every build.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

# Let Apple's signing tools use the key silently. This is the step that asks for your password.
echo "Enter your login password to let codesign use the new key without asking each build:"
if [ -n "$KC_PASS" ]; then
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" -l "$NAME" "$KEYCHAIN" >/dev/null
else
    security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" "$KEYCHAIN" >/dev/null
fi

echo "Created \"$NAME\". Now run: ./build.sh install"
echo "Then grant Accessibility to AgentPill one last time (remove the old AgentPill entry first)."
