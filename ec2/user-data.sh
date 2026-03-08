#!/bin/bash
set -euo pipefail

# Update system
yum update -y

# Install Docker
yum install -y docker
systemctl enable docker
systemctl start docker

# Install Docker Compose
COMPOSE_VERSION="v2.24.0"
curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Install AWS CLI (already on Amazon Linux 2023, but ensure latest)
yum install -y aws-cli

# Install curl and jq for smoke tests
yum install -y curl jq
