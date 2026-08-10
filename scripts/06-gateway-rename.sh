#!/usr/bin/env bash
# =============================================================================
# 06-gateway-rename.sh — move the MaaS Gateway to a new name in the same
# namespace, keeping the hostname and TLS secret.
# =============================================================================
# Why: the MaaS controller parents HTTPRoutes at a Gateway called
# "maas-default-gateway". If your Gateway has any other name, MaaSModelRefs fail
# with "does not reference gateway .../maas-default-gateway".
#
# A Route host can only be claimed once, so this is delete-then-create, not
# create-then-switch. Expect a short outage on that hostname.
#
# config.env must already describe the DESIRED end state:
#   GATEWAY_NS        namespace to keep the gateway in
#   GATEWAY_NAME      new name (usually maas-default-gateway)
#   GATEWAY_HOSTNAME  hostname to keep (reused, so no DNS change)
#   GATEWAY_CERT_SECRET, GATEWAY_CLASS, ROUTE_LABELS
#
# Usage:
#   . ./config.env
#   ./scripts/06-gateway-rename.sh <old-gateway-name>
#   ./scripts/06-gateway-rename.sh data-science-gateway --yes
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env first."; exit 1; }
# shellcheck disable=SC1091
. ./config.env

OLD="${1:-}"
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
  esac
done
[ -n "$OLD" ] && [ "${OLD#-}" = "$OLD" ] || {
  echo "Usage: $0 <old-gateway-name> [--yes]"; exit 2; }

GW_RES="gateways.gateway.networking.k8s.io"
: "${GATEWAY_NS:?set GATEWAY_NS in config.env}"
: "${GATEWAY_NAME:?set GATEWAY_NAME in config.env}"
APP_NS="${APP_NS:-redhat-ods-applications}"
GATEWAY_CERT_SECRET="${GATEWAY_CERT_SECRET:-maas-gateway-tls}"

# --- safety ----------------------------------------------------------------
if [ "$GATEWAY_NS" = "openshift-ingress" ]; then
  echo "REFUSING to rename gateways in openshift-ingress — that is the cluster"
  echo "router namespace and holds RHOAI's own data-science-gateway."
  exit 1
fi
if [ "$OLD" = "$GATEWAY_NAME" ]; then
  echo "Old and new names are identical ($OLD). Nothing to do."
  exit 0
fi
if ! oc get "$GW_RES" "$OLD" -n "$GATEWAY_NS" >/dev/null 2>&1; then
  echo "ERROR: Gateway $GATEWAY_NS/$OLD not found. Existing gateways there:"
  oc get "$GW_RES" -n "$GATEWAY_NS" -o wide
  exit 1
fi

OLD_HOST="$(oc get "$GW_RES" "$OLD" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || true)"
OLD_CERT="$(oc get "$GW_RES" "$OLD" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}' 2>/dev/null || true)"
NEW_HOST="${GATEWAY_HOSTNAME:-$OLD_HOST}"

echo "==> rename plan"
echo "    namespace : $GATEWAY_NS"
echo "    old       : $OLD          host=$OLD_HOST cert=$OLD_CERT"
echo "    new       : $GATEWAY_NAME host=$NEW_HOST cert=$GATEWAY_CERT_SECRET"

# The certificate must survive the delete, otherwise the new listener has no TLS.
if ! oc get secret "$GATEWAY_CERT_SECRET" -n "$GATEWAY_NS" >/dev/null 2>&1; then
  echo "ERROR: TLS secret $GATEWAY_NS/$GATEWAY_CERT_SECRET does not exist."
  echo "       Not deleting the working gateway without a certificate for the new one."
  exit 1
fi
echo "    TLS secret $GATEWAY_CERT_SECRET present (kept — secrets are not deleted here)"

if [ "$NEW_HOST" != "$OLD_HOST" ]; then
  echo
  echo "WARNING: hostname changes from '$OLD_HOST' to '$NEW_HOST'."
  echo "         That needs its own DNS record and a certificate covering it."
fi

# --- backup ----------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=".maas-backup/gateway-${STAMP}"
mkdir -p "$BACKUP"; chmod 700 .maas-backup "$BACKUP"
oc get "$GW_RES" "$OLD" -n "$GATEWAY_NS" -o yaml > "$BACKUP/gateway-${OLD}.yaml" 2>/dev/null || true
oc get route -n "$GATEWAY_NS" -o yaml > "$BACKUP/routes.yaml" 2>/dev/null || true
echo "    backup: $BACKUP"

if [ "$ASSUME_YES" != 1 ]; then
  echo
  printf 'Delete %s/%s and recreate as %s? [y/N] ' "$GATEWAY_NS" "$OLD" "$GATEWAY_NAME"
  read -r C
  case "$C" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# --- delete the old gateway (frees the Route host) -------------------------
echo
echo "==> deleting old gateway objects"
oc delete route "$OLD" -n "$GATEWAY_NS" --ignore-not-found
# Any Route claiming the hostname blocks the new one with HostAlreadyClaimed.
for r in $(oc get route -n "$GATEWAY_NS" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.host}{"\n"}{end}' 2>/dev/null || true); do
  [ "${r#*=}" = "$NEW_HOST" ] || continue
  echo "    releasing host $NEW_HOST held by route ${r%%=*}"
  oc delete route "${r%%=*}" -n "$GATEWAY_NS" --ignore-not-found
done
oc delete "$GW_RES" "$OLD" -n "$GATEWAY_NS" --ignore-not-found
oc delete svc -n "$GATEWAY_NS" -l "gateway.networking.k8s.io/gateway-name=${OLD}" --ignore-not-found 2>/dev/null || true
oc delete envoyfilter -n "$GATEWAY_NS" \
  "kuadrant-auth-${OLD}" "kuadrant-${OLD}" "kuadrant-ratelimiting-${OLD}" "${OLD}-authn-ssl" \
  --ignore-not-found 2>/dev/null || true

echo "    waiting for the old Gateway to disappear"
for _ in $(seq 1 30); do
  oc get "$GW_RES" "$OLD" -n "$GATEWAY_NS" >/dev/null 2>&1 || break
  sleep 2
done

# --- recreate under the new name ------------------------------------------
echo
echo "==> installing $GATEWAY_NS/$GATEWAY_NAME (reuses cluster/10-maas-default-gateway.yaml)"
./scripts/05-gateway.sh install

# --- make the controller notice -------------------------------------------
echo
echo "==> restarting maas-controller (it caches the gateway target at startup)"
oc rollout restart deploy/maas-controller -n "$APP_NS" 2>/dev/null || true
oc rollout status deploy/maas-controller -n "$APP_NS" --timeout=180s 2>/dev/null || true

echo
echo "==> re-pointing the Tenant"
./scripts/07-tenant.sh || true

# --- verify ----------------------------------------------------------------
echo
echo "==> result"
oc get "$GW_RES" -n "$GATEWAY_NS" -o wide
oc get route -n "$GATEWAY_NS" -o wide
echo
oc get httproutes.gateway.networking.k8s.io -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PARENTNS:.spec.parentRefs[*].namespace,PARENT:.spec.parentRefs[*].name,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status' 2>/dev/null || true
echo
oc get maasmodelrefs.maas.opendatahub.io -A 2>/dev/null || true

cat <<EOF

If HTTPRoutes still name a gateway in openshift-ingress, this build ignores
Tenant.spec.gatewayRef and hardcodes the namespace. In that case the only
working option is openshift-ingress/maas-default-gateway — say so and I will
switch the approach rather than keep renaming.

Backup of the old gateway: $BACKUP
Health check:  curl -sk -o /dev/null -w '%{http_code}\\n' https://${NEW_HOST}/maas-api/health
EOF
