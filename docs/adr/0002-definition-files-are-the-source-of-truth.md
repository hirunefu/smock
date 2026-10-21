---
status: accepted
---

# Definition files are the source of truth, and replicas share no state

What smock serves is declared in Definition files that live in version control and are mounted into each Pod as a directory. Mocks, and the Host each one answers to, come only from those files. The Admin API can add Ephemeral Stubs to an existing Mock, but they are scoped to a Session, live only in the replica that received them, and disappear on reset or restart. Replicas share no state: each one serves the same files and keeps its own Ephemeral Stubs, Scenario state and Journal. We chose this so a shared mock on Kubernetes can be managed with GitOps and stays explainable from the repository alone, and so replicas can be scaled for load tests without a shared store in the request path.

## Considered Options

- **Admin API as the source of truth (as in WireMock and mountebank).** Flexible for tests, but what a shared instance serves would then depend on whoever called it last, and nothing in Git would show it.
- **State shared across replicas, through an external store or built-in consensus (as in MockServer's clustering).** Makes Ephemeral Stubs and verification work behind any load balancer, at the cost of an extra dependency or a consensus protocol, and of store access on every request.
- **Ephemeral Mocks created through the Admin API.** Would let tests build everything through the API, but Hosts could then collide on a shared instance, and the mapping from Host to Mock would no longer be visible in the files.

## Consequences

- Tests that rely on Ephemeral Stubs, Scenarios or the Journal need one replica or session affinity.
- With no Definition files, smock starts with one empty Default Mock, so it can still be used through the Admin API alone.
- Edge builds start read-only (no Admin API) because the platforms there give no reliable process memory. A pluggable state store can be added later.

## Follow-up, 2026-10-22

Variables (spec #73) and the contents of Data buckets (spec #75) are per-replica state too, kept per Mock and Session in the replica that received the writes, beside its Ephemeral Stubs, Scenario state and Journal, and lost on restart. A Data bucket and its initial value come only from the Definition files; the Admin API reads, sets and drops one Session's copy of it, as it adds Ephemeral Stubs. This note does not change the decision.
