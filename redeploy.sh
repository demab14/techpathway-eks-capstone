#!/usr/bin/env bash
# redeploy.sh - rebuilds the TechPathway platform on an existing EKS cluster
set -euo pipefail
NS=techpathway
REGION=eu-west-2
CLUSTER=techpathway-cluster
cd "$(dirname "$0")"

echo "==> 1/7 Pointing kubectl at $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl config current-context | grep -q "$CLUSTER" || { echo "Wrong kubectl context - stopping"; exit 1; }

echo "==> 2/7 Namespace"
kubectl apply -f k8s/00-namespace.yaml

echo "==> 3/7 Secrets (generated here, never stored in Git)"
kubectl create secret generic weekly-call-secret -n "$NS" \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic action-messages-secret -n "$NS" \
  --from-literal=SMTP_USER= --from-literal=SMTP_PASSWORD= --dry-run=client -o yaml | kubectl apply -f -

echo "==> 4/7 ConfigMaps"
kubectl apply -f k8s/02-configmaps.yaml

echo "==> 5/7 Deployments + Services"
kubectl apply -f k8s/10-action-messages.yaml -f k8s/11-techpathway-warehouse.yaml -f k8s/12-weekly-call.yaml
for d in action-messages techpathway-warehouse weekly-call; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=180s
done

echo "==> 6/7 Horizontal Pod Autoscalers (also rewrites k8s/20-hpa.yaml cleanly)"
: > k8s/20-hpa.yaml
for d in action-messages techpathway-warehouse weekly-call; do
  kubectl autoscale deployment "$d" --cpu=50% --min=2 --max=6 -n "$NS" --dry-run=client -o yaml >> k8s/20-hpa.yaml
  echo "---" >> k8s/20-hpa.yaml
done
kubectl apply -f k8s/20-hpa.yaml

echo "==> 7/7 Waiting for load balancers, then wiring public URLs"
lb() { kubectl get svc "$1" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; }
for s in action-messages techpathway-warehouse weekly-call; do
  until [ -n "$(lb "$s")" ]; do sleep 5; done
done
AM=$(lb action-messages); WH=$(lb techpathway-warehouse); WC=$(lb weekly-call)
sed -i "s|NOTIFICATION_PUBLIC_URL: .*|NOTIFICATION_PUBLIC_URL: \"http://$AM:5001\"|; s|WAREHOUSE_PUBLIC_URL: .*|WAREHOUSE_PUBLIC_URL: \"http://$WH:5002\"|" k8s/02-configmaps.yaml
kubectl apply -f k8s/02-configmaps.yaml
kubectl rollout restart deployment/weekly-call -n "$NS"
kubectl rollout status deployment/weekly-call -n "$NS" --timeout=180s

echo
echo "Done. Open these in your browser (DNS can take 2-5 minutes):"
echo "  Action Messages : http://$AM:5001"
echo "  Warehouse       : http://$WH:5002"
echo "  Weekly Call     : http://$WC:5111"
kubectl get deploy,hpa,svc -n "$NS"
