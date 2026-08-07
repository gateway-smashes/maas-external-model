#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. ./config.env
h() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

h "Model object + events"
oc describe llminferenceservice "$MODEL_NAME" -n "$MAAS_NS" 2>/dev/null | tail -40
oc get events -n "$MAAS_NS" --sort-by=.lastTimestamp | tail -30

h "maas-api logs"
oc logs -n "$APP_NS" -l app.kubernetes.io/name=maas-api --tail=200 2>/dev/null | grep -iE "$MODEL_NAME|error|denied|404" | tail -40

h "Gateway / istiod routing"
oc get httproute -A
ISTIOD=$(oc get deploy -n "$GATEWAY_NS" -o name | grep istiod | head -1)
[ -n "$ISTIOD" ] && oc logs -n "$GATEWAY_NS" "$ISTIOD" --tail=200 | grep -iE "$MODEL_NAME|error" | tail -30

h "kube-auth-proxy (auth failures show here)"
oc logs -n "$GATEWAY_NS" -l app=kube-auth-proxy --tail=200 2>/dev/null | tail -40

h "Dashboard maas-ui container"
oc logs -n "$APP_NS" -l app=rhods-dashboard -c maas-ui --tail=150 2>/dev/null | tail -40

h "Egress test to provider"
oc run egress-test-$$ --rm -i --restart=Never -n "$MAAS_NS" \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sS -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' "$PROVIDER_BASE_URL/models" 2>&1 | tail -5
