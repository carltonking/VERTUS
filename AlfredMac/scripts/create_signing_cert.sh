#!/usr/bin/env bash
set -euo pipefail

# Creates a STABLE self-signed code-signing identity in your login keychain so macOS stops
# re-prompting for permissions (Accessibility, Automation, Microphone, etc.) every time Alfred
# is rebuilt.
#
# Why this is needed: build_app.sh used to sign ad-hoc (`codesign --sign -`). An ad-hoc signature
# changes on every build, so macOS treats each rebuild as a brand-new app and forgets all prior
# permission grants. A stable identity keeps the same designated requirement across rebuilds, so
# you grant each permission ONCE and it sticks.
#
# Run this once:  ./scripts/create_signing_cert.sh
# Then rebuild:   ./scripts/build_app.sh --install   (grant permissions one final time)

IDENTITY="${1:-Alfred Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ Code-signing identity '$IDENTITY' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "▶ Generating self-signed code-signing certificate '$IDENTITY' (valid 10 years)…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# Use a real p12 password (empty passwords trip "MAC verification failed" on macOS import) and
# the legacy PKCS12 MAC — OpenSSL 3 defaults to a MAC algorithm Apple's `security` can't read.
# `-legacy` is unknown to LibreSSL (Apple's /usr/bin/openssl), so fall back without it.
P12_PW="alfred-local"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$P12_PW" >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$P12_PW" >/dev/null 2>&1

# Import the key+cert and pre-authorize /usr/bin/codesign to use the private key (the -T flag),
# so codesign never prompts for keychain access during a build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign >/dev/null

# Best-effort: add codesign to the key's partition list (no-op if it needs a keychain password;
# in that case you'll see one "Always Allow" prompt on the first signed build — that's fine).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "✓ Created '$IDENTITY'. Now run: ./scripts/build_app.sh --install"
echo "  Grant each macOS permission one final time on that launch — they will persist afterward."
