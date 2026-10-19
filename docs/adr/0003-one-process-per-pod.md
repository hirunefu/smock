---
status: accepted
---

# One smock process per Pod; scale by adding Pods

A smock Pod runs a single single-threaded process, and capacity grows by adding Pods, not processes. Ephemeral Stubs, Scenario state and the Journal live in the process that received them (ADR 0002), and SO_REUSEPORT spreads connections across processes by a hash of their addresses and ports, so several processes in one Pod would split that state exactly as several replicas do, with no way to steer a Session to the right one. One process is also enough for a first release: in the 2026-10 prototype (one laptop core, loopback, a fixed response), a single MoonBit process with its own HTTP/1.1 parser served about 300k requests per second under a 1-CPU limit. smock's real request path (matching, Journal, templates) will cost more and has not been measured yet.

## Considered Options

- **Several processes per Pod sharing the port with SO_REUSEPORT.** In the same prototype, two processes gave about 1.7 times the throughput and roughly halved p99 above 30k requests per second under a 2-CPU limit. Rejected because it splits per-Session state inside one Pod. It remains an option for stateless load tests if measurements of smock's real request path ever need it.

## Consequences

- A CPU limit above one core does not make a Pod faster; Helm values should request about one core per Pod and scale replicas instead.
- CPU limits below one core (CFS throttling of the single thread) were not measured yet and must be covered by the release benchmark.

## Follow-up, 2026-10-19

The release benchmark has since measured smock's real request path, under CPU limits below one core too. On GKE Autopilot, one process under a 1-CPU limit served about 19,000 to 21,000 requests per second over plain HTTP on x86 nodes, and about 50,000 on Arm. The chart's [sizing table](../../charts/smock/README.md#sizing) has the numbers for each Pod size, and [bench/README.md](../../bench/README.md#targets) the provisional targets and where they come from. This note does not change the decision.
