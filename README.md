# External LLM via MaaS on OpenShift AI 3.4

Registers an external OpenAI-compatible LLM with Models-as-a-Service so it appears
in the OpenShift AI dashboard and is usable from the Gen AI studio playground.

Target: RHOAI 3.4.2 self-managed, OCP 4.20, gateway **`maas-default-gateway`**
(`maas.apps.<domain>`).

For full platform bring-up, diagrams, playground fixes, and a
**manual reproduction checklist**, see **[CONFIGURING_MAAS.md](./CONFIGURING_MAAS.md)**
(especially [§9](./CONFIGURING_MAAS.md#9-full-manual-reproduction-checklist)).

---

## Read this first

On RHOAI 3.4.2 the **native** path is the `ExternalModel` CRD (`maas.opendatahub.io`),
not `LLMInferenceService.spec.external` (that field does not exist on the CRD).

| Path | What it is | When to use |
|---|---|---|
| `native/` | `ExternalModel` + `MaaSModelRef` + MaaS auth/subscription | Default on RHOAI 3.4+ with MaaS enabled |
| `litellm-fallback/` | LiteLLM in-cluster shim registered as a normal backend | If ExternalModel / IPP is unavailable |

---

## Prerequisites (cluster)

1. **Red Hat Connectivity Link** installed and a `Kuadrant` instance ready (Authorino + Limitador with TLS).
2. **MaaS enabled** on the DataScienceCluster:
   ```bash
   oc patch datasciencecluster default-dsc --type=merge \
     -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Managed"}}}}}'
   ```
3. **Postgres** for maas-api: Secret `maas-db-config` in `redhat-ods-applications` with key `DB_CONNECTION_URL`.
4. **Tenant gatewayRef** on a Programmed `maas-default-gateway` with hostname `maas.apps.<domain>` (needed for `maas-ui` discovery). See [CONFIGURING_MAAS.md](./CONFIGURING_MAAS.md) §3.6.
5. **IPP EnvoyFilter fix** so payload-processing runs *after* Kuadrant auth wasm (`INSERT_BEFORE router`):
   ```bash
   oc apply -f cluster/ipp-envoyfilter-fix.yaml
   oc annotate envoyfilter payload-processing -n openshift-ingress opendatahub.io/managed=false --overwrite
   oc patch envoyfilter payload-processing -n openshift-ingress --type=json \
     -p='[{"op":"replace","path":"/spec/configPatches","value":[]}]'
   oc delete pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
   ```

---

## Steps

### 1. Configure

```bash
cd maas-external-model
cp config.env.example config.env
$EDITOR config.env      # base URL (must end in /v1), model id, API key
# GATEWAY_NAME=maas-default-gateway
```

### 2. Discover

```bash
./scripts/00-discover.sh | tee discover-output.txt
```

Confirm `ExternalModel` exists (`oc api-resources | grep externalmodel`) and the gateway is `Programmed=True`.

### 3. Apply

```bash
./scripts/10-apply.sh native      # or: ./scripts/10-apply.sh litellm
```

Creates the namespace, IPP-labeled provider Secret (`api-key`), ExternalModel,
MaaSModelRef, and MaaSAuthPolicy/MaaSSubscription (includes
`groups: [{name: system:authenticated}]` so non-admin users can see/call the model).

### 4. Dashboard flags

```bash
oc get odhdashboardconfig -n redhat-ods-applications -o yaml | grep -iE 'maas|genai|modelAsService'
# genAiStudio: true and modelAsService: true (or equivalent) must be on
```

### 5. Verify (curl)

```bash
./scripts/20-verify.sh
```

```bash
export TOKEN=$(oc whoami -t)
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export GW_HOST=maas.${CLUSTER_DOMAIN}

export MAAS_KEY=$(curl -sk -X POST "https://$GW_HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"verify","subscription":"<MODEL_NAME>-access"}' | jq -r .key)

curl -sk "https://$GW_HOST/v1/models" -H "Authorization: Bearer $MAAS_KEY" | jq

curl -sk "https://$GW_HOST/<MAAS_NS>/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer $MAAS_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<MODEL_NAME>","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}' | jq
```

### 6. Playground

After the model appears under **Gen AI studio → AI asset endpoints → Models as a service**,
add it to the playground, then:

```bash
. ./config.env
# export SUBSCRIPTION=granite-admin-access   # if your subscription name differs
./cluster/lsd-playground-fix.sh
```

That sets `VLLM_MAX_TOKENS=512`, wires a real `sk-oai-*` key into LSD, and
registers a short model-id alias (UI sends `<MODEL>`, LSD registers
`maas-vllm-inference-1/<MODEL>`). Details: [CONFIGURING_MAAS.md §5.5](./CONFIGURING_MAAS.md#55-gen-ai-playground-after-curl-works).

### 7. If something breaks

```bash
./scripts/90-troubleshoot.sh
```

---

## Layout

```
config.env.example
scripts/00-discover.sh
scripts/10-apply.sh
scripts/20-verify.sh
scripts/90-troubleshoot.sh
native/                          ExternalModel + MaaSModelRef + access policy
litellm-fallback/                LiteLLM shim + LLMInferenceService
cluster/ipp-envoyfilter-fix.yaml
cluster/lsd-model-alias-bootstrap.yaml
cluster/lsd-playground-fix.sh
CONFIGURING_MAAS.md              Full bring-up + troubleshooting + checklist §9
```

---

## Gotchas

- **Gateway for UI.** Prefer `maas-default-gateway` / `maas.apps.<domain>`. Curl against
  `inference-gateway` can work while the dashboard catalog stays empty.
- **Secret shape.** Key must be `api-key` (hyphen). Labels required:
  `inference.llm-d.ai/ipp-managed=true` (and on some builds also
  `inference.networking.k8s.io/bbr-managed=true`).
- **PROVIDER_API_KEY line.** Do not put `# comments` on the same line as the key.
- **Endpoint field.** `ExternalModel.spec.endpoint` is FQDN only (no `https://`, no `/v1`).
- **IPP after auth.** Filter chain must be `wasm` → `ext_proc.bbr` → `router`. IPP
  between wasm filters rewrites the path before Authorino → chat **401**.
- **Access groups.** `groups: [{name: system:authenticated}]` (objects, not strings).
- **Playground ≠ curl.** Needs LSD max-tokens + real MaaS key + short model-id alias
  (`./cluster/lsd-playground-fix.sh`). Operator may undo Deployment patches — re-run.
- **Custom maas-ui URL.** `MAAS_API_URL` / `-maas-api-url` overrides autodiscovery
  (see CONFIGURING_MAAS §3.9). `GATEWAY_DOMAIN` on the container is unrelated.
- **Egress.** The cluster must reach `$PROVIDER_BASE_URL`.

## References

- [CONFIGURING_MAAS.md](./CONFIGURING_MAAS.md) — checklist §9
- [Deploy and manage Models-as-a-Service — RHOAI 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [External Model Setup (ODH)](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/external-model-setup.md)
- [rh-aiservices-bu/rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide)
