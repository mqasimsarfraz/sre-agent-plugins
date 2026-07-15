# Inspektor Gadget Plugin

Read kernel-level Kubernetes observability data from **Inspektor Gadget (IG)**
for the Azure SRE Agent, using the CNCF [Inspektor Gadget](https://inspektor-gadget.io)
project.

This is a **skills-only plugin** — it requires no MCP server. It is also
**read-only** and works entirely through `kubectl get` and `kubectl logs`, so it
runs on locked-down kubectl surfaces (like the Azure SRE Agent) with **no**
`kubectl debug`, `exec`, `attach`, `port-forward`, `krew`, local `ig` binary,
`kubectl gadget` plugin — and **no `jq`**.

Use it to read what already-running gadgets are seeing from the kernel: DNS, TCP,
exec, files, signals, OOM, syscalls and more.

## How it works

When IG is deployed with the **logs operator enabled**
(`config.operator.logs.enabled: true` — the default in recent charts), every
**headless** gadget instance continuously writes its events as JSON lines to the
gadget pods' stderr. So the data is retrievable with plain `kubectl logs`.

The `inspektor_gadget_logs` skill teaches the agent to:

- Confirm the logs operator is enabled (`kubectl get cm gadget`).
- List running headless gadget instances from their `type=gadget-instance`
  ConfigMaps — the ConfigMap name is the instance's `instanceID`.
- Inspect an instance's scope (traced namespace / pod / selector / fields).
- Read and filter its events by `instanceID` / gadget / datasource using only
  `kubectl logs` + `grep` (no `jq`).

### Layout

```
skills/inspektor_gadget_logs/
├── SKILL.md                    # Rules, base command, workflow, manual commands
├── references/logs-operator.md # Envelope schema, operator config, instance map, troubleshooting
└── scripts/gadget-logs.sh      # kubectl get/logs wrapper (only kubectl + grep needed)
```

## Requirements

- `kubectl` configured for the target cluster (read access to the `gadget`
  namespace: `get configmap`, `get pods`, `logs`).
- IG deployed with the logs operator enabled and at least one **headless**
  gadget running (started out-of-band via `kubectl gadget run <gadget> --detach`
  or the gadget CRD). This plugin does **not** start gadgets — it only reads them.

## Quick start

```bash
# Is the logs operator enabled?
scripts/gadget-logs.sh check

# What headless gadgets are running? (INSTANCE_ID == ConfigMap name)
scripts/gadget-logs.sh list

# Inspect one instance's scope, then read its events (raw JSON; grep to narrow).
scripts/gadget-logs.sh show <instanceID>
scripts/gadget-logs.sh logs --instance <instanceID> --since 5m
```

Override the IG namespace with the `GADGET_NAMESPACE` env var (default `gadget`).

MIT licensed.
