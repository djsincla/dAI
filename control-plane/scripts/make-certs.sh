#!/bin/bash
# Development certificate authority for mTLS.
#
# TLS is on from the first deployment, including locally, because a local
# plaintext start grows an unauthenticated dispatch endpoint that is hard to
# close later. These are development certificates: production issues node
# certificates at enrollment approval, against keys generated on-device in the
# Secure Enclave and marked non-exportable.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs && cd certs

if [ -f ca.crt ]; then echo "certs already present; delete certs/ to regenerate"; exit 0; fi

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout ca.key -out ca.crt -subj "/CN=dAI dev CA" 2>/dev/null

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -sha256 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1") 2>/dev/null

# One node certificate, so an agent can be pointed at a local control plane.
openssl req -newkey rsa:2048 -nodes -keyout node.key -out node.csr \
  -subj "/CN=dev-node" 2>/dev/null
openssl x509 -req -in node.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out node.crt -days 365 -sha256 2>/dev/null

rm -f server.csr node.csr
echo "wrote certs/{ca,server,node}.{crt,key}"
echo "node fingerprint (sha256):"
openssl x509 -in node.crt -noout -fingerprint -sha256 | cut -d= -f2
