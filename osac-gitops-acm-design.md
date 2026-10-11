# OSAC MaaS — GitOps and ACM Automation Design 
---

## 1. Introduction

This document describes how Models-as-a-Service (MaaS) is delivered to a fleet of
OpenShift clusters using a single Git repository, OpenShift GitOps (Argo CD), and
Advanced Cluster Management (ACM). It covers the delivery architecture, the two-plane
model, the repository layout, and how sites are added and configured.

This document focuses on what the GitOps layer does with the manifests in this repository.

Key topology facts. All tenants share the same inference clusters; multi-tenancy is enforced by the MaaSSubscription + MaaSAuthPolicy governance pairing on each cluster, not by cluster separation

---

## 2. Out-of-Scope Infrastructure Components

The MaaS platform plane is designed to be delivered independently of the underlying
infrastructure choices or cluster bootstrap process. It assumes the cluster exists
and is operational; it does not prescribe how that cluster was built, what storage
backend it uses, or which hardware accelerators are present.

This separation means the platform plane can be applied to any conformant OpenShift
cluster — bare-metal, cloud, or on-premises — without modification, as long as the
necessary prerequisites are in place. The components below belong to the cluster
bootstrap layer. They are consumed by the platform plane (e.g., GPU node labels are
read by hardware profiles; NFD discovery feeds RHOAI scheduling), but the platform
plane does not install, manage, or take opinions on them.

The following components were identified in the AI Grid POC (`RHsyseng/ai-grid-policies`)
and are explicitly **not part of this design**:

| Component | One-line summary | Why out of scope |
|---|---|---|
| **MetalLB** | Assigns routable LoadBalancer IPs to services on bare-metal/on-prem clusters via L2 or BGP. | Cluster bootstrap infrastructure (same layer as CNI). Needed only where no cloud load balancer exists (bare-metal or on-premises); this deployment runs on AWS and does not install it. |
| **LVM Storage** | Provisions local persistent volumes from raw node disks using Linux LVM, exposed as a StorageClass. | Storage infrastructure; the platform plane assumes storage is already provided. Belongs with cluster prerequisites, not with MaaS policies. |
| **OpenShift Virtualization + Tenant Host role** | Runs KubeVirt VMs alongside containers and, combined with MCE, hosts per-tenant OpenShift control planes as pods. | Cluster lifecycle and hypervisor infrastructure — both explicitly out of scope. Closer to cluster provisioning than to the platform plane. |
| **ZTP Delivery Patterns** | Wave-ordered, `PolicyGenerator`-based ACM policy delivery pipeline from the Telco RAN world. | Alternative delivery mechanism to Argo CD chosen in prescribed architecture in design. |
| **Node Feature Discovery (NFD)** | Detects hardware features (CPU flags, PCIe devices, etc.) on each node and exposes them as node labels. | Cluster bootstrap infrastructure; a prerequisite on sites that serve GPU models, where the GPU operator relies on it. The platform plane does not install or configure NFD. Its hardware profiles select GPU nodes by `nvidia.com/gpu.present`, a label the GPU operator sets. |
| **NVIDIA GPU Operator** | Installs and manages NVIDIA drivers, device plugins, and DCGM exporters on GPU nodes as a DaemonSet. | Cluster bootstrap infrastructure; a prerequisite for GPU inference on sites that serve GPU models. The platform plane does not install, configure or reference it. |

---

## 3. Repository Structure

One Git repository, one branch per environment. The current environment uses the
`main` branch. Argo CD applies the manifests as they are, with no Helm or
Kustomize rendering. The ACM policies contain ACM templates, which ACM resolves when it
evaluates a policy.

```
osac-gitops/
├── hub/
│   ├── platform/                  # ACM Policies 01–08 + PlacementBindings
│   │   ├── 01-operators-policy.yaml
│   │   ├── 02-platform-config-policy.yaml
│   │   ├── 03-gateway-policy.yaml
│   │   ├── 04-database-policy.yaml
│   │   ├── 05-default-tenant-policy.yaml
│   │   ├── 06-hardware-profiles-policy.yaml
│   │   ├── 07-service-tls-policy.yaml
│   │   └── 08-external-model-secrets-policy.yaml
│   ├── platform-sites/            # Per-site parameters + placement
│   │   ├── namespace.yaml         # osac-platform namespace
│   │   ├── managedclustersetbinding.yaml  # binds the default cluster set
│   │   ├── site-params.yaml       # osac-site-params ConfigMap
│   │   └── placement.yaml         # Placement selecting platform sites
│   └── projects/                  # Argo CD AppProjects (applied manually once)
│       ├── platform-policies.yaml
│       ├── scope-global.yaml
│       └── scope-tenant-novatech.yaml
│
├── global/
│   └── sites/
│       ├── site-a/
│       │   ├── models/            # Local model (CPU simulator)
│       │   └── external-models/   # ExternalProvider, ExternalModel, MaaSModelRef, recheck job
│       └── site-b/
│           ├── models/            # Local model (Granite GPU)
│           └── external-models/   # ExternalProvider, ExternalModel, MaaSModelRef, recheck job
│
└── tenants/
    └── novatech/
        └── sites/
            ├── site-a/
            │   └── governance/    # MaaSSubscription, MaaSAuthPolicy
            └── site-b/
                └── governance/    # MaaSSubscription, MaaSAuthPolicy
```

Each layer directory has a descriptor beside it, named `<layer>.app.json` (for example
`hub/platform.app.json`). The descriptors are omitted from the tree above.

### 3.1 Layer Descriptors

Every Argo CD Application is discovered through a `*.app.json` file in the repository.
The single ApplicationSet scans `**/*.app.json` and instantiates one
Application per file. The descriptor carries everything Argo needs:

```json
{
  "schema": 1,
  "scope":          { "kind": "global" },
  "target":         "site",
  "site":           "site-b",
  "layer":          "models",
  "argoDestination": "site-b",
  "project":        "scope-global",
  "manifestPath":   "global/sites/site-b/models",
  "namespace":      "maas-models",
  "targetRevision": "main"
}
```

The ApplicationSet template derives the Application name from `scope.kind`, `scope.id`
(tenant scope only), `site`, and `layer`, producing names like `global-site-b-models` or
`tenant-novatech-site-a-governance`. All Applications use `destination.name`
(a cluster name registered in Argo CD), not a server URL, so they work with both
the hub's built-in `in-cluster` name and spoke cluster secrets created by ACM.

### 3.2 Application inventory

| Application | Destination | Project | Namespace |
|---|---|---|---|
| `global-hub-platform` | `in-cluster` (hub) | `platform-policies` | `openshift-gitops` |
| `global-hub-platform-sites` | `in-cluster` (hub) | `platform-policies` | `openshift-gitops` |
| `global-site-a-models` | `in-cluster` (hub) | `scope-global` | `maas-models` |
| `global-site-a-external-models` | `in-cluster` (hub) | `scope-global` | `external-models` |
| `global-site-b-models` | `site-b` | `scope-global` | `maas-models` |
| `global-site-b-external-models` | `site-b` | `scope-global` | `external-models` |
| `tenant-novatech-site-a-governance` | `in-cluster` (hub) | `scope-tenant-novatech` | `models-as-a-service` |
| `tenant-novatech-site-b-governance` | `site-b` | `scope-tenant-novatech` | `models-as-a-service` |

### 3.3 AppProject gating

Three AppProjects restrict what each scope can deploy:

**`platform-policies`** — hub-only. Allows `Policy`, `PlacementBinding`, `Placement`,
`ManagedClusterSetBinding`, and `ConfigMap` in the `osac-platform` and `openshift-gitops`
namespaces, plus the cluster-scoped `Namespace`. The policies and the site parameters live
in `osac-platform`, where ACM picks them up. This scope writes only to the hub; ACM
carries the results to the sites.

**`scope-global`** — intent plane, global scope. Allows `LLMInferenceService`,
`MaaSModelRef`, `ExternalProvider`, `ExternalModel`, and the recheck job's
`ServiceAccount`, `Role`, `RoleBinding` and `CronJob` in the `maas-models` and
`external-models` namespaces, plus the cluster-scoped `Namespace`. `Secret` is not
allowed: the API key Secret is delivered by Policy 08, not by Argo CD. Targets both
`in-cluster` and spoke clusters by name.

**`scope-tenant-novatech`** — intent plane, tenant scope. Allows only `MaaSSubscription`
and `MaaSAuthPolicy`, and only in `models-as-a-service`. All tenants share that
namespace, so the project limits a tenant layer to governance objects there; it does not
separate one tenant's objects from another's.

---

## 4. Platform Plane (ACM Policies)

The platform plane configures every site selected by the platform Placement with the
MaaS runtime: operators, RHOAI, gateway, database, tenancy, hardware profiles, and TLS.
It uses ACM `ConfigurationPolicy` templates with `remediationAction: enforce`, so ACM
creates the objects and re-applies them when they drift. The one exception is a
status-only `inform` template in Policy 08. Policy 07 sets an explicit evaluation
interval (10 minutes when compliant, 1 minute when not); the other policies use ACM's
default.

### 4.1 Delivery model

```
Argo CD (hub)          ACM (hub)             ACM agent (spoke)
      │                    │                       │
      │── sync ──▶ Policies applied to hub         │
      │            ACM reads them                  │
      │                    │── replicate ──────────▶│
      │                    │                       │── enforce on spoke
      │                    │                       │
```

Argo CD applies the policy objects to the hub cluster. ACM's policy controller reads
them, replicates them to each managed cluster's namespace on the hub, and delivers them
to the spoke cluster's ACM agent. The agent enforces them locally. Argo CD never touches
a spoke directly for platform objects.

### 4.2 Policy catalogue

| Policy | Content | Delivery |
|---|---|---|
| **01 Operators** | OLM Subscriptions (with Namespaces and OperatorGroups) for RHOAI, RHCL, cert-manager, LWS, OpenTelemetry and the Cluster Observability Operator. Also removes RHCL-family Subscriptions left in `openshift-operators` | All platform sites |
| **02 Platform config** | User workload monitoring, DSCInitialization, DataScienceCluster with MaaS enabled, `OdhDashboardConfig` | All platform sites |
| **03 Gateway** | GatewayClasses, Gateways (`maas-default-gateway`, `openshift-ai-inference`), Kuadrant, Authorino (listener TLS on from the start), the MaaS gateway Route | All platform sites |
| **04 Database** | PostgreSQL, site-generated credentials (`randAlphaNum` in managed-side template) | All platform sites |
| **05 Default tenant** | Tenant CR, governance and model namespaces (`models-as-a-service`, `maas-models`) | All platform sites |
| **06 Hardware profiles** | `HardwareProfile` CRs per site, read from `osac-site-params` via hub template | All platform sites |
| **07 Service TLS** | Service annotations for `authorino-server-cert` and inference gateway serving cert; Authorino Deployment env patch | All platform sites |
| **08 External model secrets** | ExternalProvider API key Secret distributed to consumer clusters via hub template `fromSecret`, only once the hub Secret exists; "Awaiting credential" until then | Per-direction Placements |

### 4.3 Per-site parameterisation

Policies read per-site values from the `osac-site-params` ConfigMap in the hub
namespace using ACM hub templates:

```
{{hub fromConfigMap "osac-platform" "osac-site-params"
    (printf "%s.cluster-domain" .ManagedClusterName) hub}}
```

Keys are prefixed by the ACM `ManagedClusterName` (e.g., `local-cluster.rhoai-channel`,
`site-b.hardware-profiles`). Adding a new site requires adding its key block to the
ConfigMap and its name to the platform placement — no new policy files needed.

### 4.4 Database secret generation

Policy 04 uses a Sprig `randAlphaNum` call inside a **managed-side** (not hub-side)
policy template. This means:
- The password is generated on each site, by that site's own policy controller.
- The value is not in Git and not in the hub Policy: the replicated policy holds the
  template text, not the password.
- On the first evaluation the template finds no Secret and generates a random value. On
  later evaluations it looks up the existing Secret and reuses its password, so the value
  does not change.
- ACM censors Secret diffs from policy status by default.

Hub-side generation (hub template producing a secret value) is forbidden because the
value would be embedded in the replicated policy body and visible on the hub.

---

## 5. Intent Plane (Argo CD)

The intent plane delivers models, external model references, and tenant governance
directly to each site. Argo CD pushes these via the cluster secret that ACM's
`GitOpsCluster` creates for each registered spoke.

### 5.1 Delivery model

```
Git repository          Argo CD (hub)           Spoke cluster
      │                      │                       │
      │── *.app.json ────────▶│                       │
      │── manifests ──────────▶── push via cluster ──▶│
      │                      │      secret            │
      │                      │                       │── objects applied locally
```

For hub layers (`argoDestination: "in-cluster"`), Argo CD applies to the hub itself.
For spoke layers (`argoDestination: "site-b"`), Argo CD uses the cluster secret
created by ACM's `GitOpsCluster` controller. That secret holds a bearer token and CA that
ACM issues, and its server address is ACM's cluster proxy on the hub. Argo CD therefore
does hold a credential for each spoke, but ACM creates and owns it; none is created by
hand or stored in Git.

### 5.2 Scope structure

**Global scope** applies objects that belong to the MaaS platform but are not
tenant-specific: model definitions (`LLMInferenceService` with its `MaaSModelRef`) and
cross-site model references (`ExternalProvider`, `ExternalModel`, `MaaSModelRef`, and the
provider recheck job). These land in `maas-models` and `external-models` namespaces.

**Tenant scope** applies objects that are specific to a tenant: subscriptions
(`MaaSSubscription`) and auth policies (`MaaSAuthPolicy`). These land in
`models-as-a-service`. The tenant's AppProject limits its Application to those two kinds
in that namespace. Tenants share the namespace, so the project does not separate one
tenant's objects from another's.

---

## 6. Bridge Layer

The platform plane and the intent plane do not communicate directly. They meet through
two shared objects in the `hub/platform-sites/` layer, applied by the
`global-hub-platform-sites` Argo Application. The layer also creates the `osac-platform`
namespace and a `ManagedClusterSetBinding`. The two objects are:

**`osac-site-params` ConfigMap** (namespace `osac-platform`) holds one key block per
site, prefixed by the ACM `ManagedClusterName`. Platform policies read these values via
hub templates. It is committed to Git as `hub/platform-sites/site-params.yaml`; Argo CD
applies it to the hub.

**`osac-platform-sites` Placement** (namespace `osac-platform`) lists the managed
cluster names that platform policies 01–07 target (Policy 08 has its own Placements).
Adding a cluster name here (and its parameter keys to the ConfigMap) is all the platform
plane needs for a new site. The site's intent layers are added separately (section 8).

```
osac-site-params ConfigMap
  local-cluster.cluster-domain:  apps.<hub-cluster-domain>
  local-cluster.identity-issuer: https://keycloak.apps.<hub-cluster-domain>/realms/osac
  local-cluster.rhoai-channel:   stable-3.5
  local-cluster.hardware-profiles: [cpu-only]

  site-b.cluster-domain:  apps.<spoke-cluster-domain>
  site-b.identity-issuer: https://keycloak.apps.<hub-cluster-domain>/realms/osac
  site-b.rhoai-channel:   stable-3.5
  site-b.hardware-profiles: [nvidia-a10g-24gb, cpu-only]
```

All sites share the same Keycloak identity issuer (on the hub, which hosts Keycloak). Each site has
its own `cluster-domain` so that gateway routes, serving-cert Services, and model
URLs are cluster-specific.

---

## 7. Cross-site External Model Pattern

A site can call a model served on another site without deploying the model locally.
RHOAI 3.5 delivers this through `ExternalProvider` and `ExternalModel` CRs in the
`inference.opendatahub.io` API group. RHOAI's own payload-processing components at the
gateway (the `payload-pre-processing` and `payload-processing` Deployments in
`openshift-ingress`) resolve the provider and inject the upstream API key, so no proxy has
to be deployed by hand.

### 7.1 Request flow

```
Client
  │ model: "granite-remote"
  ▼
Hub MaaS gateway
  │ payload-pre-processing: copies `model` from the body into X-Gateway-Model-Name,
  │                         resolves the provider
  │ payload-processing: resolves the provider, translates the API format,
  │                     injects the upstream API key
  │
  ▼ HTTPS to maas.<spoke-domain>/maas-models/<model-name>/v1/...
Site-b MaaS gateway
  │ verifies upstream API key, routes to GPU model
  ▼
granite-3-1-8b-fp8 (vLLM on A10G)
```

### 7.2 Object model per consumer cluster

For each remote model, three objects live in the `external-models` namespace:

```
ExternalProvider  ──── points to upstream FQDN, references the API key Secret
ExternalModel     ──── maps client model name to upstream path + targetModel id
MaaSModelRef      ──── binds ExternalModel into MaaS governance
```

The API key Secret in `external-models` is **not** in Git. It is distributed by Policy 08.

### 7.3 Upstream pass-through governance

On each upstream cluster, a `system:authenticated` `MaaSAuthPolicy` and
`MaaSSubscription` let a ServiceAccount on that cluster (`cross-cluster-consumer`, created
by the operator, not from Git) mint the API key. In this implementation the two objects
are part of the `novatech` governance layer:

```
# On site-b (upstream for granite)
MaaSAuthPolicy: granite-cross-cluster-access
  modelRefs: [granite-3-1-8b-fp8 in maas-models]
  subjects: [system:authenticated]

MaaSSubscription: granite-cross-cluster-sub
  owner: [system:authenticated]
  tokenRateLimits: [999999999/1m]   # effectively unlimited
  priority: 1
```

### 7.4 Policy 08: scalable API key distribution

Instead of patching a Secret on each consumer cluster, the operator mints one key
on the upstream and stores it in a hub Secret (not in Git). Policy 08 reads it
via an ACM hub template and propagates it to all consumer clusters automatically.

Policy 08 is platform plane and owns only the namespace and the credential Secret. It
renders the Secret **only once the hub Secret exists** (a hub-template `lookup` guard), and
an inform template reports `Awaiting credential` until it is delivered, so there is no
template error before the key is registered. The ExternalProvider, ExternalModel and
MaaSModelRef are intent and stay with Argo CD; no policy touches them.

The ExternalProvider controller checks its Secret once and does not watch Secrets, so a
provider created before the key reports `Failed / SecretNotFound` and only retries on a
growing backoff (up to about 16 minutes). Each external-models layer therefore ships a
small CronJob, `osac-provider-recheck` (delivered by Argo CD), which annotates such a
provider once its Secret exists; the annotation makes the controller reconcile again.

```
Operator mints one key on site-b
  → stores in osac-platform/granite-remote-upstream-key (hub, not Git)
  → Policy 08 hub template: {{hub fromSecret "osac-platform"
                               "granite-remote-upstream-key" "api-key" hub}}
  → ACM creates granite-remote-key Secret on every cluster in
    the osac-granite-consumers Placement
  → the osac-provider-recheck CronJob in that cluster's external-models layer
    wakes the Argo-created ExternalProvider
```

To add site-c as a consumer of Granite, add `site-c` to the `osac-granite-consumers`
Placement. No additional key minting is needed. site-c also needs its own external-models
layer (ExternalProvider, ExternalModel, MaaSModelRef and the recheck job).

---

## 8. Adding a Site

Adding an existing OpenShift cluster to the platform:

**Step 1 — Import the cluster into ACM.**
Create a `ManagedCluster` CR on the hub named after the site, with the `name` label set to
the site name and the `cluster.open-cluster-management.io/clusterset: default` label.
Use a `KlusterletAddonConfig` to enable `applicationManager`, `policyController`,
`searchCollector`, and `certPolicyController`. Give ACM the spoke's API address and a login
token in an `auto-import-secret`. ACM installs the klusterlet and deletes that Secret.
Wait for `ManagedClusterConditionAvailable=True`.

**Step 2 — Add to the GitOps cluster placement.**
The `osac-gitops-placement` lists the spoke names only (the hub is reached as
`in-cluster`). It is applied by hand, not from Git. Add the new name to its
`matchExpressions` values list. ACM's `GitOpsCluster` controller then creates an Argo CD
cluster secret for the new site; this took 3–4 minutes the one time it was measured. This
is the credential Argo uses to push to the spoke.

**Step 3 — Publish site parameters and intent.**
Add the site's key block to `hub/platform-sites/site-params.yaml` (cluster domain,
identity issuer, RHOAI channel, hardware profiles). Add its name to the
`hub/platform-sites/placement.yaml` values list. Add `global/sites/<site>/models/`
with model definitions and `tenants/<tenant>/sites/<site>/governance/` with
subscriptions, each with its `*.app.json` descriptor. Commit and push; Argo CD and ACM
converge automatically.

**Step 4 — Bootstrap cross-site secrets (if the site consumes remote models).**
Add the site name to the relevant `Placement` in Policy 08, and add the site's
`external-models` layer with its descriptor. The policy distributes the upstream API key
to the new site once the key is registered on the hub.

No new policy files are needed; policies 01–07 are shared. No cluster credentials
are committed to Git. The Git changes are the ConfigMap key block, the placement name
additions, and the site's intent layers with their descriptors.

---

## 9. Security Model

**No secrets in Git.** The repository contains no credential values. Secrets fall into
three categories:

| Category | How managed |
|---|---|
| Database passwords | Generated on each site by a managed-side ACM template (`randAlphaNum`); not in Git and not in the hub Policy |
| External API keys (cross-site) | Minted once by operator, stored in hub namespace (`osac-platform`), distributed by Policy 08 hub template (ACM encrypts the value in the replicated policy); never in Git |
| Service TLS certificates | Minted by OpenShift service-CA from Service annotation; the annotation is in Git, the certificate is not |

**Repository access.** Argo CD is the only component that reads the repository. ACM reads
the `Policy` objects that Argo CD applies to the hub; it never reads the repository.

**AppProject gating.** Each Argo CD AppProject restricts which namespaces and resource
kinds an Application can manage. A bug or misconfiguration in a tenant's governance
layer cannot create other kinds or write to platform namespaces. Tenants share the
`models-as-a-service` namespace, so the project does not separate tenants from each other.
