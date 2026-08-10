#!/usr/bin/env bash
# Fix Gen AI playground → MaaS ExternalModel silent failures on RHOAI 3.4.x.
#
# Problems this addresses:
#   1) VLLM_MAX_TOKENS defaults to 4096 on a 4096-context model → ContextWindowExceeded
#      (UI shows no error, just no answer)
#   2) LSD ships VLLM_API_TOKEN_1=fake → need a real sk-oai-* MaaS key
#   3) UI sends short model id; LSD only registers maas-vllm-inference-1/<model>
#
# Usage (from repo root, after model is registered and curl chat works):
#   . ./config.env
#   ./cluster/lsd-playground-fix.sh
#
# Re-run after the LlamaStack operator reconciles away Deployment patches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "${ROOT}/config.env" ]] && . "${ROOT}/config.env"

MAAS_NS="${MAAS_NS:-maas-external-models}"
MODEL_NAME="${MODEL_NAME:-granite-3-2-8b-instruct-cpu}"
SUBSCRIPTION="${SUBSCRIPTION:-${MODEL_NAME}-access}"
# Live playground subscription name used in this cluster's demo:
# SUBSCRIPTION=granite-admin-access
LSD_NAME="${LSD_NAME:-lsd-genai-playground}"
GATEWAY_HOST="${GATEWAY_HOST:-}"
MAX_TOKENS="${PLAYGROUND_MAX_TOKENS:-512}"
PROVIDER_ID="${PLAYGROUND_PROVIDER_ID:-maas-vllm-inference-1}"

if [[ -z "${GATEWAY_HOST}" ]]; then
  if [[ -n "${GATEWAY_NAME:-}" && -n "${GATEWAY_NS:-}" ]]; then
    GATEWAY_HOST="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" \
      -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || true)"
  fi
  if [[ -z "${GATEWAY_HOST}" ]]; then
    CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    GATEWAY_HOST="maas.${CLUSTER_DOMAIN}"
  fi
fi

echo "==> Gateway host: ${GATEWAY_HOST}"
echo "==> Namespace/model: ${MAAS_NS}/${MODEL_NAME}"
echo "==> LSD: ${LSD_NAME}"

if ! oc get llamastackdistribution "${LSD_NAME}" -n "${MAAS_NS}" >/dev/null 2>&1; then
  echo "ERROR: LlamaStackDistribution/${LSD_NAME} not found in ${MAAS_NS}."
  echo "Create a playground from Gen AI studio (Add to playground) first."
  exit 1
fi

echo "==> Mint MaaS API key for playground LSD"
TOKEN="$(oc whoami -t)"
KEY="$(curl -sk -X POST "https://${GATEWAY_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"playground-lsd-$(date +%s)\",\"subscription\":\"${SUBSCRIPTION}\"}" | jq -r .key)"
if [[ -z "${KEY}" || "${KEY}" == "null" ]]; then
  echo "ERROR: failed to mint API key. Check subscription name (${SUBSCRIPTION}) and maas-api."
  exit 1
fi
echo "    key prefix: ${KEY:0:12}..."

oc create secret generic lsd-maas-api-key -n "${MAAS_NS}" \
  --from-literal=api-key="${KEY}" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> Lower VLLM_MAX_TOKENS and wire secret on LSD CR (best effort)"
# valueFrom may be ignored by some operator versions; Deployment patch below is authoritative.
oc patch llamastackdistribution "${LSD_NAME}" -n "${MAAS_NS}" --type=json -p "$(cat <<EOF
[
  {"op":"replace","path":"/spec/server/containerSpec/env","value":[
    {"name":"VLLM_TLS_VERIFY","value":"false"},
    {"name":"MILVUS_DB_PATH","value":"~/.llama/milvus.db"},
    {"name":"FMS_ORCHESTRATOR_URL","value":"http://localhost"},
    {"name":"VLLM_MAX_TOKENS","value":"${MAX_TOKENS}"},
    {"name":"VLLM_API_TOKEN_1","valueFrom":{"secretKeyRef":{"name":"lsd-maas-api-key","key":"api-key"}}},
    {"name":"LLAMA_STACK_CONFIG_DIR","value":"/opt/app-root/src/.llama/distributions/rh/"},
    {"name":"PLAYGROUND_MODEL_ID","value":"${MODEL_NAME}"},
    {"name":"PLAYGROUND_PROVIDER_ID","value":"${PROVIDER_ID}"}
  ]}
]
EOF
)" || true

echo "==> Cap registered model max_tokens in llama-stack-config (if present)"
if oc get cm llama-stack-config -n "${MAAS_NS}" >/dev/null 2>&1; then
  oc get cm llama-stack-config -n "${MAAS_NS}" -o json | python3 -c '
import json,sys,re
cm=json.load(sys.stdin)
y=cm["data"]["config.yaml"]
y=re.sub(r"(?m)^(\s*max_tokens:\s*)100000\s*$", r"\g<1>4096", y)
cm["data"]["config.yaml"]=y
json.dump(cm, open("/tmp/llama-stack-config.json","w"))
'
  oc replace -f /tmp/llama-stack-config.json || true
fi

echo "==> Apply short-model alias ConfigMap"
# Rewrite default model id in the bundled YAML for this MODEL_NAME
sed -e "s/granite-3-2-8b-instruct-cpu/${MODEL_NAME}/g" \
    -e "s/namespace: maas-external-models/namespace: ${MAAS_NS}/g" \
    "${ROOT}/cluster/lsd-model-alias-bootstrap.yaml" | oc apply -f -

echo "==> Patch Deployment env + postStart alias bootstrap"
# Wait briefly for operator to create/update Deployment
sleep 2
DEPLOY="${LSD_NAME}"
oc get deploy "${DEPLOY}" -n "${MAAS_NS}" >/dev/null

# Strategic merge: keep operator fields, overlay our env/mount/lifecycle
oc patch deploy "${DEPLOY}" -n "${MAAS_NS}" --type=strategic -p "$(cat <<EOF
spec:
  template:
    spec:
      volumes:
      - name: model-alias-bootstrap
        configMap:
          name: lsd-model-alias-bootstrap
      containers:
      - name: llama-stack
        env:
        - name: VLLM_MAX_TOKENS
          value: "${MAX_TOKENS}"
        - name: VLLM_API_TOKEN_1
          valueFrom:
            secretKeyRef:
              name: lsd-maas-api-key
              key: api-key
        - name: PLAYGROUND_MODEL_ID
          value: "${MODEL_NAME}"
        - name: PLAYGROUND_PROVIDER_ID
          value: "${PROVIDER_ID}"
        volumeMounts:
        - name: model-alias-bootstrap
          mountPath: /opt/alias
          readOnly: true
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/sh
              - -c
              - python3 /opt/alias/bootstrap-alias.py > /tmp/alias.log 2>&1 || true
EOF
)"

oc rollout status "deploy/${DEPLOY}" -n "${MAAS_NS}" --timeout=180s
sleep 8

POD="$(oc get pods -n "${MAAS_NS}" -l app.kubernetes.io/name="${LSD_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${POD}" ]]; then
  POD="$(oc get pods -n "${MAAS_NS}" -o jsonpath='{.items[0].metadata.name}')"
fi
echo "==> Pod: ${POD}"
oc exec -n "${MAAS_NS}" "${POD}" -- sh -c 'echo MAX=$VLLM_MAX_TOKENS; echo TOKEN_PREFIX=${VLLM_API_TOKEN_1:0:12}'
oc exec -n "${MAAS_NS}" "${POD}" -- cat /tmp/alias.log 2>/dev/null || echo "(alias log not ready yet — wait a few seconds)"

echo "==> Smoke: short model id via LSD /v1/responses"
oc exec -n "${MAAS_NS}" "${POD}" -- python3 -c "
import json, urllib.request
req=urllib.request.Request(
  'http://127.0.0.1:8321/v1/responses',
  data=json.dumps({'model':'${MODEL_NAME}','input':'Say hi in one word','stream':False}).encode(),
  headers={'Content-Type':'application/json'}, method='POST')
with urllib.request.urlopen(req, timeout=90) as r:
  b=json.loads(r.read().decode())
  print(b.get('status'), (b.get('output') or [{}])[0].get('content',[{}])[0].get('text'))
"

echo
echo "Done. Retry Gen AI studio playground in project ${MAAS_NS}."
echo "If the LlamaStack operator reconciles the Deployment later, re-run this script."
