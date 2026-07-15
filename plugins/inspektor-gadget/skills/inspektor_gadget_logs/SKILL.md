---
name: inspektor_gadget_logs
description: >-
  Read data from ALREADY-RUNNING (headless) Inspektor Gadget instances without
  starting anything — using only `kubectl get configmap` and `kubectl logs`. When
  the logs operator is enabled, every persistent/headless gadget streams its
  events as JSON to the gadget pods' stderr, so their kernel-level data (DNS, TCP,
  exec, files, signals, OOM, syscalls, ...) is retrievable with plain `kubectl
  logs` — no `kubectl debug`, `exec`, `attach`, `port-forward`, or `kubectl gadget`
  plugin. Ideal for restricted kubectl surfaces (e.g. Azure SRE Agent). First list
  the running instances from their gadget-instance ConfigMaps, then tail and
  filter their events by instance/gadget/datasource. WHEN: "what gadgets are
  running", "list running gadgets", "read gadget output", "gadget logs", "get
  inspektor gadget events", "headless gadget data", "logs operator", "trace_dns
  results", "existing DNS/TCP trace", "gadget data via kubectl logs", "inspektor
  gadget without debug pod".
license: MIT
metadata:
  author: mqasimsarfraz
  version: "1.0.0"
---

# Reading Running Gadgets via the Logs Operator

Inspektor Gadget (IG) can run **headless** gadgets that keep tracing in the
background (started with `kubectl gadget run --detach`, `ig run --detach`, or the
gadget CRD). When IG is deployed with the **logs operator enabled**
(`config.operator.logs.enabled: true` in the `gadget` ConfigMap — the default in
recent charts), every such instance continuously writes its events as JSON lines
to the **gadget pods' stderr**.

That means you can inspect the kernel-level output of already-running gadgets with
nothing but **`kubectl get configmap`** (to discover what's running) and
**`kubectl logs`** (to read the data). No `kubectl debug`, `exec`, `attach`,
`port-forward`, `krew`, local `ig` binary, or `kubectl gadget` plugin — so it
works on locked-down kubectl surfaces such as the Azure SRE Agent.

> Use this skill to READ existing gadgets. To START a new ad-hoc trace, use the
> companion `inspektor_gadget_observability` skill (that one needs `kubectl
> debug`). This skill never starts, stops, or modifies gadgets.

## Rules

1. **Read-only, no debug pod** — only `kubectl get`/`kubectl logs`. Never `debug`,
   `exec`, `attach`, `port-forward`, or `kubectl gadget`.
2. **Discover before reading** — list running instances from their ConfigMaps
   (`-l type=gadget-instance`) and note each instance's **ConfigMap name = its
   instanceID**, plus its gadget image and filter params.
3. **Precondition: logs operator on** — data only appears in pod logs if the
   `gadget` ConfigMap has `operator.logs.enabled: true`. If it's off/absent,
   say so; don't expect events (see [logs-operator.md](references/logs-operator.md)).
4. **Filter by instanceID** — headless instances tag every line with
   `"instanceID":"<configmap-name>"`. Filter on it to isolate one gadget's output;
   lines without `instanceID` come from attached CLI runs, not headless instances.
5. **Bound the read** — always use `--since`/`--tail`; the gadget namespace is a
   DaemonSet, so `-l k8s-app=gadget` aggregates every node. Use `--prefix` to see
   which node emitted a line. Note: `kubectl logs --tail=N` is applied
   **server-side before** your instance/gadget filter, so a tiny `--tail` can hide
   matches on a busy cluster — prefer `--since` to bound, and keep `--tail` large.
6. **Each event is a JSON envelope** —
   `{type,seq,gadget,datasource,instanceID,timestamp,data}`, one per line. Filter
   by `grep`-ing the envelope fields; the payload is under `.data`. Skip
   `gadget-data-empty` lines (periodic empty snapshots).
7. **No `jq` assumed** — `jq` is NOT available on the Azure SRE Agent. Use
   `kubectl -o custom-columns`/`-o jsonpath` and `grep` only. The helper prints
   raw JSON event lines by default; it uses `jq` solely as an optional nicety
   (`--jq`) when present.

## Base command

Use the bundled helper `scripts/gadget-logs.sh` — it wraps the two `kubectl`
verbs, checks the logs operator is enabled, filters to real event lines, and
lets you scope by instance/gadget/datasource. It needs **only `kubectl` and
`grep`** (no `jq`). Override the namespace with the `GADGET_NAMESPACE` env var
(default `gadget`).

```bash
# 0. Is the logs operator enabled? (precondition)
scripts/gadget-logs.sh check

# 1. List running headless gadget instances (name, image, filters, instanceID).
scripts/gadget-logs.sh list

# 2. Show one instance's full config (which namespace/pod/fields it traces).
scripts/gadget-logs.sh show <instanceID-or-name>

# 3. Read its events (add --since/--tail to bound; --follow to stream).
#    Prints raw JSON event lines; narrow further with grep (no jq needed).
scripts/gadget-logs.sh logs --instance <instanceID> --since 5m
scripts/gadget-logs.sh logs --gadget trace_dns --since 10m --tail 200
```

Everything is plain `kubectl` under the hood, so it works anywhere `kubectl get`
and `kubectl logs` are allowed.

## Workflow

1. `scripts/gadget-logs.sh check` — confirm the logs operator is enabled.
2. `scripts/gadget-logs.sh list` — see what's running and grab the `instanceID`
   (= ConfigMap name) of the gadget matching your symptom.
3. `scripts/gadget-logs.sh show <instanceID>` — confirm its scope (namespace,
   pod, selector, fields) so you know what its events cover.
4. `scripts/gadget-logs.sh logs --instance <instanceID> --since <window>` — read
   the raw JSON events. To narrow to a field, `grep` the line (no `jq` needed):
   ```bash
   # Only failed DNS lookups (rcode != NOERROR / non-zero):
   scripts/gadget-logs.sh logs --instance <instanceID> --since 5m \
     | grep -v '"rcode":"No Error"'
   ```
   If `jq` happens to be installed you can project fields with `--jq`:
   ```bash
   scripts/gadget-logs.sh logs --instance <instanceID> --since 5m --jq \
     | jq -r '[.timestamp,.k8s.podName,.name,.rcode] | @tsv'   # jq optional
   ```
5. For live issues, add `--follow` and reproduce.

## Manual commands (no helper, no jq)

If you can't run the script, these are the exact `kubectl` calls it makes:

```bash
# Logs operator enabled?
kubectl get cm gadget -n gadget -o jsonpath='{.data.config\.yaml}' | grep -A2 'logs:'

# Running headless instances (ConfigMap name == instanceID):
kubectl get cm -n gadget -l type=gadget-instance \
  -o custom-columns='INSTANCE_ID:.metadata.name,NAME:.metadata.labels.name,GADGET:.metadata.annotations.gadgetImage,NAMESPACE:.data.operator\.KubeManager\.namespace'

# One instance's config (scope: namespace/pod/selector/fields):
kubectl get cm <instanceID> -n gadget -o yaml

# Its events — filter by instanceID, drop empty snapshots (grep only):
kubectl logs -n gadget -l k8s-app=gadget --since=5m --tail=1000 --prefix \
  | grep '"type":"gadget-data"' \
  | grep -v '"gadget-data-empty"' \
  | grep '"instanceID":"<instanceID>"'
```

## Reference

- [logs-operator.md](references/logs-operator.md) — the JSON envelope schema, how
  the logs operator is configured (channel/format/mode), how headless instances
  and their ConfigMaps map to `instanceID`, and troubleshooting when no events
  appear.
