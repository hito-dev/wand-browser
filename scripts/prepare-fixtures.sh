#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p tests/.certificates
chmod 700 tests/.certificates
if [ ! -f tests/.certificates/server.pem ]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 7 \
    -keyout tests/.certificates/ca.key -out tests/.certificates/ca.pem \
    -subj '/CN=Hito Wand Local Fixture CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign'
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout tests/.certificates/server.key -out tests/.certificates/server.csr \
    -subj '/CN=localhost'
  cat > tests/.certificates/server.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1
EOF
  openssl x509 -req -sha256 -days 7 -in tests/.certificates/server.csr \
    -CA tests/.certificates/ca.pem -CAkey tests/.certificates/ca.key -CAcreateserial -CAserial tests/.certificates/ca.srl \
    -extfile tests/.certificates/server.ext -out tests/.certificates/server.pem
  chmod 600 tests/.certificates/*.key
fi
openssl x509 -checkend 60 -noout -in tests/.certificates/server.pem
if [ "$#" -gt 0 ]; then
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b
  xcrun simctl keychain "$1" add-root-cert tests/.certificates/ca.pem
fi
