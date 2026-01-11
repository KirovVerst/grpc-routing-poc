#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CERTS_DIR="${SCRIPT_DIR}"

echo "Generating self-signed TLS certificates..."

# Generate CA private key
openssl genrsa -out "${CERTS_DIR}/ca-key.pem" 4096

# Generate self-signed CA certificate
openssl req -new -x509 -days 365 -key "${CERTS_DIR}/ca-key.pem" \
    -out "${CERTS_DIR}/ca-cert.pem" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=CA"

# Generate private key for Envoy
openssl genrsa -out "${CERTS_DIR}/key.pem" 4096

# Generate CSR (Certificate Signing Request) for Envoy
openssl req -new -key "${CERTS_DIR}/key.pem" \
    -out "${CERTS_DIR}/cert.csr" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=envoy-ingress.grpc-routing-poc.svc.cluster.local"

# Sign certificate with CA
openssl x509 -req -days 365 -in "${CERTS_DIR}/cert.csr" \
    -CA "${CERTS_DIR}/ca-cert.pem" \
    -CAkey "${CERTS_DIR}/ca-key.pem" \
    -CAcreateserial \
    -out "${CERTS_DIR}/server-cert.pem"

# Create full certificate chain (certificate + CA)
cat "${CERTS_DIR}/server-cert.pem" "${CERTS_DIR}/ca-cert.pem" > "${CERTS_DIR}/cert.pem"

# Remove temporary files
rm -f "${CERTS_DIR}/cert.csr" "${CERTS_DIR}/server-cert.pem"

echo "Certificates generated successfully:"
echo "  CA Certificate: ${CERTS_DIR}/ca-cert.pem"
echo "  CA Key: ${CERTS_DIR}/ca-key.pem"
echo "  Envoy Certificate: ${CERTS_DIR}/cert.pem"
echo "  Envoy Key: ${CERTS_DIR}/key.pem"
