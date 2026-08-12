#!/usr/bin/env bash
# =============================================================================
# 15-playground.sh — create the LlamaStackDistribution so the model shows up in
# the dashboard Gen AI playground.
# =============================================================================
# Removes the need to click "Add to playground" in the UI, and fixes the error:
#   maas-ui: no LlamaStackDistribution found in namespace "<ns>"
#
# spec.server.distribution needs a name or image that is valid ON THIS CLUSTER.
# This script resolves it in order:
#   1. $LSD_DISTRIBUTION_IMAGE  (explicit image ref)
#   2. $LSD_DISTRIBUTION_NAME   (explicit distribution name)
#   3. copied from any existing LlamaStackDistribution on the cluster
#   4. the llama-stack operator's distribution ConfigMap
# and refuses to guess if none of those work.
#
# Usage:
#   . ./config.env && ./scripts/15-playground.sh
#   LSD_DISTRIBUTION_NAME=rh-dev ./scripts/15-playground.sh
#   ./scripts/15-playground.sh resolve      # just show what it would use
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env first."; exit 1; }
# shellcheck disable=SC1091
. ./config.env

CMD="${1:-apply}"

LSD_RES="llamastackdistributions.llamastack.io"
GW_RES="gateways.gateway.networking.k8s.io"

: "${MAAS_NS:?set MAAS_NS in config.env}"
: "${MODEL_NAME:?set MODEL_NAME in config.env}"
LSD_NAME="${LSD_NAME:-lsd-genai-playground}"
SUBSCRIPTION="${SUBSCRIPTION:-${MODEL_NAME}-access}"
PLAYGROUND_MAX_TOKENS="${PLAYGROUND_MAX_TOKENS:-512}"
# Empty by default: the provider id differs per distribution image, so the
# registration step reads it from /v1/providers. Set it only to disambiguate
# when more than one inference provider exists.
PLAYGROUND_PROVIDER_ID="${PLAYGROUND_PROVIDER_ID:-}"
APP_NS="${APP_NS:-redhat-ods-applications}"

oc get crd "$LSD_RES" >/dev/null 2>&1 || {
  echo "ERROR: CRD $LSD_RES not present. Set components.llamastackoperator=Managed on the DSC."
  exit 1
}

# --- gateway hostname -------------------------------------------------------
if [ -z "${GATEWAY_HOSTNAME:-}" ]; then
  GATEWAY_HOSTNAME="$(oc get "$GW_RES" "${GATEWAY_NAME:?set GATEWAY_NAME}" -n "${GATEWAY_NS:?set GATEWAY_NS}" \
    -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || true)"
fi
[ -n "$GATEWAY_HOSTNAME" ] || { echo "ERROR: cannot determine gateway hostname; set GATEWAY_HOSTNAME."; exit 1; }

# --- 1. resolve the distribution -------------------------------------------
LSD_DIST_KEY=""; LSD_DIST_VALUE=""; SRC=""
if [ -n "${LSD_DISTRIBUTION_IMAGE:-}" ]; then
  LSD_DIST_KEY="image"; LSD_DIST_VALUE="$LSD_DISTRIBUTION_IMAGE"; SRC="\$LSD_DISTRIBUTION_IMAGE"
elif [ -n "${LSD_DISTRIBUTION_NAME:-}" ]; then
  LSD_DIST_KEY="name"; LSD_DIST_VALUE="$LSD_DISTRIBUTION_NAME"; SRC="\$LSD_DISTRIBUTION_NAME"
else
    OP_NS="$(oc get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="llama-stack-k8s-operator-controller-manager")]}{.metadata.namespace}{end}' 2>/dev/null || true)"

    # Authoritative source: the operator advertises every distribution it
    # supports as RELATED_IMAGE_<NAME>_DISTRIBUTION, e.g. on RHOAI 3.4:
    #   RELATED_IMAGE_RH_DISTRIBUTION=registry.redhat.io/rhoai/odh-llama-stack-core-rhel9@sha256:...
    # Take the image from the right-hand side. Do NOT try to derive a short
    # name from the middle: "rh" is rejected with "Distribution name not
    # supported", after which the operator stops reconciling the CR entirely.
    if [ -n "$OP_NS" ]; then
      DIST_ENV="$(oc set env deploy/llama-stack-k8s-operator-controller-manager \
        -n "$OP_NS" --list 2>/dev/null | grep -E '^RELATED_IMAGE_.+_DISTRIBUTION=' || true)"
      NDIST="$(printf '%s\n' "$DIST_ENV" | grep -c . || true)"
      if [ "${NDIST:-0}" = "1" ]; then
        # Use the IMAGE, not a name derived from the env var. The operator's
        # name table is not simply the lowercased env var middle -- deriving
        # "rh" from RELATED_IMAGE_RH_DISTRIBUTION is rejected with
        # "Distribution name not supported". The image ref always works.
        LSD_DIST_KEY="image"
        LSD_DIST_VALUE="${DIST_ENV#*=}"
        SRC="operator env RELATED_IMAGE_*_DISTRIBUTION in $OP_NS"
      elif [ "${NDIST:-0}" -gt 1 ]; then
        echo "==> operator supports several distributions:"
        printf '%s\n' "$DIST_ENV" \
          | sed -E 's/^RELATED_IMAGE_(.+)_DISTRIBUTION=.*/      \1/' | tr 'A-Z' 'a-z'
        echo "ERROR: pick one explicitly rather than letting this script choose:"
        echo "         LSD_DISTRIBUTION_NAME=<name> ./scripts/15-playground.sh"
        exit 1
      fi
    fi

    # Last resort: copy from an LSD that already works on this cluster.
    if [ -z "$LSD_DIST_VALUE" ]; then
      EX_NAME="$(oc get "$LSD_RES" -A -o jsonpath='{.items[0].spec.server.distribution.name}' 2>/dev/null || true)"
      EX_IMG="$(oc get "$LSD_RES" -A -o jsonpath='{.items[0].spec.server.distribution.image}' 2>/dev/null || true)"
      if [ -n "$EX_NAME" ]; then
        LSD_DIST_KEY="name"; LSD_DIST_VALUE="$EX_NAME"; SRC="existing LlamaStackDistribution"
      elif [ -n "$EX_IMG" ]; then
        LSD_DIST_KEY="image"; LSD_DIST_VALUE="$EX_IMG"; SRC="existing LlamaStackDistribution"
      fi
    fi
fi

if [ -z "$LSD_DIST_VALUE" ]; then
  cat <<EOF
ERROR: cannot determine a valid spec.server.distribution for this cluster,
       and guessing would create a broken LlamaStackDistribution.

Find a valid value, then re-run with it:

  # what the operator supports
  oc get cm -A | grep -i llama
  oc get deploy -A | grep llama-stack

  # or create one LSD from the dashboard (Gen AI -> Add to playground) and copy it
  oc get $LSD_RES -A -o yaml | grep -A3 distribution

  LSD_DISTRIBUTION_NAME=<name>   ./scripts/15-playground.sh
  LSD_DISTRIBUTION_IMAGE=<image> ./scripts/15-playground.sh
EOF
  exit 1
fi
# Sanity: a resolved distribution that matches a namespace on this cluster is
# almost certainly a resolution bug, not a real distribution. Refuse it rather
# than writing a CR the operator will reject.
if oc get ns "$LSD_DIST_VALUE" >/dev/null 2>&1; then
  echo "ERROR: resolved distribution '${LSD_DIST_VALUE}' is a namespace name (source: ${SRC})."
  echo "       That is a bad resolution, not a distribution. Pin one explicitly:"
  echo "         LSD_DISTRIBUTION_NAME=<name>   ./scripts/15-playground.sh"
  echo "         LSD_DISTRIBUTION_IMAGE=<image> ./scripts/15-playground.sh"
  exit 1
fi

echo "==> distribution: ${LSD_DIST_KEY}=${LSD_DIST_VALUE}   (source: ${SRC})"
[ "$CMD" = "resolve" ] && exit 0

# --- 2. mint a MaaS API key for the LSD ------------------------------------
echo "==> minting MaaS API key for subscription ${SUBSCRIPTION}"
TOKEN="$(oc whoami -t)"
MINT_URL="https://${GATEWAY_HOSTNAME}/maas-api/v1/api-keys"
# Keep status and body so a failure says WHY instead of "could not mint".
RESP="$(curl -sk -m 30 -w '\n__HTTP__%{http_code}' -X POST "$MINT_URL" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d "{\"name\":\"playground-lsd-$(date +%s)\",\"subscription\":\"${SUBSCRIPTION}\"}" 2>&1 || true)"
HTTP="${RESP##*__HTTP__}"
BODY="${RESP%$'\n'__HTTP__*}"
KEY="$(printf '%s' "$BODY" | { command -v jq >/dev/null && jq -r '.key // empty' 2>/dev/null || sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; })"

if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
  echo "ERROR: could not mint an API key."
  echo "    POST $MINT_URL"
  echo "    HTTP ${HTTP:-<no response>}"
  echo "    body: $(printf '%s' "$BODY" | head -c 400)"
  echo
  case "$HTTP" in
    404|503|000|"")
      echo "  maas-api is not reachable through this gateway. That is the Tenant"
      echo "  binding, not the playground. Run this first:"
      echo "      ./scripts/07-tenant.sh"
      echo "      curl -sk https://${GATEWAY_HOSTNAME}/maas-api/health" ;;
    401|403)
      echo "  Authentication rejected. 'oc whoami -t' may be expired, or the"
      echo "  MaaSAuthPolicy does not cover your user/group." ;;
    *)
      echo "  Subscriptions on this cluster:"
      oc get maassubscriptions.maas.opendatahub.io -A 2>/dev/null | sed 's/^/      /' ;;
  esac
  echo
  echo "  Note: a subscription in phase Failed cannot mint keys even though it exists."
  exit 1
fi
echo "    key prefix ${KEY:0:10}…"
oc create secret generic lsd-maas-api-key -n "$MAAS_NS" \
  --from-literal=api-key="$KEY" --dry-run=client -o yaml | oc apply -f -

# --- 3. apply the LSD -------------------------------------------------------
export LSD_NAME MAAS_NS MODEL_NAME GATEWAY_HOSTNAME PLAYGROUND_MAX_TOKENS \
       PLAYGROUND_PROVIDER_ID LSD_DIST_KEY LSD_DIST_VALUE
echo "==> applying Postgres backend for the distribution"
envsubst < playground/postgres.yaml | oc apply -f -

echo "==> applying model-discovery shim"
envsubst < playground/model-shim.yaml | oc apply -f -
oc rollout status deploy/lsd-model-shim -n "$MAAS_NS" --timeout=180s || true

echo "==> applying LlamaStackDistribution $MAAS_NS/$LSD_NAME"
envsubst < playground/llamastackdistribution.yaml | oc apply -f -

echo "==> waiting for the operator to create the Deployment"
DEPLOY_OK=0
for _ in $(seq 1 24); do
  if oc get deploy "$LSD_NAME" -n "$MAAS_NS" >/dev/null 2>&1; then DEPLOY_OK=1; break; fi
  sleep 5
done

# The API server accepts any distribution string; the operator validates it and
# then silently stops reconciling ("Distribution name not supported"). Without
# this check you get a CR, no Deployment, no Service, and maas-ui reporting
# "has no service url" with nothing explaining why.
if [ "$DEPLOY_OK" != 1 ]; then
  echo
  echo "ERROR: the operator did not create a Deployment for $MAAS_NS/$LSD_NAME."
  echo "       Distribution used: ${LSD_DIST_KEY}=${LSD_DIST_VALUE} (source: ${SRC})"
  echo
  echo "  operator says:"
  oc logs -n "${LSD_OP_NS:-redhat-ods-applications}" \
    deploy/llama-stack-k8s-operator-controller-manager --tail=200 2>/dev/null \
    | grep -iE "$LSD_NAME|distribution" | tail -5 | sed 's/^/      /'
  echo
  echo "  'Distribution name not supported' means the value above is not in the"
  echo "  operator's table. Re-run pinning a supported one:"
  echo "      LSD_DISTRIBUTION_NAME=<name>   ./scripts/15-playground.sh"
  echo "      LSD_DISTRIBUTION_IMAGE=<image> ./scripts/15-playground.sh"
  exit 1
fi
oc rollout status "deploy/${LSD_NAME}" -n "$MAAS_NS" --timeout=300s || true

# --- 4. nothing to register -----------------------------------------------
# This image exposes /v1/models as GET-only (no registration API) and its run
# config has no static `models:` section, so the model can ONLY appear via
# provider discovery -- which is why playground/model-shim.yaml exists and why
# VLLM_URL points at it rather than at the gateway.
echo "==> models come from discovery via the shim; verifying"
oc get deploy lsd-model-shim -n "$MAAS_NS" >/dev/null 2>&1 \
  || echo "WARNING: lsd-model-shim is not deployed -- the playground will list no models."

cat <<EOF

Playground wired.
  LSD:     ${MAAS_NS}/${LSD_NAME}
  backend: https://${GATEWAY_HOSTNAME}/${MAAS_NS}/${MODEL_NAME}/v1

Check the dashboard error is gone:
  oc logs -n ${APP_NS} deploy/rhods-dashboard -c maas-ui --tail=50 | grep -i llamastack

Then: dashboard -> Gen AI -> playground, project ${MAAS_NS}.
Re-run this script if the LlamaStack operator reconciles the Deployment later.
EOF
