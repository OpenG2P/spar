#!/usr/bin/env bash
#
# uninstall-spar.sh
# -----------------
# Cleanly uninstall an OpenG2P SPAR Helm release and every resource it touched,
# including the PostgreSQL database and role that live inside the
# commons-postgresql instance (which are NOT owned by the SPAR Helm release and
# therefore survive `helm uninstall`).
#
# What it does, in order:
#   1. helm uninstall <release>            (spar-mapper-api + bene-portal-api
#                                           workloads, services, helm-owned
#                                           secrets & configmaps, istio
#                                           virtualservices/gateways, etc.)
#   2. Delete leftover Jobs + their Pods   (subchart jobs: postgres-init and
#                                           keycloak-init)
#   3. Sweep leftover Secrets/ConfigMaps   (label: app.kubernetes.io/instance)
#                                           — EXCLUDING the keycloak-init client
#                                           secret(s), which are kept intact.
#   4. Drop Postgres database + role       (via `kubectl exec` into
#                                           commons-postgresql-0)
#   5. Delete PVCs by label                (app.kubernetes.io/instance)
#   6. Delete PVs still bound to those PVCs
#      (typically `Released` PVs created with reclaimPolicy=Retain)
#
# Database dropped (only the one THIS chart's postgres-init creates):
#   - <release-underscored>            e.g. release "spar"  -> db "spar"
#                                           release "spar-x" -> db "spar_x"
# It does NOT drop databases owned by other components.
#
# KEYCLOAK CLIENT SECRETS ARE KEPT INTACT.
#   keycloak-init creates a K8s Secret named after the OIDC clientId
#   (default: openg2p-spar, key: client_secret) carrying
#   `helm.sh/resource-policy: keep`, so `helm uninstall` already leaves it.
#   The Secret sweep in step 3 additionally EXCLUDES anything labeled
#   `app.kubernetes.io/name=keycloak-init`, so the auto-generated client
#   password is preserved across uninstall/reinstall. Pass
#   --purge-keycloak-secrets to delete them too.
#
# Requires: kubectl (cluster admin), helm, jq, bash 4+.
#
# USAGE:
#   ./uninstall-spar.sh \
#       --namespace <ns> \
#       [--release <name>]            (default: spar)
#       [--postgres-release <name>]   (default: commons-postgresql)
#       [--postgres-namespace <ns>]   (default: same as --namespace)
#       [--purge-keycloak-secrets]    (ALSO delete keycloak-init client secrets)
#       [--keep-pvs]                  (delete PVCs but not PVs)
#       [--dry-run]                   (print actions, change nothing)
#       [--yes]                       (skip interactive confirmation)
#
# EXAMPLES:
#   # Dry run first — no changes made:
#   ./uninstall-spar.sh --namespace trial --dry-run
#
#   # For real, with confirmation prompt:
#   ./uninstall-spar.sh --namespace trial
#
#   # Non-interactive (CI / scripted):
#   ./uninstall-spar.sh --namespace trial --yes

set -euo pipefail

# ---------- defaults ----------
RELEASE="spar"
NAMESPACE=""
POSTGRES_RELEASE="commons-postgresql"
POSTGRES_NAMESPACE=""
PURGE_KEYCLOAK_SECRETS=false
KEEP_PVS=false
DRY_RUN=false
ASSUME_YES=false

# keycloak-init subchart name (label app.kubernetes.io/name on its resources).
# Only change this if the chart sets keycloak-init.nameOverride.
KEYCLOAK_INIT_NAME="keycloak-init"

# ---------- cli ----------
usage() { sed -n '2,60p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)              RELEASE="$2";              shift 2 ;;
    --namespace|-n)         NAMESPACE="$2";            shift 2 ;;
    --postgres-release)     POSTGRES_RELEASE="$2";     shift 2 ;;
    --postgres-namespace)   POSTGRES_NAMESPACE="$2";   shift 2 ;;
    --purge-keycloak-secrets) PURGE_KEYCLOAK_SECRETS=true; shift ;;
    --keep-pvs)             KEEP_PVS=true;             shift ;;
    --dry-run)              DRY_RUN=true;              shift ;;
    --yes|-y)               ASSUME_YES=true;           shift ;;
    -h|--help)              usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { echo "ERROR: --namespace is required"; exit 1; }
[[ -z "$POSTGRES_NAMESPACE" ]] && POSTGRES_NAMESPACE="$NAMESPACE"

# ---------- derived: DB / user names (templated exactly like values.yaml) ----------
# values.yaml (global):
#   sparDB:     '{{ printf "%s" .Release.Name | replace "-" "_" }}'
#   sparDBUser: '{{ printf "%s_user" .Release.Name | replace "-" "_" }}'
RELEASE_UNDERSCORED="${RELEASE//-/_}"
SPAR_DB="${RELEASE_UNDERSCORED}"
SPAR_USER="${RELEASE_UNDERSCORED}_user"

# ---------- helpers ----------
_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
_green() { printf "\033[32m%s\033[0m\n" "$*"; }
_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

run() {
  # Print + execute, or just print if --dry-run.
  # Never aborts the script on non-zero exit — cleanup commands must be
  # idempotent. Already-deleted resources produce a notice and we move on.
  echo "  \$ $*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@" || _yellow "  (command returned non-zero — continuing)"
  fi
}

kexec_psql() {
  # Run SQL as postgres superuser inside the commons-postgresql pod.
  # Uses PGPASSWORD from the pod's env so no secret reads are needed on
  # the admin's machine. Tolerant of failure — script continues.
  local sql="$1"
  local cmd=(kubectl exec -n "$POSTGRES_NAMESPACE" "$PG_POD" -c postgresql -- \
             bash -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U postgres -v ON_ERROR_STOP=0 -c \"$sql\"")
  echo "  \$ psql -U postgres -c \"$sql\""
  if [[ "$DRY_RUN" == false ]]; then
    "${cmd[@]}" || _yellow "  (psql returned non-zero — continuing)"
  fi
}

# Secret label selector for the sweep. Excludes keycloak-init client secret(s)
# unless the operator explicitly opts in to purging them.
if [[ "$PURGE_KEYCLOAK_SECRETS" == true ]]; then
  SECRET_SELECTOR="app.kubernetes.io/instance=$RELEASE"
else
  SECRET_SELECTOR="app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name!=$KEYCLOAK_INIT_NAME"
fi

# ---------- pre-flight ----------
_blue "==> Pre-flight checks"

command -v kubectl >/dev/null || { _red "kubectl not found"; exit 1; }
command -v helm    >/dev/null || { _red "helm not found";    exit 1; }
command -v jq      >/dev/null || { _red "jq not found";      exit 1; }

if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  NAMESPACE_EXISTS=true
  _green "  Namespace '$NAMESPACE' exists"
else
  NAMESPACE_EXISTS=false
  _yellow "  Namespace '$NAMESPACE' does not exist — namespace-scoped cleanup will be skipped"
fi

# Locate commons-postgresql pod. Bitnami's chart gives it these labels.
PG_POD=""
if kubectl get ns "$POSTGRES_NAMESPACE" >/dev/null 2>&1; then
  PG_POD=$(kubectl get pod -n "$POSTGRES_NAMESPACE" \
    -l "app.kubernetes.io/instance=$POSTGRES_RELEASE,app.kubernetes.io/name=postgresql" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  # Fallback: by name.
  if [[ -z "$PG_POD" ]]; then
    if kubectl get pod -n "$POSTGRES_NAMESPACE" "${POSTGRES_RELEASE}-0" >/dev/null 2>&1; then
      PG_POD="${POSTGRES_RELEASE}-0"
    fi
  fi
fi

if [[ -z "$PG_POD" ]]; then
  PG_POD_FOUND=false
  _yellow "  commons-postgresql pod not found — DB / role drop step will be skipped"
  _yellow "  (tried label app.kubernetes.io/instance=$POSTGRES_RELEASE and pod name ${POSTGRES_RELEASE}-0 in namespace '$POSTGRES_NAMESPACE')"
else
  PG_POD_FOUND=true
  _green "  Found Postgres pod: $PG_POD (namespace: $POSTGRES_NAMESPACE)"
fi

# Helm release presence is not strictly required (user may have already uninstalled
# and is now running the cleanup half). Note it but don't abort.
if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  _green "  Helm release '$RELEASE' found in namespace '$NAMESPACE'"
  HELM_RELEASE_EXISTS=true
else
  _yellow "  Helm release '$RELEASE' not found — will skip helm uninstall step"
  HELM_RELEASE_EXISTS=false
fi

# ---------- build the DB drop list ----------
DBS_TO_DROP=("$SPAR_DB")
ROLES_TO_DROP=("$SPAR_USER")

# ---------- show the blast radius ----------
_blue "==> Plan"

echo
echo "Will DELETE:"
echo "  - Helm release:        $RELEASE (namespace: $NAMESPACE)"
echo "  - Postgres database:   ${DBS_TO_DROP[*]}   (dropped INSIDE postgres via the SQL below)"
echo "  - Postgres role:       ${ROLES_TO_DROP[*]}"
echo "  - namespace resources: Jobs/ConfigMaps/PVCs/PVs labeled app.kubernetes.io/instance=$RELEASE"
echo "  - Secrets matching:    $SECRET_SELECTOR"
echo
echo "Will PRESERVE (NOT deleted):"
echo "  - Postgres instance/pod: ${PG_POD:-<not found — DB drop will be skipped>} ($POSTGRES_NAMESPACE)"
echo "      (the script only 'kubectl exec's into it to DROP the database/role above)"
echo "  - Other databases owned by other components"
if [[ "$PURGE_KEYCLOAK_SECRETS" == false ]]; then
  echo "  - Keycloak client secrets: any Secret labeled app.kubernetes.io/name=$KEYCLOAK_INIT_NAME"
  echo "      (e.g. 'openg2p-spar' — the OIDC client password, kept for reinstall)"
else
  _yellow "  - (--purge-keycloak-secrets given: keycloak client secrets WILL be deleted)"
fi
echo

if [[ "$NAMESPACE_EXISTS" == true ]]; then
  echo "Jobs (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get job -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "Secrets to delete ($SECRET_SELECTOR):"
  kubectl -n "$NAMESPACE" get secret -l "$SECRET_SELECTOR" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "Secrets to KEEP (label app.kubernetes.io/name=$KEYCLOAK_INIT_NAME):"
  kubectl -n "$NAMESPACE" get secret \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=$KEYCLOAK_INIT_NAME" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "ConfigMaps (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get configmap -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "PVCs (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get pvc -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"
else
  echo "(namespace '$NAMESPACE' does not exist — no namespace-scoped resources to preview)"
fi

if [[ "$KEEP_PVS" == false ]]; then
  echo "PVs to delete (Released/Failed in '$NAMESPACE', or labeled instance=$RELEASE):"
  # Mirror the step-6 deletion criteria EXACTLY so we never preview (or scare the
  # operator with) Bound PVs that belong to other components in this namespace.
  kubectl get pv -o json 2>/dev/null | \
    jq -r --arg ns "$NAMESPACE" --arg rel "$RELEASE" \
      '.items[] | select((((.spec.claimRef.namespace==$ns) and (.status.phase=="Released" or .status.phase=="Failed"))) or (.metadata.labels["app.kubernetes.io/instance"]==$rel)) | "  - " + .metadata.name + " (" + .status.phase + ")"' \
    2>/dev/null | sort -u || echo "  (none)"
fi
echo

# ---------- confirmation ----------
if [[ "$DRY_RUN" == true ]]; then
  _yellow "DRY-RUN: no changes will be made."
fi

if [[ "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
  _red "This is destructive. Type the release name ('$RELEASE') to confirm:"
  read -r CONFIRM
  if [[ "$CONFIRM" != "$RELEASE" ]]; then
    _red "Confirmation did not match. Aborting."
    exit 1
  fi
fi

# ========== STEP 1: helm uninstall ==========
_blue "==> [1/6] Helm uninstall"
if [[ "$HELM_RELEASE_EXISTS" == true ]]; then
  run "helm uninstall '$RELEASE' -n '$NAMESPACE' --wait --timeout 5m || true"
else
  echo "  (skipped — release not present)"
fi

# ========== STEP 2: delete leftover Jobs (and their Pods) ==========
# Subchart Jobs (postgres-init, keycloak-init) may linger after uninstall.
# Delete them BEFORE dropping the DB, so their Pods close Postgres connections
# cleanly. This deletes Jobs only — the keycloak client SECRET is untouched.
_blue "==> [2/6] Delete leftover Jobs and their Pods"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete job -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found --wait=true --timeout=2m"
  # Orphan pods (completed/failed) that a Job left behind after TTL etc.
  run "kubectl -n '$NAMESPACE' delete pod -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found --field-selector=status.phase!=Running"
else
  echo "  (skipped — namespace '$NAMESPACE' not present)"
fi

# ========== STEP 3: sweep leftover Secrets & ConfigMaps ==========
# Secret sweep uses $SECRET_SELECTOR, which (unless --purge-keycloak-secrets)
# EXCLUDES app.kubernetes.io/name=keycloak-init so the OIDC client secret(s)
# are kept intact.
_blue "==> [3/6] Sweep leftover Secrets / ConfigMaps"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete secret    -l '$SECRET_SELECTOR' --ignore-not-found"
  run "kubectl -n '$NAMESPACE' delete configmap -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found"
else
  echo "  (skipped — namespace '$NAMESPACE' not present)"
fi

# ========== STEP 4: drop Postgres DB & role ==========
_blue "==> [4/6] Drop Postgres database and role"
if [[ "$PG_POD_FOUND" == true ]]; then
  for db in "${DBS_TO_DROP[@]}"; do
    echo "  - Database: $db"
    kexec_psql "REVOKE CONNECT ON DATABASE \\\"$db\\\" FROM PUBLIC;"
    kexec_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();"
    kexec_psql "DROP DATABASE IF EXISTS \\\"$db\\\";"
  done

  for role in "${ROLES_TO_DROP[@]}"; do
    echo "  - Role: $role"
    # Reassign/drop stray ownership outside the dropped DBs (roles can own cluster-wide objects).
    kexec_psql "REASSIGN OWNED BY \\\"$role\\\" TO postgres;"
    kexec_psql "DROP OWNED BY \\\"$role\\\";"
    kexec_psql "DROP ROLE IF EXISTS \\\"$role\\\";"
  done
else
  echo "  (skipped — commons-postgresql pod not reachable; if Postgres is already gone, DBs are gone too)"
fi

# ========== STEP 5: PVCs ==========
_blue "==> [5/6] Delete PVCs"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete pvc -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found"
else
  echo "  (skipped — namespace '$NAMESPACE' not present; any orphan PVs handled in step 6)"
fi

# ========== STEP 6: PVs ==========
_blue "==> [6/6] Delete PVs"
if [[ "$KEEP_PVS" == true ]]; then
  _yellow "  (skipped — --keep-pvs)"
else
  # Any PV that still references a PVC in $NAMESPACE (now Released/Failed after
  # step 5), plus any PV labeled with our release at creation time.
  pv_list=$(kubectl get pv -o json 2>/dev/null | \
    jq -r --arg ns "$NAMESPACE" \
      '.items[] | select(.spec.claimRef.namespace==$ns) | select(.status.phase=="Released" or .status.phase=="Failed") | .metadata.name' \
    2>/dev/null || true)
  pv_labeled=$(kubectl get pv -l "app.kubernetes.io/instance=$RELEASE" \
                 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  pv_all=$(echo "$pv_list $pv_labeled" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')

  if [[ -z "$pv_all" ]]; then
    echo "  (no PVs to delete)"
  else
    for pv in $pv_all; do
      run "kubectl delete pv '$pv' --ignore-not-found"
    done
  fi
fi

echo
_green "==> Done."
if [[ "$DRY_RUN" == true ]]; then
  _yellow "    (dry-run — nothing was actually changed)"
fi
if [[ "$PURGE_KEYCLOAK_SECRETS" == false ]]; then
  _yellow "Note: Keycloak client secret(s) (e.g. 'openg2p-spar') were KEPT intact."
  _yellow "      They carry helm.sh/resource-policy: keep and are excluded from the"
  _yellow "      sweep, so a reinstall reuses the same client password."
  _yellow "      Re-run with --purge-keycloak-secrets to remove them as well."
fi
_yellow "Note: the Keycloak realm/client itself lives in Keycloak (not this"
_yellow "      namespace) and is left untouched. keycloak-init is idempotent."
