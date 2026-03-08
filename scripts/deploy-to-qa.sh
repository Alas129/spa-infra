#!/bin/bash
set -euo pipefail

QA_HOST="${QA_EC2_HOST}"
KEY="/tmp/deploy_key"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Deploying to QA EC2: ${QA_HOST}"

# Fetch DB credentials from Secrets Manager
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id spa-app/db-credentials \
  --query SecretString --output text)

DB_HOST=$(echo "$DB_SECRET" | jq -r '.host')
DB_USER=$(echo "$DB_SECRET" | jq -r '.username')
DB_PASS=$(echo "$DB_SECRET" | jq -r '.password')

# Copy QA compose file
scp -o StrictHostKeyChecking=no -i "$KEY" \
  ec2/docker-compose.qa.yml "ec2-user@${QA_HOST}":~/qa-deploy/docker-compose.yml

# Deploy on QA EC2
ssh -o StrictHostKeyChecking=no -i "$KEY" "ec2-user@${QA_HOST}" << EOF
  set -euo pipefail
  cd ~/qa-deploy

  # Login to ECR
  aws ecr get-login-password --region ${AWS_REGION} | \
    docker login --username AWS --password-stdin ${ECR_REGISTRY}

  # Create .env for compose
  cat > .env << ENVFILE
ECR_REGISTRY=${ECR_REGISTRY}
RDS_ENDPOINT=${DB_HOST}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
ENVFILE

  # Pull latest images and restart
  docker compose pull
  docker compose down
  docker compose up -d

  # Wait and verify
  sleep 15
  curl -sf http://localhost/api/health || {
    echo "Health check failed after deploy!"
    exit 1
  }

  echo "QA deployment successful!"
EOF
