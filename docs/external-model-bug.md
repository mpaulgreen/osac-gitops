# External Models — Fix Status Investigation

**Status**: Upstream fix merged, awaiting downstream release  
**Bug**: opendatahub-io/ai-gateway-controller#150  
**Fix PR**: opendatahub-io/ai-gateway-controller#151 (merged)  
**Branch**: `feature/rhoai-3.6`  
**Date**: 2026-10-30  

---

## Problem

Cross-cluster external model routing in RHOAI 3.6 is broken. The ai-gateway-controller generates routing overlays that omit `path` and `targetModel` fields from ExternalModel CRDs. The ext-proc `intelligent_route` filter selects the correct candidate but cannot rewrite the path or body model name. Requests either hang (300s ext-proc timeout) or arrive at the spoke without proper credentials.

---

## Fix PR #151 — Status

PR #151 (`feat(translation): route ExternalModels through Praxis`) is **merged** into `opendatahub-io/ai-gateway-controller:main` (commit `6fd534d`, labeled `3.6 GA`).

Companion PRs (all merged):

| PR | Repo | Purpose |
|----|------|---------|
| #151 | opendatahub-io/ai-gateway-controller | Routing overlay fix — populates `path` and `targetModel` |
| #1736 | opendatahub-io/praxis-ai | Praxis AI grid support |
| #161 | opendatahub-io/praxis-extproc | ExtProc filter updates |
| #1700 | opendatahub-io/models-as-a-service | MaaS integration |
| #179 | opendatahub-io/ai-gateway-controller | Bumps ExtProc to Praxis AI v0.8.0 (required by #151) |

---

## Downstream Release Chain

The fix must traverse this chain before it reaches the pinned FBC image:

| Step | Repo / Artifact | Status |
|------|----------------|--------|
| 1. Upstream merge | `opendatahub-io/ai-gateway-controller:main` | ✅ Merged (commit `6fd534d`) |
| 2. Downstream sync | `red-hat-data-services/ai-gateway-controller` main→stable (PR #45) | ❌ **Still open** |
| 3. Container image build | `rhoai/odh-ai-gateway-controller-rhel9` | ❌ Blocked on step 2 |
| 4. CSV update | rhods-operator CSV `RELATED_IMAGE_ODH_AI_GATEWAY_CONTROLLER_IMAGE` digest | ❌ Blocked on step 3 |
| 5. FBC fragment rebuild | `quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.6` | ❌ Blocked on step 4 |

**Conclusion**: The fix is **not** in the pinned FBC image (`quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.6@sha256:54a8068a...`). The blocking step is the downstream sync PR #45.

The latest published `odh-ai-gateway-operator-rhel9` image in the Red Hat catalog is **v3.5.2** — no 3.6 build exists yet.

---

## RHOAI Operator Architecture

The ai-gateway-controller is not embedded in the rhods-operator. It is a separate container image deployed through a chain of module operators:

```
rhods-operator (RHOAI meta operator)
  └─ deploys ai-gateway-operator (module operator)
       ├─ image: RELATED_IMAGE_ODH_AI_GATEWAY_OPERATOR_IMAGE
       └─ deploys sub-modules via RELATED_IMAGE_* env vars:
            ├─ RELATED_IMAGE_ODH_AI_GATEWAY_CONTROLLER_IMAGE  ← fix target
            ├─ RELATED_IMAGE_ODH_PRAXIS_EXTPROC_IMAGE
            ├─ RELATED_IMAGE_ODH_MAAS_CONTROLLER_IMAGE
            ├─ RELATED_IMAGE_ODH_PRAXIS_AI_GRID_OPERATOR_IMAGE
            └─ (batch gateway, MaaS API/discovery, kube-auth-proxy, etc.)
```

Source: `red-hat-data-services/rhods-operator` rhoai-3.6 branch:
- Handler: `internal/controller/modules/aigateway/handler.go`
- Manifests: `prefetched-manifests/aigateway/`
- Manifests source: `build/manifests-config.yaml` → `red-hat-data-services/ai-gateway-operator` @ `a6cfcfe6`
- Manager deployment: `prefetched-manifests/aigateway/manager/manager.yaml` (image placeholder `controller:latest`, replaced at build time)

The `RELATED_IMAGE_*` env vars are injected into the ai-gateway-operator Deployment from the CSV's `relatedImages` at install time. The CSV is built into the FBC fragment image.

---

## What to Watch

1. **PR #45** in `red-hat-data-services/ai-gateway-controller` — once this merges, the downstream release pipeline begins
2. **Red Hat catalog** — a new `odh-ai-gateway-controller-rhel9` image tag ≥ v3.6.0 signals the fix is built
3. **FBC fragment** — a new `rhoai-fbc-fragment:rhoai-3.6` digest (different from `sha256:54a8068a...`) would contain the updated CSV

Once a new FBC image is available with the fix, update the pinned digest in this repo and re-test external model routing end-to-end.
