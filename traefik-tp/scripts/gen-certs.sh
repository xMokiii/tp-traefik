#!/usr/bin/env bash
# Génère une autorité de certification locale (CA de labo) et un certificat
# serveur pour app1.localhost / app2.localhost signé par cette CA.
# Les fichiers restent dans ./certs (exclu de Git via .gitignore).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash sous Windows : ne pas convertir "/CN=..."

cd "$(dirname "$0")/../certs"

# 1. CA locale
openssl req -x509 -newkey rsa:4096 -sha256 -days 30 -nodes \
  -keyout ca.key -out ca.crt -subj "/CN=DevTech Lab Local CA"

# 2. Clé + CSR serveur
openssl req -newkey rsa:2048 -nodes -keyout localhost.key -out localhost.csr \
  -subj "/CN=app1.localhost"

# 3. Certificat serveur signé par la CA, avec SAN
cat > san.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:app1.localhost,DNS:app2.localhost
EOF
openssl x509 -req -in localhost.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out localhost.crt -days 30 -sha256 -extfile san.ext

rm -f localhost.csr san.ext ca.srl
chmod 600 ca.key localhost.key
echo "OK : certs/ca.crt (à faire confiance côté client), certs/localhost.crt|key (Traefik)"
