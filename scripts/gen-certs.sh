#!/bin/sh
# Generate a private CA plus server and client certificates for
# ModelMirrors --server --tls (mutual TLS). Plain openssl, no extra tooling.
#
# Usage:
#   scripts/gen-certs.sh <outdir> <server-host-or-ip> [days]
#
# Example:
#   scripts/gen-certs.sh certs 127.0.0.1 30
#
# Produces in <outdir>:
#   ca.crt                CA certificate (distribute to server and clients)
#   ca.key                CA private key (keep offline, do not ship)
#   server.crt/server.key server credentials (SAN = <server-host-or-ip>)
#   client.crt/client.key client credentials (CN=modelmirrors-client)
#
# Renewal: re-run the script with the same arguments before expiry.

set -eu

if [ $# -lt 2 ]; then
  echo "usage: $0 <outdir> <server-host-or-ip> [days]" >&2
  exit 1
fi

OUT=$1
HOST=$2
DAYS=${3:-30}

mkdir -p "$OUT"
cd "$OUT"

case "$HOST" in
  *[!0-9.]*) SAN="DNS:$HOST" ;;
  *)         SAN="IP:$HOST" ;;
esac

if [ ! -f ca.key ]; then
  openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.crt \
    -days "$DAYS" -nodes -subj "/CN=ModelMirrors CA" 2>/dev/null
  echo "generated new CA"
else
  echo "reusing existing CA"
fi

printf "subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" "$SAN" > server.ext
printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n" > client.ext

issue() {
  name=$1
  cn=$2
  ext=$3
  openssl req -newkey rsa:2048 -keyout "$name.key" -out "$name.csr" \
    -nodes -subj "/CN=$cn" 2>/dev/null
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "$name.crt" -days "$DAYS" -extfile "$ext" 2>/dev/null
  chmod 600 "$name.key"
  rm -f "$name.csr"
  echo "generated $name.crt/$name.key (CN=$cn, expires in $DAYS days)"
}

issue server "$HOST" server.ext
issue client "modelmirrors-client" client.ext

chmod 600 ca.key

cat <<EOF

Done. Start the server:

  ModelMirrors --server <port> --tls \\
      --cert $OUT/server.crt --key $OUT/server.key --ca $OUT/ca.crt

Connect a client with ca.crt + client.crt + client.key.
Keep ca.key offline; re-run this script to renew before expiry.
EOF
