#!/usr/bin/env bash
# =============================================================================
# 07-tenant.sh — bind the MaaS control plane to an existing Gateway.
# =============================================================================
# Fixes the failure mode where every MaaSModelRef reports:
#   Failed to reconcile HTTPRoute: HTTPRoute <ns>/<model> does not reference
#   gateway openshift-ingress/maas-default-gateway (found: <your-gateway>)
#
# That default is what the controller uses when no MaaS Tenant exists.
# Tenant.spec.gatewayRef is the only supported way to point it elsewhere.
#
# Usage:
#   . ./config.env && ./scripts/07-tenant.sh          # create or patch
#   ./scripts/07-tenant.sh status                     # show current binding
#
# Safe to re-run. Does NOT create or delete Gateways — use 05-gateway.sh for that.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env first."; exit 1; }
# shellcheck disable=SC1091
. ./config.env

CMD="${1:-apply}"

# "Tenant" and "Gateway" are ambiguous Kinds (3scale Tenant, Istio Gateway).
# Always fully qualify or oc silently talks to the wrong API.
TENANT_RES="tenants.maas.opendatahub.io"
GW_RES="gateways.gateway.networking.k8s.io"
MMR_RES="maasmodelrefs.maas.opendatahub.io"

TENANT_NS="${TENANT_NS:-models-as-a-service}"
TENANT_NAME="${TENANT_NAME:-default-tenant}"
: "${GATEWAY_NS:?set GATEWAY_NS in config.env}"
: "${GATEWAY_NAME:?set GATEWAY_NAME in config.env}"
export TENANT_NS TENANT_NAME GATEWAY_NS GATEWAY_NAME

show() {
  echo "==> MaaS Tenants (fully qualified):"
  oc get "$TENANT_RES" -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,GW:.spec.gatewayRef.namespace,GWNAME:.spec.gatewayRef.name,PHASE:.status.phase' \
    2>/dev/null || echo "  (none)"
  echo
  echo "==> Gateway $GATEWAY_NS/$GATEWAY_NAME:"
  oc get "$GW_RES" "$GATEWAY_NAME" -n "$GATEWAY_NS" \
    -o jsonpath='{range .status.conditions[*]}    {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null \
    || echo "  MISSING"
  echo
  echo "==> MaaSModelRefs:"
  oc get "$MMR_RES" -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,ROUTE:.status.httpRouteName' 2>/dev/null \
    || echo "  (none)"
}

if [ "$CMD" = "status" ]; then show; exit 0; fi

# --- 1. the target gateway must exist and be Programmed --------------------
echo "==> checking gateway $GATEWAY_NS/$GATEWAY_NAME"
if ! oc get "$GW_RES" "$GATEWAY_NAME" -n "$GATEWAY_NS" >/dev/null 2>&1; then
  echo "ERROR: Gateway $GATEWAY_NS/$GATEWAY_NAME not found."
  echo "       Existing Gateway API gateways:"
  oc get "$GW_RES" -A -o wide
  exit 1
fi
PROG="$(oc get "$GW_RES" "$GATEWAY_NAME" -n "$GATEWAY_NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
if [ "$PROG" != "True" ]; then
  echo "ERROR: Gateway is not Programmed=True (got '${PROG:-none}'). Fix the gateway first."
  oc get "$GW_RES" "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason} {.message}{"\n"}{end}'
  exit 1
fi
GW_HOST="$(oc get "$GW_RES" "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || true)"
echo "    Programmed=True  hostname=${GW_HOST:-<none>}"

# --- 2. the gateway must accept routes from the model namespace ------------
if [ -n "${MAAS_NS:-}" ]; then
  ALLOWED="$(oc get "$GW_RES" "$GATEWAY_NAME" -n "$GATEWAY_NS" \
    -o jsonpath='{.spec.listeners[*].allowedRoutes.namespaces.selector.matchExpressions[*].values}' 2>/dev/null || true)"
  if [ -n "$ALLOWED" ] && [[ "$ALLOWED" != *"$MAAS_NS"* ]]; then
    echo "WARNING: listener allowedRoutes does not list $MAAS_NS: $ALLOWED"
    echo "         HTTPRoutes from $MAAS_NS will be rejected. scripts/10-apply.sh adds it."
  fi
fi

# --- 3. namespace for the Tenant ------------------------------------------
oc create namespace "$TENANT_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

# --- 4. create or re-point the Tenant --------------------------------------
EXISTING="$(oc get "$TENANT_RES" -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)"

if [ -z "$EXISTING" ]; then
  echo "==> no MaaS Tenant exists — creating $TENANT_NS/$TENANT_NAME"
  if ! envsubst < cluster/30-maas-tenant.yaml | oc apply -f -; then
    echo
    echo "ERROR: Tenant rejected by the API server. Dump the real schema and send it over:"
    echo "  oc explain ${TENANT_RES}.spec.gatewayRef --recursive --api-version=maas.opendatahub.io/v1alpha1"
    exit 1
  fi
else
  echo "==> existing MaaS Tenant(s):"
  printf '    %s\n' $EXISTING
  for t in $EXISTING; do
    tns="${t%%/*}"; tname="${t##*/}"
    echo "==> pointing $tns/$tname -> $GATEWAY_NS/$GATEWAY_NAME"
    oc patch "$TENANT_RES/$tname" -n "$tns" --type=merge \
      -p "{\"spec\":{\"gatewayRef\":{\"name\":\"${GATEWAY_NAME}\",\"namespace\":\"${GATEWAY_NS}\"}}}"
  done
fi

# --- 5. nudge the model refs to reconcile ----------------------------------
echo "==> waiting for MaaSModelRefs to reconcile (up to 90s)"
for _ in $(seq 1 18); do
  BAD="$(oc get "$MMR_RES" -A \
    -o jsonpath='{range .items[?(@.status.phase!="Ready")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)"
  [ -z "$BAD" ] && break
  sleep 5
done

echo
show

echo
if [ -n "${BAD:-}" ]; then
  echo "Still not Ready: $(printf '%s ' $BAD)"
  echo "Reason:"
  for b in $BAD; do
    oc get "$MMR_RES" "${b##*/}" -n "${b%%/*}" \
      -o jsonpath='  {.metadata.name}: {.status.conditions[*].message}{"\n"}' 2>/dev/null || true
  done
  echo
  echo "If it still names a different gateway, the controller cached the old Tenant —"
  echo "restart it:  oc rollout restart deploy/maas-controller -n ${APP_NS:-redhat-ods-applications}"
  exit 1
fi
echo "Tenant bound. Next: ./scripts/20-verify.sh"
