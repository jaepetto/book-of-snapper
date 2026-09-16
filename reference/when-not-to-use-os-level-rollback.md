# When not to use OS-level rollback

OS-level rollback — whether via `snapper rollback` or a hypervisor
snapshot revert — reverts local disk state with no awareness of peers,
replication, or consensus. It's safe exactly when a host's disk is the
*only* source of truth for what that host is doing, and unsafe whenever
another system holds an independent, still-advancing view of state the
host was part of. For the full explanation and worked examples, see the
[subvolume layout](../concepts/subvolume-layout.md) page — this page is a
fast lookup, not a re-read of that one.

## Two separate questions, easy to conflate

| Axis | Question | Answer |
|---|---|---|
| **Mechanism** — how to revert OS state | VM with a hypervisor snapshot fallback, or bare metal? | VM → hypervisor snapshot; bare metal → snapper (or equivalent) |
| **Eligibility** — whether reverting OS state is safe at all | Does this host hold cluster/replication state another system depends on staying monotonic? | If yes → **neither mechanism is safe**; exclude from OS-level rollback entirely |

The mistake to avoid: concluding "snapper is unsafe here, use a VM
snapshot instead" for a host that fails the eligibility check. A VM
snapshot revert is exactly the same kind of local, offline,
no-peer-awareness disk-state revert as `snapper rollback` — switching
mechanism fixes nothing. A host that fails eligibility needs a **different
recovery strategy entirely**, not a different disk-snapshot tool.

## Quick host-class check

- **Generally safe** — a plain OS + application-config host, a stateless
  web or application server, a CI runner: anywhere the disk genuinely is
  the sole source of truth for what the host is doing.
- **Not safe — exclude from OS-level rollback entirely**:
  - A Raft/consensus store member (etcd and similar) — reverting one
    member's WAL resurrects it with a stale but internally *consistent*
    log; unlike a crash, peers have no signal this happened.
  - A database primary — reverts transactions already acknowledged to
    clients or shipped to replicas, leaving replicas ahead of a
    "resurrected" primary.
  - A Kubernetes node — reverting kubelet/containerd state produces a node
    claiming resources (pods, IPs, volumes) it no longer holds, a desync
    the node can't detect locally.
- **Ask first** — anything replicating to or from another system, or
  anything another service depends on for state it can't independently
  reconstruct.

## A partial mitigation — untested, worth evaluating

The exclusion above is about the **data/cluster-state layer**, not
necessarily the whole machine. The OS/package layer of a k8s node or DB
host (kernel, base packages, non-data config) is, in principle, just as
rollback-eligible as any other host. A layout that puts a service's own
data directory (`/var/lib/<service>`) on its own subvolume, excluded from
rollback — the same pattern already used for `/var/log` and similar
directories — could let a rollback revert the surrounding OS without
touching that service's data at all. This has not been proven here; it
depends heavily on whether the service in question can tolerate its
binaries and configuration reverting out from under a data directory that
didn't. Flagged as a real option worth evaluating, not a recommendation.

## Real recovery paths for excluded host classes

These stay independent of anything in this book — they're already the
standard operational answer for each host class:

- **etcd / Raft store**: snapshot/restore plus member replacement.
- **Database primary**: replica promotion, or point-in-time recovery from
  WAL/backup.
- **Kubernetes node**: drain and replace.

## Further reading

- [Subvolume layout](../concepts/subvolume-layout.md) — the full
  narrative and citations behind this reference.
