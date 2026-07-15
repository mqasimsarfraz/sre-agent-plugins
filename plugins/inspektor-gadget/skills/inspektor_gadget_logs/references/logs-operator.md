# Logs Operator: reading running gadgets from `kubectl logs`

This reference explains the mechanism the `inspektor_gadget_logs` skill relies
on: how the **logs operator** turns headless gadget instances into readable
`kubectl logs` output, the JSON envelope schema, and how to troubleshoot.

## Why this works

Inspektor Gadget's **logs operator** (`pkg/operators/logs`) is a server-side
`DataOperator` that subscribes to every datasource of a running gadget and writes
each event as a single JSON (or logfmt) line to a channel — by default the gadget
pod's **stderr**, which Kubernetes captures as the pod log.

Because the IG DaemonSet pods run persistently, any **headless** gadget instance
(started with `--detach` or via the gadget CRD) keeps emitting events into those
pod logs for as long as it runs. So `kubectl logs` on the gadget pods is a live
feed of every running gadget's kernel-level data — no debug pod, exec, or
port-forward required.

## Precondition: enabling the operator

The operator only runs when the `gadget` ConfigMap enables it:

```yaml
# ConfigMap gadget -n gadget, key config.yaml
operator:
  logs:
    enabled: true       # required
    # channel: stderr   # stdout | stderr (default) | file
    # format:  json      # json (default) | logfmt
    # mode:    all       # all (default: attached + headless) | detached (headless only)
```

Set it via the Helm value `config.operator.logs.enabled=true` (and optionally
`config.operator.logs.channel/format/mode`). Config keys (see `logs.go`):

| Key                             | Values                          | Default  |
|---------------------------------|---------------------------------|----------|
| `operator.logs.enabled`         | bool                            | (off)    |
| `operator.logs.channel`         | `stdout` / `stderr` / `file`    | `stderr` |
| `operator.logs.format`          | `json` / `logfmt`               | `json`   |
| `operator.logs.mode`            | `all` / `detached`              | `all`    |
| `operator.logs.filename` etc.   | file rotation (channel=file)    | —        |

- **channel=stderr/stdout** → readable with `kubectl logs`. **channel=file** → the
  data goes to a file inside the pod instead and is NOT in `kubectl logs`.
- **mode=detached** → only headless instances are logged (attached CLI runs are
  skipped). **mode=all** → both. Either way, headless instances are logged.

## Running instances = gadget-instance ConfigMaps

Each headless instance is persisted as a ConfigMap in the gadget namespace,
labelled `type=gadget-instance`. The mapping the skill uses:

| Where                                              | Meaning                                  |
|----------------------------------------------------|------------------------------------------|
| `.metadata.name`                                   | **instanceID** (hex) — matches log lines |
| `.metadata.labels.name`                            | human-friendly name (e.g. `reverent_buck`)|
| `.metadata.annotations.gadgetImage`                | gadget image (e.g. `trace_dns`)          |
| `.metadata.annotations.gadgetNodes`                | node filter (empty = all nodes)          |
| `.data["operator.KubeManager.namespace"]`          | traced namespace filter                  |
| `.data["operator.KubeManager.podname"]`            | traced pod filter                        |
| `.data["operator.KubeManager.selector"]`           | traced label selector                    |
| `.data["operator.cli.fields"]`                     | fields the gadget was configured to show |

List them:

```bash
kubectl get cm -n gadget -l type=gadget-instance \
  -o custom-columns='INSTANCE_ID:.metadata.name,NAME:.metadata.labels.name,GADGET:.metadata.annotations.gadgetImage,NAMESPACE:.data.operator\.KubeManager\.namespace'
```

## The event envelope

With `format: json` (default) each event is one line. Data events:

```json
{
  "type": "gadget-data",
  "seq": 42,
  "gadget": "trace_tcp",
  "datasource": "tracetcp",
  "instanceID": "e3ccf628f17d6bd842788579fb8158c8",
  "timestamp": "2026-07-22T13:40:27.4278Z",
  "data": { "...": "the gadget's fields (k8s, proc, src, dst, ...)" }
}
```

- `type`: `gadget-data` for real events, `gadget-data-empty` for periodic empty
  snapshots (from `top`/snapshot gadgets) — filter these out unless you want them.
- `instanceID`: present **only** for headless instances (set via
  `gadgetcontext.WithID()`), and equals the gadget-instance ConfigMap name. Lines
  **without** `instanceID` come from attached CLI runs. Filter on it to isolate
  one instance.
- `gadget` / `datasource`: use these to disambiguate when several instances of
  the same gadget run, or a gadget exposes multiple datasources.
- `seq`: per-datasource monotonic counter — gaps across pods are expected because
  each node's pod has its own instance of the datasource.

With `format: logfmt` the same envelope is `key=value` pairs
(`type=gadget-data seq=42 gadget=trace_tcp ... field=value ...`).

## Reading and filtering (no jq)

The gadget namespace is a **DaemonSet**, so `-l k8s-app=gadget` aggregates all
nodes; use `--prefix` to see which pod/node produced each line.

```bash
kubectl logs -n gadget -l k8s-app=gadget --since=5m --tail=1000 --prefix \
  | grep '"type":"gadget-data"' \
  | grep -v '"gadget-data-empty"' \
  | grep '"instanceID":"<instanceID>"'
```

Narrow to specific events with more `grep` (the payload is inline JSON), e.g.
`grep -v '"rcode":"No Error"'` for DNS errors, or `grep '"type":"connect"'` for
trace_tcp connects. `jq` is optional and not available on the Azure SRE Agent.

## Troubleshooting: no events appear

1. **Operator off** — `kubectl get cm gadget -n gadget -o
   jsonpath='{.data.config\.yaml}' | grep -A2 'logs:'`. Need `enabled: true`.
2. **channel=file** — data is written to a file in the pod, not `kubectl logs`.
   Check `operator.logs.channel`.
3. **No headless instances** — `kubectl get cm -n gadget -l type=gadget-instance`
   is empty. Nothing is running; start one with `kubectl gadget run <gadget>
   --detach` (needs the `kubectl gadget` plugin / cluster admin — outside this
   read-only skill).
4. **Instance filtered too tightly** — check the instance's
   `operator.KubeManager.*` params via `show`; it may only trace a namespace/pod
   with no current activity.
5. **Window too short / rotated** — widen `--since`; pod logs are capped and old
   lines rotate out. For durable capture the operator can be set to
   `channel: file` with rotation (not readable via `kubectl logs`).
6. **Reading the wrong namespace** — set `GADGET_NAMESPACE` if IG isn't in
   `gadget`.

## Relationship to the other IG skill

- `inspektor_gadget_logs` (this skill) — **read** already-running headless
  gadgets via `kubectl get`/`kubectl logs` only. No privileges beyond read.
- `inspektor_gadget_observability` — **start** a new ad-hoc trace via `kubectl
  debug` on the node (privileged debug pod). Use it when nothing relevant is
  already running.
