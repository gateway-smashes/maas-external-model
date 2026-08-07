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

h "H. Gateway is actually programmed (must be, or nothing routes)"
oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null
oc get gatewayconfig default-gateway -o jsonpath='{.spec}{"\n"}' 2>/dev/null

h "I. Egress reachability to your provider from inside the cluster"
echo "run manually if you want:"
echo "  oc run egress-test --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- \\"
echo "    curl -sS -o /dev/null -w '%{http_code}\\n' ${PROVIDER_BASE_URL}/models"

h "DONE -- paste sections B, D, E and F back if the manifests need adjusting"
