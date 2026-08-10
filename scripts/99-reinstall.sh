#!/usr/bin/env bash
# =============================================================================
# 99-reinstall.sh — destroy and rebuild the model namespace from scratch.
# =============================================================================
# DESTRUCTIVE. Deletes namespace $MAAS_NS and the MaaS access objects that
# reference it, then reinstalls model + tenant binding + access policy.
#
# The provider API key lives ONLY in the in-cluster Secret. Deleting the
# namespace destroys it. This script recovers it first and refuses to delete
# anything if it cannot (set PROVIDER_API_KEY in config.env to override).
# A full YAML backup is written to .maas-backup/<stamp>/ (mode 600, gitignored).
#
# Usage:
#   . ./config.env
#   ./scripts/99-reinstall.sh              # prompts before deleting
#   ./scripts/99-reinstall.sh --yes        # no prompt (CI)
#   ./scripts/99-reinstall.sh --backup-only
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f config.env ] || { echo "Create config.env first."; exit 1; }
# shellcheck disable=SC1091
. ./config.env

ASSUME_YES=0
BACKUP_ONLY=0
for a in "$@"; do
  case "$a" in
    --yes|-y)      ASSUME_YES=1 ;;
    --backup-only) BACKUP_ONLY=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

: "${MAAS_NS:?set MAAS_NS in config.env}"
: "${MODEL_NAME:?set MODEL_NAME in config.env}"
TENANT_NS="${TENANT_NS:-models-as-a-service}"
SECRET_NAME="${MODEL_NAME}-provider"

EM_RES="externalmodels.maas.opendatahub.io"
MMR_RES="maasmodelrefs.maas.opendatahub.io"
MAP_RES="maasauthpolicies.maas.opendatahub.io"
SUB_RES="maassubscriptions.maas.opendatahub.io"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=".maas-backup/${STAMP}"
mkdir -p "$BACKUP"
chmod 700 .maas-backup "$BACKUP"

echo "=== 1. back up everything in $MAAS_NS -> $BACKUP ==="
for res in "$EM_RES" "$MMR_RES" secret configmap; do
  f="$BACKUP/${res%%.*}.yaml"
  oc get "$res" -n "$MAAS_NS" -o yaml > "$f" 2>/dev/null || true
  chmod 600 "$f"
done
for res in "$MAP_RES" "$SUB_RES"; do
  f="$BACKUP/${res%%.*}-${TENANT_NS}.yaml"
  oc get "$res" -n "$TENANT_NS" -o yaml > "$f" 2>/dev/null || true
  chmod 600 "$f"
done
echo "    backup written (contains secrets — mode 600, .maas-backup/ is gitignored)"

# --- recover the provider credential ---------------------------------------
echo
echo "=== 2. recover provider API key ==="
CFG_KEY="${PROVIDER_API_KEY:-}"
LIVE_KEY="$(oc get secret "$SECRET_NAME" -n "$MAAS_NS" -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null || true)"

KEY=""; SRC=""
if [ -n "$CFG_KEY" ] && [ -n "$LIVE_KEY" ] && [ "$CFG_KEY" != "$LIVE_KEY" ]; then
  # Classic footgun: config.env still holds the key for a DIFFERENT provider
  # than the one actually registered in the cluster.
  echo "WARNING: PROVIDER_API_KEY in config.env does not match the live Secret."
  echo "    config.env : ${CFG_KEY:0:6}… (${#CFG_KEY} chars)"
  echo "    live secret: ${LIVE_KEY:0:6}… (${#LIVE_KEY} chars)"
  echo "    The live Secret is the one $MODEL_NAME is currently using."
  if [ "$ASSUME_YES" = 1 ]; then
    echo "ERROR: refusing to choose for you under --yes. Fix PROVIDER_API_KEY in config.env."
    exit 1
  fi
  printf 'Use [l]ive secret or [c]onfig.env value? '
  read -r PICK
  case "$PICK" in
    l|L) KEY="$LIVE_KEY"; SRC="live Secret $MAAS_NS/$SECRET_NAME" ;;
    c|C) KEY="$CFG_KEY";  SRC="config.env PROVIDER_API_KEY" ;;
    *)   echo "Aborted."; exit 1 ;;
  esac
elif [ -n "$LIVE_KEY" ]; then
  KEY="$LIVE_KEY"; SRC="live Secret $MAAS_NS/$SECRET_NAME"
elif [ -n "$CFG_KEY" ]; then
  KEY="$CFG_KEY";  SRC="config.env PROVIDER_API_KEY"
fi
if [ -z "$KEY" ]; then
  echo "ERROR: no provider API key available."
  echo "       Not deleting anything — the key would be unrecoverable."
  echo "       Either set PROVIDER_API_KEY in config.env, or read it first:"
  echo "         oc get secret $SECRET_NAME -n $MAAS_NS -o jsonpath='{.data.api-key}' | base64 -d"
  exit 1
fi
echo "    recovered from: $SRC (prefix ${KEY:0:6}…, ${#KEY} chars)"
export PROVIDER_API_KEY="$KEY"

if [ "$BACKUP_ONLY" = 1 ]; then
  echo
  echo "Backup only — nothing deleted. Backup: $BACKUP"
  exit 0
fi

# --- confirm ----------------------------------------------------------------
echo
echo "=== 3. about to DELETE ==="
echo "    namespace           $MAAS_NS  (and everything in it)"
echo "    $MAP_RES / $SUB_RES named ${MODEL_NAME}-access in $TENANT_NS"
oc get all -n "$MAAS_NS" --no-headers 2>/dev/null | head -20 || true
if [ "$ASSUME_YES" != 1 ]; then
  echo
  printf 'Type the namespace name to confirm: '
  read -r CONFIRM
  [ "$CONFIRM" = "$MAAS_NS" ] || { echo "Aborted."; exit 1; }
fi

# --- delete -----------------------------------------------------------------
echo
echo "=== 4. delete ==="
# MaaSModelRef carries finalizer maas.opendatahub.io/model-cleanup. Delete it
# before the namespace so termination does not hang on it.
oc delete "$MMR_RES" --all -n "$MAAS_NS" --timeout=90s 2>/dev/null || true
oc delete "$EM_RES"  --all -n "$MAAS_NS" --timeout=90s 2>/dev/null || true
oc delete "$MAP_RES" "${MODEL_NAME}-access" -n "$TENANT_NS" --ignore-not-found 2>/dev/null || true
oc delete "$SUB_RES" "${MODEL_NAME}-access" -n "$TENANT_NS" --ignore-not-found 2>/dev/null || true
oc delete namespace "$MAAS_NS" --wait=false --ignore-not-found

echo "    waiting for namespace termination (up to 180s)"
for _ in $(seq 1 36); do
  oc get ns "$MAAS_NS" >/dev/null 2>&1 || break
  sleep 5
done
if oc get ns "$MAAS_NS" >/dev/null 2>&1; then
  echo "WARNING: namespace still terminating. Stuck finalizers:"
  oc get ns "$MAAS_NS" -o jsonpath='{.spec.finalizers}{"\n"}{.status.conditions[*].message}{"\n"}' || true
  echo "         Investigate before continuing; re-run this script once it is gone."
  exit 1
fi
echo "    gone"

# --- rebuild ----------------------------------------------------------------
echo
echo "=== 5. reinstall model ==="
./scripts/10-apply.sh native

echo
echo "=== 6. bind tenant to gateway ==="
./scripts/07-tenant.sh

echo
echo "=== 7. verify ==="
./scripts/20-verify.sh || true

cat <<EOF

Rebuild complete.
  backup:    $BACKUP   (delete it once you are happy — it contains the API key)
  namespace: $MAAS_NS
  model:     $MODEL_NAME

Playground (dashboard) still needs a LlamaStackDistribution:
  ./scripts/15-playground.sh
EOF
