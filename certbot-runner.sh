#!/usr/bin/env bash
set -euo pipefail

# Run under supervisord to manage issuance and renewals conditionally.
# Domain is now read from /etc/ssl_certificate_host.txt file

DOMAIN_FILE="/etc/ssl_certificate_host.txt"

# Read domain from file
if [[ -f "$DOMAIN_FILE" ]]; then
  TLS_DOMAIN=$(cat "$DOMAIN_FILE" | tr -d '[:space:]')
else
  TLS_DOMAIN=""
fi

if [[ -z "$TLS_DOMAIN" ]]; then
  echo "[certbot] No domain configured in $DOMAIN_FILE; sleeping indefinitely."
  exec sleep infinity
fi

CERT_LIVE_DIR="/etc/letsencrypt/live/${TLS_DOMAIN}"
FULLCHAIN_PATH="${CERT_LIVE_DIR}/fullchain.pem"
PRIVKEY_PATH="${CERT_LIVE_DIR}/privkey.pem"
LINK_CERT="/etc/ssl/${TLS_DOMAIN}.pem"
LINK_KEY="/etc/ssl/${TLS_DOMAIN}.key"

ensure_links_and_reload() {
  # Ensure predictable symlinks and reload vector on success
  if [[ -f "$FULLCHAIN_PATH" && -f "$PRIVKEY_PATH" ]]; then
    ln -sf "$FULLCHAIN_PATH" "$LINK_CERT"
    ln -sf "$PRIVKEY_PATH" "$LINK_KEY"
    # Make both cert and key readable by Vector (running as root in container)
    chmod 0644 "$LINK_CERT" || true
    chmod 0644 "$LINK_KEY" || true
    echo "[certbot] Updated symlinks at $LINK_CERT and $LINK_KEY with permissions 0644"
    # Ask Vector to reload config without restart
    if supervisorctl -c /etc/supervisor/conf.d/supervisord.conf signal HUP vector; then
      echo "[certbot] Sent HUP to Vector for reload."
    else
      echo "[certbot] WARNING: Failed to signal Vector for reload - Vector may need manual restart"
    fi
  fi
}

has_valid_cert() {
  # Valid if certificate exists and is not expired now
  if [[ ! -f "$FULLCHAIN_PATH" ]]; then
    return 1
  fi
  if openssl x509 -in "$FULLCHAIN_PATH" -noout -checkend 0 >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

issue_once() {
  echo "[certbot] Attempting initial/repair issuance for ${TLS_DOMAIN}..."
  if certbot certonly \
    --non-interactive \
    --standalone \
    --agree-tos \
    --register-unsafely-without-email \
    --preferred-challenges http \
    -d "$TLS_DOMAIN" \
    --deploy-hook /certbot-deploy-hook.sh; then
    echo "[certbot] Certificate issuance successful"
    return 0
  else
    echo "[certbot] Certificate issuance failed with exit code $?"
    return 1
  fi
}

renew_once() {
  echo "[certbot] Attempting renewal for any due certificates..."
  if certbot renew \
    --non-interactive \
    --deploy-hook /certbot-deploy-hook.sh; then
    echo "[certbot] Renewal check completed successfully"
  else
    echo "[certbot] WARNING: Renewal check failed with exit code $? - will retry next cycle"
  fi
}

echo "[certbot] Domain configured as $TLS_DOMAIN from $DOMAIN_FILE; managing certificates."

# Always attempt issuance immediately on startup/restart if cert doesn't exist
# This handles the case where domain just changed and we need to get a cert quickly
if ! has_valid_cert; then
  echo "[certbot] No valid certificate found. Attempting immediate issuance..."
  if issue_once; then
    echo "[certbot] Certificate obtained successfully."
    ensure_links_and_reload
  else
    echo "[certbot] Initial issuance attempt failed. Will retry every 10 minutes."
  fi
fi

if has_valid_cert; then
  echo "[certbot] Valid certificate found. Starting 6-hour renewal check cycle."
  ensure_links_and_reload
  while true; do
    sleep 6h
    echo "[certbot] Running scheduled renewal check..."
    renew_once
    ensure_links_and_reload
  done
else
  echo "[certbot] No valid certificate found. Will attempt issuance every 10 minutes until successful."
  until issue_once; do
    echo "[certbot] Waiting 10 minutes before next issuance attempt..."
    sleep 10m
  done
  echo "[certbot] Initial certificate obtained. Switching to 6-hour renewal check cycle."
  ensure_links_and_reload
  while true; do
    sleep 6h
    echo "[certbot] Running scheduled renewal check..."
    renew_once
    ensure_links_and_reload
  done
fi

