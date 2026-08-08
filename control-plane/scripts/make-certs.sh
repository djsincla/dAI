#!/bin/bash
# Server TLS material for the control plane.
#
# Distinct from the node CA (src/lib/ca.ts), which signs agent identities. This
# one proves the control plane is who it says it is. Conflating them would mean
# anything trusted to talk to the fleet could also impersonate a node.
#
# The CA must carry basicConstraints and keyUsage. Without keyUsage a strict
# verifier refuses it outright: Python's TLS stack fails with "CA cert does not
# include key usage extension", which reads like a connectivity problem and is
# not one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs && cd certs

SANS="${SANS:-DNS:localhost,IP:127.0.0.1}"

if [ -f srv-ca.crt ]; then echo "server CA already present; delete certs/srv-ca.* to regenerate"; exit 0; fi

cat > ca.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = dAI server CA
[v3_ca]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout srv-ca.key -out srv-ca.crt -config ca.cnf 2>/dev/null
chmod 600 srv-ca.key

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=dai-control" 2>/dev/null
chmod 600 server.key

openssl x509 -req -in server.csr -CA srv-ca.crt -CAkey srv-ca.key -CAcreateserial \
  -out server.crt -days 365 -sha256 \
  -extfile <(printf "subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth" "$SANS") 2>/dev/null

rm -f server.csr ca.cnf
echo "wrote certs/srv-ca.crt, certs/server.crt, certs/server.key"
echo "SANs: $SANS"
echo
echo "Distribute srv-ca.crt with the join token: a node must be able to verify"
echo "the control plane before it has an identity of its own."
