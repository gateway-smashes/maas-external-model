#!/usr/bin/env bash
# Install / delete / reinstall the MaaS inference Gateway in ${GATEWAY_NS}.
#
# This is NOT the dashboard Gateway (data-science-gateway / openshift-ai.*).
#
# Usage:
#   . ./config.env
#   ./scripts/05-gateway.sh install|delete|reinstall|ipp|status|route
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env from config.env.example first."; exit 1; }
# shellcheck disable=SC1091
. ./config.env

: "${GATEWAY_NS:?}"
: "${GATEWAY_NAME:?}"
GATEWAY_CLASS="${GATEWAY_CLASS:-openshift-default}"
GATEWAY_CERT_SECRET="${GATEWAY_CERT_SECRET:-maas-gateway-tls}"
IPP_NS="${IPP_NS:-$GATEWAY_NS}"
TENANT_NS="${TENANT_NS:-models-as-a-service}"
TENANT_NAME="${TENANT_NAME:-default-tenant}"
APP_NS="${APP_NS:-redhat-ods-applications}"
CMD="${1:-status}"

resolve_hostname() {
  if [[ -n "${GATEWAY_HOSTNAME:-}" ]]; then
    echo "$GATEWAY_HOSTNAME"
    return
  fi
  if [[ -n "${CUSTOM_DOMAIN:-}" ]]; then
    echo "maas.${CUSTOM_DOMAIN}"
    return
  fi
  local domain
  domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -z "$domain" ]]; then
    echo "ERROR: set CUSTOM_DOMAIN or GATEWAY_HOSTNAME (no *.apps DNS on this cluster)" >&2
    exit 1
  fi
  echo "maas.${domain}"
}

allowed_namespaces_json() {
  local -a ns
  # shellcheck disable=SC2206
  ns=(${GATEWAY_ALLOWED_NAMESPACES:-$GATEWAY_NS $APP_NS $MAAS_NS models-as-a-service})
  local -a out=()
  local n
  for n in "${ns[@]}" "$GATEWAY_NS" "${MAAS_NS:-maas-external-models}" "$APP_NS" "$TENANT_NS"; do
    [[ -n "$n" ]] || continue
    local seen=0 x
    for x in "${out[@]+"${out[@]}"}"; do [[ "$x" == "$n" ]] && seen=1 && break; done
    [[ $seen -eq 0 ]] && out+=("$n")
  done
  printf '%s\n' "${out[@]}" | jq -R . | jq -s -c .
}

route_labels_yaml() {
  # Emit indented label lines from ROUTE_LABELS="k=v k2=v2"
  local pair key val
  if [[ -z "${ROUTE_LABELS:-}" ]]; then
    echo "ERROR: set ROUTE_LABELS in config.env (required for Route admission on this cluster)" >&2
    exit 1
  fi
  if [[ "$ROUTE_LABELS" == "changeme=true" ]]; then
    echo "ERROR: replace ROUTE_LABELS=changeme=true with the real router/external-dns label(s)" >&2
    exit 1
  fi
  for pair in $ROUTE_LABELS; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if [[ -z "$key" || "$key" == "$pair" ]]; then
      echo "ERROR: ROUTE_LABELS entries must be key=value (got: $pair)" >&2
      exit 1
    fi
    printf '    %s: %s\n' "$key" "$val"
  done
}

resolve_gateway_service() {
  local svc
  svc="$(oc get svc -n "$GATEWAY_NS" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$svc" ]]; then
    # OpenShift often names it <gateway>-openshift-default / <gateway>-<class>
    svc="$(oc get svc -n "$GATEWAY_NS" -o name 2>/dev/null \
      | sed 's|^service/||' \
      | grep -E "^${GATEWAY_NAME}" \
      | head -1 || true)"
  fi
  echo "$svc"
}

render_gateway() {
  export GATEWAY_HOSTNAME
  export GATEWAY_ALLOWED_NAMESPACES_JSON
  export GATEWAY_NS GATEWAY_NAME GATEWAY_CLASS GATEWAY_CERT_SECRET IPP_NS
  envsubst '${GATEWAY_NS}' < cluster/00-gateway-namespace.yaml
  echo '---'
  envsubst '${GATEWAY_NS} ${GATEWAY_NAME} ${GATEWAY_CLASS} ${GATEWAY_HOSTNAME} ${GATEWAY_CERT_SECRET} ${GATEWAY_ALLOWED_NAMESPACES_JSON}' \
    < cluster/10-maas-default-gateway.yaml
}

render_route() {
  local svc="$1"
  local labels tmp
  labels="$(route_labels_yaml)"
  GATEWAY_SERVICE_NAME="$svc"
  export GATEWAY_NS GATEWAY_NAME GATEWAY_HOSTNAME GATEWAY_SERVICE_NAME
  tmp="$(mktemp)"
  # shellcheck disable=SC2016
  envsubst '${GATEWAY_NS} ${GATEWAY_NAME} ${GATEWAY_HOSTNAME} ${GATEWAY_SERVICE_NAME}' \
    < cluster/20-maas-gateway-route.yaml >"$tmp"
  # Replace the ${ROUTE_LABELS_YAML} sentinel with indented label lines
  awk -v labels="$labels" '
    index($0, "${ROUTE_LABELS_YAML}") { printf "%s", labels; next }
    { print }
  ' "$tmp"
  rm -f "$tmp"
}

label_controller_routes() {
  # Also stamp ROUTE_LABELS onto any auto-created Routes for this gateway.
  local pair key val names
  names="$(oc get route -n "$GATEWAY_NS" -o json 2>/dev/null \
    | jq -r --arg g "$GATEWAY_NAME" '
        .items[]
        | select(
            (.metadata.name | startswith($g))
            or (.spec.to.name // "" | contains($g))
          )
        | .metadata.name' 2>/dev/null || true)"
  [[ -z "$names" ]] && return 0
  local n
  for n in $names; do
    for pair in $ROUTE_LABELS; do
      key="${pair%%=*}"
      val="${pair#*=}"
      oc label route "$n" -n "$GATEWAY_NS" "${key}=${val}" --overwrite >/dev/null
    done
    echo "    labeled route/$n with $ROUTE_LABELS"
  done
}

cmd_route() {
  GATEWAY_HOSTNAME="$(resolve_hostname)"
  export GATEWAY_HOSTNAME
  local svc=""
  local i
  echo "==> wait for Gateway Service in $GATEWAY_NS"
  for i in $(seq 1 60); do
    svc="$(resolve_gateway_service)"
    [[ -n "$svc" ]] && break
    sleep 2
  done
  if [[ -z "$svc" ]]; then
    echo "ERROR: no Service for gateway $GATEWAY_NS/$GATEWAY_NAME yet"
    oc get svc,gateway -n "$GATEWAY_NS" || true
    exit 1
  fi
  echo "    service: $svc"
  echo "==> apply Route host=$GATEWAY_HOSTNAME labels=$ROUTE_LABELS"
  render_route "$svc" | oc apply -f -
  label_controller_routes
  oc get route -n "$GATEWAY_NS" -o wide
}

cmd_status() {
  echo "==> config: $GATEWAY_NS/$GATEWAY_NAME"
  echo "    hostname=$(resolve_hostname)"
  echo "    custom_domain=${CUSTOM_DOMAIN:-"(unset)"}"
  echo "    route_labels=${ROUTE_LABELS:-"(unset)"}"
  echo "    ipp=$IPP_NS"
  echo
  echo "==> Dashboard GatewayConfig (LEAVE ALONE — not MaaS)"
  oc get gatewayconfig default-gateway -o jsonpath='domain={.spec.domain} subdomain={.spec.subdomain}{"\n"}' 2>/dev/null \
    || echo "  (no GatewayConfig)"
  oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='dashboard Gateway={.metadata.name} listeners={.spec.listeners[*].hostname}{"\n"}' 2>/dev/null \
    || echo "  (no data-science-gateway — ok if named differently)"
  echo
  echo "==> MaaS Gateway"
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o wide 2>/dev/null || echo "  (missing)"
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
  echo
  echo "==> Routes in $GATEWAY_NS"
  oc get route -n "$GATEWAY_NS" -o wide 2>/dev/null || echo "  (none)"
  echo
  echo "==> Tenant gatewayRef"
  oc get tenant "$TENANT_NAME" -n "$TENANT_NS" -o jsonpath='{.spec.gatewayRef.namespace}/{.spec.gatewayRef.name} phase={.status.phase}{"\n"}' 2>/dev/null || echo "  (no tenant)"
  echo
  echo "==> EnvoyFilters in $GATEWAY_NS"
  oc get envoyfilter -n "$GATEWAY_NS" 2>/dev/null || true
  echo
  local host
  host="$(resolve_hostname)"
  echo "==> health: https://${host}/maas-api/health"
  curl -sk -o /dev/null -w "  HTTP %{http_code}\n" "https://${host}/maas-api/health" || echo "  (unreachable — check DNS + ROUTE_LABELS)"
}

cmd_install() {
  GATEWAY_HOSTNAME="$(resolve_hostname)"
  GATEWAY_ALLOWED_NAMESPACES_JSON="$(allowed_namespaces_json)"
  export GATEWAY_HOSTNAME GATEWAY_ALLOWED_NAMESPACES_JSON

  # Fail fast on placeholder labels before creating anything heavy
  route_labels_yaml >/dev/null

  echo "==> ensure TLS secret $GATEWAY_NS/$GATEWAY_CERT_SECRET"
  if ! oc get secret "$GATEWAY_CERT_SECRET" -n "$GATEWAY_NS" >/dev/null 2>&1; then
    oc create namespace "$GATEWAY_NS" --dry-run=client -o yaml | oc apply -f -
    if oc get secret "$GATEWAY_CERT_SECRET" -n openshift-ingress >/dev/null 2>&1; then
      echo "    copying $GATEWAY_CERT_SECRET from openshift-ingress → $GATEWAY_NS"
      oc get secret "$GATEWAY_CERT_SECRET" -n openshift-ingress -o json \
        | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences) | .metadata.namespace="'"$GATEWAY_NS"'"' \
        | oc apply -f -
    elif oc get secret cert-manager-ingress-cert -n openshift-ingress >/dev/null 2>&1; then
      echo "    copying cert-manager-ingress-cert as $GATEWAY_CERT_SECRET"
      oc get secret cert-manager-ingress-cert -n openshift-ingress -o json \
        | jq --arg n "$GATEWAY_CERT_SECRET" --arg ns "$GATEWAY_NS" \
          'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences)
           | .metadata.name=$n | .metadata.namespace=$ns' \
        | oc apply -f -
    else
      echo "ERROR: create TLS Secret $GATEWAY_NS/$GATEWAY_CERT_SECRET first."
      echo "  oc create secret tls $GATEWAY_CERT_SECRET -n $GATEWAY_NS --cert=tls.crt --key=tls.key"
      echo "  Cert must cover hostname: $GATEWAY_HOSTNAME"
      exit 1
    fi
  fi

  echo "==> apply GatewayClass + Gateway in $GATEWAY_NS (host=$GATEWAY_HOSTNAME)"
  render_gateway | oc apply -f -

  echo "==> wait for Programmed"
  local i st
  for i in $(seq 1 60); do
    st="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
    [[ "$st" == "True" ]] && break
    sleep 2
  done
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'

  cmd_route

  echo "==> point Tenant $TENANT_NS/$TENANT_NAME → $GATEWAY_NS/$GATEWAY_NAME"
  oc patch "tenant.maas.opendatahub.io/$TENANT_NAME" -n "$TENANT_NS" --type=merge -p "{
    \"spec\": {
      \"gatewayRef\": {
        \"name\": \"${GATEWAY_NAME}\",
        \"namespace\": \"${GATEWAY_NS}\"
      }
    }
  }"

  echo "==> label gateway namespace for route attachment"
  oc label namespace "$GATEWAY_NS" "kubernetes.io/metadata.name=$GATEWAY_NS" --overwrite 2>/dev/null || true

  cmd_ipp

  if [[ -n "${MAAS_API_URL:-}" ]]; then
    echo "==> set maas-ui MAAS_API_URL=$MAAS_API_URL"
    oc set env deploy/rhods-dashboard -n "$APP_NS" -c maas-ui "MAAS_API_URL=${MAAS_API_URL}" || true
  elif [[ "$GATEWAY_HOSTNAME" != maas.* ]]; then
    echo "==> GATEWAY_HOSTNAME is not maas.* — pointing maas-ui at https://${GATEWAY_HOSTNAME}/maas-api"
    oc set env deploy/rhods-dashboard -n "$APP_NS" -c maas-ui \
      "MAAS_API_URL=https://${GATEWAY_HOSTNAME}/maas-api" || true
  fi

  echo
  echo "Installed MaaS gateway (dashboard data-science-gateway untouched)."
  echo "  DNS A/CNAME:  $GATEWAY_HOSTNAME  →  cluster router / LB"
  echo "  Health:       curl -sk https://${GATEWAY_HOSTNAME}/maas-api/health"
  echo "  Status:       ./scripts/05-gateway.sh status"
}

cmd_ipp() {
  export GATEWAY_NS GATEWAY_NAME IPP_NS
  echo "==> IPP EnvoyFilter fix in $GATEWAY_NS (INSERT_BEFORE router)"
  envsubst '${GATEWAY_NS} ${GATEWAY_NAME} ${IPP_NS}' < cluster/ipp-envoyfilter-fix.yaml | oc apply -f -

  if oc get envoyfilter payload-processing -n "$IPP_NS" >/dev/null 2>&1; then
    oc annotate envoyfilter payload-processing -n "$IPP_NS" opendatahub.io/managed=false --overwrite
    oc patch envoyfilter payload-processing -n "$IPP_NS" --type=json \
      -p='[{"op":"replace","path":"/spec/configPatches","value":[]}]' || true
  else
    echo "    (payload-processing EnvoyFilter not in $IPP_NS yet — Tenant may create it after gatewayRef patch)"
  fi

  echo "==> restart gateway pods"
  oc delete pod -n "$GATEWAY_NS" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" --ignore-not-found
  oc wait --for=condition=Ready pod -n "$GATEWAY_NS" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" --timeout=180s 2>/dev/null || true
}

cmd_delete() {
  echo "==> delete MaaS gateway objects in $GATEWAY_NS/$GATEWAY_NAME"
  echo "    (does NOT touch openshift-ingress/data-science-gateway)"
  oc delete route "$GATEWAY_NAME" -n "$GATEWAY_NS" --ignore-not-found
  oc delete envoyfilter payload-processing-attach-fix -n "$GATEWAY_NS" --ignore-not-found
  oc delete gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" --ignore-not-found
  oc delete svc -n "$GATEWAY_NS" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" --ignore-not-found
  oc delete envoyfilter -n "$GATEWAY_NS" \
    "kuadrant-auth-${GATEWAY_NAME}" \
    "kuadrant-${GATEWAY_NAME}" \
    "kuadrant-ratelimiting-${GATEWAY_NAME}" \
    "${GATEWAY_NAME}-authn-ssl" \
    --ignore-not-found 2>/dev/null || true

  if [[ "${DELETE_GATEWAY_NS:-false}" == "true" ]]; then
    if [[ "$GATEWAY_NS" == "openshift-ingress" ]]; then
      echo "REFUSING DELETE_GATEWAY_NS=true on openshift-ingress (would break the cluster router / dashboard gateway)"
      exit 1
    fi
    echo "==> DELETE_GATEWAY_NS=true → deleting namespace $GATEWAY_NS"
    oc delete namespace "$GATEWAY_NS" --ignore-not-found
  else
    echo "    namespace $GATEWAY_NS kept (set DELETE_GATEWAY_NS=true to remove)"
  fi

  echo "Deleted MaaS gateway objects. Re-run install before serving traffic."
}

case "$CMD" in
  install)   cmd_install ;;
  delete)    cmd_delete ;;
  reinstall) cmd_delete; cmd_install ;;
  ipp)       cmd_ipp ;;
  route)     cmd_route ;;
  status)    cmd_status ;;
  *)
    echo "Usage: $0 {install|delete|reinstall|ipp|route|status}"
    exit 1
    ;;
esac
