# SPA Infra

Infrastructure and CI/CD for deploying the [spa-app](https://github.com/Alas129/spa-app) to AWS.

## What It Does

A **nightly GitHub Actions workflow** (`nightly-deploy.yml`) that runs at 3:00 AM UTC and:

1. Launches a **temporary EC2** instance
2. Deploys the app and runs **smoke tests**
3. If tests pass, builds and pushes Docker images to **Amazon ECR**
4. Deploys the images to a **QA EC2** instance
5. Tears down the temporary EC2

## Structure

```
.github/workflows/nightly-deploy.yml   # Nightly build & deploy workflow
ec2/
  docker-compose.qa.yml                # Compose file for QA deployment (ECR images)
  nginx-ssl.conf                       # Nginx config with SSL
  user-data.sh                         # EC2 bootstrap script (Docker install)
scripts/
  deploy-to-qa.sh                      # Deploys to the QA EC2
  setup-ssl.sh                         # Let's Encrypt SSL setup
  smoke-test.sh                        # Health checks after deployment
```

## Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `SOURCE_REPO_PAT` | PAT to clone the spa-app repo |
| `EC2_SSH_PRIVATE_KEY` | SSH key for EC2 access |

AWS credentials are provided via **OIDC** (role: `github-actions-deploy`).
