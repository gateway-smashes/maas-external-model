#!/usr/bin/env bash
# Render + apply. Usage: ./scripts/10-apply.sh [native|litellm]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env from config.env.example first."; exit 1; }
. ./config.env
MODE="${1:-native}"

echo ">> namespace $MAAS_NS"
oc create namespace "$MAAS_NS" --dry-run=client -o yaml | oc apply -f -
oc label namespace "$MAAS_NS" opendatahub.io/dashboard=true --overwrite
oc annotate namespace "$MAAS_NS" openshift.io/display-name="MaaS External Models" --overwrite

echo ">> provider credential secret"
oc create secret generic "${MODEL_NAME}-provider" \
  --from-literal=api_key="$PROVIDER_API_KEY" \
  --from-literal=base_url="$PROVIDER_BASE_URL" \
  --from-literal=model_id="$PROVIDER_MODEL_ID" \
  -n "$MAAS_NS" --dry-run=client -o yaml | oc apply -f -
oc label secret "${MODEL_NAME}-provider" -n "$MAAS_NS" \
  opendatahub.io/managed=true --overwrite

if [ -n "${PROVIDER_CA_BUNDLE_FILE:-}" ] && [ -f "$PROVIDER_CA_BUNDLE_FILE" ]; then
  echo ">> custom CA bundle"
  oc create configmap "${MODEL_NAME}-ca" --from-file=ca-bundle.crt="$PROVIDER_CA_BUNDLE_FILE" \
    -n "$MAAS_NS" --dry-run=client -o yaml | oc apply -f -
fi

render() { envsubst < "$1"; }

case "$MODE" in
  native)
    echo ">> native external LLMInferenceService"
    for f in native/*.yaml; do
      [ "$(basename "$f")" = "kustomization.yaml" ] && continue
      render "$f" | oc apply -f -
    done
    ;;
  litellm)
    echo ">> LiteLLM shim + LLMInferenceService"
    for f in litellm-fallback/*.yaml; do
      [ "$(basename "$f")" = "kustomization.yaml" ] && continue
      render "$f" | oc apply -f -
    done
    oc rollout status deploy/litellm -n "$MAAS_NS" --timeout=180s
    ;;
  *) echo "unknown mode: $MODE (native|litellm)"; exit 1 ;;
esac

echo ">> tier access RBAC"
for t in $TIERS; do
  render native/30-tier-access-rbac.yaml | sed "s/__TIER__/$t/g" | oc apply -f -
done

echo
echo "Applied. Now run: ./scripts/20-verify.sh"
