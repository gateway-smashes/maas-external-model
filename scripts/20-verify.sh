#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. ./config.env
h() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

h "1. Object state"
oc get llminferenceservice -n "$MAAS_NS" -o wide
oc get llminferenceservice "$MODEL_NAME" -n "$MAAS_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'

h "2. HTTPRoute attached to the gateway?"
oc get httproute -n "$MAAS_NS" -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hostnames,PARENT:.spec.parentRefs[*].name,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status'

h "3. Does maas-api list the model?"
GW_HOST=$(oc get route data-science-gateway -n "$GATEWAY_NS" -o jsonpath='{.spec.host}' 2>/dev/null)
echo "gateway host: $GW_HOST"
echo "As a logged-in user, generate an API key in the dashboard (Gen AI studio ->"
echo "AI asset endpoints -> Models as a service), then:"
cat <<SNIP

  export MAAS_KEY=<key from dashboard>
  curl -sS https://$GW_HOST/maas/v1/models -H "Authorization: Bearer \$MAAS_KEY" | jq

  curl -sS https://$GW_HOST/maas/v1/chat/completions \\
    -H "Authorization: Bearer \$MAAS_KEY" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"$MODEL_NAME","messages":[{"role":"user","content":"say hi"}]}' | jq

SNIP
echo "(the /maas path prefix may differ on your build -- check the HTTPRoute above)"

h "4. Dashboard visibility checklist"
oc get odhdashboardconfig -n "$APP_NS" -o jsonpath='{.items[0].spec.dashboardConfig}{"\n"}' 2>/dev/null | tr ',' '\n' | grep -iE 'maas|genai|modelcatalog|playground' || echo "  (no matching flags found -- see README step 4)"
