# External LLM via MaaS on OpenShift AI 3.4

Registers an external OpenAI-compatible LLM with Models-as-a-Service so it appears
in the OpenShift AI dashboard and is usable from the Gen AI studio playground.

Target: RHOAI 3.4.2 self-managed, OCP 4.20, gateway `data-science-gateway`.

---

## Read this first

**External models are Technology Preview in RHOAI 3.4** and the `LLMInferenceService`
external field names are not fully documented publicly. So this folder ships two paths:

| Path | What it is | Risk |
|---|---|---|
| `native/` | The product's own external-model support | Field names must be verified against your CRD |
| `litellm-fallback/` | LiteLLM in-cluster as a provider shim, registered to MaaS as a normal backend | Well-documented, one extra Deployment |

Run discovery first. If your CRD has the external fields, use `native`. If not, use `litellm`.

---

## Steps

### 1. Configure

```bash
cd maas-external-model
cp config.env.example config.env
$EDITOR config.env      # base URL (must end in /v1), model id, API key
```

### 2. Discover what your cluster actually supports

```bash
./scripts/00-discover.sh | tee discover-output.txt
```

Check section **B** — if `oc explain llminferenceservice.spec --recursive` shows
external/url/apiKey fields, native works. If it shows nothing external, use litellm.

Section **F** matters too: the playground needs MaaS and Gen AI studio enabled in
`OdhDashboardConfig` (step 4 below).

### 3. Apply

```bash
./scripts/10-apply.sh native      # or: ./scripts/10-apply.sh litellm
```

Creates the namespace, the provider credential Secret, the model object, and one
tier-access Role/RoleBinding per tier in `$TIERS`.

### 4. Make it visible in the dashboard

The playground lives under **Gen AI studio → AI asset endpoints → Models as a service**,
and both the MaaS feature and the Gen AI studio menu item must be enabled:

```bash
oc get odhdashboardconfig -n redhat-ods-applications -o yaml | grep -iE 'maas|genai|playground'
# then, with the exact flag names your build uses:
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"disableMaaS":false,"disableGenAiStudio":false}}}'
oc rollout restart deploy/rhods-dashboard -n redhat-ods-applications
```

Flag names vary across 3.x point releases — read them from the `grep` output rather
than pasting the patch blind.

### 5. Grant yourself a tier and an API key

Tiers map OpenShift groups → access levels via the `tier-to-group-mapping` ConfigMap
in `redhat-ods-applications`. `free` defaults to `system:authenticated`, so you should
already qualify. Generate a key in the dashboard, then:

### 6. Verify

```bash
./scripts/20-verify.sh
```

Then the two curls it prints — `/v1/models` should list your model, and
`/v1/chat/completions` should return a completion.

### 7. If something breaks

```bash
./scripts/90-troubleshoot.sh
```

---

## Layout

```
config.env.example          all tunables in one place
scripts/00-discover.sh      dump real CRD schemas + platform state
scripts/10-apply.sh         render (envsubst) + apply
scripts/20-verify.sh        status, HTTPRoute, inference smoke test
scripts/90-troubleshoot.sh  logs from every pod in the request path
native/                     Tech Preview external-model manifests
litellm-fallback/           LiteLLM shim + standard MaaS registration
```

Manifests use `${VAR}` placeholders resolved by `envsubst`, so `kubectl apply -k`
won't work directly — go through `10-apply.sh`, or render by hand:

```bash
. ./config.env && envsubst < native/20-llminferenceservice.yaml
```

---

## Gotchas specific to your cluster

- **Gateway must be programmed.** You hit the Istio `v1.26.2` EOL issue —
  confirm `oc get gateway data-science-gateway -n openshift-ingress` shows
  `Programmed=True` before expecting any of this to route.
- **Custom domain.** You set both `domain` and `subdomain` on the GatewayConfig.
  If the maas-ui container is still calling a stale host, the HTTPRoute hostnames
  created here will inherit the same problem — check section H of discovery.
- **Egress.** The cluster must reach `$PROVIDER_BASE_URL`. If you're behind a
  proxy, the model object needs the cluster proxy env or an EgressNetworkPolicy
  exception. `90-troubleshoot.sh` runs a reachability test.
- **Private CA.** Set `PROVIDER_CA_BUNDLE_FILE` in `config.env` and the apply
  script creates the ConfigMap; you may need to reference it from the model spec
  depending on what discovery reveals.

## References

- [Deploy and manage Models-as-a-Service — RHOAI 3.3](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [Govern LLM access with MaaS — RHOAI 3.4 (PDF)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/pdf/govern_llm_access_with_models-as-a-service/Red_Hat_OpenShift_AI_Self-Managed-3.4-Govern_LLM_access_with_Models-as-a-Service-en-US.pdf)
- [Centralized routing for external and self-hosted LLMs](https://developers.redhat.com/articles/2026/05/25/route-external-and-local-llms-models-as-a-service) — source of the LiteLLM pattern
- [rh-aiservices-bu/rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) — full MaaS install walkthrough for 3.4+
