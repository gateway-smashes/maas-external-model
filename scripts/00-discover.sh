#!/usr/bin/env bash
# Dump the ACTUAL schemas and state from your cluster. External models are
# Tech Preview in RHOAI 3.4 and the CR shape is not fully public -- run this
# first and correct native/20-llminferenceservice.yaml against the output.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] && . ./config.env || . ./config.env.example
h() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

h "A. Relevant CRDs present"
oc get crd 2>/dev/null | grep -Ei 'kserve|maas|kuadrant|authorino|limitador|opendatahub|gateway.networking'

h "B. LLMInferenceService schema -- look for external/url/endpoint/apiKey fields"
oc explain llminferenceservice.spec --recursive 2>/dev/null | head -250
echo "--- fields whose name hints at external routing ---"
oc explain llminferenceservice.spec --recursive 2>/dev/null \
  | grep -iE 'extern|url|endpoint|apikey|secret|provider|base|passthrough|upstream'

h "C. Full CRD versions + any 'external' anywhere in the OpenAPI schema"
oc get crd llminferenceservices.serving.kserve.io -o json 2>/dev/null \
  | jq -r '.spec.versions[] | .name + " served=" + (.served|tostring) + " storage=" + (.storage|tostring)'
oc get crd llminferenceservices.serving.kserve.io -o json 2>/dev/null \
  | jq -r '[paths(scalars) as $p | $p | join(".")] | map(select(test("extern|provider|upstream";"i"))) | unique | .[]' \
  | head -40

h "D. MaaS-specific CRDs (if any) and their schemas"
for c in $(oc get crd -o name 2>/dev/null | grep -i maas); do
  echo "--- $c"; oc get "$c" -o jsonpath='{.spec.group}{"/"}{.spec.names.kind}{"\n"}'
done
oc api-resources 2>/dev/null | grep -i maas

h "E. Existing LLMInferenceService objects -- copy the shape that already works"
oc get llminferenceservice -A 2>/dev/null
for x in $(oc get llminferenceservice -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | head -3); do
  echo "--- $x"; oc get llminferenceservice -n "${x%%/*}" "${x##*/}" -o yaml | sed -n '1,120p'
done

h "F. Dashboard feature flags -- MaaS + Gen AI studio must be ON for the playground"
oc get odhdashboardconfig -n "$APP_NS" -o yaml 2>/dev/null | sed -n '/^  spec:/,/^  status:/p'

h "G. MaaS platform health"
oc get pods -n "$APP_NS" -l app.kubernetes.io/name=maas-api 2>/dev/null
oc get configmap tier-to-group-mapping -n "$APP_NS" -o yaml 2>/dev/null
oc get subscriptions -A 2>/dev/null | grep -Ei 'connectivity|kuadrant|authorino'

h "H. Gateways (all) + configured GATEWAY_NS/GATEWAY_NAME"
echo "config.env target: ${GATEWAY_NS:-?}/${GATEWAY_NAME:-?}"
oc get gateway -A -o wide 2>/dev/null
echo "--- configured gateway status ---"
oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null \
  || echo "(missing $GATEWAY_NS/$GATEWAY_NAME — run ./scripts/05-gateway.sh install)"
echo "--- listener hostname ---"
oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[*].hostname}{"\n"}' 2>/dev/null || true
echo "--- Tenant gatewayRef ---"
oc get tenant -n "${TENANT_NS:-models-as-a-service}" -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.gatewayRef.namespace}{"/"}{.spec.gatewayRef.name}{" phase="}{.status.phase}{"\n"}{end}' 2>/dev/null || true
echo "--- GatewayConfig (DASHBOARD only: data-science-gateway → openshift-ai.*; not MaaS) ---"
oc get gatewayconfig default-gateway -o jsonpath='domain={.spec.domain} subdomain={.spec.subdomain}{"\n"}{.spec}{"\n"}' 2>/dev/null
echo "--- config.env DNS ---"
echo "CUSTOM_DOMAIN=${CUSTOM_DOMAIN:-"(unset)"} GATEWAY_HOSTNAME=${GATEWAY_HOSTNAME:-"(auto)"} ROUTE_LABELS=${ROUTE_LABELS:-"(unset)"}"
echo "--- Routes in GATEWAY_NS ---"
oc get route -n "${GATEWAY_NS:-maas-gateway}" -o wide 2>/dev/null || true
echo "--- Sample route labels elsewhere (find the required key) ---"
oc get route -A -o json 2>/dev/null \
  | jq -r '[.items[].metadata.labels | keys[]] | unique | .[]' 2>/dev/null | head -40 \
  || true

h "I. Egress reachability to your provider from inside the cluster"
echo "run manually if you want:"
echo "  oc run egress-test --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- \\"
echo "    curl -sS -o /dev/null -w '%{http_code}\\n' ${PROVIDER_BASE_URL}/models"

h "DONE -- paste sections B, D, E and F back if the manifests need adjusting"
