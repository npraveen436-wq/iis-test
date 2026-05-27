# IIS Test Setup — Simplified

A working Terraform + GitHub Actions setup that deploys a Windows Server 2019 EC2 instance with:

- ✅ IIS installed (built into Windows, no internet needed)
- ✅ Notepad++ downloaded from GitHub releases
- ✅ 7-Zip downloaded from 7-zip.org
- ✅ Config fetched from AWS Secrets Manager via IAM role
- ✅ Custom HTML page showing the hostname and setup status
- ✅ Default VPC, no domain, no certs required

## What success looks like

After deployment, open the public IP in your browser. You should see:

```
🚀 IIS Test Server: iis-test-01
[DEPLOYED VIA TERRAFORM + GITHUB ACTIONS]

Hostname (from Terraform)    iis-test-01
Computer Name                EC2AMAZ-XXXXX
Timezone                     Eastern Standard Time
IIS Status                   Running
Software Installed           Notepad++, 7-Zip
Secrets Manager              OK - 3 keys loaded
DB Connection (masked)       Server=mydb.example.com;Da...
```

If you see this page, every piece worked: Terraform created the resource, the AMI booted, IIS installed, software downloaded from the internet, the IAM role allowed reading from Secrets Manager, and the secret was decoded and used.

## Quick start

### 1. AWS one-time setup (CloudShell, ~10 min)

```bash
# State backend
BUCKET="yourname-tfstate-$(date +%s)"
aws s3api create-bucket --bucket $BUCKET --region us-east-1
aws s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws dynamodb create-table --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

echo "TF_STATE_BUCKET = $BUCKET"   # ← save this

# OIDC provider for GitHub
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Get your account ID
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "AWS_ACCOUNT_ID = $ACCOUNT"   # ← save this
```

Create trust policy (replace `YOUR_GITHUB_USERNAME`):

```bash
cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
      "StringLike": {"token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USERNAME/*:*"}
    }
  }]
}
EOF

aws iam create-role --role-name github-actions-terraform \
  --assume-role-policy-document file:///tmp/trust.json

aws iam attach-role-policy --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

Create the test secret:

```bash
aws secretsmanager create-secret \
  --name dev/app-config \
  --secret-string '{"db_connection":"Server=mydb.example.com;Database=AppDB;User=appuser;Password=SuperSecret123","api_key":"abc123xyz789","environment":"development"}' \
  --region us-east-1
```

Create EC2 key pair:

```bash
aws ec2 create-key-pair --key-name test-iis-key --query 'KeyMaterial' \
  --output text > test-iis-key.pem
chmod 400 test-iis-key.pem
```

### 2. Push this code to GitHub

```bash
cd iis-test
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/iis-test.git
git push -u origin main
```

### 3. Add GitHub secrets

In repo Settings → Secrets and variables → Actions, add:

- `AWS_ACCOUNT_ID`: your 12-digit AWS account ID
- `TF_STATE_BUCKET`: the bucket name from step 1

### 4. Trigger the apply

Either:
- **Option A**: Push directly to main (apply runs immediately)
- **Option B**: Go to Actions tab → Terraform Apply → Run workflow

### 5. Watch it work

In Actions tab, watch the workflow. After ~3 minutes, the apply finishes.

Look at the workflow output — under "Show outputs" you'll see something like:

```json
{
  "server_details": {
    "iis-test-01": {
      "public_ip": "54.123.45.67",
      "browser_url": "http://54.123.45.67",
      "ssm_command": "aws ssm start-session --target i-0abc... --region us-east-1"
    }
  }
}
```

### 6. Verify

**Wait 5-10 minutes** for user data to finish (IIS install, software download, etc.)

Open `http://PUBLIC_IP` in your browser. You should see the green status page.

Or use SSM to check the log:
```bash
aws ssm start-session --target i-0abc... --region us-east-1
# Once connected:
type C:\Setup\setup.log
```

### 7. Test scaling - add a second server

Edit `terraform/variables.tf`, change the `servers` default to:

```hcl
default = {
  "iis-test-01" = {}
  "iis-test-02" = {}   # NEW
}
```

Create a feature branch, PR, merge → second server appears. The first is untouched.

### 8. Clean up

```bash
cd terraform
terraform destroy -auto-approve
```

Or remove all entries from `servers` and merge.

## File structure

```
iis-test/
├── .github/workflows/
│   ├── terraform-plan.yml      # On PR
│   └── terraform-apply.yml     # On main push
├── terraform/
│   ├── providers.tf
│   ├── main.tf                 # All resources in one file
│   ├── variables.tf
│   ├── outputs.tf
│   └── templates/
│       └── setup.ps1.tftpl     # PowerShell user data
└── README.md
```

## What each piece teaches

| Piece | Real-world lesson |
|---|---|
| `data "aws_vpc" "default"` | Looking up existing infra by attribute |
| `for_each` over servers map | Idempotent multi-instance pattern |
| IAM role with Secrets Manager policy | Least-privilege EC2 to AWS service access |
| `templatefile` for user data | Per-instance config injection |
| `Get-SECSecretValue` in PowerShell | The standard pattern for fetching secrets at boot |
| GitHub OIDC → AWS | Modern secretless CI/CD |
| Generated HTML status page | Self-verifying deployment |

## Cost

- t3.medium Windows: ~$0.05/hour
- 50GB gp3 EBS: ~$0.005/hour
- **Total: ~$0.06/hour or ~$1.40/day**

**Remember to destroy when done testing.**

## Troubleshooting

**Browser shows nothing / connection refused**
- Wait 10 min after instance launches — user data takes time
- Check security group allows port 80 from 0.0.0.0/0
- SSM to instance, check `C:\Setup\setup.log`

**Setup log shows "Secret fetch failed"**
- Verify the secret exists: `aws secretsmanager get-secret-value --secret-id dev/app-config`
- Check IAM role has the permission (run `aws sts get-caller-identity` from instance)

**Workflow fails: "Could not assume role"**
- Trust policy mismatch — verify `repo:YOUR_USERNAME/*:*` in the OIDC condition

**Workflow fails on `terraform init`**
- `TF_STATE_BUCKET` secret missing or wrong
- DynamoDB table doesn't exist

**Notepad++ install fails**
- URL may have changed (release versions move) — update in `setup.ps1.tftpl`
- Check `C:\Setup\setup.log` for the actual error
