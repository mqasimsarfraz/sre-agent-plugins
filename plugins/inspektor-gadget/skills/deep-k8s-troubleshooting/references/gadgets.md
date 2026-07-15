# Gadgets: catalog, symptoms & run behavior

Gadget list as of IG `v0.54.1`. **Field names differ per gadget** (e.g.
`trace_open` uses `comm`, `trace_tcp` uses `proc.comm`) — always get them from
`ig run <gadget> --help`; never hardcode.

## Run behavior by type

Each type needs specific flags to stay cheap and terminate cleanly.

| Type | Behavior | How to run |
|---|---|---|
| `snapshot` | One-shot list, but the run **does not self-exit** | **Must set `--timeout 5`** — without it the run hangs until killed. |
| `top` | Ranked aggregate, re-read each interval | Set the interval **and** cap rows: `--max-entries` defaults to `-1` (unlimited). Use e.g. `--max-entries 10` + a sort. |
| `trace` | Streams events live | `--timeout 30` (longer for rare events). Start *before* reproducing. |
| `profile` | Samples over a window | `--timeout 30`. |
| `tcpdump` | Streams pcap-ng | `--timeout 30 -o pcap-ng --pf "<expr>"`, pipe to `tcpdump -nvr -`. |

**Interval flag differs by gadget** (confirm in `--help`):
- `top_process` → `--interval` (default `3s`)
- `top_file`, `top_tcp`, `top_blockio` → `--map-fetch-interval` (default `1000ms`)

```bash
# top_process: refresh every 5s, only top 10 by CPU, ~2 reports
scripts/ig.sh --pod <pod> <ns> run top_process --interval 5s --max-entries 10 \
  --sort '-cpuUsage' --timeout 12 -o columns
```

**`traceloop`**: always pass `--syscall-filters open,connect,execve,...` to keep
the flight-recorder volume manageable.

## Catalog & symptom map

### Networking
`trace_dns` DNS failures/latency · `trace_tcp` connect/accept/close ·
`trace_tcpretrans` retransmits · `trace_tcpdrop` kernel drops/RSTs ·
`trace_bind` port conflicts · `trace_sni`/`trace_ssl` TLS routing/content ·
`snapshot_socket` open/listening sockets · `top_tcp` busiest connections ·
`tcpdump` raw capture

### Process & workload
`snapshot_process` process list · `trace_exec` what runs (CrashLoop) ·
`trace_oomkill` OOM victim + memory · `trace_signal` unexpected SIGKILL/SIGTERM ·
`top_process` CPU/mem ranking · `profile_cpu` hot stacks ·
`traceloop` catch-all (needs `--syscall-filters`) · `trace_malloc` leaks

### File & storage
`trace_open` missing files / EACCES · `trace_fsslower` slow FS ops ·
`top_file` I/O-heavy files · `snapshot_file` fd leaks · `trace_mount` mount
failures · `profile_blockio`/`top_blockio` block I/O latency

### Security & audit
`trace_capabilities` dropped-cap denials · `trace_lsm` AppArmor/SELinux ·
`audit_seccomp`/`advise_seccomp` seccomp

### Symptom → gadget
| Symptom | Gadget(s) |
|---|---|
| DNS failures | `trace_dns` |
| Connection refused / timeout | `trace_tcp` + `snapshot_socket` |
| Silent drops / RSTs / latency | `trace_tcpdrop` + `trace_tcpretrans` |
| TLS routing | `trace_sni` |
| CrashLoopBackOff | `trace_exec` + `trace_open` |
| OOMKilled | `trace_oomkill` + `top_process` |
| Killed unexpectedly | `trace_signal` |
| Missing config/secret | `trace_open` |
| Slow disk / PVC | `trace_fsslower` + `top_file` |
| Permission denied (caps) | `trace_capabilities` + `trace_lsm` |
| High CPU | `profile_cpu` + `top_process` |
| Intermittent / catch-all | `traceloop` (`--syscall-filters`) |
| Deep packet inspection | `tcpdump` |

## Filtering quick ref

- **In-kernel first** (cheap): `-c <name>`, `--k8s-namespace <ns>`,
  `--k8s-podname <pod>`, `--k8s-selector app=web` (comma lists, `!` excludes).
- **User-space** `--filter 'field<op>value'`: ops `== != >= > <= < ~`(regex).
  Comma-separate = AND. Single-quote the expression.
- **Prefer numeric `*_raw` fields for filter/sort** — many fields have a raw
  twin (`error_raw`, `rcode_raw`, `latency_ns_raw`). Filtering the string form
  (e.g. empty `error`) is unreliable; `error_raw!=0` cleanly matches failures.
- **Columns** `--fields 'f1,f2'` · **Sort** `--sort '-field'` · **Output**
  `-o columns|json|yaml`.

```bash
# Real open() failures (ENOENT/EACCES) from a pod — validated on v0.54.1
scripts/ig.sh --pod <pod> <ns> run trace_open \
  --filter 'error_raw!=0' --fields 'comm,fname,error' --timeout 30 -o columns
```
