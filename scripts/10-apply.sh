#!/usr/bin/env bash
# Render + apply. Usage: ./scripts/10-apply.sh [native|litellm]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env from config.env.example first."; exit 1; }
. ./config.env
MODE="${1:-native}"

: "${GATEWAY_NS:?set GATEWAY_NS in config.env}"
: "${GATEWAY_NAME:?set GATEWAY_NAME in config.env}"

# ExternalModel.spec.endpoint is hostname/FQDN only — no scheme, path, or :port.
# CRD pattern: ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9](...))?*$
if [ -z "${PROVIDER_HOST:-}" ]; then
  PROVIDER_HOST=$(printf '%s' "$PROVIDER_BASE_URL" \
    | sed -E 's|^https?://||; s|/.*||; s|:[0-9]+$||')
  export PROVIDER_HOST
fi
# Strip :port if someone set PROVIDER_HOST with it
if [[ "$PROVIDER_HOST" == *:* ]]; then
  echo "WARNING: PROVIDER_HOST must not include :port (got '$PROVIDER_HOST'); stripping"
  PROVIDER_HOST="${PROVIDER_HOST%%:*}"
  export PROVIDER_HOST
fi
PROVIDER_PORT=$(printf '%s' "${PROVIDER_BASE_URL:-}" \
  | sed -E 's|^https?://||; s|/.*||; s|^[^:]*:?||')
if [[ -n "${PROVIDER_PORT:-}" && "$PROVIDER_PORT" != "443" && "$PROVIDER_PORT" != "80" ]]; then
  echo "WARNING: provider uses port ${PROVIDER_PORT}; ExternalModel.spec.endpoint cannot carry a port."
  echo "         Controllers usually originate TLS to :443. For in-cluster :${PROVIDER_PORT} (e.g. OLS),"
  echo "         expose the service on 443 or put a TLS sidecar / Route in front."
fi
echo ">> provider host: $PROVIDER_HOST"

echo ">> namespace $MAAS_NS"
oc create namespace "$MAAS_NS" --dry-run=client -o yaml | oc apply -f -
oc label namespace "$MAAS_NS" opendatahub.io/dashboard=true --overwrite
oc annotate namespace "$MAAS_NS" openshift.io/display-name="MaaS External Models" --overwrite

# Allow HTTPRoutes from this namespace onto the inference gateway (idempotent).
if oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" >/dev/null 2>&1; then
  echo ">> ensure gateway $GATEWAY_NS/$GATEWAY_NAME allows namespace $MAAS_NS"
  CURRENT=$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.selector.matchExpressions[0].values}' 2>/dev/null || true)
  if [[ "$CURRENT" != *"$MAAS_NS"* ]]; then
    oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o json \
      | jq --arg ns "$MAAS_NS" '
          .spec.listeners |= map(
            if .allowedRoutes.namespaces.selector.matchExpressions then
              .allowedRoutes.namespaces.selector.matchExpressions |= map(
                if .key=="kubernetes.io/metadata.name" and .operator=="In" then
                  .values = ((.values + [$ns]) | unique)
                else . end)
            else . end)' \
      | oc apply -f -
  fi
else
  echo "WARNING: gateway $GATEWAY_NS/$GATEWAY_NAME not found."
  echo "         Install it first:  ./scripts/05-gateway.sh install"
fi

echo ">> provider credential secret (key: api-key, IPP-managed label required)"
oc create secret generic "${MODEL_NAME}-provider" \
  --from-literal=api-key="$PROVIDER_API_KEY" \
  -n "$MAAS_NS" --dry-run=client -o yaml | oc apply -f -
oc label secret "${MODEL_NAME}-provider" -n "$MAAS_NS" \
  opendatahub.io/managed=true \
  inference.llm-d.ai/ipp-managed=true \
  inference.networking.k8s.io/bbr-managed=true \
  --overwrite

if [ -n "${PROVIDER_CA_BUNDLE_FILE:-}" ] && [ -f "$PROVIDER_CA_BUNDLE_FILE" ]; then
  echo ">> custom CA bundle"
  oc create configmap "${MODEL_NAME}-ca" --from-file=ca-bundle.crt="$PROVIDER_CA_BUNDLE_FILE" \
    -n "$MAAS_NS" --dry-run=client -o yaml | oc apply -f -
fi

render() { envsubst < "$1"; }

case "$MODE" in
  native)
    echo ">> native ExternalModel + MaaSModelRef + access policy"
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

echo
echo "Applied (gateway $GATEWAY_NS/$GATEWAY_NAME)."
echo "Now run: ./scripts/20-verify.sh"
echo "Mint a key:  POST https://<gateway>/maas-api/v1/api-keys  {\"name\":\"test\",\"subscription\":\"${MODEL_NAME}-access\"}"
echo "Chat:        POST https://<gateway>/${MAAS_NS}/${MODEL_NAME}/v1/chat/completions"
