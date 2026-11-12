#!/usr/bin/env bash
# grant-eks-access.sh - run after the cluster exists. Lets the pipeline role deploy,
# but only inside the techpathway namespace (AmazonEKSEditPolicy, namespace-scoped).
set -euo pipefail
REGION="${AWS_REGION:-eu-west-2}"
CLUSTER="techpathway-cluster"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/techpathway-github-actions"

aws eks create-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
  --principal-arn "$ROLE_ARN" >/dev/null 2>&1 && echo "access entry created" || echo "access entry already exists"

aws eks associate-access-policy --cluster-name "$CLUSTER" --region "$REGION" \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=techpathway >/dev/null
echo "AmazonEKSEditPolicy associated (scope: namespace techpathway)"

aws eks list-associated-access-policies --cluster-name "$CLUSTER" --region "$REGION" \
  --principal-arn "$ROLE_ARN" --query 'associatedAccessPolicies[].[policyArn,accessScope.type,accessScope.namespaces[0]]' --output table
