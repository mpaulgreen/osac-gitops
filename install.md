# OSAC GitOps — Install Runbook

> **Note.** This copy uses placeholder environment values. Replace every line marked `#REPLACE-ME` with your own cluster information before running any command. Search for them with `grep -rn REPLACE-ME .`
>
> | Where | What to replace it with |
> |---|---|
> | `HUB_CTX`, `SPOKE_CTX` (§1.2) | your `oc` contexts (`oc config get-contexts -o name`) |
> | `GITHUB_USER` (§1.2) | your GitHub user |
> | `KC_PASS` (§1.2) | the password of the Keycloak test user `novatech-free` in your realm |
> | `hub/platform-sites/site-params.yaml`: `cluster-domain`, `identity-issuer` | your clusters' ingress domains and your Keycloak issuer URL |
> | `hub/platform-sites/site-params.yaml`: `hardware-profiles` | the CPU and GPU profiles your nodes support (GPU type, CPU and memory limits) |
> | `global/sites/*/external-models/*-provider.yaml`: `endpoint` | the other site's `maas.<apps domain>` |
> | `global/sites/site-b/models/granite-3-1-8b-fp8.yaml`: `uri`, `resources` | your model image in your registry, and CPU, memory and GPU sized for your node |
> | `hub/platform/05-default-tenant-policy.yaml`: `clientId` | the OIDC client in your Keycloak realm |
>
> `site-b-cluster` is a placeholder name for the spoke cluster. It appears only in comments and prose.

Deploys the OSAC MaaS platform on a hub and its spokes.

| Site | Cluster | ACM ManagedCluster | Argo destination | Model |
|---|---|---|---|---|
| `site-a` (hub) | `hub` | `local-cluster` | `in-cluster` | `facebook-opt-125m-simulated` (CPU) |
| `site-b` (spoke) | `site-b-cluster` | `site-b` | `site-b` | `granite-3-1-8b-fp8` (NVIDIA A10G) |
| `site-c` (spoke) | — | `site-c` | `site-c` | added later with §7 |

For a spoke, the site name, the ManagedCluster name and the Argo destination are the same string. One Keycloak (realm `osac`, on the hub) serves every site.

- **Platform plane** (`hub/platform/`, policies 01–08): Argo applies the ACM policies to the hub; ACM delivers them to every selected site.
- **Intent plane** (models, governance, external models): Argo pushes straight to each site.

**How to run it.** Do §1, then Part A once, Part B once per spoke, Part C once, then the smoke tests (§10). Every step is *Run → Expect → If not*; "If not" points to §11. Commands are zsh-safe, one per block. Plain `oc` targets the hub.

**Do not paste the next block until the wait block under a step has printed its result.** Many steps only *start* work (an operator install, an import, a sync); the thing you check next does not exist for minutes. A `Wait` block ends as soon as its condition is met and fails after a timeout, so a timeout means something is wrong: follow the §11 entry named under it. "No resources found" straight after a step is usually not an error, it is the wait you skipped (§1.2 has typical durations).

---

## 1. Prepare

### 1.1 Requirements

| | |
|---|---|
| OpenShift | 4.20+ with cluster-admin on every cluster (hub 4.20, spoke 4.21) |
| ACM | 2.16+ (policy 04 uses `randAlphaNum`); installed in §2 |
| Tools | `oc`, `git`, `jq`, `curl`, `python3`, `gh` (token for the Argo repository secret) |
| Git | `https://github.com/mpaulgreen/osac-gitops.git`, branch `main`, pushed; Argo reads it |
| GPU sites | NFD and NVIDIA GPU operators installed on every site that runs a GPU model (`site-b`) |
| Control plane | Keycloak (realm `osac`, client `osac-cli`), tenants, Kafka and Vault are provided by the OSAC control plane and are not installed here |

### 1.2 Set variables

Run this in every new terminal. Contexts come from `oc login`; list them with `oc config get-contexts -o name`.

```bash
export HUB_CTX="default/api-hub-example.com:6443/kube:admin"   #REPLACE-ME
export SPOKE_CTX="default/api-site-b-example.com:6443/kube:admin"   #REPLACE-ME
export REPO_URL="https://github.com/mpaulgreen/osac-gitops.git"
export GIT_BRANCH="main"
export GITHUB_USER="mpaulgreen"   #REPLACE-ME
export KC_PASS="<password of the Keycloak test user novatech-free>"   #REPLACE-ME
export HUB_DOMAIN=$(oc --context "$HUB_CTX" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export SPOKE_DOMAIN=$(oc --context "$SPOKE_CTX" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export KC_DOMAIN="$HUB_DOMAIN"   # Keycloak runs on the hub
```

```bash
oc --context "$HUB_CTX" whoami && oc --context "$SPOKE_CTX" whoami
```

Expect `kube:admin` twice. If a login has expired, `oc login` again; the context name stays the same. Then select the hub for plain `oc`:

```bash
oc config use-context "$HUB_CTX"
```

**Waiting helper.** `oc wait` fails at once if the object does not exist yet, so for objects that appear later the steps below use `wait_for <seconds> '<test command>'`. It polls every 10 seconds and prints `OK`, or `TIMEOUT` with the failing test. Define it in every new terminal:

```bash
wait_for() {
  local limit=$1 test=$2 end=$((SECONDS+$1))
  until eval "$test" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$end" ]; then echo "TIMEOUT after ${limit}s: $test"; return 1; fi
    sleep 10
  done
  echo OK
}
```

Typical durations, so you know whether to keep waiting. These are what this runbook has seen, not guarantees; the timeouts in the wait blocks are deliberately larger.

| Step | Waits for | Typical |
|---|---|---|
| §2.1 | MultiClusterHub `Complete` | 5–10 minutes |
| §6.1–6.2 | operators installed and the seven platform policies `Compliant` | 10–20 minutes |
| §7.2 | spoke import (`ManagedClusterConditionAvailable`) | a few minutes |
| §7.3 | Argo cluster secret after the import | 3–4 minutes (seen once, 2026-10-08) |
| §7.4 | site Applications appear, then connect to the spoke | 1–2 minutes grey, then `Synced` |
| §8 | GPU model `Ready` (image pull plus weights) | 3–10 minutes |
| §9.3 | consumer policies after the key is registered | about 1 minute; the chains `Ready` in 1–2 |

### 1.3 Pre-flight

```bash
oc get packagemanifest advanced-cluster-management -o jsonpath='{.status.channels[*].name}{"\n"}'
```

Expect `release-2.16` in the list.

```bash
git ls-remote --heads origin "$GIT_BRANCH"
```

Expect one line: the branch is pushed.

```bash
for CTX in "$HUB_CTX" "$SPOKE_CTX"; do oc --context "$CTX" run oidc-check --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- curl -sk -o /dev/null -w '%{http_code}\n' "https://keycloak.${KC_DOMAIN}/realms/osac/.well-known/openid-configuration"; done
```

Expect `200` for each cluster. If not, stop: every site's `identity-issuer` depends on this endpoint.

---

## Part A — Hub (`site-a`), once

### 2. Install ACM and OpenShift GitOps

**2.1 ACM.**

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operator-group
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.16
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
oc wait --for=condition=CatalogSourcesUnhealthy=false \
  subscription.operators.coreos.com/advanced-cluster-management -n open-cluster-management --timeout=300s
until oc get crd multiclusterhubs.operator.open-cluster-management.io 2>/dev/null; do
  echo "Waiting for MultiClusterHub CRD..."; sleep 10
done
```

```bash
oc apply -f - <<'EOF'
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
```

```bash
oc wait --for=condition=Complete multiclusterhub/multiclusterhub -n open-cluster-management --timeout=600s
```

Expect the condition to be met (5–10 minutes). If not, see §11 "Operators stuck".

**Wait.** The hub registers itself as `local-cluster` after the MultiClusterHub is up; §3 needs it `Available`:

```bash
wait_for 600 'oc get managedcluster local-cluster'
oc wait --for=condition=ManagedClusterConditionAvailable managedcluster/local-cluster --timeout=600s
```

**2.2 OpenShift GitOps.** A running `openshift-gitops` Argo CD instance does not prove the operator is installed (after an incomplete uninstall the instance keeps running with no operator). Check for the operator CSV:

```bash
oc get csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator
```

If there is none, subscribe:

```bash
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-gitops-operator -n openshift-operators --timeout=300s
until oc get deployment openshift-gitops-server -n openshift-gitops 2>/dev/null; do
  echo "Waiting for openshift-gitops-server deployment..."; sleep 10
done
oc wait --for=condition=Available deployment/openshift-gitops-server -n openshift-gitops --timeout=300s
```

Expect the Argo CD server `Available`.

**Wait.** The Argo CD instance itself reports `Available` a little after its server pod:

```bash
wait_for 300 'oc get argocd openshift-gitops -n openshift-gitops'
oc wait --for=jsonpath='{.status.phase}'=Available argocd/openshift-gitops -n openshift-gitops --timeout=300s
```

### 3. Connect ACM to Argo CD

```bash
oc get managedcluster local-cluster -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}{"\n"}'
```

Expect `default`. If empty: `oc label managedcluster local-cluster cluster.open-cluster-management.io/clusterset=default --overwrite`.

This creates the `ManagedClusterSetBinding` (without it the Placement selects nothing and no spoke cluster secret is ever created), the `GitOpsCluster` and its Placement. The Placement lists spokes only: `local-cluster` is deliberately absent, because all hub layers use Argo's built-in `in-cluster`, and a second cache of the hub makes the application controller run out of memory.

```bash
oc apply -f - <<'EOF'
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: openshift-gitops
spec:
  clusterSet: default
---
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: osac-gitops-cluster
  namespace: openshift-gitops
spec:
  argoServer:
    cluster: local-cluster
    argoNamespace: openshift-gitops
  placementRef:
    kind: Placement
    apiVersion: cluster.open-cluster-management.io/v1beta1
    name: osac-gitops-placement
    namespace: openshift-gitops
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: osac-gitops-placement
  namespace: openshift-gitops
spec:
  clusterSets:
    - default
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: name
              operator: In
              values:
                - site-b
                - site-c
EOF
```

Use `labelSelector`, not `claimSelector`: ManagedClusters carry a `name` label but no `name` cluster claim.

```bash
oc get placement osac-gitops-placement -n openshift-gitops -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

Expect `PlacementMisconfigured=False`. A reason of `NoManagedClusterSetBindings` means the binding is missing. No cluster is selected until a spoke is imported (§7), so a `GitOpsCluster` that reports "resolved 0 managed clusters" is correct for now; there is nothing to wait for here.

### 4. Configure Argo CD

**4.1 Git repository.** Needs a token with `repo` scope from `gh auth token` (refresh a stale one with `echo "<new-token>" | gh auth login --with-token`). Never write the token into a file (P9).

```bash
GITHUB_TOKEN=$(gh auth token)
```

```bash
oc create secret generic osac-gitops-repo \
  --from-literal=type=git \
  --from-literal=url="${REPO_URL}" \
  --from-literal=username="${GITHUB_USER}" \
  --from-literal=password="${GITHUB_TOKEN}" \
  -n openshift-gitops \
  --dry-run=client -o yaml | \
  oc label --local -f - argocd.argoproj.io/secret-type=repository --dry-run=client -o yaml | \
  oc apply -f -
```

**4.2 Permissions for the Argo application controller.** One block: it may manage ACM policy objects and the intent kinds, and it may bind the `default` ManagedClusterSet (the ACM admission webhook requires `managedclustersets/bind` for the `platform-sites` layer).

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openshift-gitops-acm-policies
rules:
  - apiGroups: ["policy.open-cluster-management.io"]
    resources: ["policies", "placementbindings"]
    verbs: ["*"]
  - apiGroups: ["apps.open-cluster-management.io"]
    resources: ["placementrules"]
    verbs: ["*"]
  - apiGroups: ["cluster.open-cluster-management.io"]
    resources: ["placements", "managedclustersetbindings", "managedclustersets"]
    verbs: ["*"]
  - apiGroups: ["maas.opendatahub.io"]
    resources: ["maassubscriptions", "maasauthpolicies", "maasmodelrefs"]
    verbs: ["*"]
  - apiGroups: ["serving.kserve.io"]
    resources: ["llminferenceservices"]
    verbs: ["*"]
  - apiGroups: ["inference.opendatahub.io"]
    resources: ["externalmodels", "externalproviders"]
    verbs: ["*"]
  - apiGroups: ["batch"]
    resources: ["cronjobs"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["secrets", "namespaces", "serviceaccounts"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-acm-policies
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-gitops-acm-policies
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openshift-gitops-clusterset-bind
rules:
  - apiGroups: ["cluster.open-cluster-management.io"]
    resources: ["managedclustersets/bind"]
    resourceNames: ["default"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-clusterset-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-gitops-clusterset-bind
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
EOF
```

**4.3 Controller memory.** The default 2 Gi limit is too small once a spoke has 60+ CRDs (RHOAI, KServe, RHCL, Kuadrant): the controller is OOMKilled and every spoke Application stays grey. Raise it before creating the ApplicationSet:

```bash
oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
  -p '{"spec":{"controller":{"resources":{"limits":{"memory":"6Gi","cpu":"2"},"requests":{"memory":"2Gi","cpu":"250m"}}}}}'
```

```bash
oc rollout status statefulset/openshift-gitops-application-controller -n openshift-gitops --timeout=120s
```

**Wait.** The GitOps operator applies the patch to the StatefulSet after a delay, so `rollout status` can return before the new limit is in place. Do not continue until the running controller pod carries it. The block prints nothing until it prints `OK`:

```bash
wait_for 300 '[ "$(oc get pod openshift-gitops-application-controller-0 -n openshift-gitops -o jsonpath="{.spec.containers[0].resources.limits.memory}")" = "6Gi" ]'
```

On `TIMEOUT`, check that the ArgoCD resource carries the limit, re-run the patch above if it does not, and check the `openshift-gitops-operator` pod is running:

```bash
oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.resources.limits.memory}{"\n"}'
```

**4.4 AppProjects.** Run from the repository root.

```bash
oc apply -f hub/projects/platform-policies.yaml
oc apply -f hub/projects/scope-global.yaml
oc apply -f hub/projects/scope-tenant-novatech.yaml
```

The projects and the §4.2 ClusterRole are applied by hand; no Application delivers them. `scope-global` lists both `server: "*"` and `name: "*"` destinations because the ApplicationSet addresses clusters by name. **On an existing hub, re-run §4.2 and §4.4 before pushing a layer that adds new resource kinds**, or Argo rejects the sync with `not permitted in project` or `forbidden` (§11).

**4.5 Verify §4.**

```bash
oc get secret osac-gitops-repo -n openshift-gitops -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}{"\n"}'
oc get clusterrole openshift-gitops-acm-policies openshift-gitops-clusterset-bind
oc get appproject -n openshift-gitops
```

Expect `repository`, both ClusterRoles, and the AppProjects `platform-policies`, `scope-global`, `scope-tenant-novatech`.

Argo console, if you want it:

```bash
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}{"\n"}'
oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d; echo
```

The user is `admin`.

### 5. Deploy

The ApplicationSet creates one Application per `*.app.json` descriptor. The branch is set in two places that must agree: `revision` below (where descriptors are read) and `targetRevision` in each descriptor (where manifests are read).

```bash
oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: osac-layers
  namespace: openshift-gitops
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: "${REPO_URL}"
        revision: "${GIT_BRANCH}"
        files:
          - path: "**/*.app.json"
  template:
    metadata:
      name: "{{ .scope.kind }}{{ if eq .scope.kind \"tenant\" }}-{{ .scope.id }}{{ end }}-{{ .site }}-{{ .layer }}"
      namespace: openshift-gitops
      labels:
        osac.io/scope: "{{ .scope.kind }}"
        osac.io/site: "{{ .site }}"
        osac.io/layer: "{{ .layer }}"
    spec:
      project: "{{ .project }}"
      source:
        repoURL: "${REPO_URL}"
        targetRevision: "{{ .targetRevision }}"
        path: "{{ .manifestPath }}"
      destination:
        name: "{{ .argoDestination }}"
        namespace: "{{ .namespace }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
  syncPolicy:
    preserveResourcesOnDeletion: true
EOF
```

Push the branch if you have local changes:

```bash
git push origin "$GIT_BRANCH"
```

**Wait.** The ApplicationSet reads Git, then creates the Applications, then each one syncs. Wait for the five hub Applications to exist, then to be `Synced`:

```bash
wait_for 300 '[ "$(oc get applications.argoproj.io -n openshift-gitops --no-headers | wc -l)" -ge 5 ]'
```

```bash
oc wait --for=jsonpath='{.status.sync.status}'=Synced applications.argoproj.io --all -n openshift-gitops --timeout=600s
```

If the count stays below 5, the ApplicationSet failed its first reconcile (for example it was created before its AppProjects, §4.4) and retries only after about 3 minutes. Force it: `oc annotate applicationset osac-layers -n openshift-gitops argocd.argoproj.io/application-set-refresh=true --overwrite`. If Applications show old descriptor values, restart the repo-server (§11).

```bash
oc get applicationset osac-layers -n openshift-gitops
oc get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,DEST:.spec.destination.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Expect the ApplicationSet and five Applications, all on `in-cluster`. The three site-b Applications are not created yet: the ApplicationSet reports `application destination spec is invalid: there are no clusters with this name: site-b` until §7 registers the spoke. That error is expected here. Use `applications.argoproj.io`: the bare `application` kind resolves to ACM's.

| Application | Destination | Expect now |
|---|---|---|
| `global-hub-platform-sites`, `global-site-a-models`, `tenant-novatech-site-a-governance`, `global-site-a-external-models` | `in-cluster` | `Synced` |
| `global-hub-platform` | `in-cluster` | `Synced`, `Degraded` until the keys are registered (§9): Policy 08 reports `Awaiting credential` (NonCompliant, by design) |
| `global-site-b-models`, `tenant-novatech-site-b-governance`, `global-site-b-external-models` | `site-b` | not created until the spoke is added (§7); then grey for 1–2 minutes while Argo connects |

### 6. Verify the hub

Set the cluster once; the same commands verify a spoke in §8.

```bash
CTX="$HUB_CTX"
```

**6.1 Operators converge** (10–20 minutes). First wait for the seven platform policies to turn `Compliant`; they depend on each other (operators, then platform config, then gateway, database, tenant, hardware profiles, service TLS), so this one block covers all of §6.1–6.2 and returns when the platform is up. The two consumer policies are excluded: they stay `NonCompliant` until §9.

```bash
for p in osac-operators osac-platform-config osac-gateway osac-database osac-default-tenant osac-hardware-profiles osac-service-tls; do
  echo "waiting for $p"
  wait_for 1800 "oc get policy $p -n osac-platform" && oc wait --for=jsonpath='{.status.compliant}'=Compliant policy/$p -n osac-platform --timeout=1800s
done
```

A timeout names the policy that is stuck. `osac-operators` stuck means a Subscription is waiting for approval (§11 "Operators stuck"); any other means read its status (§11 "Policy `NonCompliant`"). While you wait, you can watch, or list anything not `Succeeded`:

```bash
oc --context "$CTX" get csv --all-namespaces -o json | jq -r '.items[] | select(.status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase)"'
```

Expect no output. The policies install: cert-manager, RHCL with Authorino, Limitador and DNS (in `kuadrant-system`), LWS, RHOAI, OpenTelemetry and the Cluster Observability Operator. If a Subscription sits at `RequiresApproval`, see §11 "Operators stuck".

**6.2 Policies.**

```bash
oc get policy -n osac-platform -o custom-columns=NAME:.metadata.name,COMPLIANT:.status.compliant
```

Expect the seven platform policies `Compliant`. The two consumer policies (`osac-granite-consumer-secrets`, `osac-facebook-consumer-secrets`) stay `NonCompliant` ("Awaiting credential") until §9.

```bash
oc get policy -n osac-platform -o json | jq -r '.items[] | .metadata.name as $p | .status.status[]? | "\($p)\t\(.clustername)\t\(.compliant)"'
```

Each cluster shows 8 entries (7 platform + its one consumer policy).

**6.3 Platform resources.**

```bash
oc --context "$CTX" get dscinitializations,datasciencecluster -A
oc --context "$CTX" get gateway -n openshift-ingress
oc --context "$CTX" get authorino,kuadrant -n kuadrant-system
oc --context "$CTX" get tenant -n models-as-a-service
oc --context "$CTX" get hardwareprofile -n redhat-ods-applications
```

Expect each to exist; gateways `Programmed`.

**6.4 Models and governance.**

```bash
oc --context "$CTX" get llminferenceservice,maasmodelref -n maas-models
oc --context "$CTX" get maassubscription,maasauthpolicy -n models-as-a-service
```

Expect the site's model `Ready`. Argo has no health check for `LLMInferenceService`, so the models Application is `Healthy` as soon as the object exists; check the model itself.

**Wait** (hub: the CPU simulator; for a GPU model use the longer wait in §8):

```bash
wait_for 600 'oc get llminferenceservice facebook-opt-125m-simulated -n maas-models'
oc wait --for=condition=Ready llminferenceservice/facebook-opt-125m-simulated -n maas-models --timeout=900s
```

**6.5 Authorino TLS.** Authorino must be created with listener TLS on from the start (policy 03), otherwise the gateway's TLS EnvoyFilter is never created.

```bash
oc --context "$CTX" get secret authorino-server-cert -n kuadrant-system
oc --context "$CTX" get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls}' | jq .
oc --context "$CTX" get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
```

Expect all three. If not, see §11 "Inference returns 403 or 500".

The Secret comes from policy `osac-service-tls` and the EnvoyFilter from the RHOAI model controller after the gateway and Authorino exist, so on a fresh site they can lag the policies by a few minutes. Wait for both before judging the TLS (the `oc` calls use the cluster in `CTX`):

```bash
wait_for 600 'oc --context "$CTX" get secret authorino-server-cert -n kuadrant-system && oc --context "$CTX" get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress'
```

If only the EnvoyFilter is missing after the wait, use the recovery in §11 (delete the `odh-model-controller` pod).

**6.6 Database Secrets** are generated on each site by policy `osac-database` (no step to run). Never delete `postgresql-maas-credentials` afterwards (§11).

```bash
oc --context "$CTX" get secret postgresql-maas-credentials -n redhat-ods-applications -o jsonpath='{.data}' | jq 'keys'
oc --context "$CTX" get secret maas-db-config -n redhat-ai-gateway-infra -o jsonpath='{.data}' | jq 'keys'
```

Expect the key names `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`, `POSTGRESQL_DATABASE` and `DB_CONNECTION_URL`.

**Run smoke test row 1** (§10).

---

## Part B — Spoke (`site-b`), once per spoke

For `site-c`, repeat with its own context and `SITE=site-c`.

### 7. Add a spoke

**7.1 Check the spoke.**

```bash
oc --context "$SPOKE_CTX" version
```

Expect a supported OpenShift version with cluster-admin. For a GPU site, the NFD and NVIDIA GPU operators must be installed:

```bash
oc --context "$SPOKE_CTX" get csv -A | grep -E 'nfd|gpu-operator'
```

Expect both `Succeeded`.

**7.2 Import into ACM.** ACM installs the klusterlet and deletes the import Secret afterwards. The Secret carries the spoke's API server and your `oc login` token, which must stay valid during the import.

```bash
SITE=site-b
```

**Re-import only:** if this site was imported before, count the certificate requests the hub kept for it. Detaching a ManagedCluster does not remove them, and once about ten pile up the `cluster-proxy` add-on stops issuing certificates (`too many csr created already on hub`), so Argo can never reach the spoke. Expect `0` on a first import (`oc` also prints "No resources found" on stderr):

```bash
oc get csr -l open-cluster-management.io/cluster-name="$SITE" --no-headers | wc -l
```

If it is not `0`, delete them before importing:

```bash
oc get csr -l open-cluster-management.io/cluster-name="$SITE" -o name | xargs -r oc delete
```

```bash
oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${SITE}
  labels:
    name: ${SITE}
    cloud: auto-detect
    vendor: auto-detect
    cluster.open-cluster-management.io/clusterset: default
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${SITE}
  namespace: ${SITE}
spec:
  applicationManager:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  certPolicyController:
    enabled: true
EOF
```

The `KlusterletAddonConfig` needs the namespace ACM creates for the ManagedCluster; if the apply says it does not exist yet, apply again.

```bash
oc create secret generic auto-import-secret -n "$SITE" \
  --from-literal=autoImportRetry=5 \
  --from-literal=server="$(oc --context "$SPOKE_CTX" whoami --show-server)" \
  --from-literal=token="$(oc --context "$SPOKE_CTX" whoami -t)"
```

```bash
oc wait --for=condition=ManagedClusterConditionAvailable managedcluster/"$SITE" --timeout=900s
```

Expect the wait to succeed, and the `default` clusterset label on the ManagedCluster:

```bash
oc get managedcluster "$SITE" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}{"\n"}'
```

**Wait.** `Available` means the klusterlet joined. Argo reaches the spoke through the `cluster-proxy` add-on, which comes up a little later; do not go to §7.3 until it is `Available`:

```bash
wait_for 600 'oc get managedclusteraddon cluster-proxy -n "$SITE"'
oc wait --for=condition=Available managedclusteraddon/cluster-proxy -n "$SITE" --timeout=600s
```

**7.3 Argo cluster secret.** `GitOpsCluster` creates it from the Placement; Argo reaches the spoke through it. It is created a few minutes after the import (3–4 minutes were seen), so a check straight after §7.2 shows "No resources found". That is not an error, so wait for the secret:

```bash
wait_for 600 'oc get secret "$SITE-application-manager-cluster-secret" -n openshift-gitops'
```

Expect `OK`. Then list it (the `acm-cluster` label is on it):

```bash
oc get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true
```

Expect a `site-b-application-manager-cluster-secret`. The Placement decision lists the spoke:

```bash
oc get placementdecision -n openshift-gitops -o jsonpath='{range .items[*].status.decisions[*]}{.clusterName}{"\n"}{end}'
```

If the wait timed out, see §11 "`GitOpsCluster` failed, no cluster secret"; if the decision is empty, "Spoke Application fails with cluster not found".

**7.4 Site files.** `site-b` is already in this repository. For a **new** spoke, add these, commit and push to `$GIT_BRANCH`; the policies in `hub/platform/` do not change:

| File | Change |
|---|---|
| `hub/platform-sites/site-params.yaml` | add the `<site>.*` keys; set `<site>.cluster-domain` to the spoke's real ingress domain (`$SPOKE_DOMAIN`) |
| `hub/platform-sites/placement.yaml` | add the site to the `name` values |
| `global/sites/<site>/` | `models.app.json` and `models/`, with `argoDestination: <site>` |
| `tenants/novatech/sites/<site>/` | `governance.app.json` and `governance/`, with `argoDestination: <site>` |
| `global/sites/<site>/external-models*` | only if the site consumes a remote model (§9) |

Also add the site to the `osac-gitops-placement` values in §3.

**Wait.** Argo polls Git about every 3 minutes, then the ApplicationSet creates the site's Applications, and they stay grey for 1–2 minutes while Argo connects to the spoke. Wait for them to appear (the ApplicationSet labels each with `osac.io/site`; `site-b` has three, a site without an external-models layer has two), then to be `Synced`:

```bash
wait_for 600 '[ "$(oc get applications.argoproj.io -n openshift-gitops -l osac.io/site="$SITE" --no-headers | wc -l)" -ge 2 ]'
```

```bash
oc wait --for=jsonpath='{.status.sync.status}'=Synced applications.argoproj.io -l osac.io/site="$SITE" -n openshift-gitops --timeout=600s
```

To skip the Git poll after a push, refresh the ApplicationSet: `oc annotate applicationset osac-layers -n openshift-gitops argocd.argoproj.io/application-set-refresh=true --overwrite`. If the Applications stay `Unknown` with `No agent available`, see §11 "Spoke Applications stay `Unknown`".

### 8. Verify the spoke

```bash
CTX="$SPOKE_CTX"
```

**Wait for the spoke's policies.** The policies live on the hub, and the spoke installs the same operators as the hub (10–20 minutes). Wait until the seven platform policies are `Compliant` *for this site* (the `wait` block in §6.1 checks the hub's own status and does not apply here). The consumer policy is left out; it stays `NonCompliant` until §9:

```bash
spoke_ready() { oc get policy -n osac-platform -o json | jq -e --arg s "$1" '[.items[] | select(.metadata.name | contains("consumer-secrets") | not) | .status.status[]? | select(.clustername==$s)] | (length >= 7) and all(.compliant=="Compliant")' >/dev/null; }
```

```bash
wait_for 1800 'spoke_ready "$SITE"'
```

A timeout means a policy is stuck on the spoke: list them with `oc get policy -n osac-platform -o json | jq -r '.items[] | .metadata.name as $p | .status.status[]? | select(.clustername=="site-b") | "\($p)\t\(.compliant)"'` and see §11 "Policy `NonCompliant`" or "Policies never reach the spoke".

Then re-run the CSV listing in §6.1 and §6.3–§6.6 with this `CTX` (skip the policy wait in §6.1 and the hub model wait in §6.4; the `site-b` entry in §6.2 shows 8 policies). Check the GPU model, which takes 3–10 minutes to load (image pull plus weights); this waits for it:

```bash
wait_for 600 'oc --context "$SPOKE_CTX" get llminferenceservice granite-3-1-8b-fp8 -n maas-models'
oc --context "$SPOKE_CTX" wait --for=condition=Ready llminferenceservice/granite-3-1-8b-fp8 -n maas-models --timeout=900s
```

Expect it to print `condition met`. To read the condition on its own later:

```bash
oc --context "$SPOKE_CTX" get llminferenceservice granite-3-1-8b-fp8 -n maas-models -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expect `True`, with the pod on a GPU node:

```bash
oc --context "$SPOKE_CTX" get pods -n maas-models -l app.kubernetes.io/name=granite-3-1-8b-fp8 -o wide
```

If not, see §11 "GPU model". **Run smoke test row 2** (§10).

---

## Part C — Cross-site models, once

A consumer calls a model on another site through an `ExternalProvider`, `ExternalModel` and `MaaSModelRef` (Argo, from the start), authenticated by an API key. Policy 08 delivers the key Secret **only after you register the key** here. Registering is the one manual step: the key is minted on the upstream and stored in a hub Secret, never in Git (P9).

| Model | Consumer | Upstream | Hub Secret you create |
|---|---|---|---|
| `granite-remote` | `site-a` (policy `osac-granite-consumer-secrets`) | `site-b` | `osac-platform/granite-remote-upstream-key` |
| `facebook-remote` | `site-b` (policy `osac-facebook-consumer-secrets`) | `site-a` | `osac-platform/facebook-remote-upstream-key` |

Why a provider can lag: the RHOAI `ExternalProvider` controller checks its Secret once and retries on a growing backoff; it does not watch Secrets. The `osac-provider-recheck` CronJob in each external-models layer wakes a provider stuck on `SecretNotFound` once its Secret exists.

### 9. Register the keys

**9.1 Prerequisites.** Both sites must already pass their smoke test (§6 row 1, §8 row 2): minting a key calls `maas-api` on each upstream, which is not up before then. Both external-models Applications must be `Synced`:

```bash
oc wait --for=jsonpath='{.status.sync.status}'=Synced applications.argoproj.io/global-site-a-external-models applications.argoproj.io/global-site-b-external-models -n openshift-gitops --timeout=600s
```

```bash
oc get applications.argoproj.io global-site-a-external-models global-site-b-external-models -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status
```

Until you register the keys, each provider is `Failed / SecretNotFound` and the consumer policies show "Awaiting credential": that is normal. Create the minting ServiceAccount on both upstreams:

```bash
oc --context "$SPOKE_CTX" create sa cross-cluster-consumer -n models-as-a-service --dry-run=client -o yaml | oc --context "$SPOKE_CTX" apply -f -
oc --context "$HUB_CTX" create sa cross-cluster-consumer -n models-as-a-service --dry-run=client -o yaml | oc --context "$HUB_CTX" apply -f -
```

**9.2 Mint and store the keys** (once per model).

Granite key, minted on `site-b`, stored on the hub:

```bash
SA_TOKEN=$(oc --context "$SPOKE_CTX" create token cross-cluster-consumer \
  -n models-as-a-service --duration=8760h)
GRANITE_KEY=$(curl -sk -X POST \
  "https://maas.${KC_DOMAIN}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $SA_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"granite-consumers"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
oc create secret generic granite-remote-upstream-key \
  -n osac-platform --from-literal=api-key="$GRANITE_KEY" \
  --dry-run=client -o yaml | oc apply -f -
```

Facebook key, minted on the hub, stored on the hub:

```bash
SA_TOKEN_H=$(oc --context "$HUB_CTX" create token cross-cluster-consumer \
  -n models-as-a-service --duration=8760h)
FACEBOOK_KEY=$(curl -sk -X POST \
  "https://maas.${HUB_DOMAIN}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $SA_TOKEN_H" -H "Content-Type: application/json" \
  -d '{"name":"facebook-consumers"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
oc create secret generic facebook-remote-upstream-key \
  -n osac-platform --from-literal=api-key="$FACEBOOK_KEY" \
  --dry-run=client -o yaml | oc apply -f -
```

**9.3 Verify.** Within about a minute both consumer policies are `Compliant` and the key Secret exists on each consumer; within 1–2 minutes the chains are `Ready` with no manual annotation. Wait for both, in this order (a timeout on the first means the hub Secret in §9.2 was not created; on a later one, see §11 "Awaiting credential" and "ExternalProvider stays Failed"):

```bash
oc wait --for=jsonpath='{.status.compliant}'=Compliant policy/osac-granite-consumer-secrets policy/osac-facebook-consumer-secrets -n osac-platform --timeout=300s
```

```bash
wait_for 300 'oc get secret granite-remote-key -n external-models && oc --context "$SPOKE_CTX" get secret facebook-remote-key -n external-models'
```

```bash
wait_for 600 '[ "$(oc get externalprovider.inference.opendatahub.io/granite-remote-provider -n external-models -o jsonpath="{.status.phase}")" = "Ready" ] && [ "$(oc --context "$SPOKE_CTX" get externalprovider.inference.opendatahub.io/facebook-remote-provider -n external-models -o jsonpath="{.status.phase}")" = "Ready" ]'
```

Then read the result:

```bash
oc get policy osac-granite-consumer-secrets osac-facebook-consumer-secrets -n osac-platform -o custom-columns=NAME:.metadata.name,COMPLIANT:.status.compliant
```

```bash
oc get secret granite-remote-key -n external-models
oc --context "$SPOKE_CTX" get secret facebook-remote-key -n external-models
```

Use fully qualified kinds: `externalmodel` is also defined by `maas.opendatahub.io`, so the bare name is ambiguous.

```bash
oc get externalprovider.inference.opendatahub.io/granite-remote-provider \
  externalmodel.inference.opendatahub.io/granite-remote \
  maasmodelref.maas.opendatahub.io/granite-remote \
  -n external-models \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}: {.status.phase}{"\n"}{end}'
```

```bash
oc --context "$SPOKE_CTX" \
  get externalprovider.inference.opendatahub.io/facebook-remote-provider \
      externalmodel.inference.opendatahub.io/facebook-remote \
      maasmodelref.maas.opendatahub.io/facebook-remote \
  -n external-models \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}: {.status.phase}{"\n"}{end}'
```

Expect all six objects `Ready`. If not, see §11 "Awaiting credential" and "ExternalProvider stays Failed".

**9.4 Add a consumer (optional; skip it with two sites).** Only when you add a third site, for example `site-c` as a Granite consumer. No new key is needed; the same hub Secret is reused:

```bash
oc patch placement osac-granite-consumers -n osac-platform --type=json \
  -p='[{"op":"add","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/0/values/-","value":"site-c"}]'
```

The consumer also needs its own external-models Argo layer: copy the `site-a` or `site-b` layer, set the site name and `argoDestination`, and set the provider and Secret names in `provider-recheck.yaml`.

**Run smoke test rows 3 and 4** (§10).

---

## 10. Smoke test

Flow: Keycloak JWT → API key minted with it → inference with the key → rate limit. Minting succeeds only if one of the user's groups matches a MaaSSubscription, so it also proves the governance pair. The JWT always comes from the one Keycloak; API keys are per site.

| Row | Call from | Gateway domain | URL prefix | `MODEL_PATH` | `MODEL_ID` | Run after |
|---|---|---|---|---|---|---|
| 1 | `site-a` | `$HUB_DOMAIN` | `maas-models` | `facebook-opt-125m-simulated` | `facebook/opt-125m` | §6 |
| 2 | `site-b` | `$SPOKE_DOMAIN` | `maas-models` | `granite-3-1-8b-fp8` | `granite-3.1-8b-instruct-fp8` | §8 |
| 3 | `site-a` → Granite on `site-b` | `$HUB_DOMAIN` | `external-models` | `granite-remote` | `granite-remote` | §9 |
| 4 | `site-b` → Facebook on `site-a` | `$SPOKE_DOMAIN` | `external-models` | `facebook-remote` | `facebook-remote` | §9 |

**10.1 Get a JWT** (once; valid for all rows). `novatech-free` is a test user in the Keycloak realm.

```bash
JWT=$(curl -sk -X POST \
  "https://keycloak.${KC_DOMAIN}/realms/osac/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=osac-cli \
  -d username=novatech-free --data-urlencode "password=${KC_PASS}" -d scope=openid \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
echo "JWT: ${JWT:0:20}..."
```

**10.2 Pick a row.** Set the four variables from the table. Example for row 1:

```bash
ROW=1; DOMAIN="$HUB_DOMAIN"; PREFIX=maas-models; MODEL_PATH=facebook-opt-125m-simulated; MODEL_ID=facebook/opt-125m
```

**10.3 Mint an API key** (expect HTTP 201).

```bash
KEY=$(curl -sk -w "\nHTTP %{http_code}\n" -X POST "https://maas.${DOMAIN}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${JWT}" -H 'Content-Type: application/json' \
  -d "{\"name\":\"smoke-row-${ROW}-$(date +%s)\"}" \
  | tee /dev/stderr | python3 -c 'import sys,json; lines=sys.stdin.readlines(); print(json.loads(lines[0])["key"])' 2>/dev/null)
echo "key: ${KEY:0:12}..."
```

**10.4 Inference** (expect HTTP 200).

```bash
curl -sk -X POST "https://maas.${DOMAIN}/${PREFIX}/${MODEL_PATH}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}],\"max_tokens\":20}" \
  -w "\nHTTP %{http_code}\n"
```

Rows 1 and 4 answer with random tokens (the CPU simulator, `facebook/opt-125m`); rows 2 and 3 answer in plain text, and row 3's `system_fingerprint` is `vllm-0.x`, proving the request reached the GPU model on `site-b`.

**10.5 Rate limit** (expect 429 within 8 calls; the free tier is 100 tokens a minute).

```bash
for i in $(seq 1 8); do
  curl -sk -o /dev/null -w "req $i: HTTP %{http_code}\n" \
    -X POST "https://maas.${DOMAIN}/${PREFIX}/${MODEL_PATH}/v1/chat/completions" \
    -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"tell me a long story\"}],\"max_tokens\":50}"
done
```

**If not:**
- **4xx on the key:** no group in the JWT matched a subscription. Inspect the groups: `jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$JWT"`.
- **401 on the key:** the site cannot reach or trust Keycloak (§11 "API key minting returns 401").
- **403 on rows 3 and 4:** the subscription or auth policy does not include the external model; re-sync the governance layer and wait 30 s.
- **404 on rows 3 and 4:** `MODEL_ID` must equal the ExternalModel `metadata.name`.

---

## 11. Troubleshooting

### Application `Unknown` or `Missing`

```bash
oc get appproject <project-name> -n openshift-gitops -o yaml
oc logs deployment/openshift-gitops-repo-server -n openshift-gitops --tail=50
```

A spoke Application is grey for 1–2 minutes after creation while Argo connects through the cluster proxy. If it stays grey, check the controller was not OOMKilled (§4.3). If Applications still show old descriptor values, restart the repo-server and re-create the ApplicationSet.

### Spoke Applications stay `Unknown`: `No agent available`

The sync condition reads `proxy to anp-proxy-server failed because No agent available`. Argo reaches the spoke through the `cluster-proxy` add-on, and a re-imported spoke can leave that add-on without a certificate. Check:

```bash
oc get managedclusteraddon cluster-proxy -n site-b -o json | jq -r '.status.conditions[] | select(.type=="ClusterCertificateRotated" or .type=="Available") | .type+"="+.status+" "+.reason+" "+(.message//"")'
```

`ClientCertificateUpdateFailed: Stop creating csr since there are too many csr created already on hub` means the hub still holds certificate requests from an earlier registration of the same name (teardown did not remove them). Delete the ones older than the current import (replace the timestamp with the import time), then restart the stuck agent on the spoke:

```bash
oc get csr -l open-cluster-management.io/cluster-name=site-b -o json | jq -r '.items[] | select(.metadata.creationTimestamp < "<UTC import time, e.g. 2026-10-08T17:00:00Z>") | .metadata.name' | xargs -r oc delete csr
```

```bash
oc --context "$SPOKE_CTX" delete pod -n open-cluster-management-agent-addon -l proxy.open-cluster-management.io/component-name=proxy-agent
oc --context "$SPOKE_CTX" get pods -n open-cluster-management-agent-addon | grep cluster-proxy-proxy-agent
```

Expect the new pod `3/3 Running`, the add-on `Available`, and the Applications to leave `Unknown` within a few minutes.

### Application `not permitted in project` or `forbidden`

The AppProject allowlist and the §4.2 ClusterRole are applied by hand, so an older hub does not allow newly added kinds. Nothing deployed is deleted, but the Application shows a sync error and skips that revision after its retries. Re-apply, then refresh:

```bash
oc apply -f hub/projects/scope-global.yaml
oc annotate applications.argoproj.io global-site-a-external-models -n openshift-gitops --overwrite argocd.argoproj.io/refresh=hard
```

For a spoke, the credential is the one ACM provisions on the spoke, not the hub's Argo service account. Read the denied kind from the sync result:

```bash
oc get applications.argoproj.io global-site-b-models -n openshift-gitops -o jsonpath='{.status.operationState.message}{"\n"}'
```

### Spoke Application fails with `cluster ... not found`

Argo has no cluster secret named after the descriptor's `argoDestination`. Check in order: the ManagedCluster exists and is `Available`; the Placement selects it (`oc get placementdecision -n openshift-gitops`; if nothing is selected, check the `ManagedClusterSetBinding` `default` in `openshift-gitops`, §3); the secret exists (`oc get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true`); the descriptor's `argoDestination` matches the secret's cluster name exactly. Then refresh the Application with `argocd.argoproj.io/refresh=hard`.

### `GitOpsCluster` failed, no Argo cluster secret (§7.3 times out)

The §7.3 wait ends in `TIMEOUT` and `oc get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true` finds nothing. Read the `GitOpsCluster` status:

```bash
oc get gitopscluster osac-gitops-cluster -n openshift-gitops -o jsonpath='{.status.phase}{"\n"}{.status.message}{"\n"}'
```

If it reads `failed` with `legacy secret not found for managed cluster site-b: secrets "site-b-application-manager-cluster-secret" not found`, the cluster has joined but the controller has not retried since. Confirm the cluster and the `cluster-proxy` add-on are `Available` (§7.2), then force a reconcile:

```bash
oc annotate gitopscluster osac-gitops-cluster -n openshift-gitops reconcile-at="$(date +%s)" --overwrite
```

Run the §7.3 wait again. Also look at the stale certificate requests (§7.2 re-import check): about ten or more make `cluster-proxy` stop issuing certificates. This was seen once (2026-10-08: 21 stale CSRs, a fresh import, the error for about 4 minutes, then the secret appeared). It is not confirmed whether the annotation, the stale-CSR cleanup or just more time produced the secret, so treat the annotation as a safe nudge, not a proven fix.

### Policy `NonCompliant`

```bash
oc get policy osac-platform.<policy-name> -n <cluster-namespace> -o json | jq -r '.status.details[]? | .templateMeta.name+" = "+.compliant+" :: "+(.history[0].message|.[0:200])'
```

The replicated copy of each policy lives in the cluster's namespace on the hub (`local-cluster`, `site-b`). A policy that renders nothing counts as `Compliant`, so a re-check can lag by the evaluation interval.

### Policies never reach the spoke

The root policy has no `site-b` entry in `.status.status[]`. Check: the spoke is in `hub/platform-sites/placement.yaml` and `global-hub-platform-sites` has synced; the ManagedCluster carries the `default` clusterset label; the add-ons are running (`oc get managedclusteraddon -n site-b`; `governance-policy-framework` and `config-policy-controller` must be `Available`).

### Operators stuck (`InstallPlanPending`, `RequiresApproval`)

List plans awaiting approval and approve only the ones for operators this runbook installs:

```bash
oc get installplan --all-namespaces -o json | jq -r '.items[] | select(.status.phase=="RequiresApproval") | "\(.metadata.namespace)/\(.metadata.name) \(.spec.clusterServiceVersionNames[0])"'
oc patch installplan <plan-name> -n <namespace> --type merge -p '{"spec":{"approved":true}}'
```

Leave the `servicemeshoperator3` plans in `openshift-operators`: the ingress operator owns that Manual Subscription and approves only its own pinned version, so they wait by design on a healthy cluster. RHCL must live in its own OperatorGroup in `kuadrant-system` (policy 01 does this); in `openshift-operators` the Manual Service Mesh plan locks it out. Use `subscription.operators.coreos.com`, not `subscription`: ACM installs its own `Subscription` kind.

### Inference returns 403 or 500 (Authorino TLS)

Key minting works but inference returns 403 (Authorino cannot verify maas-api) or 500 (gateway to Authorino fails).

```bash
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}{"\n"}'
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
```

If the EnvoyFilter is missing, `odh-model-controller` saw Authorino with TLS off and never re-checks. Make it reconcile the Gateway again:

```bash
oc delete pod -n redhat-ods-applications -l control-plane=odh-model-controller
```

If `authorino-server-cert` or the Authorino Deployment is missing after 2 minutes, check service-CA (`oc get deployment service-ca -n openshift-service-ca`) and the annotation on the `authorino-authorino-authorization` Service.

### GPU model stays Pending or never becomes Ready

Run on the GPU site (`$SPOKE_CTX`):

```bash
oc --context "$SPOKE_CTX" get pods -n maas-models -l app.kubernetes.io/name=granite-3-1-8b-fp8 -o wide
oc --context "$SPOKE_CTX" get events -n maas-models --sort-by=.lastTimestamp | tail -20
oc --context "$SPOKE_CTX" logs -n maas-models -l app.kubernetes.io/name=granite-3-1-8b-fp8 -c main --tail=50
```

- **Pending, node affinity or `Insufficient nvidia.com/gpu`:** no free GPU node. The pod needs `nvidia.com/gpu.present=true` (NFD + GPU operator) and an unallocated GPU; each `g5.2xlarge` has one.
- **Pull errors:** the cluster cannot pull the `oci://quay.io/...` model image or the vLLM image.
- **`OOMKilled` or restarts:** lower `--max-model-len` in `global/sites/site-b/models/granite-3-1-8b-fp8.yaml`, or raise the memory limit (the node has 32 GiB).

### API key minting returns 401

The site's maas-api and Authorino validate the JWT against its `identity-issuer`, the Keycloak on the hub. Re-run the reachability check in §1.3 from the failing cluster, and check the token's `iss` claim equals `<site>.identity-issuer` in `osac-site-params` exactly.

### Policy 08 `NonCompliant`: "Awaiting credential"

The hub Secret `osac-platform/<model>-upstream-key` does not exist yet. This is the expected idle state before §9, not an error.

```bash
oc get secret granite-remote-upstream-key facebook-remote-upstream-key -n osac-platform
```

Register the missing key (§9.2). If the Secret exists and the policy stays `NonCompliant` for more than a couple of minutes, force a re-render:

```bash
oc annotate policy osac-granite-consumer-secrets -n osac-platform --overwrite osac.io/rerender=$(date +%s)
```

### ExternalProvider stays `Failed / SecretNotFound` after the key was registered

The recheck job should wake it within about a minute of the Secret appearing.

```bash
oc get secret granite-remote-key -n external-models
oc get pods -n external-models --sort-by=.metadata.creationTimestamp | grep osac-provider-recheck | tail -3
oc logs -n external-models -l job-name --tail=20
```

- **Secret missing:** Policy 08 has not delivered it (entry above).
- **No recheck pods:** the CronJob was not synced; see "not permitted in project".
- **`ImagePullBackOff`:** the internal `openshift/cli` ImageStream tag is not pullable on that cluster.

Manual fallback, the same command the job runs:

```bash
oc annotate externalprovider.inference.opendatahub.io granite-remote-provider -n external-models --overwrite osac.io/secret-recheck=$(date +%s)
```

### MaaSModelRef advertises a stale hostname after changing `cluster-domain`

`cluster-domain` in `osac-site-params` must equal the cluster's real ingress domain (`oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'`). Policy 03 renders it as the `https-ext` listener hostname on `maas-default-gateway`. After fixing it, the Gateway updates in place within seconds, but the MaaSModelRef controller does not re-derive `status.endpoint` (it ignores annotations). Restart it once on every site whose domain changed:

```bash
oc rollout restart deployment/maas-controller -n redhat-ods-applications
oc get maasmodelref.maas.opendatahub.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ENDPOINT:.status.endpoint
```

### PostgreSQL rejects the password after a Secret was deleted

PostgreSQL stores the password when its volume is first initialised. If `postgresql-maas-credentials` is deleted, policy 04 generates a new password the database does not accept. Restore the old Secret, or delete the `postgresql-data-postgresql-0` PVC to re-initialise the database (this loses all API keys).
