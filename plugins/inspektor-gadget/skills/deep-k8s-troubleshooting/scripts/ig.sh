#!/usr/bin/env bash
# ig.sh — run Inspektor Gadget on a Kubernetes node via `kubectl debug`.
# Ships with the deep-k8s-troubleshooting skill; only `kubectl` is required.
#
# Usage:
#   ig.sh --pod  <pod> <namespace> <ig-args...>   # auto-resolve the pod's node
#   ig.sh --node <node>            <ig-args...>   # target a node directly
#
# Examples:
#   ig.sh --pod web-0 shop run trace_dns --filter 'rcode_raw!=0' --timeout 30
#   ig.sh --pod web-0 shop run trace_dns --help
#   ig.sh --node aks-nodepool1-xxx image inspect trace_tcp --show-datasources
#
# Env:
#   IG_VERSION  IG release tag (default v0.54.1)
#   IG_IMAGE    full ig image ref (default mcr.microsoft.com/oss/v2/inspektor-gadget/ig:$IG_VERSION)
set -euo pipefail

IG_VERSION="${IG_VERSION:-v0.54.1}"
IG_IMAGE="${IG_IMAGE:-mcr.microsoft.com/oss/v2/inspektor-gadget/ig:$IG_VERSION}"

usage() { sed -n '2,17p' "$0"; exit "${1:-0}"; }

[ $# -ge 1 ] || usage 1
case "$1" in
  --pod)
    [ $# -ge 4 ] || { echo "error: --pod needs <pod> <namespace> <ig-args...>" >&2; exit 1; }
    pod="$2"; ns="$3"; shift 3
    node="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.nodeName}')"
    [ -n "$node" ] || { echo "error: pod $pod in ns $ns not found (or no node assigned)" >&2; exit 1; }
    ;;
  --node)
    [ $# -ge 2 ] || { echo "error: --node needs <node> <ig-args...>" >&2; exit 1; }
    node="$2"; shift 2
    ;;
  -h|--help) usage 0 ;;
  *) echo "error: first arg must be --pod or --node" >&2; usage 1 ;;
esac

[ $# -ge 1 ] || { echo "error: no ig arguments given" >&2; exit 1; }

# `ig run` needs an explicit version tag; append the pinned one if the caller
# passed a bare gadget name (e.g. `run trace_dns`).
args=("$@")
if [ "${args[0]}" = "run" ] && [ "${#args[@]}" -ge 2 ]; then
  case "${args[1]}" in
    -*|*:*) : ;;                       # a flag, or already tagged (name:tag)
    *) args[1]="${args[1]}:${IG_VERSION}" ;;
  esac
fi

exec kubectl debug --profile=sysadmin "node/${node}" --attach --quiet \
  --image="${IG_IMAGE}" -- ig "${args[@]}"
