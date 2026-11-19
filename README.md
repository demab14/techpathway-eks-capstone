# TechPathway Platform on Amazon EKS

Production-style deployment of the three TechPathway applications to Amazon EKS: containerised, published to Amazon ECR, run on Kubernetes with health checks and autoscaling, monitored with Prometheus and Grafana, and torn down cleanly afterwards.

**Author:** Saheed Ademola Abayomi · Senior DevOps / Platform Engineer
**Region:** eu-west-2 (London) · **Kubernetes:** 1.36 (EKS) · **Completed:** November 2026

Application source: [sholaolujobi/TechPathway--Website](https://github.com/sholaolujobi/TechPathway--Website). This repository holds the DevOps-owned build and platform configuration only.

---

## Architecture

```
                         Internet
                            |
        +-------------------+-------------------+
        |                   |                   |
   AWS ELB :5111       AWS ELB :5001       AWS ELB :5002
        |                   |                   |
+-------|-------------------|-------------------|--------+
| EKS   v                   v                   v        |
| ns: techpathway                                        |
|  [weekly-call] x2-6 --HTTP--> [action-messages] x2-6   |
|        |                                               |
|        +--------------HTTP--> [techpathway-warehouse]  |
|                               x2-6                     |
|  HPA (CPU 50%) on each Deployment                      |
|                                                        |
| ns: monitoring                                         |
|  Prometheus + node-exporter + kube-state-metrics       |
|  Grafana (data source: prometheus-server)              |
+--------------------------------------------------------+
  3 x t3.medium managed nodes across 3 availability zones
```

| Service | Folder | Port | Health check | Role |
| --- | --- | --- | --- | --- |
| Weekly Call | `weekly-call/` | 5111 | `GET /health` (also checks DB) | Storefront + admin dashboard |
| Action Messages | `action-messages/` | 5001 | `GET /health` | Order-confirmation emails (demo mode, no SMTP) |
| TechPathway Warehouse | `techpathway-warehouse/` | 5002 | `GET /health` | Inventory and fulfilment board |

Weekly Call reaches the other two through Kubernetes Service DNS (`http://action-messages:5001`, `http://techpathway-warehouse:5002`). An order placed in the storefront was verified end to end on EKS: Warehouse stock decremented and Action Messages logged a tracking number.

## Tech stack

Git · Docker · Amazon ECR · Amazon EKS · eksctl · kubectl · Kustomize · Kubernetes (Deployments, Services, ConfigMaps, Secrets, HPA) · Helm · Prometheus · Grafana · GitHub Actions (OIDC) · hadolint · kubeconform · Trivy · AWS CLI v2 · Python 3.11 / Flask / gunicorn

## Repository layout

```
.
├── .github/workflows/
│   └── pipeline.yml              # CI/CD: validate → build + scan → push to ECR → deploy to EKS
├── apps/                         # Hardened Dockerfiles (+ .dockerignore) per service
│   ├── action-messages/
│   ├── techpathway-warehouse/
│   └── weekly-call/
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 01-secrets.example.yaml   # placeholders only - real Secrets created by redeploy.sh
│   ├── 02-configmaps.yaml
│   ├── 10-action-messages.yaml   # Deployment + LoadBalancer Service
│   ├── 11-techpathway-warehouse.yaml
│   ├── 12-weekly-call.yaml
│   ├── 20-hpa.yaml               # HorizontalPodAutoscalers
│   └── kustomization.yaml        # What CI/CD deploys; the pipeline sets the image tag
├── cicd/
│   ├── setup-aws-oidc.sh         # One-off: GitHub OIDC provider, ECR repos, least-privilege IAM role
│   └── grant-eks-access.sh       # Lets the pipeline role deploy into the techpathway namespace only
├── monitoring/
│   └── techpathway-dashboard.json  # Grafana dashboard (cluster, CPU, memory, pods)
├── screenshots/                  # Evidence for TP-001 to TP-009
├── cluster.yaml                  # eksctl cluster definition
└── redeploy.sh                   # Platform bootstrap on a fresh cluster (namespace, Secrets, ConfigMaps, first deploy)
```

## How to deploy

```bash
# One-off AWS setup: OIDC provider, ECR repositories, pipeline IAM role
GITHUB_REPO=demab14/techpathway-eks-capstone ./cicd/setup-aws-oidc.sh

# Cluster (~15 min), then let the pipeline role into the techpathway namespace
eksctl create cluster -f cluster.yaml
./cicd/grant-eks-access.sh

# Platform bootstrap: namespace, Secrets, ConfigMaps, first deploy, public URLs
./redeploy.sh

# From now on, every push to main is built, scanned and deployed by GitHub Actions
git push origin main
```

`redeploy.sh` is idempotent: it uses `kubectl apply` throughout, refuses to run if kubectl points at the wrong cluster, and waits for every rollout and load balancer before wiring the public URLs into the ConfigMap.

## CI/CD pipeline

`.github/workflows/pipeline.yml` runs on every pull request and every push to `main`:

| Stage | Pull request | Push to main | What it does |
| --- | --- | --- | --- |
| **Validate** | ✅ | ✅ | hadolint on the three Dockerfiles; `kubectl kustomize` + kubeconform (strict) on the manifests |
| **Build and scan** | ✅ | ✅ | Checks out the application repo, applies the DevOps-owned Dockerfiles from `apps/`, builds each image, Trivy scan (HIGH/CRITICAL report) |
| **Push** | — | ✅ | Pushes each image to ECR tagged with the short commit SHA |
| **Deploy** | — | ✅ | Sets the SHA tag in `k8s/kustomization.yaml`, `kubectl apply -k`, waits for every rollout, smoke-tests `/health` through each load balancer, rolls back automatically if anything fails |

**Security design**

- **No AWS keys in GitHub.** Jobs request a short-lived OIDC token, which AWS exchanges for temporary credentials for the `techpathway-github-actions` role.
- **The role trusts one repository only**: its `main` branch and its `production` environment. Pull requests and forks cannot assume it.
- **Least privilege in AWS:** push to the three ECR repositories, plus `eks:DescribeCluster` on this one cluster.
- **Least privilege in Kubernetes:** an EKS access entry with `AmazonEKSEditPolicy` scoped to the `techpathway` namespace. The pipeline cannot read Secrets in other namespaces or change the cluster.
- **Secrets never pass through CI.** The namespace, Secrets and ConfigMaps are platform bootstrap (`redeploy.sh`). The pipeline only deploys Deployments, Services and HPAs.
- **Optional approval gate:** the deploy job runs in the `production` GitHub environment, so required reviewers can be added in repository settings.

**Traceability:** every running pod's image tag is the commit that produced it, and each run's summary lists the pushed images and the deployed tags.

**Design note:** the Deployments have no `replicas` field. With an HPA in place, a hard-coded replica count would be re-applied on every deploy and fight the autoscaler.

## Configuration

| Kind | Name | Holds |
| --- | --- | --- |
| ConfigMap | `weekly-call-config` | `FLASK_ENV`, internal service URLs, public (browser-facing) URLs |
| ConfigMap | `action-messages-config` | Sender name and address, CC address, SMTP host/port (blank = demo mode) |
| Secret | `weekly-call-secret` | `SECRET_KEY` (generated with `openssl rand -hex 32` at deploy time) |
| Secret | `action-messages-secret` | `SMTP_USER`, `SMTP_PASSWORD` |

Secrets are created from the command line and never committed; `k8s/01-secrets.example.yaml` documents their shape with placeholders.

## Resources and health checks

| Deployment | CPU request / limit | Memory request / limit | Readiness | Liveness |
| --- | --- | --- | --- | --- |
| action-messages | 100m / 500m | 128Mi / 256Mi | `/health`, 5s delay, every 10s | `/health`, 20s delay, every 20s, 3 failures |
| techpathway-warehouse | 100m / 500m | 128Mi / 256Mi | same | same |
| weekly-call | 100m / 500m | 192Mi / 384Mi (3 gunicorn workers) | same | same |

## Operations and autoscaling results

- **Manual scaling:** all three Deployments scaled 1 → 5 (15 pods spread across all 3 nodes) → 2. On scale-in Kubernetes kept the oldest pods.
- **Self-healing:** a deleted Weekly Call pod was replaced within seconds with no change to the desired count.
- **Logs, describe, exec:** inside a pod, `whoami` returned `appuser` (non-root), the ConfigMap values were present as environment variables, and the pod reached `action-messages:5001/health` by Service name.
- **HPA:** target 50% CPU, min 2, max 6. Under in-cluster load (busybox `wget` loops) all three Deployments scaled 2 → 6. After the load stopped, CPU fell to 1% immediately but replicas held at 6 for the 5-minute stabilisation window, then stepped down 6 → 4 → 2.

## Monitoring

Prometheus (`prometheus-community/prometheus`) and Grafana (`grafana/grafana`) were installed as separate Helm releases in the `monitoring` namespace, with persistence disabled. Prometheus targets were all UP, including the API servers (2/2) and nodes (3/3). Grafana uses `http://prometheus-server.monitoring.svc.cluster.local` as its data source.

`monitoring/techpathway-dashboard.json` has four rows:

1. **Kubernetes cluster:** node count, running pods, cluster CPU and memory, per-node CPU and memory
2. **TechPathway CPU:** by application and by pod
3. **TechPathway Memory:** by application and by pod
4. **TechPathway Pods:** ready replicas, HPA desired replicas, container restarts

Under load it showed cluster CPU rising from about 3% to 41%, 36 running pods, and the HPA stepping each deployment from 2 to 5–6 replicas with zero restarts.

## Troubleshooting (TP-008)

Each scenario was broken deliberately on the Warehouse Deployment, then diagnosed with `kubectl get pods`, `kubectl describe pod` and `kubectl logs`, then fixed and verified.

| # | Scenario | How it was broken | Pod state | Key evidence | Fix |
| --- | --- | --- | --- | --- | --- |
| 1 | ImagePullBackOff | Image tag `v9` (never pushed) | `ImagePullBackOff` | describe: image `not found`; logs: `waiting to start` (container never ran) | `kubectl set image ... :v1` |
| 2 | CrashLoopBackOff | Command `gunicorn ... wrong_module:app` | `CrashLoopBackOff`, restarts rising | describe: pulled/started x5 then `BackOff`; `logs --previous`: `ModuleNotFoundError: No module named 'wrong_module'` | Removed the command override |
| 3 | Pending | CPU request of 4 cores | `Pending`, 0 restarts | describe: `0/3 nodes are available: 3 Insufficient cpu` (t3.medium = 2 vCPU); no logs | Restored 100m / 500m |
| 4 | Incorrect container port | gunicorn bound to 8080; everything else expects 5002 | `Running 0/1`, then restarts | describe: probes `connection refused` on 5002; logs: `Listening at: http://0.0.0.0:8080` | Removed the override so the app binds 5002 |
| 5 | Failed readiness probe | Readiness path `/healthz` | `Running 0/1`, 0 restarts | describe: `HTTP probe failed with statuscode: 404`; logs: healthy start on 5002 | Probe path back to `/health` |
| 6 | Failed liveness probe | Liveness port 9999 | Restarts then `CrashLoopBackOff` on **all** replicas | describe: liveness `connection refused` on 9999, `will be restarted`; `logs --previous`: clean start, then `Handling signal: term` 79s later | Probe port back to 5002 |

**Key lesson from scenario 6:** in scenarios 1–5 the rolling update protected users, because the new pod never became Ready, so the old pods kept serving. In scenario 6 readiness passed, so the rollout retired every healthy pod before liveness began killing the new ones, and the Warehouse went down. A bad liveness probe gets past rollout protection, so liveness changes need staging tests and generous delays and thresholds.

## Issues found and fixed during the project

| Issue | Root cause | Resolution |
| --- | --- | --- |
| Weekly Call showed duplicated seed orders (8 instead of 4) under Docker | Each of the 3 gunicorn workers imported the app and could run the first-start DB seed | Added `--preload` so the app loads once in the master before workers fork; verified the seed runs once |
| Containers ran as root | Original Dockerfiles had no `USER` | Added a non-root `appuser` (UID 1001) to all three Dockerfiles |
| Pods stuck `Pending` after a cluster rebuild | `redeploy.sh` ran before the managed node group existed | Pods scheduled automatically once nodes joined; the script is safe to re-run |
| All Grafana panels showed errors | Repeated "Add data source" attempts created three data sources; the default one had an empty URL | Set the correct URL on the default data source and deleted the duplicates through the Grafana API |
| Community dashboard 15757 showed no data | It expects `cluster` / `job` labels added by kube-prometheus-stack | Built a dashboard with queries matching this Prometheus chart |
| `kubectl rollout undo` risk | Undo goes back one revision, not to "the last good one" | Use `kubectl rollout history` and `--to-revision=N` |
| CI/CD deploy failed: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The repository uses GitHub's immutable OIDC subject (`repo:owner@ID/repo@ID`), but the IAM trust policy matched the repo name only | Scoped the trust policy to the repository and owner IDs; `setup-aws-oidc.sh` now reads the prefix from the GitHub API |
| CI/CD job failed at "Set up job" | `trivy-action@0.28.0` does not exist; its releases are tagged with a `v` prefix | Pinned Trivy to the `v0.36.0` commit SHA |

## Known limitations and next steps

- **Stateful services:** Action Messages and Warehouse use SQLite inside the pod. Each replica has its own data, and data is lost when pods are replaced (seen after the cluster rebuild). Next step: Amazon RDS, or PersistentVolumes via the EBS CSI driver.
- **One load balancer per service:** three Classic ELBs over plain HTTP. Next step: AWS Load Balancer Controller with a single ALB Ingress and an ACM certificate for HTTPS.
- **Monitoring persistence** is disabled, so metrics and Grafana settings are lost on pod restart. Next step: EBS CSI driver and persistent volumes, and Grafana provisioning of the data source and dashboard as code.
- **Secrets:** stored as Kubernetes Secrets. The apps already support AWS Secrets Manager (`SECRETS_MANAGER_SECRET_NAME`). Next step: IRSA or EKS Pod Identity. eksctl also recommends Pod Identity for the `vpc-cni` add-on.
- **Image hygiene:** the images include files not needed at runtime (`Dockerfile`, `scripts/`, `nginx/`, `start.sh`). Next step: tighten `.dockerignore`.
- **Application:** the Weekly Call footer hard-codes "MySQL · S3 Connected", but the app is running on SQLite and local images (`/health` reports `"s3": false`).
- **Automation:** cluster provisioning via Terraform instead of eksctl, and GitOps (Flux CD or Argo CD) instead of push-based `kubectl apply` from CI.

## Cleanup (TP-009)

```bash
kubectl delete hpa,deployments,services --all -n techpathway
kubectl delete namespace techpathway
helm uninstall grafana prometheus -n monitoring && kubectl delete namespace monitoring
eksctl delete cluster --name techpathway-cluster --region eu-west-2 --wait
for r in action-messages techpathway-warehouse weekly-call; do
  aws ecr delete-repository --repository-name $r --force
done
```

Kubernetes objects were removed first, so the LoadBalancer Services deleted their ELBs before the VPC was torn down. A final sweep confirmed no EKS clusters, eksctl stacks, running EC2 instances, NAT gateways, load balancers or ECR repositories remained in eu-west-2.

## Evidence

Screenshots are in [`screenshots/`](screenshots/), one folder per stage (`TP-001-assessment` to `TP-009-cleanup`), each file named by the date and time it was taken.
