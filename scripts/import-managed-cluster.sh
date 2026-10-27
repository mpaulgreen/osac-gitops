#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Import an existing cluster into ACM.

Usage:
  import-managed-cluster.sh --spoke-context <context> --cluster-name <name> [flags]

Required flags:
  --spoke-context <context>    Kubeconfig context for the target cluster.
  --cluster-name <name>        Stable DNS-1123 ACM cluster name.

Optional flags:
  --registration-sa-namespace <namespace>
                                Namespace containing agent-registration-bootstrap.
  --hub-context <context>      Hub context; defaults to the current context.
  --use-bootstrap-token        Ask clusteradm for a bootstrap token.
  --force-internal-endpoint-lookup
                                Pass this option to clusteradm join.
  --yes                        Run after displaying the summary.
  -h, --help                   Show this help.

Environment:
  HUB_CONTEXT                  Default for --hub-context.
  SPOKE_CONTEXT                Default for --spoke-context.
  CLUSTER_NAME                 Default for --cluster-name.
  REGISTRATION_SA_NAMESPACE    Default for --registration-sa-namespace.

The command prints a summary and exits without changing either cluster unless
--yes is supplied.
EOF
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

hub_context="${HUB_CONTEXT:-}"
spoke_context="${SPOKE_CONTEXT:-}"
cluster_name="${CLUSTER_NAME:-}"
registration_sa_namespace="${REGISTRATION_SA_NAMESPACE:-}"
use_bootstrap_token=false
force_internal_endpoint_lookup=false
confirmed=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hub-context)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      hub_context=$2
      shift 2
      ;;
    --spoke-context)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      spoke_context=$2
      shift 2
      ;;
    --cluster-name)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      cluster_name=$2
      shift 2
      ;;
    --registration-sa-namespace)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      registration_sa_namespace=$2
      shift 2
      ;;
    --use-bootstrap-token)
      use_bootstrap_token=true
      shift
      ;;
    --force-internal-endpoint-lookup)
      force_internal_endpoint_lookup=true
      shift
      ;;
    --yes)
      confirmed=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -n "$spoke_context" ] || usage_error "--spoke-context is required"
[ -n "$cluster_name" ] || usage_error "--cluster-name is required"

if [ "$use_bootstrap_token" = true ] && [ -n "$registration_sa_namespace" ]; then
  usage_error "--use-bootstrap-token and --registration-sa-namespace are mutually exclusive"
fi

if [ -z "$hub_context" ]; then
  hub_context="$(kubectl config current-context)"
fi

if [[ ! "$cluster_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  die "cluster name must be a DNS-1123 label"
fi

[ "${#cluster_name}" -le 63 ] || die "cluster name must be at most 63 characters"

for required_command in kubectl clusteradm jq; do
  command -v "$required_command" >/dev/null 2>&1 || die "required command not found: $required_command"
done

context_exists() {
  kubectl config get-contexts -o name | grep -Fxq -- "$1"
}

context_exists "$hub_context" || die "hub context not found: $hub_context"
context_exists "$spoke_context" || die "spoke context not found: $spoke_context"

[ "$hub_context" != "$spoke_context" ] || die "hub and spoke contexts must be different"

get_token_args=(
  --context "$hub_context"
  get token
  --output json
)

if [ "$use_bootstrap_token" = true ]; then
  get_token_args+=(--use-bootstrap-token)
fi

if [ "$use_bootstrap_token" != true ]; then
  if [ -z "$registration_sa_namespace" ]; then
    for candidate_namespace in open-cluster-management multicluster-engine; do
      if kubectl --context "$hub_context" get serviceaccount \
        -n "$candidate_namespace" agent-registration-bootstrap >/dev/null 2>&1; then
        registration_sa_namespace=$candidate_namespace
        break
      fi
    done
  fi
fi

managed_cluster_exists=false
hub_accepted=false
joined=false

if kubectl --context "$hub_context" get managedcluster "$cluster_name" >/dev/null 2>&1; then
  managed_cluster_exists=true
  hub_accepted="$(kubectl --context "$hub_context" get managedcluster "$cluster_name" \
    -o jsonpath='{.spec.hubAcceptsClient}' 2>/dev/null || true)"
  joined="$(kubectl --context "$hub_context" get managedcluster "$cluster_name" \
    -o jsonpath='{range .status.conditions[?(@.type=="ManagedClusterJoined")]}{.status}{end}' 2>/dev/null || true)"
  [ "$hub_accepted" = "true" ] || hub_accepted=false
  [ "$joined" = "True" ] || joined=false
fi

hub_apiserver="$(kubectl config view --minify --raw --context "$hub_context" \
  -o jsonpath='{.clusters[0].cluster.server}')"
[ -n "$hub_apiserver" ] || die "failed to determine the hub API server URL"

wait_for_managed_cluster() {
  local attempt
  for attempt in $(seq 1 60); do
    if kubectl --context "$hub_context" get managedcluster "$cluster_name" >/dev/null 2>&1; then
      return 0
    fi
    printf 'Waiting for ManagedCluster %s to be created (%s/60)...\n' "$cluster_name" "$attempt" >&2
    sleep 5
  done
  die "timed out waiting for ManagedCluster: $cluster_name"
}

wait_for_gitops_cluster_secret() {
  local attempt
  local secret_name="${cluster_name}-application-manager-cluster-secret"
  for attempt in $(seq 1 60); do
    if kubectl --context "$hub_context" -n openshift-gitops get secret "$secret_name" >/dev/null 2>&1; then
      return 0
    fi
    printf 'Waiting for Argo CD cluster secret %s (%s/60)...\n' "$secret_name" "$attempt" >&2
    sleep 5
  done
  die "timed out waiting for Argo CD cluster secret: $secret_name"
}

cleanup() {
  unset hub_info hub_token
}
trap cleanup EXIT

cat <<EOF
ACM managed-cluster import

Hub context:      $hub_context
Hub API server:   $hub_apiserver
Spoke context:    $spoke_context
Cluster name:     $cluster_name
Bootstrap token:  $use_bootstrap_token
Action:           $([ "$managed_cluster_exists" = true ] && printf 'resume registration' || printf 'new import')

This may install the klusterlet on the spoke, accept the cluster on the hub,
and trigger the repository's full application fan-out. Existing registration
state is reused; the script does not reinstall an already-registered cluster.
EOF

if [ "$confirmed" != true ]; then
  printf '\nNo changes were made. Rerun with --yes to import the cluster.\n'
  exit 0
fi

if [ "$managed_cluster_exists" = false ]; then
  if [ -n "$registration_sa_namespace" ]; then
    hub_token="$(kubectl --context "$hub_context" create token \
      --namespace "$registration_sa_namespace" agent-registration-bootstrap \
      --duration=1h)"
    [ -n "$hub_token" ] || die "failed to create a registration service-account token"
  else
    hub_info="$(clusteradm "${get_token_args[@]}")"
    hub_token="$(jq -er '."hub-token" | select(type == "string" and length > 0)' <<<"$hub_info")"
  fi

  join_args=(
    --context "$spoke_context"
    join
    --hub-token "$hub_token"
    --hub-apiserver "$hub_apiserver"
    --cluster-name "$cluster_name"
  )

  if [ "$force_internal_endpoint_lookup" = true ]; then
    join_args+=(--force-internal-endpoint-lookup)
  fi

  clusteradm "${join_args[@]}"
  wait_for_managed_cluster

  hub_accepted="$(kubectl --context "$hub_context" get managedcluster "$cluster_name" \
    -o jsonpath='{.spec.hubAcceptsClient}' 2>/dev/null || true)"
  [ "$hub_accepted" = "true" ] || hub_accepted=false
fi

if [ "$joined" != true ]; then
  accept_args=(
    --context "$hub_context"
    --timeout 600
    accept
    --clusters "$cluster_name"
    --wait
  )

  if [ "$registration_sa_namespace" = "multicluster-engine" ]; then
    accept_args+=(--skip-approve-check)
  fi

  clusteradm "${accept_args[@]}"
fi

kubectl --context "$hub_context" wait --for=condition=ManagedClusterJoined "managedcluster/$cluster_name" --timeout=10m

kubectl --context "$hub_context" -n "$cluster_name" apply -f - <<EOF
apiVersion: addon.open-cluster-management.io/v1beta1
kind: ManagedClusterAddOn
metadata:
  name: application-manager
  namespace: $cluster_name
spec: {}
EOF

kubectl --context "$hub_context" -n "$cluster_name" wait \
  --for=condition=Available managedclusteraddon.addon.open-cluster-management.io/application-manager \
  --timeout=10m
wait_for_gitops_cluster_secret

printf '\nImport complete. Verify the generated Argo CD applications in the openshift-gitops namespace.\n'
