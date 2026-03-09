# Building a Nightly CI/CD Pipeline: Deploying a Dockerized SPA to AWS EC2

This tutorial walks through building a complete CI/CD pipeline that deploys a
containerized Single Page Application (frontend + backend + MySQL) to AWS EC2
using GitHub Actions. The pipeline runs nightly, spins up a temporary EC2 for
smoke testing, and promotes to a QA environment only if tests pass.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Repository Structure](#2-repository-structure)
3. [Part A: Build the SPA Application (spa-app)](#3-part-a-build-the-spa-application)
4. [Part B: AWS Infrastructure Setup (spa-infra)](#4-part-b-aws-infrastructure-setup)
5. [Part C: Domain, DNS, and SSL](#5-part-c-domain-dns-and-ssl)
6. [Part D: GitHub Actions CI/CD Pipeline](#6-part-d-github-actions-cicd-pipeline)
7. [Part E: Push to GitHub and Test](#7-part-e-push-to-github-and-test)
8. [Common Pitfalls and Things to Watch Out For](#8-common-pitfalls-and-things-to-watch-out-for)

---

## 1. Architecture Overview

```
                    GitHub Actions (nightly)
                           |
              +------------+------------+
              |                         |
        Launch Temp EC2           (on success)
        Build & Smoke Test        Build Images → ECR
              |                         |
        Terminate Temp EC2        Deploy to QA EC2
                                        |
                                  qa.spaqa.fit
                                   (Nginx + SSL)
                                        |
                                  Backend (Node.js)
                                        |
                                  RDS MySQL
```

**Key design decisions:**

- **Two repositories**: `spa-app` (source code) and `spa-infra` (deployment
  scripts, CI/CD workflow). This separates application concerns from
  infrastructure.
- **Temporary EC2 for smoke testing**: A fresh EC2 is launched each night,
  the app is built and tested on it, then it is terminated. This ensures
  tests run in a clean environment.
- **Pre-allocated QA EC2**: A long-lived EC2 with an Elastic IP and SSL
  certificate serves as the QA environment.
- **RDS MySQL**: The database is hosted on AWS RDS (not in a container) for
  durability and managed backups.
- **OIDC authentication**: GitHub Actions authenticates to AWS using OpenID
  Connect — no long-lived AWS access keys stored in GitHub.
- **Let's Encrypt SSL**: HTTPS is handled at the Nginx level using free
  certificates from Let's Encrypt, without needing an ELB or API Gateway.

---

## 2. Repository Structure

### spa-app (Application Source Code)

```
spa-app/
  frontend/
    index.html          # SPA HTML page
    styles.css          # Styles
    app.js              # Vanilla JS frontend logic
    nginx.conf          # Nginx config (SPA routing + API reverse proxy)
    Dockerfile          # Nginx-based frontend image
  backend/
    server.js           # Express.js API
    package.json        # Node.js dependencies
    package-lock.json   # Locked dependency versions
    init.sql            # Database schema
    Dockerfile          # Node.js backend image
  docker-compose.yml    # Local development (frontend + backend + MySQL)
  .env.example          # Example environment variables
  .gitignore
  .dockerignore
```

### spa-infra (Infrastructure and CI/CD)

```
spa-infra/
  .github/workflows/
    nightly-deploy.yml  # GitHub Actions nightly pipeline
  ec2/
    user-data.sh        # EC2 bootstrap script (Docker, Compose, etc.)
    docker-compose.qa.yml  # QA deployment compose file (pulls from ECR)
    nginx-ssl.conf      # Nginx config with SSL for QA
  scripts/
    smoke-test.sh       # Smoke tests (health, frontend, API, DB)
    deploy-to-qa.sh     # Deploy script for QA EC2
    setup-ssl.sh        # Let's Encrypt SSL setup script
  .env.example
  .gitignore
```

---

## 3. Part A: Build the SPA Application

### 3a. Backend (Node.js + Express)

Create `backend/server.js` — a simple REST API with health check and CRUD
for items:

```javascript
var express = require("express");
var mysql = require("mysql2/promise");

var app = express();
app.use(express.json());

var PORT = 3000;

var pool = mysql.createPool({
    host: process.env.DB_HOST || "db",
    port: parseInt(process.env.DB_PORT || "3306"),
    user: process.env.DB_USER || "app_user",
    password: process.env.DB_PASSWORD || "localdev123",
    database: process.env.DB_NAME || "spa_db",
    waitForConnections: true,
    connectionLimit: 10
});

app.get("/api/health", function (req, res) {
    pool.query("SELECT 1")
        .then(function () {
            res.json({ status: "ok", db: "connected" });
        })
        .catch(function () {
            res.status(500).json({ status: "ok", db: "disconnected" });
        });
});

app.get("/api/items", function (req, res) {
    pool.query("SELECT * FROM items ORDER BY created_at DESC")
        .then(function (result) { res.json(result[0]); })
        .catch(function (err) { res.status(500).json({ error: err.message }); });
});

app.post("/api/items", function (req, res) {
    var name = req.body.name;
    var description = req.body.description || "";
    if (!name) { res.status(400).json({ error: "Name is required" }); return; }
    pool.query("INSERT INTO items (name, description) VALUES (?, ?)", [name, description])
        .then(function (result) {
            res.status(201).json({ id: result[0].insertId, name: name, description: description });
        })
        .catch(function (err) { res.status(500).json({ error: err.message }); });
});

app.listen(PORT, function () { console.log("Backend listening on port " + PORT); });
```

Create `backend/package.json`:

```json
{
  "name": "backend",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "mysql2": "^3.6.0"
  }
}
```

Create `backend/init.sql`:

```sql
CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Create `backend/Dockerfile`:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --only=production
COPY . .
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:3000/api/health || exit 1
CMD ["node", "server.js"]
```

Generate the lock file:

```bash
cd backend && npm install && cd ..
```

### 3b. Frontend (Nginx + Static Files)

Create `frontend/nginx.conf`:

```nginx
server {
    listen 80;
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://backend:3000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Create `frontend/Dockerfile`:

```dockerfile
FROM nginx:1.25-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/
COPY styles.css /usr/share/nginx/html/
COPY app.js /usr/share/nginx/html/
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost/ || exit 1
```

Create `frontend/index.html`, `frontend/styles.css`, and `frontend/app.js`
with your SPA content (a simple form to add items and a list to display them).

### 3c. Docker Compose for Local Development

Create `docker-compose.yml` in the project root:

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

Test locally:

```bash
docker compose up -d --build
curl http://localhost/api/health
# {"status":"ok","db":"connected"}
```

---

## 4. Part B: AWS Infrastructure Setup

All commands use the AWS CLI. Region: `us-west-2`.

### 4a. Install and Configure AWS CLI

```bash
brew install awscli    # macOS
aws configure
# Enter: Access Key ID, Secret Access Key, us-west-2, json
aws sts get-caller-identity
```

### 4b. Identify Default VPC and Subnets

```bash
aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<YOUR_VPC_ID>" \
  --query 'Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone}' \
  --output table
```

### 4c. Create Security Groups

**QA EC2 Security Group** — SSH (your IP), HTTP, HTTPS:

```bash
SG_QA=$(aws ec2 create-security-group \
  --group-name qa-ec2-sg \
  --description "QA EC2 - SSH, HTTP, HTTPS" \
  --vpc-id <YOUR_VPC_ID> \
  --query 'GroupId' --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)/32

aws ec2 authorize-security-group-ingress --group-id "$SG_QA" \
  --protocol tcp --port 22 --cidr "$MY_IP"
aws ec2 authorize-security-group-ingress --group-id "$SG_QA" \
  --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_QA" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0"
```

**Temp EC2 Security Group** — SSH and HTTP from anywhere (GitHub Actions):

```bash
SG_TEMP=$(aws ec2 create-security-group \
  --group-name temp-ec2-sg \
  --description "Temp EC2 - SSH and HTTP for smoke testing" \
  --vpc-id <YOUR_VPC_ID> \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_TEMP" \
  --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_TEMP" \
  --protocol tcp --port 80 --cidr "0.0.0.0/0"
```

**RDS Security Group** — MySQL from EC2 SGs only:

```bash
SG_RDS=$(aws ec2 create-security-group \
  --group-name rds-mysql-sg \
  --description "RDS MySQL - allow from EC2 SGs only" \
  --vpc-id <YOUR_VPC_ID> \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
  --protocol tcp --port 3306 --source-group "$SG_QA"
aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
  --protocol tcp --port 3306 --source-group "$SG_TEMP"
```

### 4d. Create RDS MySQL Instance

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name spa-db-subnet-group \
  --db-subnet-group-description "Subnet group for SPA RDS" \
  --subnet-ids <SUBNET_1> <SUBNET_2>

aws rds create-db-instance \
  --db-instance-identifier spa-db \
  --db-instance-class db.t3.micro \
  --engine mysql --engine-version "8.0" \
  --master-username admin \
  --master-user-password <YOUR_SECURE_PASSWORD> \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --db-subnet-group-name spa-db-subnet-group \
  --vpc-security-group-ids "$SG_RDS" \
  --no-publicly-accessible \
  --backup-retention-period 7 --no-multi-az \
  --db-name spa_db
```

Wait for it to become available (~5-10 min):

```bash
aws rds describe-db-instances \
  --db-instance-identifier spa-db \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}'
```

### 4e. Create ECR Repositories

```bash
aws ecr create-repository --repository-name spa-frontend \
  --image-scanning-configuration scanOnPush=true
aws ecr create-repository --repository-name spa-backend \
  --image-scanning-configuration scanOnPush=true

# Add lifecycle policy (keep last 10 images)
POLICY='{"rules":[{"rulePriority":1,"description":"Keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}'
aws ecr put-lifecycle-policy --repository-name spa-frontend --lifecycle-policy-text "$POLICY"
aws ecr put-lifecycle-policy --repository-name spa-backend --lifecycle-policy-text "$POLICY"
```

### 4f. Create EC2 Key Pair

```bash
aws ec2 create-key-pair \
  --key-name qa-deploy-key \
  --query 'KeyMaterial' --output text > ~/.ssh/qa-deploy-key.pem
chmod 600 ~/.ssh/qa-deploy-key.pem
```

### 4g. Create IAM Role and Instance Profile for EC2

```bash
# Trust policy
cat > /tmp/ec2-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role --role-name ec2-qa-role \
  --assume-role-policy-document file:///tmp/ec2-trust.json

# Permissions: ECR pull + Secrets Manager read
cat > /tmp/ec2-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:us-west-2:<ACCOUNT_ID>:secret:spa-app/*"
    }
  ]
}
EOF

aws iam put-role-policy --role-name ec2-qa-role \
  --policy-name ec2-qa-ecr-secrets \
  --policy-document file:///tmp/ec2-policy.json

# Create instance profile
aws iam create-instance-profile --instance-profile-name ec2-qa-role
aws iam add-role-to-instance-profile \
  --instance-profile-name ec2-qa-role --role-name ec2-qa-role

sleep 10  # Wait for IAM propagation
```

### 4h. Launch QA EC2 with Elastic IP

```bash
# Find latest Amazon Linux 2023 AMI
AMI_ID=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

# Launch
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.small \
  --key-name qa-deploy-key \
  --security-group-ids "$SG_QA" \
  --subnet-id <SUBNET_ID> \
  --iam-instance-profile Name=ec2-qa-role \
  --user-data file://ec2/user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=qa-ec2}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Allocate and associate Elastic IP
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID"
ELASTIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" \
  --query 'Addresses[0].PublicIp' --output text)
echo "QA EC2 Elastic IP: $ELASTIC_IP"
```

The `ec2/user-data.sh` bootstrap script installs Docker, Docker Compose (as
a CLI plugin), AWS CLI, and other tools:

```bash
#!/bin/bash
set -euo pipefail
yum update -y
yum install -y docker
systemctl enable docker && systemctl start docker

# Install Docker Compose as CLI plugin
COMPOSE_VERSION="v2.24.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

mkdir -p /home/ec2-user/.docker/cli-plugins
cp /usr/local/lib/docker/cli-plugins/docker-compose /home/ec2-user/.docker/cli-plugins/docker-compose
chown -R ec2-user:ec2-user /home/ec2-user/.docker

usermod -aG docker ec2-user
yum install -y aws-cli curl jq cronie
systemctl enable crond && systemctl start crond
```

### 4i. Set Up GitHub OIDC and IAM Role

```bash
# Create OIDC provider
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"

# Create trust policy (replace YOUR_ORG with your GitHub username)
cat > /tmp/oidc-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
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
  }]
}
EOF

aws iam create-role --role-name github-actions-deploy \
  --assume-role-policy-document file:///tmp/oidc-trust.json

# Permissions: EC2, ECR, Secrets Manager, SG ingress/revoke, PassRole
cat > /tmp/gh-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Management",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances", "ec2:TerminateInstances",
        "ec2:DescribeInstances", "ec2:CreateTags",
        "ec2:DescribeImages", "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRAccess",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage", "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
        "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:us-west-2:<ACCOUNT_ID>:secret:spa-app/*"
    },
    {
      "Sid": "PassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec2-qa-role"
    }
  ]
}
EOF

aws iam put-role-policy --role-name github-actions-deploy \
  --policy-name github-actions-deploy-policy \
  --policy-document file:///tmp/gh-policy.json
```

### 4j. Store DB Credentials in Secrets Manager

```bash
aws secretsmanager create-secret \
  --name spa-app/db-credentials \
  --secret-string '{
    "username": "app_user",
    "password": "<APP_USER_PASSWORD>",
    "host": "<RDS_ENDPOINT>",
    "port": "3306",
    "dbname": "spa_db"
  }'
```

### 4k. Create DB User and Seed Table

SSH into the QA EC2 and connect to RDS:

```bash
ssh -i ~/.ssh/qa-deploy-key.pem ec2-user@<ELASTIC_IP>

# On the EC2:
sudo yum install -y mariadb105

mysql -h <RDS_ENDPOINT> -u admin -p<ADMIN_PASSWORD> -e "
  CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY '<APP_USER_PASSWORD>';
  GRANT SELECT, INSERT, UPDATE, DELETE ON spa_db.* TO 'app_user'@'%';
  FLUSH PRIVILEGES;
"

mysql -h <RDS_ENDPOINT> -u admin -p<ADMIN_PASSWORD> spa_db -e "
  CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
"
```

---

## 5. Part C: Domain, DNS, and SSL

### 5a. Purchase Domain

Buy a domain from [Name.com](https://www.name.com) (e.g. `spaqa.fit`).

### 5b. Create Route 53 Hosted Zone

```bash
aws route53 create-hosted-zone \
  --name spaqa.fit \
  --caller-reference "spa-app-$(date +%s)"

# Get the NS records
aws route53 get-hosted-zone --id <ZONE_ID> \
  --query 'DelegationSet.NameServers' --output table
```

### 5c. Update Nameservers at Name.com

Go to Name.com > My Domains > spaqa.fit > Manage Nameservers. Replace the
default nameservers with the 4 AWS NS records.

### 5d. Create A Record

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id <ZONE_ID> \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "qa.spaqa.fit",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "<ELASTIC_IP>"}]
      }
    }]
  }'
```

Verify after propagation:

```bash
dig qa.spaqa.fit
# Should return your Elastic IP
```

### 5e. Set Up SSL with Let's Encrypt

SSH into the QA EC2:

```bash
ssh -i ~/.ssh/qa-deploy-key.pem ec2-user@<ELASTIC_IP>

# Install Certbot
sudo yum install -y augeas-libs python3-pip
sudo python3 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install --upgrade pip
sudo /opt/certbot/bin/pip install certbot
sudo ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot

# Obtain certificate (port 80 must be free)
sudo certbot certonly \
  --standalone --non-interactive --agree-tos \
  --email admin@spaqa.fit \
  -d qa.spaqa.fit

# Set up auto-renewal
sudo yum install -y cronie
sudo systemctl enable crond && sudo systemctl start crond
(sudo crontab -l 2>/dev/null; echo '0 3 * * * /opt/certbot/bin/certbot renew --quiet') | sudo crontab -
```

---

## 6. Part D: GitHub Actions CI/CD Pipeline

### 6a. The Nightly Workflow

Create `.github/workflows/nightly-deploy.yml` in the `spa-infra` repo. The
pipeline has these steps:

1. **Checkout** both repos (infra + app)
2. **Authenticate** to AWS via OIDC
3. **Launch temp EC2** with user-data bootstrap
4. **Wait** for SSH and Docker to be ready
5. **Deploy** the app to the temp EC2 (build from source)
6. **Run smoke tests** (health check, frontend, API, DB connectivity)
7. **Build and push** Docker images to ECR (only if tests pass)
8. **Open SSH** to QA EC2 for the runner's IP
9. **Deploy to QA EC2** (pull images from ECR)
10. **Revoke SSH** access from QA EC2
11. **Terminate** the temp EC2
12. **Cleanup** SSH keys

Key parts of the workflow:

```yaml
name: Nightly QA Deploy

on:
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: us-west-2
  AWS_ACCOUNT_ID: "<YOUR_ACCOUNT_ID>"
  ECR_FRONTEND: spa-frontend
  ECR_BACKEND: spa-backend
  QA_EC2_HOST: qa.spaqa.fit
  QA_EC2_SG: <QA_SG_ID>
  TEMP_EC2_AMI: <AMI_ID>
  TEMP_EC2_SG: <TEMP_SG_ID>
  TEMP_EC2_SUBNET: <SUBNET_ID>
  TEMP_EC2_KEY: qa-deploy-key
  TEMP_EC2_PROFILE: ec2-qa-role
```

The **wait step** is critical — it waits for both SSH and `docker compose`
to be available:

```yaml
      - name: Wait for EC2 to be fully ready (SSH + Docker)
        run: |
          # ... wait for SSH ...
          echo "--- Waiting for Docker + Compose ---"
          for i in $(seq 1 30); do
            if ssh ... "docker compose version" 2>/dev/null; then
              echo "Docker and Compose are ready"
              break
            fi
            sleep 10
          done
```

The **QA deploy step** dynamically opens and closes SSH access:

```yaml
      - name: Allow runner SSH access to QA EC2
        run: |
          RUNNER_IP=$(curl -s https://checkip.amazonaws.com)/32
          aws ec2 authorize-security-group-ingress \
            --group-id "$QA_EC2_SG" \
            --protocol tcp --port 22 --cidr "$RUNNER_IP"

      - name: Deploy to QA EC2
        run: scripts/deploy-to-qa.sh

      - name: Revoke runner SSH access from QA EC2
        if: always()
        run: |
          aws ec2 revoke-security-group-ingress \
            --group-id "$QA_EC2_SG" \
            --protocol tcp --port 22 --cidr "$RUNNER_IP"
```

### 6b. Smoke Test Script

The `scripts/smoke-test.sh` runs 4 tests:

1. Frontend serves `index.html` (HTTP 200)
2. `/api/health` returns 200
3. Health endpoint reports DB connected
4. `/api/items` returns 200

### 6c. QA Deploy Script

The `scripts/deploy-to-qa.sh`:

1. Fetches DB credentials from Secrets Manager
2. Creates `~/qa-deploy/` on the QA EC2
3. Copies `docker-compose.qa.yml` and `.env`
4. Logs into ECR, pulls latest images, restarts containers
5. Runs a health check to verify

### 6d. QA Docker Compose

The `ec2/docker-compose.qa.yml` pulls pre-built images from ECR (instead of
building from source):

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

---

## 7. Part E: Push to GitHub and Test

### 7a. Create GitHub Repos

Create two repos on GitHub: `spa-app` and `spa-infra`.

```bash
# Push spa-app
cd spa-app
git init && git add . && git commit -m "Initial commit"
git remote add origin git@github.com:YOUR_ORG/spa-app.git
git push -u origin main

# Push spa-infra
cd ../spa-infra
git init && git add . && git commit -m "Initial commit"
git remote add origin git@github.com:YOUR_ORG/spa-infra.git
git push -u origin main
```

### 7b. Configure GitHub Secrets

In the `spa-infra` repo, go to Settings > Secrets and variables > Actions:

| Secret Name           | Value                                            |
|-----------------------|--------------------------------------------------|
| `EC2_SSH_PRIVATE_KEY` | Contents of `~/.ssh/qa-deploy-key.pem`           |
| `SOURCE_REPO_PAT`    | GitHub Personal Access Token with `repo` scope   |

To create the PAT: GitHub > Settings > Developer settings > Fine-grained
tokens > Generate new token. Grant "Contents: Read-only" on the `spa-app`
repo.

### 7c. Trigger the Pipeline

Go to the `spa-infra` repo > Actions > "Nightly QA Deploy" > "Run workflow"
> select `main` > click "Run workflow".

Watch the run. All steps should pass and you should see your app deployed at
`http://qa.spaqa.fit`.

---

## 8. Common Pitfalls and Things to Watch Out For

### Docker Compose must be installed as a CLI plugin

On Amazon Linux 2023, Docker does not include Docker Compose by default.
If you install the standalone `docker-compose` binary to `/usr/local/bin/`,
the `docker compose` (without hyphen) command will **not work**. You must
install it as a CLI plugin:

```bash
mkdir -p /usr/local/lib/docker/cli-plugins
curl -L ".../docker-compose-Linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

Also copy it to the ec2-user's plugin directory so non-root usage works.

### Wait for user-data to finish, not just SSH

When you launch an EC2 with a `user-data` script, SSH becomes available
**before** the script finishes running. If your workflow SSHes in and tries
to run `docker compose` immediately, Docker may not be installed yet. Always
add a readiness loop that checks for `docker compose version`, not just SSH
connectivity.

### QA EC2 security group blocks GitHub Actions SSH

If your QA EC2 security group only allows SSH from your personal IP, GitHub
Actions runners will get `Connection timed out` when trying to deploy. The
solution is to dynamically add the runner's IP to the security group before
deploying, then revoke it after (even on failure, using `if: always()`).
Remember to add `ec2:AuthorizeSecurityGroupIngress` and
`ec2:RevokeSecurityGroupIngress` to the GitHub Actions IAM role.

### Create the deploy directory before scp

When deploying to the QA EC2 for the first time, the `~/qa-deploy/`
directory does not exist. Your deploy script must run `mkdir -p ~/qa-deploy`
before attempting to `scp` files into it, or the copy will fail with
"No such file or directory".

### Security group names cannot start with "sg-"

AWS reserves the `sg-` prefix for security group IDs. If you try to create a
security group with a name like `sg-qa-ec2`, you will get an
`InvalidParameterValue` error. Use names like `qa-ec2-sg` instead.

### IAM instance profile propagation delay

After creating an IAM instance profile and adding a role to it, there is a
propagation delay of ~10 seconds. If you immediately try to launch an EC2
with that profile, it may fail with "Invalid IAM Instance Profile". Add a
`sleep 10` between creating the profile and launching the instance.

### AWS access key limits

Each IAM user (including root) can have a maximum of 2 access keys. If the
"Create Access Key" button is grayed out in the AWS console, you have
reached this limit. Delete an unused key first, or use an existing one if
you still have the secret.
