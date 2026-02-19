#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/create-self-signed-tls.sh example.com hello-tls

DOMAIN="${1:-example.com}"
SECRET_NAME="${2:-hello-tls}"
TMPDIR=$(mktemp -d)

echo "Generating self-signed cert for $DOMAIN"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$TMPDIR/tls.key" -out "$TMPDIR/tls.crt" \
  -subj "/CN=$DOMAIN/O=$DOMAIN"

echo "Creating Kubernetes TLS secret $SECRET_NAME in current namespace"
kubectl create secret tls "$SECRET_NAME" --cert="$TMPDIR/tls.crt" --key="$TMPDIR/tls.key"

rm -rf "$TMPDIR"
echo "Created secret: $SECRET_NAME (domain: $DOMAIN)"
