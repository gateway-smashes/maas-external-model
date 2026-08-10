#!/usr/bin/env bash
# =============================================================================
# 00-discover.sh — blind-cluster diagnostic bundle for RHOAI MaaS external models
# =============================================================================
# Assumes NOTHING: no config.env, no prior install, no knowledge of the cluster.
# Collects raw evidence into a bundle directory AND runs named checks that emit
# PASS / WARN / FAIL with a fix hint, so you can act without reading 30k lines.
#
# Usage:
#   ./scripts/00-discover.sh                       # inspect + autodetect
#   ./scripts/00-discover.sh -n my-models          # focus a model namespace
#   ./scripts/00-discover.sh -n my-models --egress # + in-cluster probe to provider
#   ./scripts/00-discover.sh --outdir /tmp/diag
#
# Options:
#   -n, --namespace NS   model namespace to inspect (may be repeated).
#                        Default: $MAAS_NS from config.env, else autodetected,
#                        else maas-external-models. A namespace that does not
#                        exist yet is fine — it is reported as "clean install".
#   -o, --outdir DIR     bundle directory (default ./diag-<cluster>-<stamp>)
#       --provider-url U OpenAI-compatible base URL ending in /v1 (default from
#                        config.env PROVIDER_BASE_URL). Used by --egress.
#       --egress         run a throwaway pod that curls the provider from inside
#                        the cluster (creates + deletes a pod; off by default)
#       --gateway-probe  curl the MaaS gateway host from THIS workstation
#       --insecure       pass -k to every curl (self-signed cluster certs)
#       --no-archive     skip the .tgz at the end
#   -h, --help
#
# Output: bundle dir with raw/ dumps, findings.tsv, report.md, and a .tgz.
# Secrets are never dumped: only names, keys and labels. All captured text is
# passed through a redactor for sk-* keys, bearer tokens and token:/password:.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------- setup ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

STAMP="$(date +%Y%m%d-%H%M%S)"
NAMESPACES=()
OUTDIR=""
PROVIDER_URL=""
DO_EGRESS=0
DO_GW_PROBE=0
CURL_INSECURE=""
DO_ARCHIVE=1

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)   NAMESPACES+=("$2"); shift 2 ;;
    -o|--outdir)      OUTDIR="$2"; shift 2 ;;
    --provider-url)   PROVIDER_URL="$2"; shift 2 ;;
    --egress)         DO_EGRESS=1; shift ;;
    --gateway-probe)  DO_GW_PROBE=1; shift ;;
    --insecure)       CURL_INSECURE="-k"; shift ;;
    --no-archive)     DO_ARCHIVE=0; shift ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# config.env is optional — it only supplies defaults.
HAVE_CONFIG=0
if [ -f "$ROOT/config.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/config.env" && HAVE_CONFIG=1
fi

command -v oc >/dev/null 2>&1 || { echo "FATAL: 'oc' not on PATH." >&2; exit 1; }
HAVE_JQ=0; command -v jq   >/dev/null 2>&1 && HAVE_JQ=1
HAVE_PERL=0; command -v perl >/dev/null 2>&1 && HAVE_PERL=1

OC=(oc --request-timeout=25s)

if ! "${OC[@]}" whoami >/dev/null 2>&1; then
  echo "FATAL: not logged in / API server unreachable." >&2
  echo "       oc config current-context -> $(oc config current-context 2>/dev/null || echo none)" >&2
  echo "       Log in with:  oc login --server=https://api.<cluster>:6443" >&2
  exit 1
fi

API_HOST="$("${OC[@]}" whoami --show-server 2>/dev/null | sed -E 's|https?://||; s|:.*||')"
CLUSTER_SLUG="$(printf '%s' "${API_HOST:-cluster}" | tr '.' '-' | cut -c1-40)"
[ -n "$OUTDIR" ] || OUTDIR="$ROOT/diag-${CLUSTER_SLUG}-${STAMP}"
RAW="$OUTDIR/raw"
mkdir -p "$RAW" || exit 1
FINDINGS="$OUTDIR/findings.tsv"
REPORT="$OUTDIR/report.md"
: > "$FINDINGS"

# -------------------------------------------------------------- helpers ----
if [ -t 1 ]; then
  C_HDR=$'\033[1;36m'; C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'
  C_FAIL=$'\033[0;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_HDR=""; C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_OFF=""
fi

redact() {
  if [ "$HAVE_PERL" = 1 ]; then
    perl -pe '
      s/(sk-[A-Za-z0-9_.-]{4})[A-Za-z0-9_.-]{4,}/$1***REDACTED***/g;
      s/((?:api[-_]?key|apikey|token|password|passwd|secret|credential)[A-Za-z0-9_-]*\s*[:=]\s*)("?)(?!type=|\*\*\*|\{|\[)[^"\s,}]{6,}/$1$2***REDACTED***/gi;
      s/(Bearer\s+)[A-Za-z0-9._~+\/-]{10,}/$1***REDACTED***/gi;
      s/(sha256[:~])[A-Za-z0-9]{16,}/$1***/g;
    '
  else
    sed -E \
      -e 's/(sk-[A-Za-z0-9_.-]{4})[A-Za-z0-9_.-]{4,}/\1***REDACTED***/g' \
      -e 's/((api[-_]?key|token|password|secret)[A-Za-z0-9_-]*[:=][[:space:]]*)("?)[^"[:space:],}]{6,}/\1\3***REDACTED***/g' \
      -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+/-]{10,}/\1***REDACTED***/g'
  fi
}

# cap <file> <cmd...>  — capture stdout+stderr, redacted, into raw/<file>
cap() {
  local f="$RAW/$1"; shift
  { "$@"; } 2>&1 | redact > "$f"
  return 0
}
# capf <file> — capture stdin (for pipelines)
capf() { redact > "$RAW/$1"; }

# Does raw/<file> have real content?
nonempty() { [ -s "$RAW/$1" ] && ! grep -qiE '^(No resources found|error: the server doesn)' "$RAW/$1"; }

sec() {
  SECTION="$*"
  printf '\n%s=== %s ===%s\n' "$C_HDR" "$SECTION" "$C_OFF"
  printf '\n## %s\n\n' "$SECTION" >> "$REPORT"
}

# finding <OK|WARN|FAIL|INFO> <id> <message> [fix]
finding() {
  local sev="$1" id="$2" msg="$3" fix="${4:-}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$sev" "$id" "${SECTION:-general}" "$msg" "$fix" >> "$FINDINGS"
  local c="$C_DIM" tag="  ..  "
  case "$sev" in
    OK)   c="$C_OK";   tag=" PASS " ;;
    WARN) c="$C_WARN"; tag=" WARN " ;;
    FAIL) c="$C_FAIL"; tag=" FAIL " ;;
    INFO) c="$C_DIM";  tag=" info " ;;
  esac
  printf '%s[%s]%s %s\n' "$c" "$tag" "$C_OFF" "$msg"
  [ -n "$fix" ] && printf '        %s-> %s%s\n' "$C_DIM" "$fix" "$C_OFF"
  {
    printf -- '- **%s** `%s` — %s\n' "$sev" "$id" "$msg"
    [ -n "$fix" ] && printf -- '  - fix: %s\n' "$fix"
  } >> "$REPORT"
  return 0
}

note() { printf '%s  %s%s\n' "$C_DIM" "$*" "$C_OFF"; printf -- '- _%s_\n' "$*" >> "$REPORT"; }

has_crd()  { "${OC[@]}" get crd "$1" >/dev/null 2>&1; }
ns_exists() { "${OC[@]}" get ns "$1" >/dev/null 2>&1; }

# conditions_of <kind> <name> [-n ns] -> "Type=Status reason"
conditions_of() {
  "${OC[@]}" get "$@" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null
}

count_sev() { awk -F'\t' -v s="$1" '$1==s' "$FINDINGS" 2>/dev/null | wc -l | tr -d ' '; }

# oc chatter ("No resources found", "Error from server") must never be mistaken
# for an object name. scrub = scalars, list_clean = newline-separated lists.
scrub() {
  case "${1:-}" in
    "No resources found"*|"Error from server"*|error:*|Error*) printf '' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}
list_clean() { grep -vE '^(No resources found|Error|error)' 2>/dev/null | grep -v '^[[:space:]]*$'; }
# ocj <get-args...> -> scrubbed scalar
ocj() { scrub "$("${OC[@]}" get "$@" 2>/dev/null)"; }

probe() { # probe <label> <url> [header]
  local label="$1" url="$2" hdr="${3:-}"
  local args
  args=(-sS -o /dev/null -m 15 -w '%{http_code} %{time_total}s')
  [ -n "$CURL_INSECURE" ] && args+=("$CURL_INSECURE")
  [ -n "$hdr" ] && args+=(-H "$hdr")
  echo "$label -> $(curl "${args[@]}" "$url" 2>&1)"
}

{
  echo "# MaaS discovery report"
  echo
  echo "- generated: $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo "- api server: \`${API_HOST}\`"
  echo "- user: \`$("${OC[@]}" whoami 2>/dev/null)\`"
  echo "- bundle: \`${OUTDIR}\`"
} > "$REPORT"

printf '%sMaaS blind discovery%s  api=%s  out=%s\n' "$C_HDR" "$C_OFF" "$API_HOST" "$OUTDIR"
[ "$HAVE_JQ" = 1 ] || echo "NOTE: jq not installed — some schema checks are skipped."

# ============================================================ A. cluster ====
sec "A. Cluster identity and platform"

cap cluster-version.txt "${OC[@]}" get clusterversion version -o yaml
OCP_VER="$("${OC[@]}" get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)"
CLUSTER_DOMAIN="$("${OC[@]}" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
WHO="$("${OC[@]}" whoami 2>/dev/null)"
finding INFO ocp-version "OpenShift ${OCP_VER:-unknown}, apps domain ${CLUSTER_DOMAIN:-unknown}, user ${WHO}"

if "${OC[@]}" auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
  finding OK rbac-admin "Current user is cluster-admin (full install possible)."
else
  finding WARN rbac-admin "Current user is NOT cluster-admin — CRD/DSC/gateway changes will fail." \
    "Log in as an admin before running scripts/05-gateway.sh or 10-apply.sh."
fi

cap nodes.txt "${OC[@]}" get nodes -o wide
cap co-degraded.txt "${OC[@]}" get co
if grep -qE 'True[[:space:]]+True' "$RAW/co-degraded.txt" 2>/dev/null; then
  finding WARN cluster-operators "Some ClusterOperators are Progressing/Degraded — see raw/co-degraded.txt."
fi

# ---------------------------------------------------------- B. operators ---
sec "B. Operators and subscriptions"

cap csvs.txt "${OC[@]}" get csv -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase
cap subscriptions.txt "${OC[@]}" get subscriptions.operators.coreos.com -A -o wide

check_operator() { # check_operator <regex> <human name> <severity-if-missing>
  # Match the CSV NAME column only. Matching whole lines produces false hits on
  # namespaces (e.g. a namespace called iib-concierge-connectivity-link).
  local re="$1" name="$2" sev="$3" line
  line="$(awk -v re="$re" 'NR>1 && tolower($2) ~ re {print; exit}' "$RAW/csvs.txt")"
  if [ -n "$line" ]; then
    local phase; phase="$(printf '%s' "$line" | awk '{print $NF}')"
    if [ "$phase" = "Succeeded" ]; then
      finding OK "op-$name" "$name installed: $(printf '%s' "$line" | awk '{print $2" "$3}')"
    else
      finding FAIL "op-$name" "$name is in phase '$phase' (not Succeeded)." "oc describe csv -A | grep -A20 '$name'"
    fi
  else
    finding "$sev" "op-$name" "$name operator NOT found." \
      "Install it from OperatorHub before MaaS will reconcile."
  fi
}
check_operator 'rhods-operator|opendatahub-operator'  'rhoai'          FAIL
check_operator 'rhcl-operator|kuadrant-operator'      'connectivity'   FAIL
check_operator 'authorino'                            'authorino'      WARN
check_operator 'servicemesh|sailoperator|istio'       'servicemesh'    WARN
check_operator 'cert-manager'                         'cert-manager'   WARN
# LlamaStack ships inside RHOAI (DSC component), not as an OLM CSV — check the
# controller Deployment instead of looking for a subscription that never exists.
LSD_OP="$("${OC[@]}" get deploy -A -o name 2>/dev/null | list_clean | grep -iE 'llama-stack.*operator' | head -1)"
if [ -n "$LSD_OP" ]; then
  finding OK op-llamastack "LlamaStack operator running ($LSD_OP)"
else
  finding WARN op-llamastack "No llama-stack operator Deployment found — Gen AI playground will not work." \
    "Set components.llamastackoperator=Managed on the DataScienceCluster."
fi

# ------------------------------------------------------------ C. DSC/DSCI --
sec "C. DataScienceCluster / DSCInitialization"

cap dsc.yaml "${OC[@]}" get datasciencecluster -A -o yaml
cap dsci.yaml "${OC[@]}" get dscinitialization -A -o yaml
DSC_NAME="$(ocj datasciencecluster -o jsonpath='{.items[0].metadata.name}')"

if [ -z "$DSC_NAME" ]; then
  finding FAIL dsc-missing "No DataScienceCluster found — RHOAI is not configured." \
    "Create a DataScienceCluster before anything else."
else
  finding INFO dsc-name "DataScienceCluster: $DSC_NAME"
  for comp in kserve dashboard llamastackoperator modelregistry; do
    st="$("${OC[@]}" get datasciencecluster "$DSC_NAME" -o jsonpath="{.spec.components.${comp}.managementState}" 2>/dev/null)"
    case "$st" in
      Managed) finding OK "dsc-$comp" "components.$comp = Managed" ;;
      "")      finding WARN "dsc-$comp" "components.$comp not set in this DSC schema." ;;
      *)       finding WARN "dsc-$comp" "components.$comp = $st" \
                 "oc patch datasciencecluster $DSC_NAME --type=merge -p '{\"spec\":{\"components\":{\"$comp\":{\"managementState\":\"Managed\"}}}}'" ;;
    esac
  done

  MAAS_STATE="$("${OC[@]}" get datasciencecluster "$DSC_NAME" -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null)"
  if [ "$MAAS_STATE" = "Managed" ]; then
    finding OK dsc-maas "kserve.modelsAsService = Managed"
  else
    finding FAIL dsc-maas "kserve.modelsAsService = ${MAAS_STATE:-unset} (MaaS will not deploy)." \
      "oc patch datasciencecluster $DSC_NAME --type=merge -p '{\"spec\":{\"components\":{\"kserve\":{\"modelsAsService\":{\"managementState\":\"Managed\"}}}}}'"
  fi

  conditions_of datasciencecluster "$DSC_NAME" | capf dsc-conditions.txt
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *"=False"*) finding FAIL "dsc-cond" "DSC condition ${line}" "oc describe datasciencecluster $DSC_NAME" ;;
    esac
  done < "$RAW/dsc-conditions.txt"
fi

# ---------------------------------------------------------------- D. CRDs --
sec "D. CRDs and real schemas (blind-mode gold)"

cap crds-all.txt "${OC[@]}" get crd -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
grep -Ei 'kserve|maas|kuadrant|authorino|limitador|opendatahub|llamastack|gateway\.networking' \
  "$RAW/crds-all.txt" > "$RAW/crds-relevant.txt" 2>/dev/null
cap api-resources.txt "${OC[@]}" api-resources

for crd in externalmodels.maas.opendatahub.io \
           maasmodelrefs.maas.opendatahub.io \
           maasauthpolicies.maas.opendatahub.io \
           maassubscriptions.maas.opendatahub.io \
           tenants.maas.opendatahub.io \
           llamastackdistributions.llamastack.io \
           llminferenceservices.serving.kserve.io ; do
  short="${crd%%.*}"
  if has_crd "$crd"; then
    finding OK "crd-$short" "CRD present: $crd"
    # 'oc explain tenant.spec' silently resolves to 3scale's Tenant when both
    # CRDs exist. Pin the api-version so the right schema is captured.
    CRD_GROUP="${crd#*.}"
    CRD_VER="$(ocj crd "$crd" -o jsonpath='{.spec.versions[?(@.storage==true)].name}')"
    cap "schema-${short}.txt" "${OC[@]}" explain "${short%s}.spec" --recursive \
      ${CRD_VER:+--api-version="${CRD_GROUP}/${CRD_VER}"}
    if [ "$HAVE_JQ" = 1 ]; then
      "${OC[@]}" get crd "$crd" -o json 2>/dev/null | jq -r '
        (.spec.versions[] | select(.storage==true)) as $v
        | "storageVersion: \($v.name)",
          "required: \($v.schema.openAPIV3Schema.properties.spec.required // [] | join(", "))",
          ( $v.schema.openAPIV3Schema.properties.spec.properties // {}
            | to_entries[]
            | "  \(.key): type=\(.value.type // "?")"
              + (if .value.pattern      then " pattern=\(.value.pattern)"   else "" end)
              + (if .value.enum         then " enum=\(.value.enum|join("|"))" else "" end)
              + (if .value.description  then " # \(.value.description|split("\n")[0])" else "" end) )
      ' | capf "schema-${short}-spec.txt"
    fi
  else
    case "$short" in
      externalmodels|maasmodelrefs)
        finding FAIL "crd-$short" "CRD missing: $crd — the native ExternalModel path is unavailable." \
          "Either enable kserve.modelsAsService=Managed, or use the litellm fallback mode." ;;
      llamastackdistributions)
        finding FAIL "crd-$short" "CRD missing: $crd — the dashboard Gen AI playground cannot work." \
          "Enable components.llamastackoperator=Managed on the DataScienceCluster." ;;
      *) finding WARN "crd-$short" "CRD missing: $crd" ;;
    esac
  fi
done

# Endpoint pattern is the #1 blind-install trap (no scheme, no path, no :port).
if [ -s "$RAW/schema-externalmodels-spec.txt" ]; then
  EP_LINE="$(grep -E '^\s*endpoint:' "$RAW/schema-externalmodels-spec.txt" | head -1)"
  [ -n "$EP_LINE" ] && finding INFO em-endpoint-pattern "ExternalModel.spec.endpoint ->${EP_LINE#*endpoint:}"
fi

# --------------------------------------------------- E. MaaS control plane --
sec "E. MaaS control plane"

APP_NS_GUESS="${APP_NS:-redhat-ods-applications}"
ns_exists "$APP_NS_GUESS" || APP_NS_GUESS="$("${OC[@]}" get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -E 'ods-applications|opendatahub' | head -1)"
finding INFO app-ns "Dashboard/app namespace: ${APP_NS_GUESS:-NOT FOUND}"

TENANT_NS_GUESS="${TENANT_NS:-models-as-a-service}"
cap pods-appns.txt "${OC[@]}" get pods -n "$APP_NS_GUESS" -o wide
cap pods-tenantns.txt "${OC[@]}" get pods -n "$TENANT_NS_GUESS" -o wide
cap deploy-appns.txt "${OC[@]}" get deploy -n "$APP_NS_GUESS" -o wide
cap deploy-tenantns.txt "${OC[@]}" get deploy -n "$TENANT_NS_GUESS" -o wide

for d in maas-api maas-controller payload-processing; do
  hit="$(grep -h "^$d" "$RAW/deploy-appns.txt" "$RAW/deploy-tenantns.txt" 2>/dev/null | head -1)"
  if [ -n "$hit" ]; then
    ready="$(printf '%s' "$hit" | awk '{print $2}')"
    if [ "${ready%%/*}" = "${ready##*/}" ] && [ "${ready%%/*}" != "0" ]; then
      finding OK "cp-$d" "$d deployment ready ($ready)"
    else
      finding FAIL "cp-$d" "$d deployment NOT ready ($ready)." "oc describe deploy $d -n $APP_NS_GUESS"
    fi
  else
    finding WARN "cp-$d" "$d deployment not found in $APP_NS_GUESS or $TENANT_NS_GUESS." \
      "Expected once kserve.modelsAsService=Managed reconciles."
  fi
done

# maas-db-config is a classic PrerequisitesNotMet cause. Names/keys only.
for ns in "$APP_NS_GUESS" "$TENANT_NS_GUESS"; do
  [ -n "$ns" ] || continue
  if "${OC[@]}" get secret maas-db-config -n "$ns" >/dev/null 2>&1; then
    finding OK maas-db "Secret maas-db-config present in $ns (keys: $("${OC[@]}" get secret maas-db-config -n "$ns" -o jsonpath='{range .data.*}{"x "}{end}' 2>/dev/null | wc -w | tr -d ' '))"
    break
  fi
done
grep -q 'maas-db' "$FINDINGS" || finding WARN maas-db "Secret maas-db-config not found — MaaS may report PrerequisitesNotMet." \
  "Create the Postgres connection secret expected by maas-api."

cap tenants.txt "${OC[@]}" get tenants.maas.opendatahub.io -A -o wide
cap tenants.yaml "${OC[@]}" get tenants.maas.opendatahub.io -A -o yaml
TENANT_LINE="$("${OC[@]}" get tenants.maas.opendatahub.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} -> {.spec.gatewayRef.namespace}/{.spec.gatewayRef.name} phase={.status.phase}{"\n"}{end}' 2>/dev/null)"
if [ -n "$TENANT_LINE" ]; then
  printf '%s\n' "$TENANT_LINE" | capf tenant-gatewayref.txt
  note "Tenant -> gatewayRef:"; printf '%s\n' "$TENANT_LINE" | sed 's/^/    /'
  TENANT_GW_NS="$(printf '%s' "$TENANT_LINE"  | head -1 | sed -E 's|.*-> ([^/]+)/.*|\1|')"
  TENANT_GW_NAME="$(printf '%s' "$TENANT_LINE" | head -1 | sed -E 's|.*-> [^/]+/([^ ]+) .*|\1|')"
else
  finding FAIL tenant-missing "No MaaS Tenant object found." "MaaS controller creates default-tenant once modelsAsService=Managed."
  TENANT_GW_NS=""; TENANT_GW_NAME=""
fi

for app in maas-api maas-controller; do
  "${OC[@]}" logs -n "$APP_NS_GUESS" -l "app.kubernetes.io/name=$app" --tail=400 2>/dev/null \
    | grep -iE 'error|fail|denied|panic|not found' | tail -60 | capf "logs-${app}-errors.txt"
  if nonempty "logs-${app}-errors.txt"; then
    finding WARN "logs-$app" "$app has recent errors — see raw/logs-${app}-errors.txt ($(wc -l < "$RAW/logs-${app}-errors.txt" | tr -d ' ') lines)."
  fi
done

# ------------------------------------------------------------ F. gateways --
sec "F. Gateways and ingress"

cap gatewayclasses.txt "${OC[@]}" get gatewayclass -o wide
cap gateways.txt "${OC[@]}" get gateways.gateway.networking.k8s.io -A -o wide
cap gateways.yaml "${OC[@]}" get gateways.gateway.networking.k8s.io -A -o yaml
cap gatewayconfig.yaml "${OC[@]}" get gatewayconfig -A -o yaml
cap httproutes-all.txt "${OC[@]}" get httproutes.gateway.networking.k8s.io -A -o wide
cap routes-all.txt "${OC[@]}" get route -A -o wide

GW_NS="${GATEWAY_NS:-${TENANT_GW_NS:-}}"
GW_NAME="${GATEWAY_NAME:-${TENANT_GW_NAME:-}}"
# Fall back to whatever gateway exists.
if [ -z "$GW_NAME" ]; then
  GW_NS="$(ocj gateway -A -o jsonpath='{.items[0].metadata.namespace}')"
  GW_NAME="$(ocj gateway -A -o jsonpath='{.items[0].metadata.name}')"
fi

if [ -z "$GW_NAME" ]; then
  finding FAIL gw-missing "No Gateway objects exist at all." "./scripts/05-gateway.sh install"
else
  finding INFO gw-target "Inspecting gateway ${GW_NS}/${GW_NAME}"
  conditions_of gateways.gateway.networking.k8s.io "$GW_NAME" -n "$GW_NS" | capf gateway-conditions.txt
  if grep -q 'Programmed=True' "$RAW/gateway-conditions.txt" 2>/dev/null; then
    finding OK gw-programmed "Gateway ${GW_NS}/${GW_NAME} is Programmed=True"
  else
    finding FAIL gw-programmed "Gateway ${GW_NS}/${GW_NAME} is not Programmed: $(tr '\n' ' ' < "$RAW/gateway-conditions.txt")" \
      "oc describe gateway $GW_NAME -n $GW_NS"
  fi

  GW_HOST="$(ocj gateway "$GW_NAME" -n "$GW_NS" -o jsonpath='{.spec.listeners[0].hostname}')"
  finding INFO gw-host "Gateway listener hostname: ${GW_HOST:-<none>}"

  # Which namespaces may attach routes to this gateway?
  "${OC[@]}" get gateways.gateway.networking.k8s.io "$GW_NAME" -n "$GW_NS" -o jsonpath='{range .spec.listeners[*]}{.name}{" from="}{.allowedRoutes.namespaces.from}{" sel="}{.allowedRoutes.namespaces.selector}{"\n"}{end}' 2>/dev/null \
    | capf gateway-allowedroutes.txt
  note "listener allowedRoutes: $(tr '\n' ' ' < "$RAW/gateway-allowedroutes.txt")"

  # TLS secret referenced by the listener must exist.
  TLS_SECRET="$(ocj gateway "$GW_NAME" -n "$GW_NS" -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}')"
  if [ -n "$TLS_SECRET" ]; then
    if "${OC[@]}" get secret "$TLS_SECRET" -n "$GW_NS" >/dev/null 2>&1; then
      finding OK gw-tls "Listener TLS secret $TLS_SECRET exists in $GW_NS"
    else
      finding FAIL gw-tls "Listener references TLS secret $TLS_SECRET which does NOT exist in $GW_NS." \
        "./scripts/05-gateway.sh install  (regenerates the cert secret)"
    fi
  fi

  if [ -n "$GW_HOST" ]; then
    if host "$GW_HOST" >/dev/null 2>&1 || nslookup "$GW_HOST" >/dev/null 2>&1; then
      finding OK gw-dns "Gateway host $GW_HOST resolves from this workstation."
    else
      finding WARN gw-dns "Gateway host $GW_HOST does NOT resolve from this workstation." \
        "Add a DNS record or /etc/hosts entry pointing at the ingress LB, or curl with --resolve."
    fi
  fi
fi

# IPP ext_proc attachment — without it, requests reach the provider unauthenticated
cap envoyfilters.txt "${OC[@]}" get envoyfilter -A
if grep -qiE 'payload-processing|ext-proc|ipp' "$RAW/envoyfilters.txt" 2>/dev/null; then
  finding OK ipp-filter "An IPP/ext_proc EnvoyFilter is present."
else
  finding WARN ipp-filter "No payload-processing EnvoyFilter found — API key injection may not happen." \
    "./scripts/05-gateway.sh ipp"
fi

cap kuadrant.txt "${OC[@]}" get kuadrant -A -o wide
cap authpolicies.txt "${OC[@]}" get authpolicy -A -o wide
cap ratelimitpolicies.txt "${OC[@]}" get tokenratelimitpolicy,ratelimitpolicy -A -o wide

# --------------------------------------------------- G. namespace targets --
sec "G. Target namespaces"

# Autodetect namespaces that already hold models, then merge with -n args.
DETECTED=""
if has_crd externalmodels.maas.opendatahub.io; then
  DETECTED="$("${OC[@]}" get externalmodels.maas.opendatahub.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | list_clean | sort -u)"
fi
if [ ${#NAMESPACES[@]} -eq 0 ]; then
  if [ -n "${MAAS_NS:-}" ]; then NAMESPACES+=("$MAAS_NS"); fi
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    dup=0; for n in ${NAMESPACES[@]+"${NAMESPACES[@]}"}; do [ "$n" = "$d" ] && dup=1; done
    [ $dup -eq 0 ] && NAMESPACES+=("$d")
  done <<< "$DETECTED"
  [ ${#NAMESPACES[@]} -eq 0 ] && NAMESPACES+=("maas-external-models")
fi
finding INFO ns-list "Namespaces under inspection: ${NAMESPACES[*]}"
[ -n "$DETECTED" ] && note "namespaces already holding ExternalModels: $(echo "$DETECTED" | tr '\n' ' ')"

# ------------------------------------------------------ H. per-namespace ----
for NS in "${NAMESPACES[@]}"; do
  sec "H. Namespace: $NS"

  if ! ns_exists "$NS"; then
    finding INFO "ns-$NS-absent" "Namespace $NS does not exist — clean slate, nothing to clean up."
    continue
  fi

  cap "ns-${NS}.yaml" "${OC[@]}" get ns "$NS" -o yaml
  DASH_LABEL="$("${OC[@]}" get ns "$NS" -o jsonpath='{.metadata.labels.opendatahub\.io/dashboard}' 2>/dev/null)"
  if [ "$DASH_LABEL" = "true" ]; then
    finding OK "ns-$NS-dashlabel" "$NS has opendatahub.io/dashboard=true (visible as a Data Science project)."
  else
    finding FAIL "ns-$NS-dashlabel" "$NS is missing opendatahub.io/dashboard=true — the dashboard will not list it." \
      "oc label ns $NS opendatahub.io/dashboard=true --overwrite"
  fi
  DISPLAY="$("${OC[@]}" get ns "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/display-name}' 2>/dev/null)"
  [ -n "$DISPLAY" ] || finding WARN "ns-$NS-display" "$NS has no openshift.io/display-name annotation (shows raw name in UI)." \
    "oc annotate ns $NS openshift.io/display-name='...' --overwrite"

  cap "objects-${NS}.txt" "${OC[@]}" get all,externalmodels.maas.opendatahub.io,maasmodelrefs.maas.opendatahub.io,httproutes.gateway.networking.k8s.io,serviceentries.networking.istio.io,destinationrules.networking.istio.io,llamastackdistributions.llamastack.io -n "$NS" -o wide
  cap "events-${NS}.txt" "${OC[@]}" get events -n "$NS" --sort-by=.lastTimestamp

  # ---- models
  cap "externalmodels-${NS}.yaml" "${OC[@]}" get externalmodels.maas.opendatahub.io -n "$NS" -o yaml
  cap "maasmodelrefs-${NS}.yaml" "${OC[@]}" get maasmodelrefs.maas.opendatahub.io -n "$NS" -o yaml
  MODELS="$("${OC[@]}" get externalmodels.maas.opendatahub.io -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | list_clean)"

  if [ -z "$MODELS" ]; then
    finding WARN "ns-$NS-models" "No ExternalModel in $NS." "./scripts/10-apply.sh native"
  fi

  for M in $MODELS; do
    EP="$(ocj externalmodel "$M" -n "$NS" -o jsonpath='{.spec.endpoint}')"
    TM="$(ocj externalmodel "$M" -n "$NS" -o jsonpath='{.spec.targetModel}')"
    CREF="$(ocj externalmodel "$M" -n "$NS" -o jsonpath='{.spec.credentialRef.name}')"
    finding INFO "model-$M" "ExternalModel $NS/$M endpoint=$EP targetModel=$TM credentialRef=$CREF"

    case "$EP" in
      *://*|*/*|*:*) finding FAIL "model-$M-endpoint" "endpoint '$EP' contains scheme/path/port — CRD wants a bare hostname." \
                       "Set PROVIDER_HOST to the hostname only and re-apply." ;;
    esac

    conditions_of externalmodels.maas.opendatahub.io "$M" -n "$NS" | capf "conditions-em-${M}.txt"
    grep -q '=False' "$RAW/conditions-em-${M}.txt" 2>/dev/null && \
      finding FAIL "model-$M-cond" "ExternalModel $M has failing conditions: $(grep '=False' "$RAW/conditions-em-${M}.txt" | tr '\n' ' ')" \
        "oc describe externalmodel $M -n $NS"

    # credential secret: existence, required key, required label
    if [ -n "$CREF" ]; then
      if "${OC[@]}" get secret "$CREF" -n "$NS" >/dev/null 2>&1; then
        HAS_KEY="$("${OC[@]}" get secret "$CREF" -n "$NS" -o jsonpath='{.data.api-key}' 2>/dev/null)"
        [ -n "$HAS_KEY" ] && finding OK "model-$M-secret-key" "Secret $CREF has data key 'api-key'." \
          || finding FAIL "model-$M-secret-key" "Secret $CREF is missing data key 'api-key'." \
               "oc create secret generic $CREF -n $NS --from-literal=api-key=... --dry-run=client -o yaml | oc apply -f -"
        IPP_LABEL="$("${OC[@]}" get secret "$CREF" -n "$NS" -o jsonpath='{.metadata.labels.inference\.llm-d\.ai/ipp-managed}' 2>/dev/null)"
        [ "$IPP_LABEL" = "true" ] && finding OK "model-$M-secret-label" "Secret $CREF is labelled ipp-managed=true." \
          || finding FAIL "model-$M-secret-label" "Secret $CREF lacks inference.llm-d.ai/ipp-managed=true — IPP will not inject the provider key." \
               "oc label secret $CREF -n $NS inference.llm-d.ai/ipp-managed=true --overwrite"
      else
        finding FAIL "model-$M-secret" "credentialRef secret $CREF does not exist in $NS."
      fi
    fi

    # reconciler-generated objects prove the controller actually ran
    for kind in service serviceentry destinationrule httproute; do
      cnt="$("${OC[@]}" get "$kind" -n "$NS" --no-headers 2>/dev/null | grep -c "$M")"
      [ "${cnt:-0}" -gt 0 ] && finding OK "model-$M-$kind" "$kind generated for $M ($cnt)" \
        || finding WARN "model-$M-$kind" "No $kind generated for $M — reconciler may not have run." \
             "oc describe externalmodel $M -n $NS; check maas-controller logs"
    done
  done

  # ---- HTTPRoute acceptance (the thing that actually wires the gateway)
  "${OC[@]}" get httproutes.gateway.networking.k8s.io -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" parents="}{.spec.parentRefs[*].name}{" accepted="}{.status.parents[*].conditions[?(@.type=="Accepted")].status}{" resolved="}{.status.parents[*].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}' 2>/dev/null \
    | capf "httproutes-${NS}.txt"
  if nonempty "httproutes-${NS}.txt"; then
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      case "$r" in
        *"accepted=True"*) : ;;
        *) finding FAIL "route-$NS" "HTTPRoute not accepted: $r" \
             "Gateway listener allowedRoutes must include namespace $NS (see raw/gateway-allowedroutes.txt)." ;;
      esac
    done < "$RAW/httproutes-${NS}.txt"
    grep -q 'accepted=True' "$RAW/httproutes-${NS}.txt" && finding OK "route-$NS-ok" "At least one HTTPRoute in $NS is Accepted."
  fi

  # ---- LlamaStackDistribution: the exact thing maas-ui /api/v1/lsd/models needs
  if has_crd llamastackdistributions.llamastack.io; then
    LSD_LIST="$("${OC[@]}" get llamastackdistributions.llamastack.io -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | list_clean)"
    if [ -z "$LSD_LIST" ]; then
      finding FAIL "lsd-$NS" "No LlamaStackDistribution in $NS — this is exactly what makes maas-ui log 'no LlamaStackDistribution found in namespace \"$NS\"'." \
        "Create one: dashboard Gen AI -> 'Add to playground' for the model in project $NS, then ./cluster/lsd-playground-fix.sh"
    else
      for L in $LSD_LIST; do
        finding OK "lsd-$NS-$L" "LlamaStackDistribution $NS/$L exists."
        cap "lsd-${NS}-${L}.yaml" "${OC[@]}" get llamastackdistributions.llamastack.io "$L" -n "$NS" -o yaml
        LSD_PHASE="$("${OC[@]}" get llamastackdistributions.llamastack.io "$L" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
        note "LSD $L phase=${LSD_PHASE:-<none>}"
        DREADY="$("${OC[@]}" get deploy "$L" -n "$NS" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)"
        [ "${DREADY%%/*}" = "${DREADY##*/}" ] && [ -n "${DREADY%%/*}" ] && [ "${DREADY%%/*}" != "0" ] \
          && finding OK "lsd-$NS-$L-deploy" "LSD deployment ready ($DREADY)" \
          || finding FAIL "lsd-$NS-$L-deploy" "LSD deployment not ready (${DREADY:-none})." "oc describe deploy $L -n $NS"

        # The three known playground killers
        "${OC[@]}" get deploy "$L" -n "$NS" -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
          | capf "lsd-${L}-env.txt"
        if grep -q '^VLLM_API_TOKEN_1=fake$' "$RAW/lsd-${L}-env.txt" 2>/dev/null; then
          finding FAIL "lsd-$L-token" "LSD still has the literal VLLM_API_TOKEN_1=fake — every playground call is unauthenticated." \
            "./cluster/lsd-playground-fix.sh"
        fi
        MAXTOK="$(grep '^VLLM_MAX_TOKENS=' "$RAW/lsd-${L}-env.txt" 2>/dev/null | cut -d= -f2)"
        if [ -z "$MAXTOK" ] || [ "${MAXTOK:-4096}" -ge 4096 ] 2>/dev/null; then
          finding WARN "lsd-$L-maxtokens" "VLLM_MAX_TOKENS=${MAXTOK:-unset} — at/over the 4096 context it silently returns nothing." \
            "PLAYGROUND_MAX_TOKENS=512 ./cluster/lsd-playground-fix.sh"
        fi
        if ! "${OC[@]}" get cm lsd-model-alias-bootstrap -n "$NS" >/dev/null 2>&1; then
          finding WARN "lsd-$L-alias" "No lsd-model-alias-bootstrap ConfigMap — the UI's short model id will 404 inside LlamaStack." \
            "./cluster/lsd-playground-fix.sh"
        fi
        "${OC[@]}" logs -n "$NS" "deploy/$L" --tail=200 2>/dev/null | grep -iE 'error|exceed|401|403|404' | tail -40 | capf "lsd-${L}-logs.txt"
      done
    fi
  fi
done

# ------------------------------------------------------------ I. dashboard --
sec "I. Dashboard visibility"

cap odhdashboardconfig.yaml "${OC[@]}" get odhdashboardconfig -A -o yaml
if [ "$HAVE_JQ" = 1 ]; then
  "${OC[@]}" get odhdashboardconfig -A -o json 2>/dev/null \
    | jq -r '.items[0].spec.dashboardConfig // {} | to_entries[] | "\(.key)=\(.value)"' | capf dashboard-flags.txt
  for f in disableModelServing disableModelCatalog disableModelRegistry disableGenAiStudio disableLlamaStack disableModelsAsService; do
    v="$(grep "^$f=" "$RAW/dashboard-flags.txt" 2>/dev/null | cut -d= -f2)"
    [ -z "$v" ] && continue
    [ "$v" = "true" ] \
      && finding FAIL "dash-$f" "Dashboard flag $f=true — that feature is hidden in the UI." \
           "oc patch odhdashboardconfig <name> -n $APP_NS_GUESS --type=merge -p '{\"spec\":{\"dashboardConfig\":{\"$f\":false}}}'" \
      || finding OK "dash-$f" "Dashboard flag $f=false"
  done
fi

# Scan EVERY dashboard-ish deployment and EVERY container. The maas-ui and
# gen-ai-ui sidecars live in rhods-dashboard; picking one deployment by name
# silently misses them (dashboard-redirect sorts first and only has nginx).
DASH_DEPLOYS="$("${OC[@]}" get deploy -n "$APP_NS_GUESS" -o name 2>/dev/null \
  | list_clean | grep -iE 'dashboard|maas-ui|gen-ai|genai')"
if [ -n "$DASH_DEPLOYS" ]; then
  : > "$RAW/dashboard-containers.txt"
  for DASH_DEPLOY in $DASH_DEPLOYS; do
    DSHORT="$(basename "$DASH_DEPLOY")"
    CONTAINERS="$("${OC[@]}" get "$DASH_DEPLOY" -n "$APP_NS_GUESS" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null | list_clean)"
    printf '%s: %s\n' "$DSHORT" "$(printf '%s' "$CONTAINERS" | tr '\n' ' ')" >> "$RAW/dashboard-containers.txt"
    note "$DSHORT containers: $(printf '%s' "$CONTAINERS" | tr '\n' ' ')"
    for c in $CONTAINERS; do
      "${OC[@]}" logs -n "$APP_NS_GUESS" "$DASH_DEPLOY" -c "$c" --tail=400 2>/dev/null \
        | grep -iE 'level=ERROR|level=WARN|error|denied|not found' | tail -60 | capf "logs-${DSHORT}-${c}.txt"
      nonempty "logs-${DSHORT}-${c}.txt" || continue
      finding WARN "dash-log-$DSHORT-$c" "$DSHORT/$c logged errors — raw/logs-${DSHORT}-${c}.txt"
      # surface the LSD error explicitly, it is the one that breaks the playground
      if [ "${LSD_ERR_SEEN:-0}" = 0 ] && grep -q 'no LlamaStackDistribution found' "$RAW/logs-${DSHORT}-${c}.txt"; then
        LSD_ERR_SEEN=1
        BADNS="$(grep -o 'namespace \\*"[^"\\]*' "$RAW/logs-${DSHORT}-${c}.txt" | head -1 | sed 's/.*"//')"
        finding FAIL "dash-lsd-error" "maas-ui reports: no LlamaStackDistribution found in namespace \"${BADNS:-?}\" — the Gen AI playground has no backend there." \
          "Create an LSD in that namespace (dashboard: Gen AI -> Add to playground), then ./cluster/lsd-playground-fix.sh"
      fi
    done
  done
else
  finding FAIL dash-deploy "No dashboard deployment found in $APP_NS_GUESS."
fi

cap dsprojects.txt "${OC[@]}" get ns -l opendatahub.io/dashboard=true -o custom-columns=NAME:.metadata.name,DISPLAY:.metadata.annotations.openshift\\.io/display-name

# To author a LlamaStackDistribution you need a valid spec.server.distribution
# (name or image). Capture any existing LSD to copy, plus the operator's
# distribution image map and RELATED_IMAGE_* env.
if has_crd llamastackdistributions.llamastack.io; then
  cap lsd-all.txt "${OC[@]}" get llamastackdistributions.llamastack.io -A -o wide
  cap lsd-all.yaml "${OC[@]}" get llamastackdistributions.llamastack.io -A -o yaml
  LSD_OP_NS="$("${OC[@]}" get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="llama-stack-k8s-operator-controller-manager")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | list_clean | head -1)"
  if [ -n "$LSD_OP_NS" ]; then
    cap lsd-operator-cm.txt "${OC[@]}" get cm -n "$LSD_OP_NS"
    for c in $("${OC[@]}" get cm -n "$LSD_OP_NS" -o name 2>/dev/null | list_clean | grep -iE 'distribution|image'); do
      cap "lsd-distributions-$(basename "$c").yaml" "${OC[@]}" get "$c" -n "$LSD_OP_NS" -o yaml
    done
    "${OC[@]}" get deploy llama-stack-k8s-operator-controller-manager -n "$LSD_OP_NS" \
      -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
      | grep -iE 'image|distribution' | capf lsd-operator-env.txt
    if nonempty lsd-distributions-llama-stack-config.yaml || nonempty lsd-operator-env.txt; then
      finding OK lsd-images "Captured LlamaStack distribution image map — see raw/lsd-*."
    else
      finding WARN lsd-images "Could not find the LlamaStack distribution image map in $LSD_OP_NS." \
        "Needed to author an LSD by hand: oc get cm -n $LSD_OP_NS"
    fi
  fi
fi

# ------------------------------------------------------------- J. probes ----
if [ "$DO_GW_PROBE" = 1 ] && [ -n "${GW_HOST:-}" ]; then
  sec "J. Gateway probes from this workstation"
  TOKEN="$("${OC[@]}" whoami -t 2>/dev/null)"
  {
    probe "GET https://$GW_HOST/v1/models" "https://$GW_HOST/v1/models" "Authorization: Bearer $TOKEN"
    probe "GET https://$GW_HOST/maas-api/v1/models" "https://$GW_HOST/maas-api/v1/models" "Authorization: Bearer $TOKEN"
  } | capf gateway-probes.txt
  cat "$RAW/gateway-probes.txt" | sed 's/^/    /'
  grep -qE ' (200|401|403) ' "$RAW/gateway-probes.txt" \
    && finding OK gw-reachable "Gateway answered (see raw/gateway-probes.txt)." \
    || finding FAIL gw-reachable "Gateway did not answer — DNS, LB or listener problem."
fi

[ -n "$PROVIDER_URL" ] || PROVIDER_URL="${PROVIDER_BASE_URL:-}"
if [ "$DO_EGRESS" = 1 ] && [ -n "$PROVIDER_URL" ]; then
  sec "K. In-cluster egress to provider"
  EG_NS="${NAMESPACES[0]}"
  ns_exists "$EG_NS" || EG_NS="default"
  # 'oc run --rm -i' loses the output when the image pull outlives the attach
  # (first pull here took 1m37s and produced an empty capture). Run detached,
  # poll for completion, then read the logs.
  EG_POD="egress-test-$$"
  "${OC[@]}" run "$EG_POD" --restart=Never -n "$EG_NS" \
    --image=registry.access.redhat.com/ubi9/ubi-minimal --command -- \
    curl -sS -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' "${PROVIDER_URL%/}/models" \
    >/dev/null 2>&1
  for _ in $(seq 1 60); do
    case "$(ocj pod "$EG_POD" -n "$EG_NS" -o jsonpath='{.status.phase}')" in
      Succeeded|Failed) break ;;
    esac
    sleep 5
  done
  "${OC[@]}" logs "$EG_POD" -n "$EG_NS" 2>&1 | tail -5 | capf egress-test.txt
  "${OC[@]}" delete pod "$EG_POD" -n "$EG_NS" --wait=false >/dev/null 2>&1
  cat "$RAW/egress-test.txt" | sed 's/^/    /'
  grep -qE 'HTTP (200|401|403)' "$RAW/egress-test.txt" \
    && finding OK egress "Cluster can reach the provider." \
    || finding FAIL egress "Cluster cannot reach ${PROVIDER_URL} — fix egress/proxy/CA first." \
         "Check egress firewall, cluster-wide proxy, and PROVIDER_CA_BUNDLE_FILE."
fi

# ------------------------------------------------- L. discovered config -----
sec "L. Discovered install parameters"

DISCOVERED="$OUTDIR/config.env.discovered"
{
  echo "# Generated by scripts/00-discover.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "# Values observed on ${API_HOST}. Review before sourcing."
  echo
  echo "export MAAS_NS=\"${NAMESPACES[0]}\""
  echo "export APP_NS=\"${APP_NS_GUESS}\""
  echo "export TENANT_NS=\"${TENANT_NS_GUESS}\""
  echo "export OPERATOR_NS=\"$("${OC[@]}" get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -E 'ods-operator|opendatahub-operator' | head -1)\""
  echo "export GATEWAY_NS=\"${GW_NS:-maas-gateway}\""
  echo "export GATEWAY_NAME=\"${GW_NAME:-maas-default-gateway}\""
  echo "export GATEWAY_HOSTNAME=\"${GW_HOST:-}\""
  echo "export GATEWAY_CLASS=\"$("${OC[@]}" get gatewayclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)\""
  echo "export CLUSTER_DOMAIN=\"${CLUSTER_DOMAIN}\"   # apps wildcard reported by the ingress config"
  echo "export TENANT_NAME=\"$("${OC[@]}" get tenants.maas.opendatahub.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)\""
  echo
  echo "# Fill these in yourself:"
  echo "# export MODEL_NAME=..."
  echo "# export PROVIDER_BASE_URL=...   # must end in /v1"
  echo "# export PROVIDER_MODEL_ID=..."
  echo "# export PROVIDER_API_KEY=..."
} > "$DISCOVERED"
note "wrote $DISCOVERED"
sed 's/^/    /' "$DISCOVERED"

# -------------------------------------------------------------- summary -----
sec "SUMMARY"

n_fail=$(count_sev FAIL)
n_warn=$(count_sev WARN)
n_ok=$(count_sev OK)

{
  echo
  echo "## Summary"
  echo
  echo "| severity | count |"
  echo "|---|---|"
  echo "| FAIL | $n_fail |"
  echo "| WARN | $n_warn |"
  echo "| PASS | $n_ok |"
  echo
  echo "### Blocking problems (in order)"
  echo
  awk -F'\t' '$1=="FAIL"{printf "%d. **%s** — %s\n", ++i, $2, $4; if ($5!="") printf "   - fix: `%s`\n", $5}' "$FINDINGS"
  echo
  echo "### Warnings"
  echo
  awk -F'\t' '$1=="WARN"{printf "- **%s** — %s\n", $2, $4; if ($5!="") printf "  - fix: `%s`\n", $5}' "$FINDINGS"
} >> "$REPORT"

printf '%sPASS %s   WARN %s   FAIL %s%s\n\n' "$C_OK" "$n_ok" "$n_warn" "$n_fail" "$C_OFF"
if [ "$n_fail" -gt 0 ]; then
  printf '%sBlocking problems:%s\n' "$C_FAIL" "$C_OFF"
  awk -F'\t' '$1=="FAIL"{printf "  %d. %s\n", ++i, $4; if ($5!="") printf "     fix: %s\n", $5}' "$FINDINGS"
fi

printf '\nbundle:  %s\n' "$OUTDIR"
printf 'report:  %s\n' "$REPORT"
printf 'config:  %s\n' "$DISCOVERED"

if [ "$DO_ARCHIVE" = 1 ]; then
  ( cd "$(dirname "$OUTDIR")" && tar -czf "$(basename "$OUTDIR").tgz" "$(basename "$OUTDIR")" ) 2>/dev/null \
    && printf 'archive: %s.tgz  (secrets redacted — safe to share)\n' "$OUTDIR"
fi

[ "$n_fail" -gt 0 ] && exit 1
exit 0
