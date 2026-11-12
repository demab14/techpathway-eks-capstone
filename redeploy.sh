#!/usr/bin/env bash
# redeploy.sh - platform bootstrap on a fresh cluster: namespace, Secrets, ConfigMaps,
# first deploy of the apps (same kustomization CI/CD uses), then public URL wiring.
# After this, every push to main is deployed by .github/workflows/pipeline.yml.
set -euo pipefail
NS=techpathway
REGION=eu-west-2
CLUSTER=techpathway-cluster
cd "$(dirname "$0")"

echo "==> 1/6 Pointing kubectl at $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl config current-context | grep -q "$CLUSTER" || { echo "Wrong kubectl context - stopping"; exit 1; }

echo "==> 2/6 Namespace"
kubectl apply -f k8s/00-namespace.yaml

echo "==> 3/6 Secrets (generated here, never stored in Git)"
kubectl create secret generic weekly-call-secret -n "$NS" \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic action-messages-secret -n "$NS" \
  --from-literal=SMTP_USER= --from-literal=SMTP_PASSWORD= --dry-run=client -o yaml | kubectl apply -f -

echo "==> 4/6 ConfigMaps"
kubectl apply -f k8s/02-configmaps.yaml

echo "==> 5/6 Deployments, Services and HPAs (kustomization - the same files CI/CD deploys)"
kubectl apply -k k8s/
for d in action-messages techpathway-warehouse weekly-call; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=300s
done

echo "==> 6/6 Waiting for load balancers, then wiring public URLs"
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
