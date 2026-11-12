#!/usr/bin/env bash
# setup-aws-oidc.sh - one-off AWS setup so GitHub Actions can deploy without stored keys.
# Creates: the GitHub OIDC identity provider (if missing), the 3 ECR repositories (if missing),
# and an IAM role that only this repository's main branch / production environment can assume.
# Usage: GITHUB_REPO=demab14/techpathway-eks-capstone ./cicd/setup-aws-oidc.sh
set -euo pipefail
GITHUB_REPO="${GITHUB_REPO:-demab14/techpathway-eks-capstone}"
REGION="${AWS_REGION:-eu-west-2}"
CLUSTER="techpathway-cluster"
ROLE="techpathway-github-actions"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
PROVIDER_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"

echo "==> 1/4 GitHub OIDC identity provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  echo "    already exists"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "    created"
fi

echo "==> 2/4 ECR repositories"
for r in action-messages techpathway-warehouse weekly-call; do
  if aws ecr describe-repositories --repository-names "$r" --region "$REGION" >/dev/null 2>&1; then
    echo "    $r already exists"
  else
    aws ecr create-repository --repository-name "$r" --region "$REGION" \
      --image-scanning-configuration scanOnPush=true >/dev/null
    echo "    $r created"
  fi
done

echo "==> 3/4 IAM role $ROLE (trusted only by $GITHUB_REPO main branch + production environment)"
cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "$PROVIDER_ARN" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": [
        "repo:${GITHUB_REPO}:ref:refs/heads/main",
        "repo:${GITHUB_REPO}:environment:production"
      ] }
    }
  }]
}
EOF
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document file:///tmp/trust.json
  echo "    already exists - trust policy refreshed"
else
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document file:///tmp/trust.json \
    --description "GitHub Actions deploy role for $GITHUB_REPO" >/dev/null
  echo "    created"
fi

echo "==> 4/4 Least-privilege permissions: push to the 3 ECR repos + describe the EKS cluster"
cat > /tmp/perms.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "EcrPush", "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                 "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"],
      "Resource": [
        "arn:aws:ecr:${REGION}:${ACCOUNT}:repository/action-messages",
        "arn:aws:ecr:${REGION}:${ACCOUNT}:repository/techpathway-warehouse",
        "arn:aws:ecr:${REGION}:${ACCOUNT}:repository/weekly-call"
      ] },
    { "Sid": "EksConnect", "Effect": "Allow", "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}" }
  ]
}
EOF
aws iam put-role-policy --role-name "$ROLE" --policy-name techpathway-ci-deploy --policy-document file:///tmp/perms.json
rm -f /tmp/trust.json /tmp/perms.json

echo
echo "Done. Add this as a GitHub repository VARIABLE named AWS_ROLE_ARN:"
echo "  arn:aws:iam::${ACCOUNT}:role/${ROLE}"
