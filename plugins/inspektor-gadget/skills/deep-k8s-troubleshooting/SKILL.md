---
name: deep-k8s-troubleshooting
description: >-
  Deep Kubernetes troubleshooting powered by eBPF using Inspektor Gadget, run
  via `kubectl debug` node (only `kubectl` required — no local `ig` binary or
  `kubectl gadget` plugin). Trace syscalls, DNS, TCP, files, exec, signals, OOM
  and capabilities live from the kernel when logs/metrics fall short. Discover a
  gadget's params and fields with `--help`, then filter to cut noise. WHEN: deep
  dive into pod/node behavior, DNS failures, connection refused/timeouts, TCP
  retransmits, CrashLoopBackOff root cause, OOMKilled, unexpected SIGKILL,
  missing file (ENOENT), permission denied (capabilities), high CPU/mem in a
  pod, slow disk/PVC I/O, in-cluster packet capture, intermittent issues,
  "trace syscalls", "run a gadget", "ebpf troubleshooting", "inspektor gadget".
license: MIT
metadata:
  author: mqasimsarfraz
  version: "1.0.0"
---

# Deep Kubernetes Troubleshooting with eBPF

Kernel-level observability for Kubernetes via **Inspektor Gadget (IG)**, run
through **`kubectl debug` on the node**. Only `kubectl` is needed — no local
`ig` binary or `kubectl gadget` plugin. Use when logs and metrics can't explain
what the kernel is doing: syscalls, packets, DNS, TCP, files, exec, signals,
OOM and capability events.

## Rules

1. **`kubectl debug` only** — never assume `ig` is installed locally.
2. **Discover before running** — get params + fields with `ig run <gadget> --help`;
   don't guess flags or field names.
3. **Filter to cut noise** — in-kernel filters first (`-c`, `--k8s-namespace`,
   `--k8s-podname`, `--k8s-selector`), then user-space `--filter 'field<op>value'`
   (prefer numeric `*_raw` fields, e.g. `error_raw!=0`).
4. **Bound every run** — always `--timeout` (even snapshots don't self-exit);
   `top` gadgets also need `--interval`/`--map-fetch-interval` + `--max-entries`.
   See [gadgets.md](references/gadgets.md).
5. **Read-only & privileged** — gadgets never modify state, but `--profile=sysadmin`
   is a privileged pod; run only with approval + RBAC. Clean up debug pods after.

## Base command

Use the bundled helper `scripts/ig.sh` — it resolves the pod's node, injects the
`kubectl debug` scaffolding, and pins the IG version. It ships with the skill, so
only `kubectl` is needed.

```bash
# scripts/ig.sh --pod <pod> <ns> <ig-args...>   (auto-resolves the node)
# scripts/ig.sh --node <node> <ig-args...>      (target a node directly)
scripts/ig.sh --pod <pod> <ns> run <gadget> [flags]
```

Everything after `run`/`image` is passed straight to `ig`, so `--help` and
`image inspect` work the same way. Override the version/image via the
`IG_VERSION` / `IG_IMAGE` env vars.

## Workflow

1. Pick a gadget for the symptom → [gadgets.md](references/gadgets.md).
2. `scripts/ig.sh --pod <pod> <ns> run <gadget> --help` to learn params + fields.
3. Run with in-kernel + `--filter` scoping and the right run-mode flags for the
   gadget type (interval/timeout).
4. For intermittent issues, start the trace *before* reproducing.

## Discovering a gadget

`--help` lists gadget params **and** every field (with descriptions) under
`--fields`:

```bash
scripts/ig.sh --pod <pod> <ns> run trace_dns --help
```

For clean, scriptable field names:

```bash
scripts/ig.sh --pod <pod> <ns> image inspect trace_dns:$IG_VERSION \
  --show-datasources --jsonpath='[0].fields[*].fullName'
```

## Reference

- [gadgets.md](references/gadgets.md) — gadget catalog, symptom map, and per-type
  run behavior (snapshot/top/trace/profile timeouts & intervals).
