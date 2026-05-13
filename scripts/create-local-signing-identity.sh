#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${BARNOWL_LOCAL_CODESIGN_IDENTITY:-Barn Owl Local Code Signing}"
KEYCHAIN="${BARNOWL_LOCAL_CODESIGN_KEYCHAIN:-$(security default-keychain -d user | tr -d '"')}"
DAYS="${BARNOWL_LOCAL_CODESIGN_DAYS:-3650}"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "$IDENTITY_NAME"; then
  echo "local_codesign_identity_exists=true"
  echo "identity=$IDENTITY_NAME"
  echo "keychain=$KEYCHAIN"
  exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-local-codesign.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

OPENSSL_CONFIG="$WORK_DIR/openssl.cnf"
KEY_PATH="$WORK_DIR/local-codesign.key"
CERT_PATH="$WORK_DIR/local-codesign.crt"
P12_PATH="$WORK_DIR/local-codesign.p12"

cat >"$OPENSSL_CONFIG" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = codesign_ext

[ req_distinguished_name ]
CN = $IDENTITY_NAME

[ codesign_ext ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req \
  -newkey rsa:3072 \
  -nodes \
  -keyout "$KEY_PATH" \
  -x509 \
  -days "$DAYS" \
  -out "$CERT_PATH" \
  -config "$OPENSSL_CONFIG" \
  -sha256 >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -inkey "$KEY_PATH" \
  -in "$CERT_PATH" \
  -out "$P12_PATH" \
  -name "$IDENTITY_NAME" \
  -passout pass: >/dev/null 2>&1

security import "$P12_PATH" \
  -k "$KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERT_PATH" >/dev/null

echo "local_codesign_identity_created=true"
echo "identity=$IDENTITY_NAME"
echo "keychain=$KEYCHAIN"
echo "next=BARNOWL_CODESIGN_IDENTITY=\"$IDENTITY_NAME\" BARNOWL_ALLOW_LOCAL_SIGNED_UPDATE=1 scripts/publish-git-update.sh"
