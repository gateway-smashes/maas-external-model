#!/usr/bin/env bash
# Install / delete / reinstall the MaaS inference Gateway in ${GATEWAY_NS}.
#
# Usage:
#   . ./config.env          # GATEWAY_NS=maas-gateway (recommended)
#   ./scripts/05-gateway.sh install     # create NS + Gateway + point Tenant + IPP fix
#   ./scripts/05-gateway.sh delete      # remove this gateway (+ optional cleanup)
#   ./scripts/05-gateway.sh reinstall   # delete then install
#   ./scripts/05-gateway.sh ipp         # only (re)apply IPP EnvoyFilter fix
#   ./scripts/05-gateway.sh status      # show gateway / tenant / health
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
  local domain
  domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -z "$domain" ]]; then
    echo "ERROR: set GATEWAY_HOSTNAME or ensure ingresses.config.openshift.io/cluster has .spec.domain" >&2
    exit 1
  fi
  echo "maas.${domain}"
}

allowed_namespaces_json() {
  # Build JSON array from space-separated GATEWAY_ALLOWED_NAMESPACES
  local -a ns
  # shellcheck disable=SC2206
  ns=(${GATEWAY_ALLOWED_NAMESPACES:-$GATEWAY_NS $APP_NS $MAAS_NS models-as-a-service})
  # Always include GATEWAY_NS and MAAS_NS
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

render_gateway() {
  export GATEWAY_HOSTNAME
  export GATEWAY_ALLOWED_NAMESPACES_JSON
  export GATEWAY_NS GATEWAY_NAME GATEWAY_CLASS GATEWAY_CERT_SECRET IPP_NS
  envsubst '${GATEWAY_NS}' < cluster/00-gateway-namespace.yaml
  echo '---'
  envsubst '${GATEWAY_NS} ${GATEWAY_NAME} ${GATEWAY_CLASS} ${GATEWAY_HOSTNAME} ${GATEWAY_CERT_SECRET} ${GATEWAY_ALLOWED_NAMESPACES_JSON}' \
    < cluster/10-maas-default-gateway.yaml
}

cmd_status() {
  echo "==> config: $GATEWAY_NS/$GATEWAY_NAME  hostname=$(resolve_hostname)  ipp=$IPP_NS"
  echo
  echo "==> GatewayClass"
  oc get gatewayclass "$GATEWAY_CLASS" 2>/dev/null || echo "  (missing)"
  echo
  echo "==> Gateway"
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o wide 2>/dev/null || echo "  (missing)"
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
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
  curl -sk -o /dev/null -w "  HTTP %{http_code}\n" "https://${host}/maas-api/health" || echo "  (unreachable)"
}

cmd_install() {
  GATEWAY_HOSTNAME="$(resolve_hostname)"
  GATEWAY_ALLOWED_NAMESPACES_JSON="$(allowed_namespaces_json)"
  export GATEWAY_HOSTNAME GATEWAY_ALLOWED_NAMESPACES_JSON

  echo "==> ensure TLS secret $GATEWAY_NS/$GATEWAY_CERT_SECRET"
  if ! oc get secret "$GATEWAY_CERT_SECRET" -n "$GATEWAY_NS" >/dev/null 2>&1; then
    # Namespace may not exist yet — create it first for the secret check after
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
      echo "ERROR: create TLS Secret $GATEWAY_NS/$GATEWAY_CERT_SECRET first, or set GATEWAY_CERT_SECRET to an existing secret name."
      echo "  example: oc create secret tls $GATEWAY_CERT_SECRET -n $GATEWAY_NS --cert=tls.crt --key=tls.key"
      exit 1
    fi
  fi

  echo "==> apply GatewayClass + Gateway in $GATEWAY_NS"
  render_gateway | oc apply -f -

  echo "==> wait for Programmed"
  for i in $(seq 1 60); do
    local st
    st="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
    [[ "$st" == "True" ]] && break
    sleep 2
  done
  oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'

  echo "==> point Tenant $TENANT_NS/$TENANT_NAME → $GATEWAY_NS/$GATEWAY_NAME"
  oc patch "tenant.maas.opendatahub.io/$TENANT_NAME" -n "$TENANT_NS" --type=merge -p "{
    \"spec\": {
      \"gatewayRef\": {
        \"name\": \"${GATEWAY_NAME}\",
        \"namespace\": \"${GATEWAY_NS}\"
      }
    }
  }"

  echo "==> label gateway namespace for MaaS / route attachment"
  oc label namespace "$GATEWAY_NS" "kubernetes.io/metadata.name=$GATEWAY_NS" --overwrite 2>/dev/null || true

  cmd_ipp

  echo
  echo "Installed. Verify:"
  echo "  curl -sk https://${GATEWAY_HOSTNAME}/maas-api/health"
  echo "  ./scripts/05-gateway.sh status"
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
  echo "==> delete IPP attach fix + gateway $GATEWAY_NS/$GATEWAY_NAME"
  oc delete envoyfilter payload-processing-attach-fix -n "$GATEWAY_NS" --ignore-not-found
  oc delete gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" --ignore-not-found

  # LB services owned by the gateway
  oc delete svc -n "$GATEWAY_NS" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" --ignore-not-found

  # Kuadrant-managed filters for this gateway (best-effort names)
  oc delete envoyfilter -n "$GATEWAY_NS" \
    "kuadrant-auth-${GATEWAY_NAME}" \
    "kuadrant-${GATEWAY_NAME}" \
    "kuadrant-ratelimiting-${GATEWAY_NAME}" \
    "${GATEWAY_NAME}-authn-ssl" \
    --ignore-not-found 2>/dev/null || true

  if [[ "${DELETE_GATEWAY_NS:-false}" == "true" ]]; then
    echo "==> DELETE_GATEWAY_NS=true → deleting namespace $GATEWAY_NS"
    oc delete namespace "$GATEWAY_NS" --ignore-not-found
  else
    echo "    namespace $GATEWAY_NS kept (set DELETE_GATEWAY_NS=true to remove)"
  fi

  echo "Deleted gateway objects. Re-point Tenant before serving traffic again."
}

case "$CMD" in
  install)   cmd_install ;;
  delete)    cmd_delete ;;
  reinstall) cmd_delete; cmd_install ;;
  ipp)       cmd_ipp ;;
  status)    cmd_status ;;
  *)
    echo "Usage: $0 {install|delete|reinstall|ipp|status}"
    exit 1
    ;;
esac
