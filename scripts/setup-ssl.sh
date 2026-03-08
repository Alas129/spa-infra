#!/bin/bash
set -euo pipefail

DOMAIN="qa.spaqa.fit"
EMAIL="admin@spaqa.fit"

echo "Setting up SSL for ${DOMAIN}"

# Install certbot (Amazon Linux 2023)
sudo yum install -y augeas-libs
sudo python3 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install certbot certbot-nginx

# Stop any running containers that use port 80
docker compose -f ~/qa-deploy/docker-compose.yml down 2>/dev/null || true

# Obtain certificate (standalone mode)
sudo /opt/certbot/bin/certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

echo "Certificate obtained!"
echo "  Cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
echo "  Key:  /etc/letsencrypt/live/${DOMAIN}/privkey.pem"

# Setup auto-renewal via cron (renew at 3 AM, restart frontend after)
(crontab -l 2>/dev/null; echo "0 3 * * * /opt/certbot/bin/certbot renew --quiet --pre-hook 'docker stop \$(docker ps -q --filter name=frontend)' --post-hook 'docker start \$(docker ps -aq --filter name=frontend)'") | crontab -

echo "Auto-renewal cron job configured."
echo ""
echo "Now update the frontend nginx config to use the SSL cert"
echo "and restart the containers."
