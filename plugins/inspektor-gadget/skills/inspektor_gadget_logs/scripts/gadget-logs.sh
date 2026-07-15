#!/usr/bin/env bash
# gadget-logs.sh — read data from already-running (headless) Inspektor Gadget
# instances using ONLY `kubectl get` and `kubectl logs`.
#
# No `kubectl debug`, `exec`, `attach`, `port-forward`, `kubectl gadget`, local
# `ig` binary — and NO `jq` — is required. Everything uses kubectl's built-in
# `-o custom-columns` / `-o jsonpath` plus `grep`, so it works on restricted
# kubectl surfaces such as the Azure SRE Agent. READ-ONLY: never starts, stops,
# or modifies gadgets. (If `jq` happens to be installed, `logs` can pretty/project
# with --jq; otherwise it prints the raw JSON event lines.)
#
# Precondition: IG deployed with the logs operator enabled
# (`config.operator.logs.enabled: true` in the `gadget` ConfigMap). When enabled,
# every headless instance streams its events as JSON to the gadget pods' stderr.
#
# Usage:
#   gadget-logs.sh check
#   gadget-logs.sh list
#   gadget-logs.sh show   <instanceID-or-name>
#   gadget-logs.sh logs   [--instance ID] [--gadget NAME] [--datasource DS]
#                         [--since DUR] [--tail N] [--follow] [--all] [--jq]
#
# Env:
#   GADGET_NAMESPACE   namespace IG is deployed in (default: gadget)
#   KUBECTL            kubectl binary/command (default: kubectl)
set -euo pipefail

NS="${GADGET_NAMESPACE:-gadget}"
KUBECTL="${KUBECTL:-kubectl}"
POD_SELECTOR="k8s-app=gadget"
INSTANCE_SELECTOR="type=gadget-instance"

err() { printf '%s\n' "$*" >&2; }
die() { err "error: $*"; exit 1; }
have_jq() { command -v jq >/dev/null 2>&1; }

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- check: is the logs operator enabled? --------------------------------------
cmd_check() {
  local cfg
  cfg="$($KUBECTL get cm gadget -n "$NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
  [ -n "$cfg" ] || die "could not read the 'gadget' ConfigMap in namespace '$NS' (is IG deployed there? set GADGET_NAMESPACE)"
  # Find `enabled: true` on a line following the `logs:` key under operator:.
  if printf '%s\n' "$cfg" | awk '/^[[:space:]]*logs:/{f=1;next} f&&/enabled:[[:space:]]*true/{ok=1} f&&/^[[:space:]]*[a-z].*:[[:space:]]*$/&&!/logs:/{f=0} END{exit !ok}'; then
    echo "logs operator: ENABLED — headless gadget events are written to pod logs."
    return 0
  fi
  echo "logs operator: NOT enabled — headless gadget events will NOT appear in 'kubectl logs'."
  echo "Enable via Helm value 'config.operator.logs.enabled=true', then restart the gadget pods."
  return 1
}

# --- list: running headless instances (no jq) ----------------------------------
cmd_list() {
  local out
  out="$($KUBECTL get cm -n "$NS" -l "$INSTANCE_SELECTOR" \
    -o custom-columns='INSTANCE_ID:.metadata.name,NAME:.metadata.labels.name,GADGET:.metadata.annotations.gadgetImage,NAMESPACE:.data.operator\.KubeManager\.namespace,PODNAME:.data.operator\.KubeManager\.podname,SELECTOR:.data.operator\.KubeManager\.selector,NODES:.metadata.annotations.gadgetNodes' \
    2>/dev/null || true)"
  if [ -z "$out" ] || [ "$(printf '%s\n' "$out" | wc -l)" -le 1 ]; then
    echo "No running headless gadget instances found in namespace '$NS'."
    echo "(Start one with: kubectl gadget run <gadget> --detach)"
    return 0
  fi
  printf '%s\n' "$out"
}

# --- resolve an instanceID (ConfigMap name) or human label name ----------------
resolve_instance() {
  local ref="$1" cm
  if $KUBECTL get cm "$ref" -n "$NS" -l "$INSTANCE_SELECTOR" -o name >/dev/null 2>&1; then
    printf '%s' "$ref"; return 0
  fi
  cm="$($KUBECTL get cm -n "$NS" -l "$INSTANCE_SELECTOR,name=$ref" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$cm" ] || die "no gadget instance found for '$ref' (try 'gadget-logs.sh list')"
  printf '%s' "$cm"
}

cmd_show() {
  [ $# -ge 1 ] || die "usage: gadget-logs.sh show <instanceID-or-name>"
  local cm; cm="$(resolve_instance "$1")"
  $KUBECTL get cm "$cm" -n "$NS" -o yaml
}

# --- logs: read events (grep-based; jq optional via --jq) ----------------------
cmd_logs() {
  local instance="" gadget="" datasource="" since="" tail="" follow="" all="" usejq=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance)   instance="$2"; shift 2;;
      --gadget)     gadget="$2"; shift 2;;
      --datasource) datasource="$2"; shift 2;;
      --since)      since="$2"; shift 2;;
      --tail)       tail="$2"; shift 2;;
      --follow|-f)  follow=1; shift;;
      --all)        all=1; shift;;      # include gadget-data-empty snapshots
      --jq)         usejq=1; shift;;    # project .data with jq (if installed)
      -h|--help)    usage 0;;
      *) die "unknown flag: $1";;
    esac
  done

  [ -n "$instance" ] && instance="$(resolve_instance "$instance")"

  local -a kargs=(logs -n "$NS" -l "$POD_SELECTOR" --prefix)
  [ -n "$since" ] && kargs+=(--since="$since")
  if [ -n "$follow" ]; then
    kargs+=(--follow)
  else
    kargs+=(--tail="${tail:-1000}")
  fi

  # Type filter: real data events (optionally include empty snapshots).
  local typepat='"type":"gadget-data"'

  # Stream: keep lines that look like our JSON events, then narrow by field.
  # kubectl --prefix prepends "[pod/xxx] "; the grep patterns still match since
  # they look inside the JSON. Field filters are plain substring matches.
  run_pipeline() {
    $KUBECTL "${kargs[@]}" 2>/dev/null | grep --line-buffered "$typepat" \
      | { [ -n "$all" ] && cat || grep --line-buffered -v '"type":"gadget-data-empty"'; } \
      | { [ -n "$instance" ]   && grep --line-buffered "\"instanceID\":\"$instance\""     || cat; } \
      | { [ -n "$gadget" ]     && grep --line-buffered "\"gadget\":\"$gadget\""           || cat; } \
      | { [ -n "$datasource" ] && grep --line-buffered "\"datasource\":\"$datasource\""   || cat; }
  }

  if [ -n "$usejq" ] && have_jq; then
    # Strip the kubectl "[pod/xxx] " prefix, then project .data.
    run_pipeline | sed -u 's/^[^{]*//' | jq -c --unbuffered '.data'
  else
    [ -n "$usejq" ] && err "note: jq not installed — printing raw event lines."
    run_pipeline
  fi
}

main() {
  [ $# -ge 1 ] || usage 1
  local sub="$1"; shift || true
  case "$sub" in
    check) cmd_check "$@";;
    list)  cmd_list "$@";;
    show)  cmd_show "$@";;
    logs)  cmd_logs "$@";;
    -h|--help|help) usage 0;;
    *) die "unknown subcommand '$sub' (expected: check|list|show|logs)";;
  esac
}

main "$@"
