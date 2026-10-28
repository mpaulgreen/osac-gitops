# Plan: Adapt RHOAI 3.6 MaaS Components to osac-gitops Design Pattern

## Context

The osac-gitops repo implements a two-plane ACM + GitOps design pattern for MaaS on RHOAI 3.5.1. A separate team is developing MaaS on RHOAI 3.6 in `/Users/mrigankapaul/Documents/knowledgebase/ai-grid-tenant` using nightly builds with File Based Catalog (FBC). Their repo uses a different pattern (Helm charts, sync-waves, per-app ApplicationSets). We need to extract all RHOAI 3.6 components from ai-grid-tenant and implement them using the osac-gitops two-plane design pattern (raw manifests, ACM policies, `.app.json` descriptors, no Helm/Kustomize). Work happens on a new branch `feature/rhoai-3.6`.

---

## Branch

Create `feature/rhoai-3.6` from `main`.

---

## Policy Map (Platform Plane)

The current 8 policies (01–08) expand to 18 (00–17). Each new policy file also gets a corresponding `-binding.yaml`.

| # | Policy Name | Status | Summary |
|---|---|---|---|
| 00 | `osac-prerequisites` | **NEW** | FBC catalog, image mirrors, pull secret distribution |
| 01 | `osac-operators` | **MODIFY** | Add CNPG, ESO, Redis operators; parameterize RHOAI source |
| 02 | `osac-platform-config` | **MODIFY** | Add `aiGrid: Managed` to DSC |
| 03 | `osac-gateway` | **MODIFY** | Namespace-restricted listeners, Grid gateway annotation |
| 04 | `osac-database` | **REWRITE** | Replace StatefulSet PostgreSQL with CloudNativePG |
| 05 | `osac-default-tenant` | **MODIFY** | `AITenant` replaces `Tenant`, add `MaasTenantConfig`, Grid ExternalProvider, new namespaces |
| 06 | `osac-hardware-profiles` | unchanged | — |
| 07 | `osac-service-tls` | unchanged | — |
| 08 | `osac-external-model-secrets` | unchanged | — |
| 09 | `osac-keycloak` | **NEW** | Keycloak deployment, DB role, secrets (ESO), signing keys (cert-manager), realm import, route, public URL distribution |
| 10 | `osac-redis-limitador` | **NEW** | RedisReplication (3-node Sentinel), Limitador CR, Redis connection secret, NetworkPolicy |
| 11 | `osac-grid-network-policies` | **NEW** | NetworkPolicies for `ai-grid-internal-models` |
| 12 | `osac-grid-enrollment` | **NEW** | Hub-only: `grid-enrollment-invites` namespace, ServiceExport, declared peers (GridSite + InferenceProvider) |
| 13 | `osac-grid-network` | **NEW** | Per-site GridNetwork CR in `redhat-ai-grid` |
| 14 | `osac-observability` | **NEW** | ScrapeConfigs, RBAC, NetworkPolicies for ACM observability integration |
| 15 | `osac-odf` | **NEW** | ODF operator + StorageCluster |
| 16 | `osac-acm` | **NEW** | ACM operator, MultiClusterHub, MultiClusterObservability, policy addons |
| 17 | `osac-submariner` | **NEW** | Submariner broker, per-site ManagedClusterAddOn + SubmarinerConfig |

---

## Step-by-Step Implementation

### Step 1: Create branch and Policy 00 (Prerequisites)

Create branch `feature/rhoai-3.6` from `main`.

Create `hub/platform/00-prerequisites-policy.yaml` + `hub/platform/00-prerequisites-binding.yaml`:
- **`osac-image-mirrors`**: `ImageDigestMirrorSet` `quay-registry` — mirrors `registry.redhat.io/rhoai` → `quay.io/rhoai` (NeverContactSource), plus `rhaii`, `rhaii-early-access`, `rhaii-fast` → `registry.stage.redhat.io`. Adapted from `ai-grid-tenant/apps/rhoai-prerequisites/hub/03-policy.yaml` template `rhoai-image-mirror`.
- **`osac-fbc-catalog`**: `CatalogSource` `rhoai-catalog-dev` in `openshift-marketplace` with FBC image from hub template `{{hub fromConfigMap "osac-platform" "osac-site-params" (printf "%s.rhoai-fbc-image" .ManagedClusterName) hub}}`. References `secrets: [rhoai-catalog-pull-secret]`.
- **`osac-catalog-pull-secret`**: Hub-template distribution of `rhoai-quay-pull-secret` from `osac-platform` namespace (manually seeded, never in Git). Same guard pattern as Policy 08: `{{hub if (lookup ...) hub}}`.
- **`osac-global-pull-secret-merge`**: Managed-side template that merges `quay.io/rhoai` auth from `rhoai-catalog-pull-secret` into the cluster's `openshift-config/pull-secret`. Adapted from `rhoai-global-pull-secret` template.

Binding: `osac-platform-sites` Placement.

### Step 2: Modify Policy 01 (Operators)

Modify `hub/platform/01-operators-policy.yaml`:
- **Group C (RHOAI)**: Parameterize `source` via hub template: `source: '{{hub fromConfigMap "osac-platform" "osac-site-params" (printf "%s.rhoai-source" .ManagedClusterName) hub}}'`. This allows nightly FBC (`rhoai-catalog-dev`) or GA (`redhat-operators`) per site.
- **New Group E (CloudNativePG)**: Namespace `cnpg-system`, OperatorGroup `cnpg-system` (AllNamespaces), Subscription `cloudnative-pg` from `certified-operators`, channel `stable-v1`.
- **New Group F (External Secrets)**: Namespace `external-secrets-operator`, OperatorGroup `openshift-external-secrets-operator` (AllNamespaces), Subscription `openshift-external-secrets-operator` from `redhat-operators`, channel `stable-v1`. Plus cluster-scoped `ExternalSecretsConfig` CR.
- **New Group G (Redis)**: Namespace `limitador-redis`, OperatorGroup `limitador-redis` (targetNamespaces: `[limitador-redis]`), Subscription `redis-operator` from `community-operators`, channel `stable`.

### Step 3: Update bridge layer (site-params)

Modify `hub/platform-sites/site-params.yaml` — add new keys per site:
```
<site>.rhoai-channel: "stable-3.6"                    # was stable-3.5
<site>.rhoai-source: "rhoai-catalog-dev"               # NEW
<site>.rhoai-fbc-image: "quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.6@sha256:58f8056d..."  # NEW
<site>.grid-enabled: "true"                            # NEW
<site>.grid-site-name: "<site-name>"                   # NEW
<site>.grid-network-name: "grid"                       # NEW
<site>.grid-gateway-name: "grid-gateway"               # NEW
<site>.grid-namespace: "redhat-ai-grid"                # NEW
```

### Step 4: Rewrite Policy 04 (Database — CNPG replaces StatefulSet)

Rewrite `hub/platform/04-database-policy.yaml`:
- **`osac-database-namespaces`**: Create `maas-db` namespace (new, for CNPG cluster + Keycloak) and `redhat-ai-gateway-infra` (unchanged), `redhat-ods-applications` (unchanged).
- **`osac-cnpg-cluster`**: CNPG `Cluster` named `maas-db` in `maas-db`, 3 instances, initdb with database `maas` / owner `maas_api`, 20Gi storage, `serverAltDNSNames` including `maas-db-rw.maas-db.svc.clusterset.local`. Adapted from `ai-grid-tenant/apps/maas-db/local-cluster/10-primary.yaml`.
- **`osac-database-connection`**: Managed-side template reads CNPG-generated `maas-db-app` secret from `maas-db` namespace, creates `maas-db-config` secret in `redhat-ai-gateway-infra` with the connection URL. No `randAlphaNum` needed — CNPG auto-generates credentials.

### Step 5: Modify Policy 02 (Platform Config)

Modify `hub/platform/02-platform-config-policy.yaml`:
- Add `aiGrid: managementState: Managed` to `DataScienceCluster` components.

### Step 6: Modify Policy 03 (Gateway)

Modify `hub/platform/03-gateway-policy.yaml`:
- Restrict inference gateway `allowedRoutes` to namespace selectors matching `openshift-ingress` and `ai-grid-internal-models`.
- Restrict MaaS gateway `allowedRoutes` to namespace selectors matching `openshift-ingress`, `models-as-a-service`, and `redhat-ai-gateway-infra`.

### Step 7: Modify Policy 05 (Default Tenant)

Modify `hub/platform/05-default-tenant-policy.yaml`:
- Replace `Tenant` CR with `AITenant` (apiVersion `maas.opendatahub.io/v1alpha1`) in `ai-tenants` namespace. Spec changes: `gateway.name`, `oidc` with `accessTokenPurpose`, `accessTokenPurposeClaim`, `audience`, `clientId`, `issuerUrl`. The `issuerUrl` dynamically resolves the Keycloak Route via hub template with `hubTemplateOptions.serviceAccountName`.
- Add `MaasTenantConfig` in `models-as-a-service` with telemetry config (logs capture added).
- Create `ai-tenants` namespace.
- Change model namespace from `maas-models` to `ai-grid-internal-models` with label `grid.opendatahub.io/allowed: "true"`.
- Create `redhat-ai-grid` namespace.
- Add `grid-provider` `ExternalProvider` in `models-as-a-service` pointing to `grid-gateway.redhat-ai-grid.svc.cluster.local:443` with dummy API key secret and service-CA TLS. Adapted from `ai-grid-tenant/apps/rhoai/hub/02-tenant-policy.yaml`.

### Step 8: Create Policy 09 (Keycloak) — hub-only

Create `hub/platform/09-keycloak-policy.yaml` + binding:
- **`osac-keycloak-db-role`**: CNPG `DatabaseRole` + `Database` for keycloak in `maas-db`.
- **`osac-keycloak-secrets`**: ESO `Password` generators and `ExternalSecret` resources for `keycloak-db`, `keycloak-secrets`, `keycloak-signing-keystore-password`.
- **`osac-keycloak-signing-keys`**: cert-manager `Issuer` (self-signed) + 3 `Certificate` resources for Keycloak signing.
- **`osac-keycloak-deployment`**: Keycloak Deployment + Service in `maas-db`. Image: `quay.io/keycloak/keycloak:26.8.0`.
- **`osac-keycloak-route`**: Route for Keycloak in `maas-db`.
- **`osac-keycloak-realm-import`**: ConfigMap `keycloak-realm-import` with realm JSON data. The 3 realm JSON files are stored separately at `hub/platform/keycloak-realms/saas-realm.json`, `grid-tenant-1-idp-realm.json`, `grid-tenant-2-idp-realm.json` (matching ai-grid-tenant's `manifests/realms/` structure). Since osac-gitops doesn't use Kustomize's `configMapGenerator`, the ConfigMap in the policy embeds the JSON content as data keys (file names as keys, JSON as values). The JSON files in the repo serve as the editable source of truth — a helper script or manual copy keeps the policy ConfigMap in sync.
- **`osac-keycloak-public-url`**: Distributes Keycloak public URL to all sites via ConfigMap. Uses hub template with `hubTemplateOptions.serviceAccountName` to look up Route host.

Binding: Hub-only Placement for deployment; separate all-sites policy for public URL distribution.

### Step 9: Create Policy 10 (Redis + Limitador)

Create `hub/platform/10-redis-limitador-policy.yaml` + binding:
- `RedisReplication` in `limitador-redis` (3-node, Sentinel, 10Gi storage). Adapted from ai-grid-tenant.
- `limitador-redis` Secret in `kuadrant-system` with Redis connection URL.
- `Limitador` CR in `kuadrant-system` pointing to Redis backend.
- NetworkPolicy in `limitador-redis`.

Binding: `osac-platform-sites`.

### Step 10: Create Policy 11 (Grid Network Policies)

Create `hub/platform/11-grid-network-policies-policy.yaml` + binding:
- NetworkPolicy `grid-operator-metrics-scraping` in `ai-grid-internal-models` (port 9090 from `redhat-ai-grid`).
- NetworkPolicy `grid-gateway-backend` in `ai-grid-internal-models` (port 8000 from `redhat-ai-grid`).

Binding: `osac-platform-sites`.

### Step 11: Create Policy 12 (Grid Enrollment — hub-only)

Create `hub/platform/12-grid-enrollment-policy.yaml` + binding:
- `grid-enrollment-invites` Namespace.
- `ServiceExport` for `grid-enrollment` in `redhat-ai-grid`.
- `GridSite` + `InferenceProvider` for declared peers (parameterized from site-params).

Binding: Hub-only Placement.

### Step 12: Create Policy 13 (GridNetwork)

Create `hub/platform/13-grid-network-policy.yaml` + binding:
- `GridNetwork` CR in `redhat-ai-grid`. `siteName` from hub template. `signalTransport.mode: poll`, `peerTrust.mode: spiffe`, TLS secrets `grid-site-identity` / `grid-ca`, `consumerGateways` entry.

Binding: `osac-platform-sites`.

### Step 13: Create Policy 14 (Observability)

Create `hub/platform/14-observability-policy.yaml` + binding:
- ServiceAccounts + ClusterRoleBindings for `grid-epp-metrics-reader`, `grid-uwm-federate-reader`.
- 5 ScrapeConfig CRs: `rhai-metrics`, `grid-metrics`, `grid-operator-metrics`, `epp-metrics`, `vllm-metrics`.
- NetworkPolicies allowing ACM observability collector to scrape.

Binding: `osac-platform-sites`.

### Step 14: Update AppProjects

Modify `hub/projects/platform-policies.yaml`:
- Add `route.openshift.io/Route`, `v1/ServiceAccount`, RBAC types to `namespaceResourceWhitelist`.
- Add `config.openshift.io/ImageDigestMirrorSet` to `clusterResourceWhitelist`.

Modify `hub/projects/scope-global.yaml`:
- Change destination namespace `maas-models` → `ai-grid-internal-models`.
- Add `models-as-a-service` destinations (for Grid ExternalModel + MaaSModelRef).
- Add `inference.opendatahub.io/ExternalModel` to `namespaceResourceWhitelist` if not already there.

### Step 15: Replace models (Intent Plane)

Replace simulated CPU model with real RHOAI 3.6 models:

**Per site — `global/sites/<site>/models/`:**
- `facebook-opt-125m.yaml`: `LLMInferenceService` in `ai-grid-internal-models`, replicas 3, CPU, vLLM, `baseRefs: v3-6-0-kserve-config-llm-template-cpu`, gateway ref `openshift-ai-inference`. Adapted from `ai-grid-tenant/apps/acm-models/facebook-opt-125m/10-facebook-opt-125m-cpu.yaml`.
- `facebook-opt-125m-ref.yaml`: `MaaSModelRef` in `ai-grid-internal-models`.
- `smollm2-135m-instruct.yaml` + `smollm2-135m-instruct-ref.yaml`: Same pattern.

Delete old files: `facebook-opt-125m-simulated.yaml`, `facebook-opt-125m-simulated-ref.yaml`, and site-b's `granite-3-1-8b-fp8.yaml` + ref.

Update `models.app.json` per site: change namespace from `maas-models` to `ai-grid-internal-models`.

### Step 16: Create Grid ExternalModels layer (Intent Plane)

New layer per site — `global/sites/<site>/grid-models/`:
- `facebook-opt-125m-em.yaml`: `ExternalModel` in `models-as-a-service` referencing `grid-provider`, `targetModel: facebook-opt-125m`. Plus `MaaSModelRef` binding it.
- `smollm2-135m-instruct-em.yaml`: Same pattern.

New descriptors: `global/sites/<site>/grid-models.app.json` — namespace `models-as-a-service`, project `scope-global`.

### Step 17: Update governance (Intent Plane)

Update `tenants/novatech/sites/<site>/governance/`:
- `MaaSSubscription` `ocp-users`: Model refs now point to `models-as-a-service` namespace (where Grid ExternalModel + MaaSModelRef live). Token rate limits: 1000 tokens/1min per model.
- `MaaSAuthPolicy` `ocp-users-policy`: Matching model refs + group-based subjects.

### Step 18: Create bootstrap automation scripts

Replace the manual `install.md` steps with automation scripts, following ai-grid-tenant's approach.

**`scripts/bootstrap.sh`** — Hub bootstrap (replaces install.md §§1–5):
- Accepts env vars: `REPO_URL`, `GIT_BRANCH`, `GITHUB_USER`
- Applies GitOps operator (Namespace, OperatorGroup, Subscription) from `bootstrap/` manifests
- Waits for `applications.argoproj.io` and `applicationsets.argoproj.io` CRDs
- Applies Argo CD admin ClusterRoleBinding and ACM policy RBAC (ClusterRole + ClusterRoleBinding from §4.2)
- Patches Argo controller memory (§4.3)
- Applies AppProjects from `hub/projects/`
- Creates the Git repo secret (reads token from `gh auth token`)
- Creates `ManagedClusterSetBinding`, `GitOpsCluster`, and `Placement` (§3)
- Applies the `osac-layers` ApplicationSet
- Optionally seeds the `rhoai-quay-pull-secret` in `osac-platform` (prompts for `.dockerconfigjson` or reads from env)
- Waits for hub Applications to sync and platform policies to be Compliant
- Prints summary

**`scripts/import-managed-cluster.sh`** — Spoke onboarding (replaces install.md §7):
- Adapted from `ai-grid-tenant/docs/acm-cluster-onboarding/import-managed-cluster.sh`
- Accepts `--spoke-context`, `--cluster-name`, `--site-name` flags
- Creates ManagedCluster + KlusterletAddonConfig
- Creates auto-import secret
- Waits for `ManagedClusterConditionAvailable`
- Waits for `cluster-proxy` addon Available
- Waits for Argo cluster secret
- Handles stale CSR cleanup (re-import case)
- Prints verification checklist

**`scripts/smoke-test.sh`** — Automated smoke test (replaces install.md §10):
- Adapted from `ai-grid-tenant/docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh`
- Accepts site domain, model path, model ID
- Gets JWT from Keycloak
- Mints API key
- Runs inference
- Tests rate limiting
- Prints pass/fail summary

**`bootstrap/`** — Static manifests applied by bootstrap.sh:
- `bootstrap/namespace.yaml` (openshift-gitops-operator ns — if not using the built-in operator)
- `bootstrap/openshift-gitops-admin.yaml` (ClusterRoleBinding for Argo controller)

**Updated `install.md`** — Rewritten to guide users through the automated flow while preserving manual fallback. Structure:

```
# OSAC GitOps — Install Guide (RHOAI 3.6)

## Prerequisites
- OpenShift 4.20+ with cluster-admin
- Tools: oc, git, jq, curl, python3, gh, clusteradm
- GPU sites: NFD + NVIDIA GPU operator pre-installed
- Keycloak realm ready (or use the bundled realm JSONs)

## 1. Set Environment Variables
  export REPO_URL=...
  export GIT_BRANCH=feature/rhoai-3.6
  export GITHUB_USER=...
  export HUB_CTX=...
  export SPOKE_CTX=...

## 2. Bootstrap the Hub
  ./scripts/bootstrap.sh
  What it does: installs GitOps operator, ACM, RBAC, AppProjects,
  ApplicationSet, seeds the FBC pull secret. Waits for all hub
  Applications to sync and platform policies to reach Compliant.

## 3. Add a Spoke
  ./scripts/import-managed-cluster.sh \
    --spoke-context "$SPOKE_CTX" \
    --cluster-name site-b \
    --yes
  What it does: creates ManagedCluster, imports via auto-import secret,
  waits for cluster-proxy addon, waits for Argo cluster secret.
  Repeat for each spoke.

## 4. Verify Hub and Spoke
  ./scripts/smoke-test.sh --domain "$HUB_DOMAIN" --model facebook-opt-125m
  ./scripts/smoke-test.sh --domain "$SPOKE_DOMAIN" --model facebook-opt-125m
  What it does: gets JWT, mints API key, runs inference, tests rate limit.

## 5. Register Cross-Site Model Keys (manual)
  (Same as current §9 — minting API keys requires human judgment
   about which models to expose cross-site. Script prints the
   exact commands after the smoke test passes.)

## 6. Adding a New Site
  Step-by-step: add site-params keys, update placement, create
  model/governance directories, run import-managed-cluster.sh.

## 7. Troubleshooting
  (Preserved from current install.md §11, updated for RHOAI 3.6)

## Appendix A: Manual Bootstrap
  For environments where scripts cannot run (air-gapped, restricted
  terminals), the full manual steps are preserved here.
```

### Step 19: Create Policies 15–17 (ODF, ACM, Submariner)

(See "Additional Infrastructure Policies" section below.)

### Step 20: Update MANIFEST.json and design doc

- Bump `MANIFEST.json` layer versions (platform: `0.2.0`, etc.).
- Update `osac-gitops-acm-design.md` to document all RHOAI 3.6 changes, new policies, new components, FBC catalog handling, infrastructure policies, and bootstrap scripts.

---

## Additional Infrastructure Policies

These ai-grid-tenant infrastructure components are also included as ACM policies:

### Step 19: Create Policy 15 (ODF — OpenShift Data Foundation)

Create `hub/platform/15-odf-policy.yaml` + binding:
- Namespace `openshift-storage`, OperatorGroup `openshift-storage` (targetNamespaces: `[openshift-storage]`), Subscription `odf-operator` from `redhat-operators`, channel `stable-4.22`.
- `StorageCluster` `ocs-storagecluster` in `openshift-storage`. Adapted from `ai-grid-tenant/apps/odf/manifests/storagecluster.yaml`.

Binding: `osac-platform-sites`.

### Step 20: Create Policy 16 (ACM — Advanced Cluster Management)

Create `hub/platform/16-acm-policy.yaml` + binding:
- Namespace `open-cluster-management`, OperatorGroup `open-cluster-management`, Subscription `advanced-cluster-management` from `redhat-operators`, channel `release-2.17`.
- `MultiClusterHub` `multiclusterhub` in `open-cluster-management`. Adapted from `ai-grid-tenant/apps/acm/manifests/multiclusterhub.yaml`.
- Namespace `open-cluster-management-observability`.
- `MultiClusterObservability` `observability` in `open-cluster-management-observability`. Adapted from `ai-grid-tenant/apps/acm/manifests/multiclusterobservability.yaml`.
- `ClusterManagementAddOn` for `governance-policy-framework` and `config-policy-controller`. Adapted from `ai-grid-tenant/apps/acm/manifests/policy-addons.yaml`.

Binding: Hub-only Placement (ACM runs on the hub).

### Step 21: Create Policy 17 (Submariner — Cross-cluster Networking)

Create `hub/platform/17-submariner-policy.yaml` + binding:
- Submariner `Broker` `submariner-broker` in `default-broker` namespace with Globalnet CIDR config. Adapted from `ai-grid-tenant/apps/acm/manifests/submariner-broker.yaml`.
- Per-managed-cluster `ManagedClusterAddOn` `submariner` and `SubmarinerConfig`. These are parameterized per site using hub templates from `osac-site-params` with new keys for submariner config (gateway count, cable driver, etc.).
- `MachineSet` or `MachinePool` node policy for submariner gateway nodes (from `ai-grid-tenant/cluster-config/`).

Binding: Hub-only Placement for the broker; per-site Placement for the addon.

---

## Secret Management

No secrets in Git. Generation mechanisms:
- **Quay pull secret**: Manually seeded on hub in `osac-platform/rhoai-quay-pull-secret`, distributed by Policy 00 hub template
- **CNPG DB credentials**: Auto-generated by CNPG operator on each managed cluster
- **DB connection URL**: Derived by managed-side template from CNPG-generated secret
- **Keycloak secrets**: Generated by ESO Password generators on hub
- **Keycloak signing certs**: Generated by cert-manager on hub
- **Grid identity/CA**: Generated by Grid enrollment operator
- **Grid dummy API key**: In Policy 05 (not a real secret — static placeholder for in-cluster Grid)
- **Cross-site API keys**: Minted by operator, distributed by Policy 08 hub template
- **Redis URL**: In Policy 10 (no auth currently)

---

## Verification

1. `yamllint` all new/modified YAML files
2. Validate ACM policy structure (each policy has correct apiVersion, kind, namespace `osac-platform`, label `osac.io/platform: "true"`)
3. Validate all hub templates reference valid site-params keys
4. Validate all PlacementBindings reference correct Policy and Placement names
5. Validate `.app.json` descriptors match the directory structure
6. Validate AppProject permissions cover all resource types used by each scope
7. Cross-reference: every namespace created by a policy is also allowed by the relevant AppProject destination
8. Ensure no secret values appear in any file