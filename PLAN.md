# Mid-Term: Deploy an SPA to AWS EC2 — Nightly Builds (QA Testing)

## Table of Contents

- [Overview](#overview)
- [Architecture Diagram](#architecture-diagram)
- [Repository Strategy](#repository-strategy)
- [Phase 1: Source Repo (spa-app)](#phase-1-source-repo-spa-app)
- [Phase 2: Day 1 Manual AWS Setup (No IaC)](#phase-2-day-1-manual-aws-setup-no-iac)
- [Phase 3: Infrastructure Repo (spa-infra)](#phase-3-infrastructure-repo-spa-infra)
- [Phase 4: Domain Name and SSL](#phase-4-domain-name-and-ssl)
- [Phase 5: Blog Tutorial](#phase-5-blog-tutorial)
- [Security Checklist](#security-checklist)
- [Implementation Timeline](#implementation-timeline)

---

## Overview

Build and deploy a simple SPA (frontend + backend + MySQL) to AWS EC2 using a
nightly CI/CD pipeline. The pipeline spins up a temporary EC2 for smoke testing,
pushes verified images to ECR, and deploys to a pre-allocated QA EC2. The domain
is managed via Route 53 and SSL is handled at the frontend (nginx) level using
Let's Encrypt — no ELB or API Gateway.

### Key Constraints

- MySQL lives in RDS (set up manually on day 1, no IaC)
- Two separate repos: source code vs infrastructure
- Local development uses Docker Compose with a local MySQL container
- Nightly builds use a temporary/dynamic EC2 for verification
- SSL via Let's Encrypt on the EC2 itself (no ELB, no API Gateway)
- Domain purchased at Name.com, DNS migrated to Route 53

---

## Architecture Diagram

```
GitHub Actions (Nightly Cron)
  |
  |  1. Clone both repos
  |  2. Launch temp EC2 (dynamic)
  |  3. Deploy app to temp EC2
  |  4. Run smoke tests
  |  5. If pass: build images, push to ECR
  |  6. Deploy to QA EC2 from ECR
  |  7. Terminate temp EC2
  |
  v
+---------------------------------------------------------------+
|                        AWS Cloud                              |
|                                                               |
|  +-------------+     +----------------+     +---------------+ |
|  | ECR         |     | QA EC2         |     | RDS MySQL     | |
|  | - frontend  |---->| (pre-allocated)|---->| (private      | |
|  | - backend   |     | Docker Compose |     |  subnet)      | |
|  +-------------+     +-------+--------+     +---------------+ |
|                              |                                |
|        +---------------------+                                |
|        |                                                      |
|  Route 53: qa.yourdomain.com --> QA EC2 Elastic IP            |
|  Let's Encrypt SSL on nginx (port 443)                        |
|                                                               |
|  +------------------+                                         |
|  | Temp EC2         |  (ephemeral, created per nightly run)   |
|  | (smoke testing)  |                                         |
|  +------------------+                                         |
+---------------------------------------------------------------+
```

---

## Repository Strategy

Two repos enforce separation of concerns:

| Repo | Purpose | Contains |
|------|---------|----------|
| `spa-app` (source) | Application code | Frontend, backend, Dockerfiles, docker-compose for local dev |
| `spa-infra` (infra) | Deployment and CI/CD | GitHub Actions workflow, deploy scripts, EC2 user-data, QA compose file |

### Why separate?

- App developers work in `spa-app` without touching infra
- Infra changes (workflow tweaks, new scripts) don't pollute the app history
- Different access controls: devs get source repo, ops get infra repo
- Each repo has its own CI triggers and lifecycle

---

## Phase 1: Source Repo (spa-app)

### 1.1 Folder Structure

```
spa-app/
├── frontend/
│   ├── index.html            # Simple HTML SPA
│   ├── styles.css
│   ├── app.js                # Simple vanilla JS (fetch calls to /api)
│   ├── Dockerfile
│   └── nginx.conf            # SPA routing + reverse proxy to backend
├── backend/
│   ├── server.js             # Node.js/Express API (simple endpoints)
│   ├── package.json
│   ├── package-lock.json
│   ├── init.sql              # DB schema seed
│   ├── Dockerfile
│   └── .env.example
├── docker-compose.yml        # Local dev: frontend + backend + MySQL
├── .env.example
├── .dockerignore
├── .gitignore
└── README.md
```

### 1.2 Frontend

Simple HTML/CSS/JS SPA. No frameworks. The frontend:

- Serves static files via nginx
- Uses `fetch()` to call `/api/*` endpoints
- Nginx handles SPA routing (`try_files $uri $uri/ /index.html`)
- Nginx reverse-proxies `/api/` to the backend container

#### Frontend Dockerfile

```dockerfile
FROM nginx:1.25-alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy static files
COPY index.html /usr/share/nginx/html/
COPY styles.css /usr/share/nginx/html/
COPY app.js /usr/share/nginx/html/

# Run as non-root
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost/ || exit 1
```

#### nginx.conf (Local / HTTP only)

```nginx
server {
    listen 80;
    server_name localhost;

    root /usr/share/nginx/html;
    index index.html;

    # SPA routing: all paths serve index.html
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Reverse proxy API calls to backend
    location /api/ {
        proxy_pass http://backend:3000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 1.3 Backend

Simple Node.js + Express API with MySQL connection.

#### Key Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Returns `{ "status": "ok", "db": "connected" }` |
| GET | `/api/items` | List all items from DB |
| POST | `/api/items` | Create a new item |

#### Backend Dockerfile

```dockerfile
FROM node:20-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package.json package-lock.json ./
RUN npm ci --only=production

# Copy application code
COPY . .

# Non-root user
USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:3000/api/health || exit 1

CMD ["node", "server.js"]
```

### 1.4 docker-compose.yml (Local Development)

```yaml
version: "3.8"

services:
  frontend:
    build: ./frontend
    ports:
      - "80:80"
    depends_on:
      - backend
    networks:
      - app-net

  backend:
    build: ./backend
    ports:
      - "3000:3000"
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      DB_USER: app_user
      DB_PASSWORD: ${DB_PASSWORD:-localdev123}
      DB_NAME: spa_db
      NODE_ENV: development
    depends_on:
      db:
        condition: service_healthy
    networks:
      - app-net

  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-rootpass123}
      MYSQL_DATABASE: spa_db
      MYSQL_USER: app_user
      MYSQL_PASSWORD: ${DB_PASSWORD:-localdev123}
    ports:
      - "3306:3306"
    volumes:
      - db_data:/var/lib/mysql
      - ./backend/init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - app-net

volumes:
  db_data:

networks:
  app-net:
    driver: bridge
```

### 1.5 .dockerignore

```
node_modules
.env
.git
.gitignore
*.md
docker-compose*.yml
```

### 1.6 .gitignore

```
.env
node_modules/
db_data/
*.log
```

---

## Phase 2: Day 1 Manual AWS Setup (No IaC)

All AWS resources are created manually via the AWS Console on day 1.
Document every step for the blog.

### 2.1 VPC and Networking

1. Use the default VPC or create a new one with:
   - 2 public subnets (for EC2 instances)
   - 2 private subnets (for RDS)
   - Internet Gateway attached
   - Route tables configured

### 2.2 Security Groups

Create three security groups:

| SG Name | Inbound Rules | Purpose |
|---------|---------------|---------|
| `sg-qa-ec2` | TCP 22 (your IP only), TCP 80 (0.0.0.0/0), TCP 443 (0.0.0.0/0) | QA EC2 |
| `sg-temp-ec2` | TCP 22 (GitHub Actions IPs), TCP 80 (GitHub Actions IPs) | Temp EC2 |
| `sg-rds` | TCP 3306 from `sg-qa-ec2` and `sg-temp-ec2` only | RDS MySQL |

### 2.3 RDS MySQL

1. Go to RDS Console > Create Database
2. Settings:
   - Engine: MySQL 8.0
   - Template: Free tier (or Dev/Test)
   - Instance: `db.t3.micro`
   - Storage: 20 GB gp3, encryption enabled
   - Multi-AZ: No (QA environment)
   - VPC: your VPC
   - Subnet group: private subnets
   - Public access: **No**
   - Security group: `sg-rds`
   - Backup retention: 7 days
3. Note the RDS endpoint (e.g., `spa-db.xxxx.us-east-1.rds.amazonaws.com`)
4. Store credentials in **AWS Secrets Manager**:
   ```
   Secret name: spa-app/db-credentials
   Keys: username, password, host, port, dbname
   ```
5. Connect from QA EC2 (or a bastion) and run:
   ```sql
   CREATE DATABASE IF NOT EXISTS spa_db;
   CREATE USER 'app_user'@'%' IDENTIFIED BY '<strong-password>';
   GRANT SELECT, INSERT, UPDATE, DELETE ON spa_db.* TO 'app_user'@'%';
   FLUSH PRIVILEGES;
   ```

### 2.4 ECR Repositories

1. Go to ECR Console > Create Repository (private):
   - `spa-frontend`
   - `spa-backend`
2. Enable **Scan on push** for both (vulnerability scanning)
3. Add lifecycle policy: keep only last 10 images

### 2.5 QA EC2 Instance (Pre-allocated)

1. Launch instance:
   - AMI: Amazon Linux 2023
   - Type: `t3.small`
   - Key pair: create `qa-deploy-key` (save `.pem` securely)
   - VPC: your VPC, public subnet
   - Security group: `sg-qa-ec2`
   - IAM Instance Profile: `ec2-qa-role` (see below)
   - User data: install Docker + Docker Compose (see `ec2/user-data.sh`)
2. Allocate and associate an **Elastic IP**
3. Tag: `Name=qa-ec2`, `Environment=qa`

### 2.6 IAM Configuration

#### GitHub Actions Role (OIDC — no long-lived keys)

1. Go to IAM > Identity Providers > Add Provider
   - Type: OpenID Connect
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. Create IAM Role: `github-actions-deploy`
   - Trust policy: allow GitHub OIDC for your repos
   - Permissions:
     - `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:DescribeInstances`
     - `ec2:CreateTags`
     - `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`,
       `ecr:PutImage`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`,
       `ecr:CompleteLayerUpload`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`
     - `secretsmanager:GetSecretValue` (for DB credentials)
     - `iam:PassRole` (to assign instance profile to temp EC2)

Trust policy example:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/spa-infra:*"
        }
      }
    }
  ]
}
```

#### EC2 Instance Profile: `ec2-qa-role`

- Permissions:
  - `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`
  - `secretsmanager:GetSecretValue`
- Attach to both QA EC2 and temp EC2 instances

---

## Phase 3: Infrastructure Repo (spa-infra)

### 3.1 Folder Structure

```
spa-infra/
├── .github/
│   └── workflows/
│       └── nightly-deploy.yml
├── scripts/
│   ├── smoke-test.sh
│   ├── deploy-to-qa.sh
│   └── setup-ssl.sh
├── ec2/
│   ├── user-data.sh
│   ├── docker-compose.qa.yml
│   └── nginx-ssl.conf
├── .env.example
├── .gitignore
└── README.md
```

### 3.2 EC2 User Data Script

`ec2/user-data.sh` — runs on first boot of any EC2 (temp or QA):

```bash
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
```

### 3.3 QA Docker Compose

`ec2/docker-compose.qa.yml` — used on the QA EC2 (pulls from ECR, connects to RDS):

```yaml
version: "3.8"

services:
  frontend:
    image: ${ECR_REGISTRY}/spa-frontend:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - backend
    restart: unless-stopped
    networks:
      - app-net

  backend:
    image: ${ECR_REGISTRY}/spa-backend:latest
    environment:
      DB_HOST: ${RDS_ENDPOINT}
      DB_PORT: "3306"
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_NAME: spa_db
      NODE_ENV: production
    restart: unless-stopped
    networks:
      - app-net

networks:
  app-net:
    driver: bridge
```

Note: No `db` service here — the backend connects to RDS directly.

### 3.4 Nginx SSL Config

`ec2/nginx-ssl.conf` — replaces the default nginx config on QA EC2:

```nginx
server {
    listen 80;
    server_name qa.yourdomain.com;

    # Redirect all HTTP to HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name qa.yourdomain.com;

    # Let's Encrypt certificates
    ssl_certificate     /etc/letsencrypt/live/qa.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/qa.yourdomain.com/privkey.pem;

    # SSL hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';" always;

    root /usr/share/nginx/html;
    index index.html;

    # SPA routing
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Reverse proxy to backend
    location /api/ {
        proxy_pass http://backend:3000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 3.5 Nightly Deployment Workflow

`.github/workflows/nightly-deploy.yml`:

```yaml
name: Nightly QA Deploy

on:
  schedule:
    - cron: "0 3 * * *"   # 3:00 AM UTC every night
  workflow_dispatch:        # Allow manual trigger

permissions:
  id-token: write          # Required for OIDC
  contents: read

env:
  AWS_REGION: us-east-1
  AWS_ACCOUNT_ID: "123456789012"       # Replace with your account ID
  ECR_FRONTEND: spa-frontend
  ECR_BACKEND: spa-backend
  QA_EC2_HOST: qa.yourdomain.com
  TEMP_EC2_AMI: ami-0abcdef1234567890  # Amazon Linux 2023 AMI
  TEMP_EC2_TYPE: t3.micro
  TEMP_EC2_SG: sg-xxxxxxxxxxxxxxxxx
  TEMP_EC2_SUBNET: subnet-xxxxxxxxxxxxxxxxx
  TEMP_EC2_KEY: qa-deploy-key
  TEMP_EC2_PROFILE: ec2-qa-role

jobs:
  nightly-deploy:
    runs-on: ubuntu-latest
    steps:

      # ── Checkout ──────────────────────────────────────────────
      - name: Checkout infra repo
        uses: actions/checkout@v4

      - name: Checkout source repo
        uses: actions/checkout@v4
        with:
          repository: YOUR_ORG/spa-app
          path: spa-app
          token: ${{ secrets.SOURCE_REPO_PAT }}

      # ── AWS Authentication (OIDC) ────────────────────────────
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ env.AWS_ACCOUNT_ID }}:role/github-actions-deploy
          aws-region: ${{ env.AWS_REGION }}

      # ── Step 1: Launch Temporary EC2 ─────────────────────────
      - name: Launch temporary EC2 for smoke testing
        id: temp-ec2
        run: |
          INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$TEMP_EC2_AMI" \
            --instance-type "$TEMP_EC2_TYPE" \
            --key-name "$TEMP_EC2_KEY" \
            --security-group-ids "$TEMP_EC2_SG" \
            --subnet-id "$TEMP_EC2_SUBNET" \
            --iam-instance-profile Name="$TEMP_EC2_PROFILE" \
            --user-data file://ec2/user-data.sh \
            --tag-specifications \
              'ResourceType=instance,Tags=[{Key=Name,Value=temp-nightly-verify},{Key=Purpose,Value=smoke-test}]' \
            --query 'Instances[0].InstanceId' \
            --output text)

          echo "instance_id=$INSTANCE_ID" >> "$GITHUB_OUTPUT"
          echo "Launched temp EC2: $INSTANCE_ID"

          # Wait until running
          aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

          # Get public IP
          PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)

          echo "public_ip=$PUBLIC_IP" >> "$GITHUB_OUTPUT"
          echo "Temp EC2 IP: $PUBLIC_IP"

      # ── Step 2: Wait for EC2 to be ready ─────────────────────
      - name: Wait for SSH on temp EC2
        run: |
          echo "${{ secrets.EC2_SSH_PRIVATE_KEY }}" > /tmp/deploy_key
          chmod 600 /tmp/deploy_key

          for i in $(seq 1 30); do
            if ssh -o StrictHostKeyChecking=no \
                   -o ConnectTimeout=5 \
                   -i /tmp/deploy_key \
                   ec2-user@${{ steps.temp-ec2.outputs.public_ip }} \
                   "echo ready" 2>/dev/null; then
              echo "SSH is ready"
              break
            fi
            echo "Waiting for SSH... attempt $i/30"
            sleep 10
          done

      # ── Step 3: Deploy to temp EC2 ───────────────────────────
      - name: Deploy app to temp EC2
        run: |
          REMOTE="ec2-user@${{ steps.temp-ec2.outputs.public_ip }}"
          KEY="/tmp/deploy_key"

          # Copy source code
          scp -o StrictHostKeyChecking=no -i "$KEY" \
            -r spa-app "$REMOTE":~/app

          # Fetch DB credentials from Secrets Manager
          DB_SECRET=$(aws secretsmanager get-secret-value \
            --secret-id spa-app/db-credentials \
            --query SecretString --output text)

          DB_HOST=$(echo "$DB_SECRET" | jq -r '.host')
          DB_USER=$(echo "$DB_SECRET" | jq -r '.username')
          DB_PASS=$(echo "$DB_SECRET" | jq -r '.password')

          # Create .env on remote
          ssh -o StrictHostKeyChecking=no -i "$KEY" "$REMOTE" << EOF
            cd ~/app
            cat > .env << ENVFILE
          DB_HOST=$DB_HOST
          DB_PORT=3306
          DB_USER=$DB_USER
          DB_PASSWORD=$DB_PASS
          DB_NAME=spa_db
          NODE_ENV=production
          ENVFILE
            docker compose up -d --build
          EOF

      # ── Step 4: Smoke Tests ──────────────────────────────────
      - name: Run smoke tests
        id: smoke
        run: |
          chmod +x scripts/smoke-test.sh
          scripts/smoke-test.sh "${{ steps.temp-ec2.outputs.public_ip }}"

      # ── Step 5: Build and Push to ECR ────────────────────────
      - name: Login to Amazon ECR
        if: steps.smoke.outcome == 'success'
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push container images to ECR
        if: steps.smoke.outcome == 'success'
        run: |
          ECR_REGISTRY="${{ steps.login-ecr.outputs.registry }}"
          TAG="$(date +%Y%m%d)-$(git -C spa-app rev-parse --short HEAD)"

          # Build frontend
          docker build -t "$ECR_REGISTRY/$ECR_FRONTEND:$TAG" spa-app/frontend/
          docker build -t "$ECR_REGISTRY/$ECR_BACKEND:$TAG" spa-app/backend/

          # Tag as latest
          docker tag "$ECR_REGISTRY/$ECR_FRONTEND:$TAG" "$ECR_REGISTRY/$ECR_FRONTEND:latest"
          docker tag "$ECR_REGISTRY/$ECR_BACKEND:$TAG" "$ECR_REGISTRY/$ECR_BACKEND:latest"

          # Push all
          docker push "$ECR_REGISTRY/$ECR_FRONTEND:$TAG"
          docker push "$ECR_REGISTRY/$ECR_FRONTEND:latest"
          docker push "$ECR_REGISTRY/$ECR_BACKEND:$TAG"
          docker push "$ECR_REGISTRY/$ECR_BACKEND:latest"

          echo "Pushed images with tag: $TAG"

      # ── Step 6: Deploy to QA EC2 ─────────────────────────────
      - name: Deploy to QA EC2
        if: steps.smoke.outcome == 'success'
        run: |
          chmod +x scripts/deploy-to-qa.sh
          scripts/deploy-to-qa.sh

      # ── Step 7: Teardown Temp EC2 (always runs) ──────────────
      - name: Terminate temporary EC2
        if: always()
        run: |
          if [ -n "${{ steps.temp-ec2.outputs.instance_id }}" ]; then
            aws ec2 terminate-instances \
              --instance-ids "${{ steps.temp-ec2.outputs.instance_id }}"
            echo "Terminated temp EC2: ${{ steps.temp-ec2.outputs.instance_id }}"
          fi

      # ── Cleanup ──────────────────────────────────────────────
      - name: Cleanup SSH key
        if: always()
        run: rm -f /tmp/deploy_key
```

### 3.6 Smoke Test Script

`scripts/smoke-test.sh`:

```bash
#!/bin/bash
set -euo pipefail

TARGET_IP="$1"
BASE_URL="http://${TARGET_IP}"
MAX_RETRIES=30
RETRY_INTERVAL=10

echo "============================================"
echo "  Smoke Tests against ${BASE_URL}"
echo "============================================"

# Wait for the app to be ready
echo ""
echo "[WAIT] Waiting for app to become ready..."
for i in $(seq 1 "$MAX_RETRIES"); do
  if curl -sf "${BASE_URL}/api/health" > /dev/null 2>&1; then
    echo "[READY] App is responding."
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "[FAIL] App did not become ready after $((MAX_RETRIES * RETRY_INTERVAL))s"
    exit 1
  fi
  echo "  Attempt $i/$MAX_RETRIES — retrying in ${RETRY_INTERVAL}s..."
  sleep "$RETRY_INTERVAL"
done

PASS=0
FAIL=0

# Test 1: Frontend returns 200
echo ""
echo "[TEST 1] Frontend serves index page"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  PASS — HTTP $HTTP_CODE"
  PASS=$((PASS + 1))
else
  echo "  FAIL — HTTP $HTTP_CODE (expected 200)"
  FAIL=$((FAIL + 1))
fi

# Test 2: API health endpoint returns 200
echo ""
echo "[TEST 2] API health endpoint"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/health")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  PASS — HTTP $HTTP_CODE"
  PASS=$((PASS + 1))
else
  echo "  FAIL — HTTP $HTTP_CODE (expected 200)"
  FAIL=$((FAIL + 1))
fi

# Test 3: API health reports DB connected
echo ""
echo "[TEST 3] Database connectivity via health endpoint"
RESPONSE=$(curl -sf "${BASE_URL}/api/health" || echo '{}')
if echo "$RESPONSE" | grep -q '"db".*"connected"'; then
  echo "  PASS — DB is connected"
  PASS=$((PASS + 1))
else
  echo "  FAIL — DB not connected. Response: $RESPONSE"
  FAIL=$((FAIL + 1))
fi

# Test 4: API items endpoint returns 200
echo ""
echo "[TEST 4] API items endpoint"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/items")
if [ "$HTTP_CODE" = "200" ]; then
  echo "  PASS — HTTP $HTTP_CODE"
  PASS=$((PASS + 1))
else
  echo "  FAIL — HTTP $HTTP_CODE (expected 200)"
  FAIL=$((FAIL + 1))
fi

# Summary
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  echo "Smoke tests FAILED."
  exit 1
fi

echo "All smoke tests PASSED."
exit 0
```

### 3.7 Deploy to QA Script

`scripts/deploy-to-qa.sh`:

```bash
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
```

---

## Phase 4: Domain Name and SSL

### 4.1 Purchase Domain at Name.com

1. Go to [Name.com](https://www.name.com)
2. Search for and purchase your domain (e.g., `yourdomain.com`)
3. Note: do NOT configure DNS records at Name.com — we are migrating to Route 53

### 4.2 Create Hosted Zone in Route 53

1. Go to AWS Console > Route 53 > Hosted Zones > Create Hosted Zone
2. Domain name: `yourdomain.com`
3. Type: Public hosted zone
4. Note the 4 NS (nameserver) records that Route 53 assigns, e.g.:
   ```
   ns-123.awsdns-45.com
   ns-678.awsdns-90.net
   ns-111.awsdns-22.org
   ns-333.awsdns-44.co.uk
   ```

### 4.3 Update Nameservers at Name.com

1. Log in to Name.com > My Domains > yourdomain.com > Nameservers
2. Switch from Name.com default nameservers to **Custom**
3. Enter the 4 Route 53 NS records from step 4.2
4. Save changes
5. Wait for propagation (can take up to 48 hours, usually 1-2 hours)
6. Verify: `dig yourdomain.com NS` should return Route 53 nameservers

### 4.4 Create DNS Records in Route 53

| Record Name | Type | Value | TTL |
|-------------|------|-------|-----|
| `qa.yourdomain.com` | A | QA EC2 Elastic IP | 300 |

### 4.5 SSL Setup with Let's Encrypt

Run on the QA EC2 (one-time setup, auto-renews):

`scripts/setup-ssl.sh`:

```bash
#!/bin/bash
set -euo pipefail

DOMAIN="qa.yourdomain.com"
EMAIL="admin@yourdomain.com"

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
```

### 4.6 Switching Frontend to SSL

After SSL is set up, the QA EC2 uses the `nginx-ssl.conf` (from section 3.4)
instead of the default HTTP-only config. The Let's Encrypt directory is
bind-mounted into the frontend container as a read-only volume
(see `docker-compose.qa.yml`).

---

## Security Checklist

### Secrets Management

- [ ] No secrets committed to either repo (`.env` in `.gitignore`)
- [ ] `.env.example` files contain only placeholder values
- [ ] DB credentials stored in AWS Secrets Manager
- [ ] GitHub Actions uses OIDC federation (no long-lived AWS access keys)
- [ ] SSH private key stored in GitHub Secrets, not in repo
- [ ] ECR login uses short-lived tokens via `aws ecr get-login-password`

### Container Security

- [ ] All containers run as non-root users
- [ ] Base images are minimal (Alpine-based)
- [ ] `.dockerignore` excludes `.env`, `.git`, `node_modules`
- [ ] Dependencies are pinned via lock files
- [ ] Health checks defined in Dockerfiles
- [ ] ECR scan-on-push enabled

### Network Security

- [ ] RDS is in a private subnet with no public access
- [ ] RDS security group only allows inbound from EC2 security groups
- [ ] EC2 SSH access restricted to known IPs
- [ ] HTTPS enforced (HTTP redirects to HTTPS)
- [ ] Security headers set in nginx (HSTS, X-Frame-Options, CSP, etc.)
- [ ] SSL uses TLS 1.2+ only

### CI/CD Security

- [ ] Temp EC2 is always terminated (`if: always()`)
- [ ] IAM roles follow least privilege principle
- [ ] GitHub Actions permissions are scoped (`id-token: write`, `contents: read`)
- [ ] Source repo accessed via scoped PAT (not a full-access token)
- [ ] SSH keys cleaned up after workflow runs

### Infrastructure Security

- [ ] EC2 instances use IAM instance profiles (not embedded credentials)
- [ ] Let's Encrypt certificates auto-renew via cron
- [ ] ECR lifecycle policy limits stored images
- [ ] RDS automated backups enabled
- [ ] RDS storage encryption enabled

---

## Implementation Timeline

| Day | Tasks |
|-----|-------|
| **Day 1** | Manual AWS setup: VPC, security groups, RDS, ECR, QA EC2, IAM roles. Purchase domain at Name.com. Create Route 53 hosted zone and migrate nameservers. |
| **Day 2** | Build the source repo (`spa-app`): frontend, backend, Dockerfiles, docker-compose. Test locally with `docker compose up`. |
| **Day 3** | Build the infra repo (`spa-infra`): scripts, user-data, QA compose file. Set up SSL on QA EC2 with Let's Encrypt. |
| **Day 4** | Build and test the GitHub Actions nightly workflow. Iterate until the full pipeline works end-to-end. |
| **Day 5** | Final validation. Security review. Write the blog tutorial. |

---

## Deliverables

1. **`spa-app` repo** — Source code with Dockerfiles and local docker-compose
2. **`spa-infra` repo** — GitHub Actions workflow, deploy scripts, EC2 configs
3. **Running QA environment** — `https://qa.yourdomain.com` with SSL
4. **Blog tutorial** — Step-by-step guide covering the entire process
