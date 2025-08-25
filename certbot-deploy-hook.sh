#!/usr/bin/env bash
set -euo pipefail

# Certbot deploy hook - executed after successful certificate issuance or renewal
# This script is called by certbot with the following environment variables:
# - RENEWED_LINEAGE: Path to the live directory of the renewed cert (e.g., /etc/letsencrypt/live/example.com)
# - RENEWED_DOMAINS: Space-separated list of renewed domains

echo "[certbot-deploy] Deploy hook triggered for domains: ${RENEWED_DOMAINS}"

# Extract domain from the lineage path
TLS_DOMAIN="${RENEWED_DOMAINS%% *}"  # Get first domain if multiple
CERT_LIVE_DIR="/etc/letsencrypt/live/${TLS_DOMAIN}"
FULLCHAIN_PATH="${CERT_LIVE_DIR}/fullchain.pem"
PRIVKEY_PATH="${CERT_LIVE_DIR}/privkey.pem"
LINK_CERT="/etc/ssl/${TLS_DOMAIN}.pem"
LINK_KEY="/etc/ssl/${TLS_DOMAIN}.key"

# Create or update symlinks to predictable locations
if [[ -f "$FULLCHAIN_PATH" && -f "$PRIVKEY_PATH" ]]; then
    ln -sf "$FULLCHAIN_PATH" "$LINK_CERT"
    ln -sf "$PRIVKEY_PATH" "$LINK_KEY"
    # Make certificates readable by Vector
    chmod 0644 "$LINK_CERT" || true
    chmod 0644 "$LINK_KEY" || true
    echo "[certbot-deploy] Updated symlinks at $LINK_CERT and $LINK_KEY"
    
    # Signal Vector to reload configuration
    if supervisorctl -c /etc/supervisor/conf.d/supervisord.conf signal HUP vector; then
        echo "[certbot-deploy] Successfully signaled Vector to reload configuration"
    else
        echo "[certbot-deploy] WARNING: Failed to signal Vector for reload - Vector may need manual restart"
        # Don't exit with error - certificate was still successfully obtained/renewed
    fi
else
    echo "[certbot-deploy] ERROR: Certificate files not found at expected locations"
    exit 1
fi

echo "[certbot-deploy] Deploy hook completed successfully"