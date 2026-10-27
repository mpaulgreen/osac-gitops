#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# OSAC GitOps — Hub Bootstrap
#
# Automates the hub cluster setup: installs the OpenShift GitOps operator,
# configures Argo CD RBAC, applies AppProjects, creates the ACM plumbing
# (ManagedClusterSetBinding, GitOpsCluster, Placement), deploys the single
# osac-layers ApplicationSet, and optionally seeds the Quay pull secret for
# FBC nightly builds.
#
# Usage:
#   export REPO_URL="https://github.com/<org>/osac-gitops.git"
#   export GIT_BRANCH="feature/rhoai-3.6"
#   export GITHUB_USER="<your-github-user>"
#   ./scripts/bootstrap.sh [--seed-pull-secret]
#
# Flags:
#   --seed-pull-secret   Prompt for (or read from QUAY_DOCKERCONFIGJSON env)
#                        the Quay pull secret and create rhoai-quay-pull-secret
#                        in osac-platform.
#   --yes                Skip the confirmation prompt.
###############################################################################

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

REPO_URL="${REPO_URL:?Set REPO_URL to the Git repository URL}"
GIT_BRANCH="${GIT_BRANCH:-feature/rhoai-3.6}"
GITHUB_USER="${GITHUB_USER:?Set GITHUB_USER}"

seed_pull_secret=false
confirmed=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --seed-pull-secret) seed_pull_secret=true; shift ;;
    --yes) confirmed=true; shift ;;
    -h|--help) sed -n '3,/^###/{ /^#/s/^# \?//p }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for cmd in oc git jq gh; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

oc whoami >/dev/null 2>&1 || die "not logged in — run 'oc login' first"

cat <<EOF
OSAC GitOps Hub Bootstrap

  Repository:   $REPO_URL
  Branch:       $GIT_BRANCH
  GitHub user:  $GITHUB_USER
  Seed secret:  $seed_pull_secret

EOF

if [ "$confirmed" != true ]; then
  printf 'Continue? [y/N] '
  read -r answer
  [[ "$answer" =~ ^[Yy] ]] || { printf 'Aborted.\n'; exit 0; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

printf '\n=== Step 1: Install OpenShift GitOps operator ===\n'
oc apply -f "$REPO_ROOT/bootstrap/"
printf 'Waiting for GitOps CRDs...\n'
until oc get crd applications.argoproj.io >/dev/null 2>&1 && \
      oc get crd applicationsets.argoproj.io >/dev/null 2>&1; do
  sleep 10
done
printf 'GitOps CRDs ready.\n'

printf '\n=== Step 2: Create osac-platform namespace ===\n'
oc create namespace osac-platform --dry-run=client -o yaml | oc apply -f -

printf '\n=== Step 3: Argo CD RBAC ===\n'
oc apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
YAML

# ACM policy RBAC
oc apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: osac-policy-admin
rules:
  - apiGroups: ["policy.open-cluster-management.io"]
    resources: ["policies", "placementbindings"]
    verbs: ["*"]
  - apiGroups: ["cluster.open-cluster-management.io"]
    resources: ["placements", "managedclustersetbindings"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["*"]
YAML

oc apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: osac-policy-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: osac-policy-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
YAML

printf '\n=== Step 4: Patch Argo controller memory ===\n'
oc -n openshift-gitops patch argocd openshift-gitops --type merge -p '{
  "spec": {
    "controller": {
      "resources": {
        "limits":   {"memory": "4Gi"},
        "requests": {"memory": "2Gi"}
      }
    }
  }
}'

printf '\n=== Step 5: Apply AppProjects ===\n'
oc apply -f "$REPO_ROOT/hub/projects/"

printf '\n=== Step 6: ACM plumbing ===\n'
oc apply -f - <<YAML
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: global
  namespace: openshift-gitops
spec:
  clusterSet: global
YAML

oc apply -f - <<YAML
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: osac-gitops-cluster
  namespace: openshift-gitops
spec:
  argoServer:
    argoNamespace: openshift-gitops
    cluster: local-cluster
  placementRef:
    apiVersion: cluster.open-cluster-management.io/v1beta1
    kind: Placement
    name: osac-gitops-clusters
    namespace: openshift-gitops
YAML

oc apply -f - <<YAML
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: osac-gitops-clusters
  namespace: openshift-gitops
spec:
  clusterSets:
    - global
YAML

printf '\n=== Step 7: Git repository secret ===\n'
GH_TOKEN="$(gh auth token 2>/dev/null || true)"
if [ -z "$GH_TOKEN" ]; then
  die "gh auth token failed — run 'gh auth login' first"
fi

oc -n openshift-gitops create secret generic osac-repo-secret \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$GITHUB_USER" \
  --from-literal=password="$GH_TOKEN" \
  --dry-run=client -o yaml | \
  oc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | \
  oc apply -f -

printf '\n=== Step 8: Deploy osac-layers ApplicationSet ===\n'
oc apply -f "$REPO_ROOT/hub/applicationsets/"

printf '\n=== Step 9: Hub-only Placement for Keycloak and Grid Enrollment ===\n'
oc apply -f - <<YAML
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: osac-hub-only
  namespace: osac-platform
spec:
  clusterSets:
    - global
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            name: local-cluster
YAML

# Hub templating ServiceAccount for Policies that read Routes
oc apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: osac-hub-templating
  namespace: osac-platform
YAML

oc apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: osac-hub-templating
  namespace: maas-db
rules:
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get", "list", "watch"]
YAML

oc apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: osac-hub-templating
  namespace: maas-db
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: osac-hub-templating
subjects:
  - kind: ServiceAccount
    name: osac-hub-templating
    namespace: osac-platform
YAML

if [ "$seed_pull_secret" = true ]; then
  printf '\n=== Step 10: Seed Quay pull secret ===\n'
  if [ -z "${QUAY_DOCKERCONFIGJSON:-}" ]; then
    printf 'Paste the .dockerconfigjson value (base64-encoded), then press Enter:\n'
    read -r QUAY_DOCKERCONFIGJSON
  fi
  oc -n osac-platform create secret docker-registry rhoai-quay-pull-secret \
    --from-literal=.dockerconfigjson="$(echo "$QUAY_DOCKERCONFIGJSON" | base64 -d)" \
    --dry-run=client -o yaml | oc apply -f -
fi

printf '\n=== Waiting for Applications to sync ===\n'
printf 'This may take several minutes as operators install and policies propagate.\n'
sleep 30

for attempt in $(seq 1 60); do
  synced=$(oc -n openshift-gitops get applications -o json 2>/dev/null | \
    jq '[.items[] | select(.status.sync.status == "Synced")] | length')
  total=$(oc -n openshift-gitops get applications -o json 2>/dev/null | \
    jq '.items | length')
  printf 'Applications synced: %s/%s (%s/60)\n' "$synced" "$total" "$attempt"
  if [ "$synced" -ge "$total" ] && [ "$total" -gt 0 ]; then
    break
  fi
  sleep 15
done

printf '\n=== Bootstrap complete ===\n'
printf 'Hub Applications: %s synced out of %s\n' "$synced" "$total"
printf '\nNext steps:\n'
printf '  1. Add spokes with: ./scripts/import-managed-cluster.sh\n'
printf '  2. Run smoke tests with: ./scripts/smoke-test.sh\n'
