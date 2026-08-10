# Configuring Models-as-a-Service (MaaS) for External LLMs

Field guide for bringing up MaaS on **RHOAI 3.4.x / OCP 4.20** and registering an
external OpenAI-compatible model. Captures the full platform prerequisites, the
`ExternalModel` registration path, Gen AI playground fixes, and every failure
mode hit during bring-up.

Companion to [README.md](./README.md). Use this when the cluster is not already
MaaS-ready, when inference returns 401 / 404 / 500, or when the playground
gives no answer. Jump to [§9](#9-full-manual-reproduction-checklist) for an
ordered checkbox list you can reproduce by hand.

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Decision: native vs LiteLLM](#2-decision-native-vs-litellm)
3. [Platform prerequisites](#3-platform-prerequisites)
4. [Register an external model](#4-register-an-external-model)
5. [Verify end-to-end](#5-verify-end-to-end)
6. [Troubleshooting catalog](#6-troubleshooting-catalog)
7. [Quick diagnostic commands](#7-quick-diagnostic-commands)
8. [Glossary](#8-glossary)
9. [Full manual reproduction checklist](#9-full-manual-reproduction-checklist)

---

## 1. Architecture

### 1.1 Request path (happy path)

```mermaid
flowchart LR
  Client["Client / Dashboard / Playground<br/>Bearer sk-oai-…"]
  LB["maas.apps.&lt;domain&gt;"]
  GW["Gateway<br/>$GATEWAY_NS / maas-default-gateway"]
  Wasm["Kuadrant Wasm<br/>AuthPolicy + RateLimit"]
  Authorino["Authorino<br/>TokenReview / API key"]
  IPP["IPP ext_proc<br/>path rewrite + API key inject"]
  SE["ServiceEntry + DestinationRule<br/>TLS origination"]
  Provider["External provider<br/>OpenAI-compatible /v1"]

  Client --> LB --> GW --> Wasm
  Wasm --> Authorino
  Wasm --> IPP --> SE --> Provider
```

Playground path (separate from direct curl): **Gen AI UI → LlamaStackDistribution
(`lsd-genai-playground`) → same `maas.apps…/<ns>/<model>/v1`**.

### 1.2 Control plane (what must exist)

```mermaid
flowchart TB
  subgraph ocp [OpenShift / OLM]
    RHCL["RH Connectivity Link<br/>Kuadrant CR"]
    Auth["Authorino + TLS"]
    Lim["Limitador"]
  end

  subgraph rhoai [RHOAI]
    DSC["DataScienceCluster<br/>kserve.modelsAsService=Managed"]
    MC["maas-controller"]
    API["maas-api + Postgres"]
    IPPD["payload-processing Deployment"]
    Tenant["Tenant/default-tenant<br/>gatewayRef"]
  end

  subgraph modelns [Model namespace]
    EM["ExternalModel"]
    MMR["MaaSModelRef"]
    Sec["Secret api-key<br/>ipp-managed label"]
    HR["HTTPRoute"]
  end

  subgraph maasns [models-as-a-service]
    MAP["MaaSAuthPolicy"]
    Sub["MaaSSubscription"]
  end

  RHCL --> Auth
  RHCL --> Lim
  DSC --> MC --> Tenant
  Tenant --> API
  Tenant --> IPPD
  EM --> MMR
  EM --> HR
  Sec --> IPPD
  MAP --> WasmAuth["Kuadrant AuthPolicy"]
  Sub --> WasmRL["TokenRateLimitPolicy"]
```

### 1.3 Objects created per external model

| Object | Owner | Purpose |
|---|---|---|
| `Secret` (`api-key`) | You / `10-apply.sh` | Provider credential for IPP |
| `ExternalModel` | You | Provider FQDN, target model, credentialRef |
| `MaaSModelRef` | You | Registers model in MaaS catalog |
| `Service` (ExternalName) | ExternalModel reconciler | In-cluster DNS → provider FQDN |
| `ServiceEntry` | ExternalModel reconciler | Istio mesh egress |
| `DestinationRule` | ExternalModel reconciler | TLS origination to provider |
| `HTTPRoute` | ExternalModel reconciler | Path + header match on gateway |
| `MaaSAuthPolicy` | You | Who may call the model |
| `MaaSSubscription` | You | Token rate limits |
| Kuadrant `AuthPolicy` / `TokenRateLimitPolicy` | MaaS controllers | Enforced on the HTTPRoute |

---

## 2. Decision: native vs LiteLLM

```mermaid
flowchart TD
  A["oc api-resources \| grep externalmodel"] --> B{ExternalModel CRD present?}
  B -->|Yes| C["Use native/<br/>ExternalModel path"]
  B -->|No| D["oc explain llminferenceservice.spec --recursive"]
  D --> E{external / apiKey fields?}
  E -->|Yes| F["Rare: LLMInferenceService external<br/>verify field names first"]
  E -->|No| G["Use litellm-fallback/"]
```

On **RHOAI 3.4.2**, `LLMInferenceService` has **no** `spec.external` block.
The correct native API is:

```text
maas.opendatahub.io/v1alpha1  ExternalModel
maas.opendatahub.io/v1alpha1  MaaSModelRef
```

---

## 3. Platform prerequisites

Do these **before** applying model manifests. Order matters.

### 3.1 Checklist

| # | Prerequisite | How to confirm |
|---|---|---|
| 1 | RH Connectivity Link operator installed | `oc get csv -A \| grep rhcl-operator` → Succeeded |
| 2 | `Kuadrant` instance ready | `oc get kuadrant -A` → Ready |
| 3 | Authorino running **with TLS** | `oc get authorino -A` + `listener.tls.enabled=true` |
| 4 | Limitador running | `oc get limitador -A` |
| 5 | Gateway `Programmed=True` | `oc get gateway -A` |
| 6 | DSC `modelsAsService=Managed` | `ModelsAsServiceReady=True` |
| 7 | Postgres Secret `maas-db-config` | Key `DB_CONNECTION_URL` in apps NS |
| 8 | Tenant `gatewayRef` → real gateway | Not stuck on `maas-default-gateway` |
| 9 | `maas-api` Deployment Available | Pod in `redhat-ods-applications` |
| 10 | IPP attached to gateway filter chain | `ext_proc.bbr` after `wasm` |
| 11 | Dashboard flags | `genAiStudio` / `modelAsService` on |

### 3.2 Install Connectivity Link + Kuadrant

```bash
# Operator via OperatorHub / OLM (RH Connectivity Link). Then:
oc create namespace rh-connectivity-link --dry-run=client -o yaml | oc apply -f -

cat <<'EOF' | oc apply -f -
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: rh-connectivity-link
spec: {}
EOF

oc wait --for=condition=Ready kuadrant/kuadrant -n rh-connectivity-link --timeout=180s
oc get authorino,limitador -n rh-connectivity-link
```

### 3.3 Authorino TLS (required by MaaS)

MaaS validates API keys via HTTPS callbacks to `maas-api`. Authorino must
present a serving cert and trust the OpenShift service CA.

```bash
NS=rh-connectivity-link   # or kuadrant-system

oc annotate service authorino-authorino-authorization -n "$NS" \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite

oc patch authorino authorino -n "$NS" --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": { "name": "authorino-server-cert" }
      }
    }
  }
}'

oc -n "$NS" set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

### 3.4 Enable ModelsAsService on the DSC

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "kserve": {
        "modelsAsService": { "managementState": "Managed" }
      }
    }
  }
}'

# Watch until True (may first fail on missing gateway / DB / Authorino — see §6)
oc get datasciencecluster default-dsc -o json \
  | jq -r '.status.conditions[] | select(.type|test("ModelsAsService|^Ready$"))
           | "\(.type)=\(.status) \(.reason) \(.message)"'
```

> **Note:** On this RHOAI build, MaaS is nested under `spec.components.kserve.modelsAsService`,
> not a top-level `modelsasservice` / `aigateway` key. Confirm with:
> `oc explain datasciencecluster.spec.components.kserve --recursive`.

### 3.5 Postgres for maas-api

`maas-api` will not start without:

```text
Secret/maas-db-config  (namespace: redhat-ods-applications)
  └─ DB_CONNECTION_URL = postgresql://USER:PASS@HOST:5432/DB?sslmode=disable
```

POC (ephemeral) sketch:

```bash
INFRA_NS=maas-postgres
POSTGRES_IMAGE=$(oc get csv -l 'olm.copiedFrom=redhat-ods-operator' -A \
  -o jsonpath='{.items[0].spec.relatedImages[?(@.name=="postgresql_16_image")].image}')
# Deploy Postgres Deployment+Service in $INFRA_NS, then:

oc create secret generic maas-db-config -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL="postgresql://maas:PASSWORD@postgres.${INFRA_NS}.svc.cluster.local:5432/maas?sslmode=disable"
```

For production use RDS / Crunchy / Azure Database. Upstream helper:
`NAMESPACE=redhat-ods-applications ./scripts/setup-database.sh` from
[opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service).

### 3.6 MaaS Gateway in a dedicated namespace (recommended)

`maas-ui` auto-discovers `https://maas.<cluster-domain>/maas-api`. Put a real
Gateway behind that hostname. **Prefer a dedicated namespace** (`GATEWAY_NS`,
default `maas-gateway`) so you are not sharing `openshift-ingress` with other
gateways.

```bash
# config.env
export GATEWAY_NS="maas-gateway"
export GATEWAY_NAME="maas-default-gateway"
export GATEWAY_HOSTNAME=""                 # empty => maas.<cluster-domain>
export GATEWAY_CERT_SECRET="maas-gateway-tls"
export IPP_NS="$GATEWAY_NS"

# Tear down an old gateway (optional), then install
./scripts/05-gateway.sh delete
./scripts/05-gateway.sh install
./scripts/05-gateway.sh status

curl -sk "https://$(oc get gateway $GATEWAY_NAME -n $GATEWAY_NS \
  -o jsonpath='{.spec.listeners[0].hostname}')/maas-api/health"
```

What `05-gateway.sh install` does:

1. Creates Namespace `$GATEWAY_NS`
2. Ensures TLS Secret `$GATEWAY_CERT_SECRET` in that NS (copies from
   `openshift-ingress` when possible)
3. Applies GatewayClass + Gateway (`cluster/10-maas-default-gateway.yaml`)
4. Patches Tenant `gatewayRef` → `$GATEWAY_NS/$GATEWAY_NAME`
5. Applies IPP EnvoyFilter fix into `$GATEWAY_NS` (§3.7)

**Do not** use the dashboard / data-science gateway (`openshift-ai.*`) as the
MaaS gateway. Keep that separate.

### 3.7 IPP EnvoyFilter attach (auth before path rewrite)

The Tenant reconciler stamps `EnvoyFilter/payload-processing` (in `$IPP_NS`,
usually the same as `$GATEWAY_NS`) with a WasmPlugin anchor that often does not
exist. Kuadrant injects `envoy.filters.http.wasm` instead. A bad attach order
rewrites the path to `/v1/chat/completions` *before* Authorino → chat **401**.

```bash
./scripts/05-gateway.sh ipp
# equivalent: envsubst < cluster/ipp-envoyfilter-fix.yaml | oc apply -f -

# Confirm filter chain on the gateway pod:
GW_POD=$(oc get pods -n "$GATEWAY_NS" \
  -l gateway.networking.k8s.io/gateway-name="$GATEWAY_NAME" \
  -o jsonpath='{.items[0].metadata.name}')
oc exec -n "$GATEWAY_NS" "$GW_POD" -c istio-proxy -- \
  pilot-agent request GET config_dump \
  | python3 -c '
import sys,json
d=json.load(sys.stdin)
def walk(o):
  if isinstance(o,dict):
    if "http_filters" in o:
      names=[x.get("name") for x in o["http_filters"] if isinstance(x,dict)]
      if len(names)>2: print(*names, sep="\n")
    for v in o.values(): walk(v)
  elif isinstance(o,list):
    for v in o: walk(v)
walk(d)'
```

Expected fragment:

```text
envoy.filters.http.wasm
envoy.filters.http.wasm          # sometimes duplicated
envoy.filters.http.ext_proc.bbr
envoy.filters.http.router
```
### 3.8 Dashboard feature flags

```bash
oc get odhdashboardconfig -n redhat-ods-applications -o yaml \
  | grep -iE 'genAiStudio|modelAsService|maas|playground'

# Example patch (flag names vary by point release — read first):
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true}}}'
```

Confirm `maas-ui` discovered the right URL:

```bash
POD=$(oc get pods -n redhat-ods-applications -l app=rhods-dashboard \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
oc logs -n redhat-ods-applications "$POD" -c maas-ui --tail=30 \
  | grep -iE 'discovered MaaS URL|maas-api'
# expect: https://maas.apps.<domain>/maas-api
```

### 3.9 Optional: point `maas-ui` at a custom domain

By default `maas-ui` builds `https://maas.<cluster-domain>/maas-api`.
Override with env / flag **`MAAS_API_URL` / `-maas-api-url`** (does not need to
resolve for the override to be accepted — useful for custom-domain testing):

```bash
oc set env deploy/rhods-dashboard -n redhat-ods-applications -c maas-ui \
  MAAS_API_URL='https://maas.example.com/maas-api'
# Restore autodiscovery:
# oc set env deploy/rhods-dashboard -n redhat-ods-applications -c maas-ui MAAS_API_URL-
```

`GATEWAY_DOMAIN` on the same container is **not** the MaaS API URL (often the
data-science / rh-ai host).

> The dashboard operator may overwrite a manual `oc set env` on reconcile.
> For a lasting custom host, prefer a real Gateway listener hostname + DNS
> (§3.6) over a UI override.

### 3.10 Access policy subjects (playground visibility)

`groups` on `MaaSAuthPolicy` / `MaaSSubscription` are **objects** with `name`,
not bare strings. Restricting to `users: [admin]` only hides the model from
other authenticated dashboard users.

```yaml
subjects:
  users:
    - admin
  groups:
    - name: system:authenticated   # NOT - system:authenticated
```

This repo’s `native/30-maas-access.yaml` already includes that widen. To patch
a live policy:

```bash
oc patch maasauthpolicy <name> -n models-as-a-service --type=merge -p '{
  "spec":{"subjects":{"users":["admin"],"groups":[{"name":"system:authenticated"}]}}
}'
oc patch maassubscription <name> -n models-as-a-service --type=merge -p '{
  "spec":{"owner":{"users":["admin"],"groups":[{"name":"system:authenticated"}]}}
}'
```

---

## 4. Register an external model

### 4.1 Configure

```bash
cp config.env.example config.env
# Edit: PROVIDER_BASE_URL (…/v1), PROVIDER_MODEL_ID, PROVIDER_API_KEY
# GATEWAY_NS / GATEWAY_NAME must match Tenant gatewayRef (./scripts/05-gateway.sh install)
```

**Hard rules for `config.env`:**

- `PROVIDER_BASE_URL` must end in `/v1`.
- `PROVIDER_API_KEY` must be on its own line — **no trailing `# comments`**.
- `ExternalModel.spec.endpoint` is **FQDN only** (derived from the base URL by `10-apply.sh`).

### 4.2 Discover

```bash
./scripts/00-discover.sh | tee discover-output.txt
```

Check: ExternalModel CRD present, gateway Programmed, DSC ModelsAsServiceReady.

### 4.3 Apply

```bash
./scripts/10-apply.sh native
# or: ./scripts/10-apply.sh litellm
```

What `native` creates:

1. Namespace + gateway `allowedRoutes` allowlist for `$MAAS_NS`
2. Secret `${MODEL_NAME}-provider` with:
   - data key `api-key` (hyphen, not underscore)
   - labels `inference.llm-d.ai/ipp-managed=true` and
     `inference.networking.k8s.io/bbr-managed=true`
3. `ExternalModel` + `MaaSModelRef`
4. `MaaSAuthPolicy` + `MaaSSubscription` in `models-as-a-service`

### 4.4 Secret shape (critical)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-external-llm-provider
  namespace: maas-external-models
  labels:
    inference.llm-d.ai/ipp-managed: "true"
    inference.networking.k8s.io/bbr-managed: "true"   # some RHOAI builds
type: Opaque
stringData:
  api-key: "sk-...."    # MUST be this key name
```

---

## 5. Verify end-to-end

```bash
./scripts/20-verify.sh
```

### 5.1 Mint a MaaS API key

Chat completions require a `sk-oai-*` key (OpenShift tokens are only accepted for
some `/v1/models` paths).

```bash
export TOKEN=$(oc whoami -t)
. ./config.env
export GW_HOST=$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" \
  -o jsonpath='{.spec.listeners[0].hostname}')

export MAAS_KEY=$(curl -sk -X POST "https://$GW_HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"verify","subscription":"<MODEL_NAME>-access"}' | jq -r .key)
```

### 5.2 List models

```bash
curl -sk "https://$GW_HOST/v1/models" \
  -H "Authorization: Bearer $MAAS_KEY" | jq
# Expect: id=<MODEL_NAME>, kind=ExternalModel, ready=true
# url: https://maas.<domain>/<MAAS_NS>/<MODEL_NAME>
```

### 5.3 Chat (path-based — reliable)

```bash
curl -sk "https://$GW_HOST/<MAAS_NS>/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer $MAAS_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<MODEL_NAME>","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}' | jq
```

Endpoint is also on `MaaSModelRef.status.endpoint`.

> Canonical `POST /v1/chat/completions` (model in body) needs an initial
> catch-all HTTPRoute + IPP ClearRouteCache. Prefer path-based until that
> route exists on your gateway.

Authorino must see the **full** path prefix on chat (not rewritten
`/v1/chat/completions`). If you see the short path → IPP order is wrong (§3.7).

### 5.4 Direct provider sanity (bypass MaaS)

```bash
. ./config.env
curl -sS "$PROVIDER_BASE_URL/models" -H "Authorization: Bearer $PROVIDER_API_KEY"
curl -sS "$PROVIDER_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $PROVIDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"$PROVIDER_MODEL_ID"'","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

If this fails, fix the provider / egress before debugging MaaS.

### 5.5 Gen AI playground (after curl works)

Playground does **not** call MaaS chat the same way as curl. Flow:

1. UI → `rhods-dashboard` → `gen-ai-ui` → `POST …/gen-ai/api/v1/lsd/responses?namespace=<project>`
2. `LlamaStackDistribution/lsd-genai-playground` in that project
3. LSD → `https://maas.apps…/<ns>/<model>/v1` with `VLLM_API_TOKEN_1`

**Create playground** from Gen AI studio → AI asset endpoints → model ⋮ →
**Add to playground** / **Try in playground** (project = `$MAAS_NS`).

Then apply the playground fix (max tokens + real key + short model-id alias):

```bash
. ./config.env
# If your live subscription name differs (e.g. granite-admin-access):
# export SUBSCRIPTION=granite-admin-access
./cluster/lsd-playground-fix.sh
```

Manual equivalent (same as the script):

```bash
NS=maas-external-models
MODEL=<MODEL_NAME>
SUB=<MODEL_NAME>-access   # or your MaaSSubscription name
LSD=lsd-genai-playground
GW=maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# 1) Real MaaS key for LSD (UI token is NOT enough for remote::vllm)
KEY=$(curl -sk -X POST "https://$GW/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d "{\"name\":\"playground-lsd\",\"subscription\":\"$SUB\"}" | jq -r .key)
oc create secret generic lsd-maas-api-key -n "$NS" \
  --from-literal=api-key="$KEY" --dry-run=client -o yaml | oc apply -f -

# 2) Cap max output tokens (default 4096 == context → silent ContextWindowExceeded)
oc patch llamastackdistribution "$LSD" -n "$NS" --type=json -p '[
  {"op":"replace","path":"/spec/server/containerSpec/env","value":[
    {"name":"VLLM_TLS_VERIFY","value":"false"},
    {"name":"MILVUS_DB_PATH","value":"~/.llama/milvus.db"},
    {"name":"FMS_ORCHESTRATOR_URL","value":"http://localhost"},
    {"name":"VLLM_MAX_TOKENS","value":"512"},
    {"name":"VLLM_API_TOKEN_1","valueFrom":{"secretKeyRef":{"name":"lsd-maas-api-key","key":"api-key"}}},
    {"name":"LLAMA_STACK_CONFIG_DIR","value":"/opt/app-root/src/.llama/distributions/rh/"}
  ]}]'

# 3) Short model-id alias (UI sends MODEL, LSD registers maas-vllm-inference-1/MODEL)
oc apply -f cluster/lsd-model-alias-bootstrap.yaml   # edit model id if needed
oc patch deploy "$LSD" -n "$NS" --type=strategic -p "
spec:
  template:
    spec:
      volumes:
      - name: model-alias-bootstrap
        configMap: {name: lsd-model-alias-bootstrap}
      containers:
      - name: llama-stack
        env:
        - name: VLLM_MAX_TOKENS
          value: \"512\"
        - name: VLLM_API_TOKEN_1
          valueFrom: {secretKeyRef: {name: lsd-maas-api-key, key: api-key}}
        volumeMounts:
        - name: model-alias-bootstrap
          mountPath: /opt/alias
          readOnly: true
        lifecycle:
          postStart:
            exec:
              command: [\"/bin/sh\",\"-c\",\"python3 /opt/alias/bootstrap-alias.py > /tmp/alias.log 2>&1 || true\"]
"

oc rollout status deploy/"$LSD" -n "$NS" --timeout=180s
```

Smoke from inside the LSD pod (must use the **short** model id the UI uses):

```bash
POD=$(oc get pods -n "$NS" -o jsonpath='{.items[0].metadata.name}')
oc exec -n "$NS" "$POD" -- python3 -c "
import json,urllib.request
req=urllib.request.Request('http://127.0.0.1:8321/v1/responses',
  data=json.dumps({'model':'$MODEL','input':'Say hi','stream':False}).encode(),
  headers={'Content-Type':'application/json'}, method='POST')
print(urllib.request.urlopen(req, timeout=90).read().decode()[:500])
"
```

> The LlamaStack operator may reconcile the Deployment and drop env / lifecycle.
> Re-run `./cluster/lsd-playground-fix.sh` if playground breaks again after a
> controller sync. Also confirm `VLLM_API_TOKEN_1` is not still the literal
> string `fake` on the live pod.

---

## 6. Troubleshooting catalog

Each entry: **symptom → cause → fix**.

### 6.1 Platform / DSC

#### `ModelsAsServiceReady=False` reason `Removed`

| | |
|---|---|
| **Cause** | `kserve.modelsAsService.managementState` is `Removed` (default). |
| **Fix** | Patch DSC to `Managed` (§3.4). |

#### `ModelsAsServiceReady=False` `GatewayNotReady` / `maas-default-gateway not found`

| | |
|---|---|
| **Cause** | Tenant still points at a gateway that was never created. |
| **Fix** | Patch `Tenant/default-tenant` `gatewayRef` to the real Programmed gateway (§3.6). |

#### `PrerequisitesNotMet` — `maas-db-config` not found

| | |
|---|---|
| **Cause** | No Postgres connection Secret. |
| **Fix** | Create `maas-db-config` with `DB_CONNECTION_URL` (§3.5). Restart `maas-api` if it was already deployed. |

#### `PrerequisitesNotMet` — no Authorino instances / Authorino TLS

| | |
|---|---|
| **Cause** | Kuadrant not installed, or Authorino `listener.tls.enabled=false`. |
| **Fix** | Install Kuadrant (§3.2), enable Authorino TLS (§3.3). |

#### `KserveLLMInferenceServiceDependencies=False` Connectivity Link not installed

| | |
|---|---|
| **Cause** | RHCL / Kuadrant missing. |
| **Fix** | Install Red Hat Connectivity Link from OperatorHub, then Kuadrant CR. |

#### DSC Ready but `maas-api` missing / Tenant `phase: Failed`

| | |
|---|---|
| **Cause** | Prerequisites still failing; check Tenant status conditions. |
| **Fix** | `oc get tenant -n models-as-a-service -o yaml` and clear each `PrerequisitesMissing` message. |

```bash
oc logs -n redhat-ods-applications deploy/maas-controller --tail=100 \
  | grep -iE 'gateway|database|authorino|error'
```

---

### 6.2 CRD / manifest mistakes

#### `LLMInferenceService` rejected / unknown field `external`

| | |
|---|---|
| **Cause** | Using obsolete `native/20-llminferenceservice.yaml` shape. CRD has no external fields. |
| **Fix** | Use `ExternalModel` manifests (`native/20-externalmodel.yaml`). |

#### `ExternalModel` accepted but no HTTPRoute / ServiceEntry

| | |
|---|---|
| **Cause** | maas-controller not running or wrong API version. |
| **Fix** | `oc get deploy maas-controller -n redhat-ods-applications`; check controller logs for the ExternalModel name. |

#### HTTPRoute `Accepted=False` — namespace not allowed

| | |
|---|---|
| **Cause** | Gateway `allowedRoutes` selector does not include `$MAAS_NS`. |
| **Fix** | `10-apply.sh` patches this; or manually add the namespace to the gateway listener selector. |

```bash
oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" \
  -o jsonpath='{.spec.listeners[0].allowedRoutes}' | jq .
```

---

### 6.3 Auth / API keys

#### Chat returns `401 Authentication required`

| | |
|---|---|
| **Cause A** | Using OpenShift token on chat path. AuthPolicy only allows `Bearer sk-oai-*` for inference (k8s tokens often limited to `/v1/models`). |
| **Fix A** | Mint a MaaS API key (§5.1) and use that. |
| **Cause B** | IPP (`ext_proc.bbr`) runs *before* Kuadrant auth wasm and rewrites the path to `/v1/chat/completions`. Authorino then misses the `/maas-external-models/<model>` route rule. |
| **Fix B** | Apply `cluster/ipp-envoyfilter-fix.yaml` (`INSERT_BEFORE router`), clear product `payload-processing` patches, restart the gateway (§3.7). Confirm Authorino logs show the **full** path prefix on chat. |

#### Chat returns `403 Access denied`

| | |
|---|---|
| **Cause** | User/group not in `MaaSAuthPolicy.subjects`, or subscription owner mismatch. |
| **Fix** | Align subjects with the user who minted the key (e.g. `admin`, or `system:authenticated` groups). |

```bash
oc get maasauthpolicy,maassubscription -n models-as-a-service -o yaml \
  | grep -A20 'subjects:\|owner:'
```

#### Mint key fails / `404` on `/maas-api/v1/api-keys`

| | |
|---|---|
| **Cause** | Wrong path prefix, or maas-api HTTPRoute not Accepted. |
| **Fix** | Confirm `oc get httproute maas-api-route -n redhat-ods-applications` and use `/maas-api/v1/api-keys` (URLRewrite strips the prefix). |

#### Provider returns `401 Invalid proxy server token` / `Malformed API Key`

| | |
|---|---|
| **Cause A** | Secret value wrong — `# comment` appended on same `config.env` line. |
| **Cause B** | Secret key named `api_key` instead of `api-key`. |
| **Cause C** | IPP injected nothing; client MaaS key leaked upstream. |
| **Fix** | Recreate Secret from a clean key; label for IPP; confirm IPP injects (§6.4). |

```bash
# Length / prefix only — never print the key
oc get secret ${MODEL_NAME}-provider -n ${MAAS_NS} -o json | jq '{
  keys: (.data|keys),
  len: (.data["api-key"]|@base64d|length),
  starts_sk: (.data["api-key"]|@base64d|startswith("sk-"))
}'
```

---

### 6.4 IPP (payload-processing)

#### Path-based chat `404 {"detail":"Not Found"}` from `server: uvicorn`

| | |
|---|---|
| **Cause** | Request reached the provider **without** path rewrite. Full MaaS prefix was forwarded. IPP not in Envoy filter chain. |
| **Fix** | Apply `cluster/ipp-envoyfilter-fix.yaml` and restart gateway pods (§3.7). |

#### Chat `500` — `provider 'openai' credentials not found`

| | |
|---|---|
| **Cause** | IPP apikey-injection store empty — Secret missing `ipp-managed` / `bbr-managed` label, or wrong data key. |
| **Fix** | |

```bash
oc label secret ${MODEL_NAME}-provider -n ${MAAS_NS} \
  inference.llm-d.ai/ipp-managed=true \
  inference.networking.k8s.io/bbr-managed=true --overwrite

oc rollout restart deploy/payload-processing -n "${IPP_NS:-$GATEWAY_NS}"

# Confirm reconciler saw the secret:
oc logs -n "${IPP_NS:-$GATEWAY_NS}" deploy/payload-processing --tail=50 \
  | grep -i 'Reconciling Secret'
```

#### IPP logs show plugins, but EnvoyFilter keeps reverting

| | |
|---|---|
| **Cause** | Tenant reconciler overwrites `payload-processing` EnvoyFilter match. |
| **Fix** | Keep a **separate** EnvoyFilter (`payload-processing-attach-fix`) with `opendatahub.io/managed: "false"` so SSA leaves it alone. |

#### `ext_proc.bbr` missing from filter chain

```bash
# After gateway pod restart, dump filters — must include ext_proc.bbr
# AFTER all wasm filters (never between them).
```

| | |
|---|---|
| **Cause** | Product filter anchors on a non-existent WasmPlugin name. |
| **Fix** | `INSERT_BEFORE router` via `cluster/ipp-envoyfilter-fix.yaml` (§3.7); clear product `payload-processing` patches. |

#### Canonical `/v1/chat/completions` returns `404`

| | |
|---|---|
| **Cause** | No catch-all HTTPRoute for `/v1/chat/*`; IPP ClearRouteCache never gets an initial match. Path also mis-parsed as `namespace=v1,name=chat`. |
| **Fix** | Use path-based URL `/<ns>/<model>/v1/chat/completions` until a product catch-all route exists. |

#### Path-based `/v1/models` returns `404` but chat works

| | |
|---|---|
| **Cause** | OpenAI translator rewrites `:path` for chat; listing via model path is not always supported. |
| **Fix** | Use MaaS catalog `GET /v1/models` (or `/maas-api/v1/models`) instead. |

---

### 6.5 Gateway / networking

#### Gateway `Programmed=False`

| | |
|---|---|
| **Cause** | GatewayClass / Istio / cert issues. |
| **Fix** | `oc describe gateway -n $GATEWAY_NS $GATEWAY_NAME`; confirm TLS secret in `$GATEWAY_NS`. |

#### `SSL_ERROR_SYSCALL` / intermittent TLS from laptop

| | |
|---|---|
| **Cause** | Transient edge / LB issue, or wrong host. |
| **Fix** | Retry; confirm hostname from HTTPRoute / Gateway listener; try `curl -sk` and from an in-cluster debug pod. |

#### Egress timeout / connection refused to provider

| | |
|---|---|
| **Cause** | NetworkPolicy, proxy, private DNS, or missing ServiceEntry. |
| **Fix** | |

```bash
oc get serviceentry,destinationrule -n ${MAAS_NS}
oc run egress-test --rm -i --restart=Never -n ${MAAS_NS} \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sS -o /dev/null -w '%{http_code}\n' "${PROVIDER_BASE_URL}/models"
```

#### Custom / private CA

| | |
|---|---|
| **Cause** | Provider TLS not trusted by Istio / IPP. |
| **Fix** | Set `PROVIDER_CA_BUNDLE_FILE` and create the CA ConfigMap; may need DestinationRule `caCertificates` depending on discovery. |

---

### 6.6 Dashboard / Gen AI studio / playground

#### Model missing from MaaS catalog UI

| | |
|---|---|
| **Cause A** | `maas-ui` discovers `https://maas.apps…/maas-api` but that host 503s / does not exist. |
| **Fix A** | Create `maas-default-gateway` with that hostname (§3.6); restart dashboard. |
| **Cause B** | Access subjects too narrow (`users: [admin]` only). |
| **Fix B** | Add `groups: [{name: system:authenticated}]` (§3.10). |
| **Cause C** | Feature flags off / MaaSModelRef not Ready. |
| **Fix C** | §3.8; `oc get maasmodelref -n ${MAAS_NS}`. |

#### `maas-ui` calling stale / wrong hostname

| | |
|---|---|
| **Cause** | Autodiscovery vs custom override; or gateway hostname changed. |
| **Fix** | Check logs for `Using automatically discovered MaaS URL`; optional `MAAS_API_URL` (§3.9); restart `rhods-dashboard`. |

#### Playground: no answer, no error (“thinking” forever)

| | |
|---|---|
| **Cause A** | `VLLM_MAX_TOKENS` equals model context (4096/4096) → `ContextWindowExceeded` in LSD logs; UI swallows the stream error. |
| **Fix A** | Set `VLLM_MAX_TOKENS=512` (or similar) on LSD (§5.5). |
| **Cause B** | `VLLM_API_TOKEN_1=fake` — LSD never authenticates to MaaS. |
| **Fix B** | Secret `lsd-maas-api-key` + wire into Deployment env (§5.5). |
| **Cause C** | UI sends short model id; LSD only has `maas-vllm-inference-1/<model>`. |
| **Fix C** | Short-id alias ConfigMap + postStart (`cluster/lsd-model-alias-bootstrap.yaml` / §5.5). |

```bash
# Confirm in LSD logs:
oc logs -n ${MAAS_NS} deploy/lsd-genai-playground --tail=80 \
  | grep -iE 'ContextWindow|401|Model .* not found|Provider SDK'
```

#### Playground works via curl MaaS but LSD `/v1/models` refresh 404s

| | |
|---|---|
| **Cause** | Path-based `…/<model>/v1/models` often 404 for ExternalModel; LSD `list_provider_model_ids` fails and skips refresh. |
| **Fix** | Harmless if `registered_resources.models` in `llama-stack-config` lists the LLM; ensure short-id alias still exists after restart. |

---

### 6.7 Symptom → section map

| HTTP / symptom | Jump to |
|---|---|
| DSC `ModelsAsServiceReady=False` | [§6.1](#61-platform--dsc) |
| CRD unknown field `external` | [§6.2](#62-crd--manifest-mistakes) |
| `401` on chat | [§6.3](#63-auth--api-keys) |
| `403` on chat | [§6.3](#63-auth--api-keys) |
| Provider `401` / malformed key | [§6.3](#63-auth--api-keys) |
| Path chat `404` uvicorn | [§6.4](#64-ipp-payload-processing) |
| `500` credentials not found | [§6.4](#64-ipp-payload-processing) |
| Canonical `/v1/chat` `404` | [§6.4](#64-ipp-payload-processing) |
| Gateway not Programmed | [§6.5](#65-gateway--networking) |
| Egress fail | [§6.5](#65-gateway--networking) |
| Not in dashboard / empty MaaS tab | [§6.6](#66-dashboard--gen-ai-studio--playground) |
| Playground silent / no answer | [§6.6](#66-dashboard--gen-ai-studio--playground) / [§5.5](#55-gen-ai-playground-after-curl-works) |
| SSL_ERROR_SYSCALL | [§6.5](#65-gateway--networking) |

---

## 7. Quick diagnostic commands

```bash
# --- Platform ---
oc get datasciencecluster default-dsc -o json \
  | jq -r '.status.conditions[] | select(.type|test("ModelsAsService|KserveLLM"))
           | "\(.type)=\(.status) \(.reason) \(.message)"'
oc get tenant -n models-as-a-service -o wide
oc get pods -n redhat-ods-applications | grep -iE 'maas|payload'
oc get authorino,limitador,kuadrant -A

# --- Model ---
oc get externalmodel,maasmodelref,httproute,serviceentry,destinationrule -n ${MAAS_NS:-maas-external-models}
oc get maasauthpolicy,maassubscription -n models-as-a-service
oc get secret ${MODEL_NAME}-provider -n ${MAAS_NS} --show-labels

# --- IPP ---
oc logs -n "${IPP_NS:-$GATEWAY_NS}" deploy/payload-processing --tail=80 \
  | grep -iE 'Executing request plugin|credentials|Reconciling Secret|error'
oc get envoyfilter -n "$GATEWAY_NS" | grep payload
./scripts/05-gateway.sh status

# --- Auth path ---
oc get authpolicy -A
oc logs -n rh-connectivity-link deploy/authorino --tail=50

# --- Bundle script ---
./scripts/90-troubleshoot.sh
```

### Debug flow (short)

```mermaid
flowchart TD
  S["Failure"] --> A{"Provider direct curl OK?"}
  A -->|No| P["Fix provider / network / API key"]
  A -->|Yes| B{"MaaSModelRef Ready + /v1/models lists model?"}
  B -->|No| C["Platform: DSC, Tenant, maas-api, AuthPolicy"]
  B -->|Yes| D{"Path chat 401?"}
  D -->|Yes| E["Mint sk-oai key; IPP before auth? §3.7"]
  D -->|No| F{"Path chat 404 uvicorn?"}
  F -->|Yes| G["IPP EnvoyFilter attach §3.7"]
  F -->|No| H{"500 credentials not found?"}
  H -->|Yes| I["Label Secret ipp/bbr-managed; restart IPP"]
  H -->|No| K{"Playground silent?"}
  K -->|Yes| L["§5.5 lsd-playground-fix.sh"]
  K -->|No| J["90-troubleshoot.sh + controller logs"]
```

---

## 8. Glossary

| Term | Meaning |
|---|---|
| **MaaS** | Models-as-a-Service — governance layer (keys, tiers, rate limits) in front of LLMs |
| **ExternalModel** | CRD for an off-cluster OpenAI-compatible (or translated) provider |
| **MaaSModelRef** | Catalog registration + Ready status / public endpoint |
| **IPP** | Inference Payload Processor (`payload-processing`) — Envoy ext_proc that rewrites paths and injects provider keys |
| **Authorino** | Kuadrant auth service evaluating AuthPolicies |
| **Limitador** | Kuadrant rate-limit service for TokenRateLimitPolicy |
| **RHCL** | Red Hat Connectivity Link (productized Kuadrant stack) |
| **Tenant** | MaaS platform CR that deploys maas-api / IPP / gateway policies for a gateway |
| **sk-oai-*** | MaaS-issued API key prefix used for inference auth |
| **LSD** | `LlamaStackDistribution` — Gen AI playground backend that proxies to MaaS |
| **maas-default-gateway** | Preferred Gateway name; lives in `$GATEWAY_NS` (default `maas-gateway`) |
| **GATEWAY_NS** | Namespace for the MaaS Gateway + IPP EnvoyFilters (not the dashboard gateway) |
---

## 9. Full manual reproduction checklist

Ordered steps to recreate everything on a fresh cluster (or after wipe).
Replace `REPLACE_ME` / placeholders with your values.

### A. Platform

- [ ] RH Connectivity Link + `Kuadrant` (Authorino TLS on)
- [ ] DSC `kserve.modelsAsService.managementState: Managed`
- [ ] Postgres + Secret `maas-db-config` (`DB_CONNECTION_URL`) in `redhat-ods-applications`
- [ ] `cp config.env.example config.env` — set `GATEWAY_NS=maas-gateway` (or your NS), provider `/v1`, key with **no** inline `#`
- [ ] `./scripts/00-discover.sh`
- [ ] Optional: delete old gateways → `./scripts/05-gateway.sh delete` (per old `GATEWAY_NS`)
- [ ] `./scripts/05-gateway.sh install` (§3.6) — NS + Gateway + Tenant `gatewayRef` + IPP
- [ ] `./scripts/05-gateway.sh status` — Programmed=True; health 200
- [ ] Filter chain: `wasm` → (`wasm`) → `ext_proc.bbr` → `router` (IPP **after** auth)
- [ ] Dashboard flags: `genAiStudio: true`, `modelAsService: true`
- [ ] `maas-ui` log: discovered `https://maas.<domain>/maas-api` (matches Gateway hostname)

### B. Register model

- [ ] `./scripts/10-apply.sh native`
- [ ] Secret labels `ipp-managed` + `bbr-managed`, data key `api-key`
- [ ] `MaaSAuthPolicy` / `MaaSSubscription` include `groups: [{name: system:authenticated}]` (§3.10)
- [ ] `MaaSModelRef` Ready; HTTPRoute parent = `maas-default-gateway`

### C. Curl verify

```bash
. ./config.env
export GW=$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].hostname}')
export TOKEN=$(oc whoami -t)
export MAAS_KEY=$(curl -sk -X POST "https://$GW/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"verify","subscription":"'"$MODEL_NAME"'-access"}' | jq -r .key)
curl -sk "https://$GW/v1/models" -H "Authorization: Bearer $MAAS_KEY" | jq
curl -sk "https://$GW/$MAAS_NS/$MODEL_NAME/v1/chat/completions" \
  -H "Authorization: Bearer $MAAS_KEY" -H "Content-Type: application/json" \
  -d '{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' | jq
```

- [ ] `/v1/models` lists model Ready
- [ ] Path chat HTTP 200
- [ ] Authorino log path on chat includes `/<MAAS_NS>/<MODEL>/…` (not bare `/v1/chat/completions`)

### D. Dashboard + playground

- [ ] Gen AI studio → AI asset endpoints → Models as a service shows the model
- [ ] Add / Try in playground (project = model namespace)
- [ ] `. ./config.env` then `./cluster/lsd-playground-fix.sh` (or manual §5.5)
- [ ] LSD pod: `VLLM_MAX_TOKENS=512`, `VLLM_API_TOKEN_1` starts with `sk-oai-`
- [ ] `/tmp/alias.log` contains `registered short model alias …`
- [ ] In-pod short-id `/v1/responses` returns `status: completed`
- [ ] UI playground returns a reply

### E. Optional custom UI URL

- [ ] `oc set env … -c maas-ui MAAS_API_URL='https://maas.example.com/maas-api'` (§3.9)
- [ ] Restore with `MAAS_API_URL-` when done

### F. If operator fights you

| Resource | Who overwrites | Mitigation |
|---|---|---|
| `EnvoyFilter/payload-processing` | Tenant / maas-controller | `./scripts/05-gateway.sh ipp` (attach-fix + clear product patches) |
| LSD Deployment env / lifecycle | LlamaStack operator | Re-run `cluster/lsd-playground-fix.sh` |
| `oc set env` on `rhods-dashboard` | Dashboard operator | Prefer Gateway hostname over `MAAS_API_URL` |
| Old gateways in `openshift-ingress` | You (manual) | `GATEWAY_NS=openshift-ingress ./scripts/05-gateway.sh delete` then install into `maas-gateway` |

---

## References

- This repo: [README.md](./README.md), [scripts/05-gateway.sh](./scripts/05-gateway.sh), [cluster/ipp-envoyfilter-fix.yaml](./cluster/ipp-envoyfilter-fix.yaml), [cluster/lsd-playground-fix.sh](./cluster/lsd-playground-fix.sh), [cluster/lsd-model-alias-bootstrap.yaml](./cluster/lsd-model-alias-bootstrap.yaml)
- [ODH External Model Setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/external-model-setup.md)
- [ODH MaaS install](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md)
- [RHOAI MaaS docs (3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [Experimenting with models in the gen AI playground (3.4)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/experimenting_with_models_in_the_gen_ai_playground/index)
- [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide)
