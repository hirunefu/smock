---
status: accepted
---

# The Journal's default byte bound follows the memory limit

Decided by the maintainer on 2026-10-14. The Journal's byte bound used to default to 64 MiB whatever the Pod, which is more than the smallest GKE Autopilot Pod where Pods may burst (52Mi): the benchmark under that Pod's limits (`bench/plan-autopilot.json`, on an M1) saw smock's cgroup peak at 42 MiB, and at 66 MiB under 1 CPU and 4Gi at high rates. So, when neither `--journal-max-bytes` nor `SMOCK_JOURNAL_MAX_BYTES` sets the bound, smock reads at startup the memory limit of its own cgroup (`memory.max` of the cgroup v2 that `/proc/self/cgroup` names, under `/sys/fs/cgroup`) and uses a quarter of it, rounded down, at least 1 MiB and at most 64 MiB. Without a limit, or when it cannot be read, the bound stays 64 MiB. An explicit setting always wins. A quarter leaves the rest of the limit to what the bound does not count: the definition set (idle RSS was 14.5 to 16.4 MiB with the benchmark's), connection and TLS buffers, the allocator, and the gap between what entries count (256 bytes plus two per character plus the kept body) and what they take. The 1 MiB floor keeps a tiny limit recording something: about 28 entries with a full 16 KiB head and a 4 KiB body, or about 650 of the benchmark's request mix.

The cgroup is read only by the native server (`server/memory_limit.mbt`); the rule and the file formats are in the settings package, which does no I/O, so they are tested on wasm-gc too, and the engine still just takes a number. smock logs the bound at startup with its source (`flag`, `variable`, `memoryLimit`, `minimum` or `default`) and the limit it read. The Admin API status does not show Journal settings, so it does not show the bound either.

## Considered Options

- **Keep 64 MiB and let the Helm chart or the operator set the bound.** Rejected: a Pod spec outside the chart, or a lowered memory limit, would silently keep a bound larger than the Pod, and the limit is already known to the process.
- **Read the limits of the parent cgroups too.** Rejected for now: the rule reads only smock's own cgroup, which in a Kubernetes container on cgroup v2 is the container's limit. A tighter limit set only on a parent slice (possible outside Kubernetes) is not seen; `--journal-max-bytes` covers that case.

## Consequences

- The same flags give a different Journal in a different Pod: under 52Mi the bound is 13 MiB, about 8,400 entries of the benchmark's mix, so the byte bound, not the 10,000-entry bound, decides when entries are evicted there. From a 256Mi limit up nothing changes. The startup log says which bound is in use and why.
- The default is no longer one number, so `smock serve --help` describes the rule instead of printing a default for `--journal-max-bytes`.

## Follow-up, 2026-10-20

Request conditions on form fields and XML paths add values to what an entry counts. An entry's Near miss keeps the values of failed form fields and XML paths, in order, until their total reaches `--journal-body-limit`; the last one kept is cut, and the rest are left out. Each value kept counts its bytes and a fixed 32 bytes more (provisional), toward that total and toward the byte bound, so that a body with many empty or tiny values cannot make an entry take far more than it counts. Before the total and the 32 bytes, one 4 MiB request could keep tens of MiB in a single entry that counted under a kilobyte. This note does not change the decision.
