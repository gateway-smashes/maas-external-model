# External LLM via MaaS on OpenShift AI 3.4

Registers an external OpenAI-compatible LLM with Models-as-a-Service so it appears
in the OpenShift AI dashboard and is usable from the Gen AI studio playground.

Target: RHOAI 3.4.x self-managed. MaaS Gateway lives in a **dedicated namespace**
(`GATEWAY_NS`, default `maas-gateway`) — not `openshift-ingress`.

## Read before installing

This install touches the platform gateway, Authorino policy and cluster RBAC.
Skimming these two first will save you hours — most failure modes here surface
**only in a server-side log**, never to the caller.

| Doc | Read it for | Read when |
|---|---|---|
| **[UNDERSTANDING_OAI.md](./UNDERSTANDING_OAI.md)** | What RHOAI runs, which of the dashboard's 9 containers logs what, and why operator-owned objects revert your edits | Before touching anything |
| **[UNDERSTANDING_MAAS.md](./UNDERSTANDING_MAAS.md)** | MaaS components, the full request hop chain, a failure catalogue keyed by error string, and known product gaps | Before installing, and whenever a request fails |
| [CONFIGURING_MAAS.md](./CONFIGURING_MAAS.md) | Step-by-step bring-up and the manual reproduction checklist (§9) | While installing |

Two facts worth knowing up front: an external model adds **zero pods** (it is
routing metadata, not workload), and several MaaS objects are **operator-owned** —
patch them and they revert on the next reconcile.

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

Important settings in `config.env`:

```bash
export CUSTOM_DOMAIN="ai.example.com"   # no *.apps DNS
export ROUTE_LABELS="your-router-label=value"         # required on Routes

export GATEWAY_NS="maas-gateway"              # MaaS only (NOT dashboard)
export GATEWAY_NAME="maas-default-gateway"
export GATEWAY_HOSTNAME=""                    # empty => maas.${CUSTOM_DOMAIN}
export GATEWAY_CERT_SECRET="maas-gateway-tls"
export IPP_NS="$GATEWAY_NS"
```

**Two hosts, two Gateways:**

| URL | Purpose | Object |
|---|---|---|
| `https://openshift-ai.${CUSTOM_DOMAIN}` | OpenShift AI dashboard | `data-science-gateway` (RHOAI — leave alone) |
| `https://maas.${CUSTOM_DOMAIN}` | MaaS API + chat | `maas-default-gateway` (this repo) |

`data-science-gateway` is the **dashboard** Gateway name, not the MaaS hostname.

### 2. Discover

Run this **first on any cluster you do not know**. It assumes nothing (no
`config.env`, no prior install), collects a redacted evidence bundle, and prints
PASS / WARN / FAIL per check with a fix command. Exits non-zero if anything is
blocking.

```bash
./scripts/00-discover.sh
```

```bash
./scripts/00-discover.sh -n my-models --gateway-probe --egress --insecure
```

It writes `diag-<cluster>-<stamp>/` containing:

| file | contents |
|---|---|
| `report.md` | findings + ordered list of blocking problems |
| `findings.tsv` | machine-readable `severity / id / section / message / fix` |
| `config.env.discovered` | `MAAS_NS`, gateway, tenant, domain observed on the cluster |
| `raw/` | every dump (CRD schemas, conditions, logs, events) |
| `…​.tgz` | the whole bundle, secrets redacted — safe to share |

Point it at the namespace you intend to use even if it does not exist yet — a
missing namespace is reported as a clean slate, not an error.

### 3. Install / replace the MaaS gateway

```bash
# Set ROUTE_LABELS to the real cluster label first (not changeme=true)
./scripts/05-gateway.sh delete       # only maas-default-gateway (+ Route)
./scripts/05-gateway.sh install      # NS + Gateway + Route + Tenant + IPP
./scripts/05-gateway.sh status

# Point DNS: maas.${CUSTOM_DOMAIN} → cluster router / LB
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

Creates the LlamaStackDistribution, its Postgres backend and the model-discovery
shim — no clicking through Gen AI studio required. See
[UNDERSTANDING_MAAS.md §7](./UNDERSTANDING_MAAS.md) for why each piece exists.

```bash
./scripts/15-playground.sh
```

### 8. Troubleshoot

```bash
./scripts/90-troubleshoot.sh
./scripts/05-gateway.sh ipp          # re-apply IPP filter order only
```

---

## Layout

```
UNDERSTANDING_OAI.md               platform components + troubleshooting map
UNDERSTANDING_MAAS.md              MaaS components, hop chain, failure catalogue
CONFIGURING_MAAS.md                step-by-step bring-up (§9 = checklist)
config.env.example                 GATEWAY_NS / GATEWAY_NAME / cert / allowed NS

scripts/00-discover.sh             blind-cluster diagnostic bundle (run first)
scripts/05-gateway.sh              install | delete | reinstall | ipp | status
scripts/06-gateway-rename.sh       move the Gateway to another name/namespace
scripts/07-tenant.sh               bind MaaS to a Gateway (Tenant.gatewayRef)
scripts/10-apply.sh                render + apply native/ (or litellm)
scripts/15-playground.sh           Postgres + shim + LlamaStackDistribution
scripts/20-verify.sh
scripts/90-troubleshoot.sh
scripts/99-reinstall.sh            destructive rebuild, preserves the provider key

native/                            ExternalModel + MaaSModelRef + access policy
native/40-genai-dashboard-configmaps.yaml   ConfigMaps gen-ai-ui expects
playground/                        LSD + its Postgres + model-discovery shim
litellm-fallback/                  shim path when ExternalModel/IPP unavailable

cluster/00-gateway-namespace.yaml
cluster/10-maas-default-gateway.yaml
cluster/20-maas-gateway-route.yaml
cluster/30-maas-tenant.yaml        Tenant -> gatewayRef
cluster/40-dashboard-maas-rbac.yaml  binds dashboard SA to maas-viewer-role
cluster/ipp-envoyfilter-fix.yaml   rendered into GATEWAY_NS

cluster/lsd-playground-fix.sh          DEPRECATED — writes a sqlite kvstore alias;
cluster/lsd-model-alias-bootstrap.yaml DEPRECATED — does not apply to Postgres-backed
                                       distributions. Use scripts/15-playground.sh.
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
