# AWS Setup Guide — Day 1 Manual Configuration

This document records every AWS CLI command used to set up the infrastructure.
Follow these steps in order to reproduce the environment from scratch.

**Region:** us-west-2 (Oregon)
**Account ID:** 164856787183

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1: Install and Configure AWS CLI](#step-1-install-and-configure-aws-cli)
- [Step 2: Identify VPC and Subnets](#step-2-identify-vpc-and-subnets)
- [Step 3: Create Security Groups](#step-3-create-security-groups)
- [Step 4: Create RDS MySQL Instance](#step-4-create-rds-mysql-instance)
- [Step 5: Create ECR Repositories](#step-5-create-ecr-repositories)
- [Step 6: Create EC2 Key Pair](#step-6-create-ec2-key-pair)
- [Step 7: Create IAM Role and Instance Profile for EC2](#step-7-create-iam-role-and-instance-profile-for-ec2)
- [Step 8: Launch QA EC2 with Elastic IP](#step-8-launch-qa-ec2-with-elastic-ip)
- [Step 9: Set Up GitHub OIDC and IAM Role](#step-9-set-up-github-oidc-and-iam-role)
- [Step 10: Store DB Credentials in Secrets Manager](#step-10-store-db-credentials-in-secrets-manager)
- [Step 11: Create DB User and Seed Table via QA EC2](#step-11-create-db-user-and-seed-table-via-qa-ec2)
- [Resource Summary](#resource-summary)
- [Next Steps (Still TODO)](#next-steps-still-todo)

---

## Prerequisites

- An AWS account
- macOS (or Linux) terminal
- An existing access key for your AWS account (create one in AWS Console >
  Security Credentials > Access Keys)

---

## Step 1: Install and Configure AWS CLI

```bash
# Install AWS CLI via Homebrew (macOS)
brew install awscli

# Or use the official installer
# curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
# sudo installer -pkg AWSCLIV2.pkg -target /
# rm AWSCLIV2.pkg

# Verify installation
aws --version

# Configure credentials
aws configure
# AWS Access Key ID:     <your-access-key-id>
# AWS Secret Access Key: <your-secret-access-key>
# Default region name:   us-west-2
# Default output format: json

# Verify it works
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "164856787183",
    "Account": "164856787183",
    "Arn": "arn:aws:iam::164856787183:root"
}
```

---

## Step 2: Identify VPC and Subnets

We use the default VPC that comes with every AWS account.

```bash
# Find the default VPC
aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].{VpcId:VpcId,CidrBlock:CidrBlock}' \
  --output table
```

Result: `vpc-06098a5359253f8f2` (172.31.0.0/16)

```bash
# List subnets in the default VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-06098a5359253f8f2" \
  --query 'Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,CidrBlock:CidrBlock,Public:MapPublicIpOnLaunch}' \
  --output table
```

Result:

| AZ          | SubnetId                      | Public |
|-------------|-------------------------------|--------|
| us-west-2a  | subnet-092e5a89e651771b6      | True   |
| us-west-2b  | subnet-03041301c1edaed84      | True   |
| us-west-2c  | subnet-04598b131c03977c2      | True   |
| us-west-2d  | subnet-033d7841e3b34c317      | True   |

---

## Step 3: Create Security Groups

### 3a. QA EC2 Security Group

Allows SSH (your IP only), HTTP and HTTPS (public).

```bash
VPC_ID="vpc-06098a5359253f8f2"

# Create the security group
SG_QA=$(aws ec2 create-security-group \
  --group-name qa-ec2-sg \
  --description "QA EC2 - SSH, HTTP, HTTPS" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
echo "QA EC2 SG: $SG_QA"

# Get your current public IP
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
echo "Your IP: $MY_IP"

# Allow SSH from your IP only
aws ec2 authorize-security-group-ingress --group-id "$SG_QA" \
  --protocol tcp --port 22 --cidr "$MY_IP"

# Allow HTTP from anywhere
aws ec2 authorize-security-group-ingress --group-id "$SG_QA" \
  --protocol tcp --port 80 --cidr "0.0.0.0/0"

# Allow HTTPS from anywhere
aws ec2 authorize-security-group-ingress --group-id "$SG_QA" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0"
```

Result: `sg-01011275e2cb425cd`

### 3b. Temp EC2 Security Group

Allows SSH and HTTP from anywhere (GitHub Actions IPs vary).

```bash
SG_TEMP=$(aws ec2 create-security-group \
  --group-name temp-ec2-sg \
  --description "Temp EC2 - SSH and HTTP for smoke testing" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
echo "Temp EC2 SG: $SG_TEMP"

# Allow SSH from anywhere (GitHub Actions runners)
aws ec2 authorize-security-group-ingress --group-id "$SG_TEMP" \
  --protocol tcp --port 22 --cidr "0.0.0.0/0"

# Allow HTTP from anywhere (for smoke tests)
aws ec2 authorize-security-group-ingress --group-id "$SG_TEMP" \
  --protocol tcp --port 80 --cidr "0.0.0.0/0"
```

Result: `sg-080a28fcc898c33a0`

### 3c. RDS Security Group

Allows MySQL (3306) only from the QA and Temp EC2 security groups.

```bash
SG_QA="sg-01011275e2cb425cd"
SG_TEMP="sg-080a28fcc898c33a0"

SG_RDS=$(aws ec2 create-security-group \
  --group-name rds-mysql-sg \
  --description "RDS MySQL - allow from QA and Temp EC2 only" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
echo "RDS SG: $SG_RDS"

# Allow MySQL from QA EC2 SG
aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
  --protocol tcp --port 3306 --source-group "$SG_QA"

# Allow MySQL from Temp EC2 SG
aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
  --protocol tcp --port 3306 --source-group "$SG_TEMP"
```

Result: `sg-098331f2614216186`

---

## Step 4: Create RDS MySQL Instance

### 4a. Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name spa-db-subnet-group \
  --db-subnet-group-description "Subnet group for SPA RDS" \
  --subnet-ids subnet-092e5a89e651771b6 subnet-03041301c1edaed84
```

### 4b. Create the RDS Instance

```bash
aws rds create-db-instance \
  --db-instance-identifier spa-db \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --engine-version "8.0" \
  --master-username admin \
  --master-user-password SpaDbPass2026Secure \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --db-subnet-group-name spa-db-subnet-group \
  --vpc-security-group-ids sg-098331f2614216186 \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --no-multi-az \
  --db-name spa_db \
  --tags Key=Name,Value=spa-db Key=Environment,Value=qa
```

This takes ~5-10 minutes. Check status with:

```bash
aws rds describe-db-instances \
  --db-instance-identifier spa-db \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Port:Endpoint.Port}' \
  --output table
```

Wait until Status is `available`.

Result: `spa-db.cn86ysaecll7.us-west-2.rds.amazonaws.com:3306`

---

## Step 5: Create ECR Repositories

```bash
# Create frontend repo
aws ecr create-repository \
  --repository-name spa-frontend \
  --image-scanning-configuration scanOnPush=true

# Create backend repo
aws ecr create-repository \
  --repository-name spa-backend \
  --image-scanning-configuration scanOnPush=true

# Add lifecycle policy to both (keep last 10 images)
LIFECYCLE_POLICY='{"rules":[{"rulePriority":1,"description":"Keep last 10 images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}'

aws ecr put-lifecycle-policy \
  --repository-name spa-frontend \
  --lifecycle-policy-text "$LIFECYCLE_POLICY"

aws ecr put-lifecycle-policy \
  --repository-name spa-backend \
  --lifecycle-policy-text "$LIFECYCLE_POLICY"
```

Result:
- `164856787183.dkr.ecr.us-west-2.amazonaws.com/spa-frontend`
- `164856787183.dkr.ecr.us-west-2.amazonaws.com/spa-backend`

---

## Step 6: Create EC2 Key Pair

```bash
aws ec2 create-key-pair \
  --key-name qa-deploy-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/qa-deploy-key.pem

chmod 600 ~/.ssh/qa-deploy-key.pem
```

The private key is saved to `~/.ssh/qa-deploy-key.pem`. Keep this safe — you
cannot download it again.

---

## Step 7: Create IAM Role and Instance Profile for EC2

This role lets EC2 instances pull images from ECR and read secrets from
Secrets Manager.

### 7a. Create the IAM Role

```bash
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name ec2-qa-role \
  --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
  --description "EC2 role for QA and temp instances - ECR pull and Secrets Manager"
```

### 7b. Attach Permissions

```bash
cat > /tmp/ec2-qa-policy.json << 'EOF'
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
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:us-west-2:164856787183:secret:spa-app/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name ec2-qa-role \
  --policy-name ec2-qa-ecr-secrets \
  --policy-document file:///tmp/ec2-qa-policy.json
```

### 7c. Create Instance Profile and Attach Role

```bash
aws iam create-instance-profile \
  --instance-profile-name ec2-qa-role

aws iam add-role-to-instance-profile \
  --instance-profile-name ec2-qa-role \
  --role-name ec2-qa-role
```

> Wait ~10 seconds after this before launching EC2 (IAM propagation delay).

---

## Step 8: Launch QA EC2 with Elastic IP

### 8a. Find the Latest Amazon Linux 2023 AMI

```bash
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "AMI: $AMI_ID"
```

Result: `ami-03caad32a158f72db`

### 8b. Launch the Instance

```bash
# Wait 10s for instance profile to propagate
sleep 10

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ami-03caad32a158f72db \
  --instance-type t3.small \
  --key-name qa-deploy-key \
  --security-group-ids sg-01011275e2cb425cd \
  --subnet-id subnet-092e5a89e651771b6 \
  --iam-instance-profile Name=ec2-qa-role \
  --user-data file://ec2/user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=qa-ec2},{Key=Environment,Value=qa}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "Instance: $INSTANCE_ID"

# Wait for it to be running
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "Instance is running."
```

Result: `i-0a370b7e195c47c87`

### 8c. Allocate and Associate Elastic IP

```bash
ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' --output text)

ELASTIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "$ALLOC_ID" \
  --query 'Addresses[0].PublicIp' --output text)
echo "Elastic IP: $ELASTIC_IP"

aws ec2 associate-address \
  --instance-id "$INSTANCE_ID" \
  --allocation-id "$ALLOC_ID"
```

Result: Elastic IP `52.32.55.43`

### 8d. Verify SSH Access

```bash
ssh -o StrictHostKeyChecking=no \
  -i ~/.ssh/qa-deploy-key.pem \
  ec2-user@52.32.55.43 "echo 'SSH works!' && docker --version"
```

---

## Step 9: Set Up GitHub OIDC and IAM Role

This lets GitHub Actions authenticate to AWS without long-lived access keys.

### 9a. Create the OIDC Identity Provider

```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
```

### 9b. Create the GitHub Actions IAM Role

```bash
# NOTE: Replace "repo:*spa-infra:*" with "repo:YOUR_ORG/spa-infra:*"
#       once you know your GitHub org/username.
cat > /tmp/github-oidc-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::164856787183:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:*spa-infra:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name github-actions-deploy \
  --assume-role-policy-document file:///tmp/github-oidc-trust.json \
  --description "GitHub Actions OIDC role for nightly deploy pipeline"
```

### 9c. Attach Permissions to the Role

```bash
cat > /tmp/github-actions-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Management",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeInstances",
        "ec2:CreateTags",
        "ec2:DescribeImages",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRAccess",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:us-west-2:164856787183:secret:spa-app/*"
    },
    {
      "Sid": "PassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::164856787183:role/ec2-qa-role"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name github-actions-deploy \
  --policy-name github-actions-deploy-policy \
  --policy-document file:///tmp/github-actions-policy.json
```

---

## Step 10: Store DB Credentials in Secrets Manager

```bash
aws secretsmanager create-secret \
  --name spa-app/db-credentials \
  --description "SPA app database credentials" \
  --secret-string '{
    "username": "app_user",
    "password": "SpaAppUser2026Pass",
    "host": "spa-db.cn86ysaecll7.us-west-2.rds.amazonaws.com",
    "port": "3306",
    "dbname": "spa_db"
  }'
```

---

## Step 11: Create DB User and Seed Table via QA EC2

SSH into the QA EC2 and connect to RDS to create the application database user
and the items table.

```bash
ssh -i ~/.ssh/qa-deploy-key.pem ec2-user@52.32.55.43
```

Then on the EC2:

```bash
# Install MySQL client
sudo yum install -y mariadb105

# Connect to RDS and create app_user
mysql -h spa-db.cn86ysaecll7.us-west-2.rds.amazonaws.com \
  -u admin -pSpaDbPass2026Secure -e "
  CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY 'SpaAppUser2026Pass';
  GRANT SELECT, INSERT, UPDATE, DELETE ON spa_db.* TO 'app_user'@'%';
  FLUSH PRIVILEGES;
"

# Create the items table
mysql -h spa-db.cn86ysaecll7.us-west-2.rds.amazonaws.com \
  -u admin -pSpaDbPass2026Secure spa_db -e "
  CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  SHOW TABLES;
"
```

---

## Resource Summary

| Resource                  | ID / Value                                                  |
|---------------------------|-------------------------------------------------------------|
| VPC (default)             | `vpc-06098a5359253f8f2`                                     |
| Subnet (us-west-2a)      | `subnet-092e5a89e651771b6`                                  |
| Subnet (us-west-2b)      | `subnet-03041301c1edaed84`                                  |
| QA EC2 Security Group     | `sg-01011275e2cb425cd`                                      |
| Temp EC2 Security Group   | `sg-080a28fcc898c33a0`                                      |
| RDS Security Group        | `sg-098331f2614216186`                                      |
| RDS Endpoint              | `spa-db.cn86ysaecll7.us-west-2.rds.amazonaws.com:3306`      |
| ECR Frontend              | `164856787183.dkr.ecr.us-west-2.amazonaws.com/spa-frontend` |
| ECR Backend               | `164856787183.dkr.ecr.us-west-2.amazonaws.com/spa-backend`  |
| Key Pair                  | `qa-deploy-key` (saved to `~/.ssh/qa-deploy-key.pem`)       |
| IAM Instance Profile      | `ec2-qa-role`                                                |
| QA EC2 Instance           | `i-0a370b7e195c47c87`                                       |
| QA EC2 Elastic IP         | `52.32.55.43`                                                |
| GitHub OIDC Provider      | `arn:aws:iam::164856787183:oidc-provider/token.actions.githubusercontent.com` |
| GitHub Actions IAM Role   | `github-actions-deploy`                                      |
| Secrets Manager Secret    | `spa-app/db-credentials`                                     |
| Amazon Linux 2023 AMI     | `ami-03caad32a158f72db`                                      |

---

## Step 12: Purchase Domain and Set Up Route 53 (COMPLETED)

Domain `spaqa.fit` purchased from Name.com on 2026-03-08.

### 12a. Create Route 53 Hosted Zone

```bash
aws route53 create-hosted-zone \
  --name spaqa.fit \
  --caller-reference "spa-app-$(date +%s)"
```

Result: Hosted Zone ID `Z013706123DAJAMJ6K22H`

### 12b. Get NS Records

```bash
aws route53 get-hosted-zone \
  --id Z013706123DAJAMJ6K22H \
  --query 'DelegationSet.NameServers' \
  --output table
```

Result:

```
ns-775.awsdns-32.net
ns-1226.awsdns-25.org
ns-53.awsdns-06.com
ns-2009.awsdns-59.co.uk
```

### 12c. Update Nameservers at Name.com

1. Go to Name.com > My Domains > spaqa.fit > Manage Nameservers
2. Delete the default Name.com nameservers
3. Add the 4 AWS nameservers listed above
4. Save

### 12d. Create A Record

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z013706123DAJAMJ6K22H \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "qa.spaqa.fit",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "52.32.55.43"}]
      }
    }]
  }'
```

### 12e. Verify DNS

```bash
dig qa.spaqa.fit
# Should return: 52.32.55.43
```

---

## Step 13: Set Up SSL with Let's Encrypt (COMPLETED)

### 13a. SSH into QA EC2

```bash
ssh -i ~/.ssh/qa-deploy-key.pem ec2-user@52.32.55.43
```

### 13b. Install Certbot

```bash
sudo yum install -y augeas-libs python3-pip
sudo python3 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install --upgrade pip
sudo /opt/certbot/bin/pip install certbot
sudo ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
certbot --version
```

### 13c. Obtain SSL Certificate

```bash
sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email admin@spaqa.fit \
  -d qa.spaqa.fit
```

Result:
- Certificate: `/etc/letsencrypt/live/qa.spaqa.fit/fullchain.pem`
- Private key: `/etc/letsencrypt/live/qa.spaqa.fit/privkey.pem`
- Expires: 2026-06-06

### 13d. Set Up Auto-Renewal

```bash
# Install cronie (not included by default on Amazon Linux 2023)
sudo yum install -y cronie
sudo systemctl enable crond
sudo systemctl start crond

# Add renewal cron job (runs daily at 3 AM)
(sudo crontab -l 2>/dev/null; echo '0 3 * * * /opt/certbot/bin/certbot renew --quiet --pre-hook "docker stop $(docker ps -q --filter name=frontend) 2>/dev/null || true" --post-hook "docker start $(docker ps -aq --filter name=frontend) 2>/dev/null || true"') | sudo crontab -

# Verify
sudo crontab -l
```

---

## Updated Resource Summary

| Resource                  | ID / Value                                                  |
|---------------------------|-------------------------------------------------------------|
| VPC (default)             | `vpc-06098a5359253f8f2`                                     |
| Subnet (us-west-2a)      | `subnet-092e5a89e651771b6`                                  |
| Subnet (us-west-2b)      | `subnet-03041301c1edaed84`                                  |
| QA EC2 Security Group     | `sg-01011275e2cb425cd`                                      |
| Temp EC2 Security Group   | `sg-080a28fcc898c33a0`                                      |
| RDS Security Group        | `sg-098331f2614216186`                                      |
| RDS Endpoint              | `spa-db.cn86ysaecll7.us-west-2.rds.amazonaws.com:3306`      |
| ECR Frontend              | `164856787183.dkr.ecr.us-west-2.amazonaws.com/spa-frontend` |
| ECR Backend               | `164856787183.dkr.ecr.us-west-2.amazonaws.com/spa-backend`  |
| Key Pair                  | `qa-deploy-key` (saved to `~/.ssh/qa-deploy-key.pem`)       |
| IAM Instance Profile      | `ec2-qa-role`                                                |
| QA EC2 Instance           | `i-0a370b7e195c47c87`                                       |
| QA EC2 Elastic IP         | `52.32.55.43`                                                |
| GitHub OIDC Provider      | `arn:aws:iam::164856787183:oidc-provider/token.actions.githubusercontent.com` |
| GitHub Actions IAM Role   | `github-actions-deploy`                                      |
| Secrets Manager Secret    | `spa-app/db-credentials`                                     |
| Amazon Linux 2023 AMI     | `ami-03caad32a158f72db`                                      |
| Domain                    | `spaqa.fit` (purchased from Name.com)                        |
| Route 53 Hosted Zone      | `Z013706123DAJAMJ6K22H`                                     |
| DNS A Record              | `qa.spaqa.fit → 52.32.55.43`                                |
| SSL Certificate           | `/etc/letsencrypt/live/qa.spaqa.fit/` (expires 2026-06-06)  |

---

## Next Steps (Still TODO)

### 1. Push Repos to GitHub

```bash
# Create two repos on GitHub: spa-app and spa-infra

# Push spa-app
cd /path/to/spa-app
git init
git add .
git commit -m "Initial commit: SPA frontend + backend + docker-compose"
git remote add origin git@github.com:YOUR_ORG/spa-app.git
git push -u origin main

# Push spa-infra
cd /path/to/spa-infra
git init
git add .
git commit -m "Initial commit: infra scripts + nightly workflow"
git remote add origin git@github.com:YOUR_ORG/spa-infra.git
git push -u origin main
```

### 2. Configure GitHub Secrets

In the **spa-infra** repo, go to Settings > Secrets and variables > Actions,
and add these secrets:

| Secret Name            | Value                                                    |
|------------------------|----------------------------------------------------------|
| `EC2_SSH_PRIVATE_KEY`  | Contents of `~/.ssh/qa-deploy-key.pem`                   |
| `SOURCE_REPO_PAT`     | A GitHub Personal Access Token with `repo` scope         |

### 3. Update Workflow with Your GitHub Org

In `.github/workflows/nightly-deploy.yml`, replace `YOUR_ORG/spa-app` with
your actual GitHub username/org and repo name.

Also update the OIDC trust policy if needed:

```bash
# Update the trust policy to lock down to your specific repo
cat > /tmp/updated-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::164856787183:oidc-provider/token.actions.githubusercontent.com"
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
EOF

aws iam update-assume-role-policy \
  --role-name github-actions-deploy \
  --policy-document file:///tmp/updated-trust.json
```

### 4. Test the Nightly Pipeline

Go to the spa-infra repo on GitHub > Actions > "Nightly QA Deploy" >
"Run workflow" to trigger it manually and verify everything works end-to-end.

---

## Teardown (If You Need to Start Over)

Run these commands to delete everything and start fresh:

```bash
# Terminate QA EC2
aws ec2 terminate-instances --instance-ids i-0a370b7e195c47c87

# Release Elastic IP
aws ec2 release-address --allocation-id eipalloc-00ffe5673460e196f

# Delete RDS
aws rds delete-db-instance \
  --db-instance-identifier spa-db \
  --skip-final-snapshot

# Delete ECR repos
aws ecr delete-repository --repository-name spa-frontend --force
aws ecr delete-repository --repository-name spa-backend --force

# Delete Secrets Manager secret
aws secretsmanager delete-secret \
  --secret-id spa-app/db-credentials \
  --force-delete-without-recovery

# Delete security groups (wait for EC2/RDS to be fully terminated first)
aws ec2 delete-security-group --group-id sg-098331f2614216186  # rds
aws ec2 delete-security-group --group-id sg-080a28fcc898c33a0  # temp-ec2
aws ec2 delete-security-group --group-id sg-01011275e2cb425cd  # qa-ec2

# Delete DB subnet group
aws rds delete-db-subnet-group --db-subnet-group-name spa-db-subnet-group

# Delete key pair
aws ec2 delete-key-pair --key-name qa-deploy-key
rm -f ~/.ssh/qa-deploy-key.pem

# Delete IAM resources
aws iam remove-role-from-instance-profile \
  --instance-profile-name ec2-qa-role \
  --role-name ec2-qa-role
aws iam delete-instance-profile --instance-profile-name ec2-qa-role
aws iam delete-role-policy --role-name ec2-qa-role --policy-name ec2-qa-ecr-secrets
aws iam delete-role --role-name ec2-qa-role
aws iam delete-role-policy --role-name github-actions-deploy --policy-name github-actions-deploy-policy
aws iam delete-role --role-name github-actions-deploy
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::164856787183:oidc-provider/token.actions.githubusercontent.com

# Delete Route 53 A record and hosted zone
aws route53 change-resource-record-sets \
  --hosted-zone-id Z013706123DAJAMJ6K22H \
  --change-batch '{
    "Changes": [{
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "qa.spaqa.fit",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "52.32.55.43"}]
      }
    }]
  }'
aws route53 delete-hosted-zone --id Z013706123DAJAMJ6K22H
```
