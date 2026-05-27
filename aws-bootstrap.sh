#!/usr/bin/env bash
# =============================================================================
# AWS one-time bootstrap for the iis-test Terraform + GitHub Actions project.
# Run this ONCE in AWS CloudShell (or any shell with admin AWS credentials).
# Pre-filled for GitHub user: npraveen436-wq, repo: iis-test
# =============================================================================
set -euo pipefail

GITHUB_USER="npraveen436-wq"
GITHUB_REPO="iis-test"          # <-- change if you name the repo differently
REGION="us-east-1"

echo ">>> 1/6  Creating S3 bucket for Terraform state..."
BUCKET="${GITHUB_USER}-tfstate-$(date +%s)"
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo ">>> 2/6  Creating DynamoDB lock table..."
aws dynamodb create-table --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$REGION" >/dev/null

echo ">>> 3/6  Creating GitHub OIDC provider (idempotent)..."
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  2>/dev/null || echo "    (OIDC provider already exists — fine)"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo ">>> 4/6  Creating IAM role 'github-actions-terraform'..."
# Trust scoped to ONE repo. To allow any repo under your account instead,
# replace the sub line with:  repo:${GITHUB_USER}/*:*
cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": "repo:${GITHUB_USER}/${GITHUB_REPO}:*"}
    }
  }]
}
EOF
aws iam create-role --role-name github-actions-terraform \
  --assume-role-policy-document file:///tmp/trust.json >/dev/null
# NOTE: AdministratorAccess is broad. Fine for a throwaway test; scope it down
# for anything real. Terraform here needs EC2 + IAM + SG + Secrets read.
aws iam attach-role-policy --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo ">>> 5/6  Creating the dev/app-config secret..."
aws secretsmanager create-secret \
  --name dev/app-config \
  --secret-string '{"db_connection":"Server=mydb.example.com;Database=AppDB;User=appuser;Password=SuperSecret123","api_key":"abc123xyz789","environment":"development"}' \
  --region "$REGION" >/dev/null 2>&1 \
  || echo "    (secret already exists — fine)"

echo ">>> 6/6  Creating EC2 key pair 'test-iis-key'..."
if aws ec2 describe-key-pairs --key-names test-iis-key --region "$REGION" >/dev/null 2>&1; then
  echo "    (key pair already exists — skipping)"
else
  aws ec2 create-key-pair --key-name test-iis-key \
    --query 'KeyMaterial' --output text --region "$REGION" > test-iis-key.pem
  chmod 400 test-iis-key.pem
  echo "    Saved private key to ./test-iis-key.pem  (do NOT commit this)"
fi

echo ""
echo "============================================================"
echo " DONE. Add these two values as GitHub repo secrets:"
echo "   AWS_ACCOUNT_ID  = ${ACCOUNT}"
echo "   TF_STATE_BUCKET = ${BUCKET}"
echo "============================================================"
