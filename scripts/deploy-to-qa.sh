#!/bin/bash
set -euo pipefail

QA_HOST="${QA_EC2_HOST}"
KEY="/tmp/deploy_key"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SSH="ssh -o StrictHostKeyChecking=no -i $KEY ec2-user@${QA_HOST}"
SCP="scp -o StrictHostKeyChecking=no -i $KEY"

echo "Deploying to QA EC2: ${QA_HOST}"

# Fetch DB credentials from Secrets Manager
DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id spa-app/db-credentials \
  --query SecretString --output text)

# Build .env locally
echo "ECR_REGISTRY=${ECR_REGISTRY}"                          > /tmp/qa.env
echo "RDS_ENDPOINT=$(echo $DB_SECRET | jq -r '.host')"      >> /tmp/qa.env
echo "DB_USER=$(echo $DB_SECRET | jq -r '.username')"       >> /tmp/qa.env
echo "DB_PASSWORD=$(echo $DB_SECRET | jq -r '.password')"   >> /tmp/qa.env

# Create deploy directory and copy files
$SSH "mkdir -p ~/qa-deploy"
$SCP ec2/docker-compose.qa.yml "ec2-user@${QA_HOST}":~/qa-deploy/docker-compose.yml
$SCP /tmp/qa.env "ec2-user@${QA_HOST}":~/qa-deploy/.env

# Deploy on QA EC2
$SSH "cd ~/qa-deploy \
  && aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
  && docker compose pull \
  && docker compose down \
  && docker compose up -d"

# Wait and verify
echo "Waiting 15s for containers to start..."
sleep 15
$SSH "curl -sf http://localhost/api/health" || {
  echo "Health check failed after deploy!"
  exit 1
}

echo "QA deployment successful!"
