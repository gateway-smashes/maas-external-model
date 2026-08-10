#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. ./config.env
h() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

h "1. ExternalModel / MaaSModelRef"
oc get externalmodel,maasmodelref -n "$MAAS_NS" -o wide 2>/dev/null || true
oc get maasmodelref "$MODEL_NAME" -n "$MAAS_NS" -o jsonpath='{.status.phase}{" endpoint="}{.status.endpoint}{"\n"}' 2>/dev/null

h "2. HTTPRoute attached to the gateway?"
oc get httproute -n "$MAAS_NS" -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hostnames,PARENT:.spec.parentRefs[*].name,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status'

h "3. Access policy / subscription"
oc get maasauthpolicy,maassubscription -n models-as-a-service 2>/dev/null | grep -E "NAME|$MODEL_NAME" || true

h "4. Gateway host + smoke curls"
GW_HOST=$(oc get httproute -A -o jsonpath='{range .items[*]}{.spec.hostnames[0]}{"\n"}{end}' 2>/dev/null | grep -v '^$' | head -1)
[ -z "$GW_HOST" ] && GW_HOST=$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null)
echo "gateway host: $GW_HOST"
cat <<SNIP

  export TOKEN=\$(oc whoami -t)
  # Mint a MaaS API key bound to subscription ${MODEL_NAME}-access
  export MAAS_KEY=\$(curl -sk -X POST "https://\$GW_HOST/maas-api/v1/api-keys" \\
    -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" \\
    -d '{"name":"verify","subscription":"${MODEL_NAME}-access"}' | jq -r .key)

  curl -sk "https://\$GW_HOST/v1/models" -H "Authorization: Bearer \$MAAS_KEY" | jq

  curl -sk "https://\$GW_HOST/${MAAS_NS}/${MODEL_NAME}/v1/chat/completions" \\
    -H "Authorization: Bearer \$MAAS_KEY" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}' | jq

SNIP

h "5. Gateway + Tenant"
echo "gateway: $GATEWAY_NS/$GATEWAY_NAME"
oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || echo "MISSING gateway — ./scripts/05-gateway.sh install"
oc get tenant -n "${TENANT_NS:-models-as-a-service}" -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.gatewayRef.namespace}{"/"}{.spec.gatewayRef.name}{"\n"}{end}' 2>/dev/null

h "6. IPP attachment (ext_proc must be in the gateway filter chain)"
oc get envoyfilter payload-processing-attach-fix -n "$GATEWAY_NS" -o name 2>/dev/null \
  || echo "  MISSING: ./scripts/05-gateway.sh ipp"
