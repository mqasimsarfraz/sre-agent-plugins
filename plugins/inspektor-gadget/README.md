# Inspektor Gadget Plugin

Deep Kubernetes troubleshooting powered by **eBPF** for the Azure SRE Agent,
using the CNCF [Inspektor Gadget](https://inspektor-gadget.io) project.

This is a **skills-only plugin** — it requires no MCP server. Everything runs
through `kubectl debug` on the node, so only `kubectl` access to the cluster is
needed (no local `ig` binary or `kubectl gadget` plugin).

Use it when logs and metrics can't explain what the kernel is doing: syscalls,
packets, DNS, TCP, files, exec, signals, OOM and capability events.

## What it provides

The `deep-k8s-troubleshooting` skill teaches the agent to:

- Pick the right gadget for a symptom (DNS failures, connection refused,
  CrashLoopBackOff, OOMKilled, missing files, permission denied, high CPU, slow
  disk I/O, packet capture, and more).
- Discover a gadget's params and fields with `ig run <gadget> --help` before
  building any `--filter`/`--fields` expression — it never guesses.
- Bound every run with the correct `--timeout`/`--interval` flags per gadget
  type (snapshot/top/trace/profile/tcpdump) to keep runs cheap and clean.
- Scope with in-kernel filters first, then user-space `--filter` expressions
  (preferring numeric `*_raw` fields).

### Layout

```
skills/deep-k8s-troubleshooting/
├── SKILL.md               # Rules, base command, workflow, discovery
├── references/gadgets.md  # Gadget catalog, symptom map, per-type run behavior
└── scripts/ig.sh          # Bundled kubectl-debug wrapper (only kubectl needed)
```

## Requirements

- `kubectl` configured for the target cluster.
- Permission to run `kubectl debug --profile=sysadmin node/<node>` (a privileged
  debug pod). Gadgets themselves are read-only, but the debug pod is privileged —
  run only with approval and appropriate RBAC, and clean up debug pods after.

## Quick start

```bash
# Auto-resolves the pod's node and pins the IG version.
scripts/ig.sh --pod <pod> <ns> run trace_dns --filter 'rcode_raw!=0' --timeout 30
```

Override the version/image via the `IG_VERSION` / `IG_IMAGE` environment
variables.

MIT licensed.
