#!/bin/bash
set -euo pipefail

# Update system
yum update -y

# Install Docker
yum install -y docker
systemctl enable docker
systemctl start docker

# Install Docker Compose as CLI plugin
COMPOSE_VERSION="v2.24.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Also make it available for ec2-user
mkdir -p /home/ec2-user/.docker/cli-plugins
cp /usr/local/lib/docker/cli-plugins/docker-compose /home/ec2-user/.docker/cli-plugins/docker-compose
chown -R ec2-user:ec2-user /home/ec2-user/.docker

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Install AWS CLI (already on Amazon Linux 2023, but ensure latest)
yum install -y aws-cli

# Install curl, jq, and cronie (for certbot auto-renewal)
yum install -y curl jq cronie
systemctl enable crond
systemctl start crond
