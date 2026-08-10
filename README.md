# External LLM via MaaS on OpenShift AI 3.4

Registers an external OpenAI-compatible LLM with Models-as-a-Service so it appears
in the OpenShift AI dashboard and is usable from the Gen AI studio playground.

Target: RHOAI 3.4.x self-managed. MaaS Gateway lives in a **dedicated namespace**
(`GATEWAY_NS`, default `maas-gateway`) — not `openshift-ingress`.

For full bring-up, playground fixes, and a checklist, see
**[CONFIGURING_MAAS.md](./CONFIGURING_MAAS.md)** (§9).

---

## Read this first

On RHOAI 3.4.x the **native** path is the `ExternalModel` CRD (`maas.opendatahub.io`),
not `LLMInferenceService.spec.external` (that field does not exist on the CRD).

| Path | What it is | When to use |
|---|---|---|
| `native/` | `ExternalModel` + `MaaSModelRef` + MaaS auth/subscription | Default on RHOAI 3.4+ with MaaS enabled |
| `litellm-fallback/` | LiteLLM in-cluster shim registered as a normal backend | If ExternalModel / IPP is unavailable |

---

## Prerequisites (cluster)

1. **Red Hat Connectivity Link** + `Kuadrant` (Authorino TLS on).
2. **MaaS enabled** on the DataScienceCluster:
   ```bash
   oc patch datasciencecluster default-dsc --type=merge \
     -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Managed"}}}}}'
   ```
3. **Postgres** Secret `maas-db-config` in `redhat-ods-applications` (`DB_CONNECTION_URL`).
4. **MaaS Gateway** in your chosen namespace (see below).

---

## Steps

### 1. Configure

```bash
cd maas-external-model
cp config.env.example config.env
$EDITOR config.env
```

Important gateway settings in `config.env`:

```bash
export GATEWAY_NS="maas-gateway"              # dedicated NS (recommended)
export GATEWAY_NAME="maas-default-gateway"
export GATEWAY_HOSTNAME=""                    # empty => maas.<cluster-domain>
export GATEWAY_CERT_SECRET="maas-gateway-tls"
export IPP_NS="$GATEWAY_NS"                   # where payload-processing runs
```

### 2. Discover

```bash
./scripts/00-discover.sh | tee discover-output.txt
```

### 3. Install / replace the MaaS gateway

Deletes are optional; `reinstall` tears down this gateway then creates it again.

```bash
./scripts/05-gateway.sh delete       # remove previous GATEWAY_NS/GATEWAY_NAME
# DELETE_GATEWAY_NS=true ./scripts/05-gateway.sh delete   # also drop the namespace

./scripts/05-gateway.sh install      # NS + Gateway + Tenant gatewayRef + IPP fix
./scripts/05-gateway.sh status
```

### 4. Apply the external model

```bash
./scripts/10-apply.sh native         # or: litellm
```

### 5. Dashboard flags

```bash
oc get odhdashboardconfig -n redhat-ods-applications -o yaml | grep -iE 'maas|genai|modelAsService'
# need genAiStudio: true and modelAsService: true
```

### 6. Verify (curl)

```bash
./scripts/20-verify.sh

export TOKEN=$(oc whoami -t)
export GW_HOST=$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" -o jsonpath='{.spec.listeners[0].hostname}')
export MAAS_KEY=$(curl -sk -X POST "https://$GW_HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"verify","subscription":"'"$MODEL_NAME"'-access"}' | jq -r .key)

curl -sk "https://$GW_HOST/v1/models" -H "Authorization: Bearer $MAAS_KEY" | jq
curl -sk "https://$GW_HOST/$MAAS_NS/$MODEL_NAME/v1/chat/completions" \
  -H "Authorization: Bearer $MAAS_KEY" -H "Content-Type: application/json" \
  -d '{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"say hi"}],"max_tokens":8}' | jq
```

### 7. Playground

```bash
./cluster/lsd-playground-fix.sh
```

### 8. Troubleshoot

```bash
./scripts/90-troubleshoot.sh
./scripts/05-gateway.sh ipp          # re-apply IPP filter order only
```

---

## Layout

```
config.env.example                 GATEWAY_NS / GATEWAY_NAME / cert / allowed NS
scripts/00-discover.sh
scripts/05-gateway.sh              install | delete | reinstall | ipp | status
scripts/10-apply.sh
scripts/20-verify.sh
scripts/90-troubleshoot.sh
native/                            ExternalModel + access policy
litellm-fallback/
cluster/00-gateway-namespace.yaml
cluster/10-maas-default-gateway.yaml
cluster/ipp-envoyfilter-fix.yaml   rendered into GATEWAY_NS
cluster/lsd-playground-fix.sh
cluster/lsd-model-alias-bootstrap.yaml
CONFIGURING_MAAS.md
```

---

## Gotchas

- **Dedicated gateway NS.** Prefer `GATEWAY_NS=maas-gateway`. Do not confuse with the
  dashboard / `data-science-gateway` / `openshift-ai.*` host.
- **Tenant must match.** `05-gateway.sh install` patches
  `Tenant/default-tenant.spec.gatewayRef` to `$GATEWAY_NS/$GATEWAY_NAME`.
- **TLS Secret** must exist in `GATEWAY_NS` (script can copy from `openshift-ingress`).
- **IPP after auth.** `./scripts/05-gateway.sh ipp` — filter chain
  `wasm` → `ext_proc.bbr` → `router`.
- **Secret shape.** Provider Secret key `api-key`; labels `ipp-managed` + `bbr-managed`.
- **Access groups.** `groups: [{name: system:authenticated}]` (objects, not strings).
- **Playground ≠ curl.** Run `cluster/lsd-playground-fix.sh` after Add to playground.

## References

- [CONFIGURING_MAAS.md](./CONFIGURING_MAAS.md)
- [ODH External Model Setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/external-model-setup.md)
