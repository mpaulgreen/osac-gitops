# OSAC GitOps — Install Guide (RHOAI 3.6)

Deploys the OSAC MaaS platform on a hub and its spokes using the two-plane
ACM + GitOps design pattern.

| Site | Cluster | ACM ManagedCluster | Argo destination | Models |
|---|---|---|---|---|
| `site-a` (hub) | `hub` | `local-cluster` | `in-cluster` | `facebook-opt-125m`, `smollm2-135m-instruct` (CPU) |
| `site-b` (spoke) | `site-b-cluster` | `site-b` | `site-b` | same (CPU) |

- **Platform plane** (`hub/platform/`, policies 00–17): Argo applies ACM policies to the hub; ACM delivers them to every selected site.
- **Intent plane** (models, grid-models, governance): Argo pushes straight to each site.
- **Infrastructure** (policies 15–17): ODF, ACM, and Submariner as ACM policies for complete cluster management.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| OpenShift | 4.20+ with cluster-admin on every cluster |
| Tools | `oc`, `git`, `jq`, `curl`, `python3`, `gh`, `clusteradm` |
| Git | This repository pushed to GitHub, branch `feature/rhoai-3.6` |
| GPU sites | NFD + NVIDIA GPU operator pre-installed on GPU nodes |
| Keycloak realms | Bundled in `hub/platform/keycloak-realms/` — deployed by Policy 09 |

---

## 1. Set Environment Variables

Run in every new terminal. Contexts come from `oc login`.

```bash
export HUB_CTX="default/api-hub-example.com:6443/kube:admin"   #REPLACE-ME
export SPOKE_CTX="default/api-site-b-example.com:6443/kube:admin"   #REPLACE-ME
export REPO_URL="https://github.com/mpaulgreen/osac-gitops.git"
export GIT_BRANCH="feature/rhoai-3.6"
export GITHUB_USER="mpaulgreen"   #REPLACE-ME
export KC_PASS="<password of the Keycloak test user novatech-free>"   #REPLACE-ME
```

Before running any command, update the placeholder values in:

| File | Keys to update |
|---|---|
| `hub/platform-sites/site-params.yaml` | `cluster-domain`, `identity-issuer`, `rhoai-fbc-image` (digest), `hardware-profiles` |

Search for all placeholders: `grep -rn REPLACE-ME .`

---

## 2. Bootstrap the Hub

```bash
oc config use-context "$HUB_CTX"
./scripts/bootstrap.sh --seed-pull-secret --yes
```

**What it does:**
1. Installs the OpenShift GitOps operator
2. Configures Argo CD RBAC (cluster-admin for the controller, ACM policy RBAC)
3. Patches Argo controller memory limits
4. Applies AppProjects (`platform-policies`, `scope-global`, `scope-tenant-*`)
5. Creates the ACM plumbing (ManagedClusterSetBinding, GitOpsCluster, Placement)
6. Creates the Git repository secret (reads token from `gh auth token`)
7. Deploys the `osac-layers` ApplicationSet
8. Creates hub-only Placement and hub-templating RBAC for Keycloak Route lookups
9. Seeds the Quay pull secret for FBC nightly builds (when `--seed-pull-secret`)
10. Waits for all hub Applications to sync

**Expected result:** All Argo CD Applications show `Synced`. Platform policies begin propagating. Keycloak, CNPG, Redis, and ESO deploy on the hub.

---

## 3. Add a Spoke

```bash
./scripts/import-managed-cluster.sh \
  --hub-context "$HUB_CTX" \
  --spoke-context "$SPOKE_CTX" \
  --cluster-name site-b \
  --yes
```

**What it does:**
1. Creates the ManagedCluster on the hub
2. Installs the klusterlet on the spoke via `clusteradm join`
3. Accepts the cluster on the hub
4. Waits for `ManagedClusterJoined` condition
5. Enables the `application-manager` addon
6. Waits for the Argo CD cluster secret to appear

Repeat for each additional spoke.

---

## 4. Verify

### 4.1 Check policy compliance

```bash
oc -n osac-platform get policies
```

All policies should show `Compliant`. If a policy is `NonCompliant`, describe it to see which template failed:

```bash
oc -n osac-platform describe policy <policy-name>
```

### 4.2 Check Argo CD Applications

```bash
oc -n openshift-gitops get applications
```

All Applications should show `Synced` / `Healthy`.

### 4.3 Run smoke tests

```bash
export HUB_DOMAIN=$(oc --context "$HUB_CTX" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
./scripts/smoke-test.sh --domain "$HUB_DOMAIN" --password "$KC_PASS"
```

For a spoke:

```bash
export SPOKE_DOMAIN=$(oc --context "$SPOKE_CTX" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
./scripts/smoke-test.sh --domain "$SPOKE_DOMAIN" --password "$KC_PASS"
```

**What it does:**
1. Gets a JWT from Keycloak
2. Mints an API key for `facebook-opt-125m`
3. Runs a completions inference request
4. Tests rate limiting with rapid requests
5. Cleans up the API key

---

## 5. Register Cross-Site Model Keys (manual)

Cross-site model access requires minting API keys on each site and distributing them via Policy 08. This step requires human judgment about which models to expose cross-site.

```bash
# On the hub: get a JWT and mint a key for site-b to use
JWT=$(curl -sk "https://keycloak.${HUB_DOMAIN}/realms/saas/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=tenant-demo" \
  -d "username=novatech-free" -d "password=${KC_PASS}" -d "scope=openid" | jq -r .access_token)

API_KEY=$(curl -sk "https://maas.${HUB_DOMAIN}/api/v1/api_keys" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"name":"site-b-cross-cluster","model_ids":["facebook-opt-125m"]}' | jq -r .api_key)

# Create the secret on the hub for Policy 08 to distribute
oc -n osac-platform create secret generic osac-cross-site-api-keys \
  --from-literal=site-b-api-key="$API_KEY" \
  --dry-run=client -o yaml | oc apply -f -
```

---

## 6. Adding a New Site

1. Add site-params keys in `hub/platform-sites/site-params.yaml`:
   ```yaml
   site-c.rhoai-channel: "stable-3.6"
   site-c.rhoai-source: "rhoai-catalog-dev"
   site-c.rhoai-fbc-image: "quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.6@sha256:..."
   site-c.cluster-domain: "apps.site-c.example.com"
   site-c.identity-issuer: "https://keycloak.apps.hub.example.com/realms/saas"
   site-c.grid-enabled: "true"
   site-c.grid-site-name: "site-c"
   site-c.grid-network-name: "grid"
   site-c.grid-gateway-name: "grid-gateway"
   site-c.grid-namespace: "redhat-ai-grid"
   site-c.hardware-profiles: |
     [{"name": "cpu-only", ...}]
   ```

2. Create model and governance directories:
   ```
   global/sites/site-c/models/         (copy from site-a)
   global/sites/site-c/models.app.json (set site: "site-c", argoDestination: "site-c")
   global/sites/site-c/grid-models/    (copy from site-a)
   global/sites/site-c/grid-models.app.json
   tenants/novatech/sites/site-c/governance/
   tenants/novatech/sites/site-c/governance.app.json
   ```

3. Commit and push.

4. Import the spoke:
   ```bash
   ./scripts/import-managed-cluster.sh \
     --hub-context "$HUB_CTX" \
     --spoke-context "$SITE_C_CTX" \
     --cluster-name site-c \
     --yes
   ```

5. Add a declared peer in Policy 12 if needed for Grid cross-site routing.

---

## 7. Troubleshooting

### Policy stuck NonCompliant

```bash
oc -n osac-platform describe policy <name>
oc -n <managed-cluster> get configurationpolicies -o wide
```

Look at the `complianceState` and `message` on each ConfigurationPolicy status.

### Argo Application not syncing

```bash
oc -n openshift-gitops describe application <name>
oc -n openshift-gitops logs deployment/openshift-gitops-argocd-application-controller | grep <name>
```

### Keycloak not starting

```bash
oc -n maas-db get pods -l app.kubernetes.io/name=keycloak
oc -n maas-db logs deployment/keycloak -c render-realm-import
oc -n maas-db logs deployment/keycloak -c keycloak
```

Common issues:
- CNPG cluster not ready yet → check `oc -n maas-db get cluster maas-db`
- ESO secrets not created → check `oc -n maas-db get externalsecrets`
- Signing keys not ready → check `oc -n maas-db get certificates`

### CNPG database issues

```bash
oc -n maas-db get cluster maas-db -o jsonpath='{.status.phase}'
oc -n maas-db get pods -l cnpg.io/cluster=maas-db
```

### FBC catalog not resolving

```bash
oc get catalogsource rhoai-catalog-dev -n openshift-marketplace -o yaml
oc get imagedigestmirrorset quay-registry -o yaml
```

Verify the pull secret is in place:
```bash
oc -n openshift-marketplace get secret rhoai-catalog-pull-secret
```

### Grid enrollment issues

```bash
oc -n redhat-ai-grid get gridnetwork
oc -n redhat-ai-grid get gridsites
oc -n redhat-ai-grid get inferenceproviders
```

---

## Appendix A: Manual Bootstrap

For environments where scripts cannot run, the individual steps are:

1. `oc apply -f bootstrap/` — install GitOps operator
2. Wait for `applications.argoproj.io` CRD
3. `oc apply -f hub/projects/` — AppProjects
4. Create cluster-admin ClusterRoleBinding for Argo controller
5. Create ACM policy ClusterRole + ClusterRoleBinding
6. Patch Argo controller memory: `oc -n openshift-gitops patch argocd ...`
7. Create ManagedClusterSetBinding, GitOpsCluster, Placement in `openshift-gitops`
8. Create Git repo secret with `argocd.argoproj.io/secret-type: repository` label
9. `oc apply -f hub/applicationsets/` — deploy the osac-layers ApplicationSet
10. Create hub-only Placement and hub-templating RBAC in `osac-platform`
11. Seed Quay pull secret in `osac-platform` (if using FBC nightly)

See `scripts/bootstrap.sh` for the exact commands.

---

## Appendix B: Component Inventory

| Policy | Component | Source |
|---|---|---|
| 00 | FBC CatalogSource, ImageDigestMirrorSet, pull secret | ai-grid-tenant/rhoai-prerequisites |
| 01 | cert-manager, RHCL, LWS, RHOAI, OTel, COO, CNPG, ESO, Redis | Operators |
| 02 | DSCInitialization, DataScienceCluster (AI Grid), Dashboard | RHOAI config |
| 03 | MaaS Gateway, Inference Gateway, Kuadrant, Authorino, Route | Gateway API |
| 04 | CloudNativePG Cluster, DB connection URL | ai-grid-tenant/maas-db |
| 05 | AITenant, MaasTenantConfig, Grid ExternalProvider, namespaces | ai-grid-tenant/rhoai |
| 06 | Hardware profiles | site-params |
| 07 | Service TLS (cert-manager) | cert-manager |
| 08 | External model API key secrets | hub-template distribution |
| 09 | Keycloak (deployment, secrets, signing, realm, route) | ai-grid-tenant/keycloak |
| 10 | Redis + Limitador | ai-grid-tenant/limitador-redis |
| 11 | Grid NetworkPolicies | ai-grid-tenant networking |
| 12 | Grid enrollment (hub-only) | ai-grid-tenant/rhoai |
| 13 | GridNetwork CR | ai-grid-tenant/grid-network |
| 14 | Observability (ScrapeConfigs, RBAC, NetworkPolicy) | ai-grid-tenant/ai-grid-o11y |
| 15 | ODF operator + StorageCluster | ai-grid-tenant/odf |
| 16 | ACM operator + MultiClusterHub + Observability | ai-grid-tenant/acm |
| 17 | Submariner broker + per-site addons | ai-grid-tenant/acm |
