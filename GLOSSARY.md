# smock

smock is a mock server that stands in for the services a system depends on, on Kubernetes and on developers' machines.

## Language

### Mocks and stubs

**Mock**:
A named set of Stubs that impersonates one dependency service; a request reaches a Mock by its Host.
_Avoid_: Imposter, Service, Virtual service, Simulation, Fake

**Default Mock**:
The Mock that receives requests whose Host matches no other Mock; with no Definition files, it is the only Mock and starts empty.
_Avoid_: Fallback mock, catch-all

**Stub**:
A pairing of request conditions with the response to return when a request meets them; the smallest unit of mock behaviour.
_Avoid_: Mapping, Expectation, Rule, Mock (for this concept)

**Definition file**:
A version-controlled file that declares Mocks and their Stubs; together, the definition files are the source of truth for what smock serves.
_Avoid_: Config, mapping file, ConfigMap (for the file itself)

**Ephemeral Stub**:
A Stub added to an existing Mock through the Admin API instead of a Definition file; it is discarded on reset or restart. Mocks themselves only come from Definition files.
_Avoid_: Runtime stub, overlay stub, dynamic stub

**Scenario**:
A named state machine within a Mock; its current state decides which Stubs can match, and a Stub's response can move it to another state.
_Avoid_: Flow state, state store, workflow

**Variable**:
A named JSON value kept per Mock and Session, set by a Stub's `variables` or through the Admin API, and read in templates as `vars.NAME`.
_Avoid_: Global variable, state variable

**Data bucket**:
A named JSON value that a Mock declares in Definition files, with its initial value; each Session reads and writes its own copy.
_Avoid_: dataset, collection, data store, table, fixture

**CRUD Stub**:
A Stub that serves a keyed Data bucket as a REST resource: it lists and creates items at its path, and reads, replaces, updates and deletes one item at the path plus its key.
_Avoid_: CRUD route, resource route

**Upstream**:
The real service a Mock impersonates. Forwarding the requests a Mock does not match to its Upstream, and recording the exchanges as Definition files, are not implemented.
_Avoid_: Backend, origin, target

**Fault**:
A deliberate failure a Stub injects into its response, such as a delay drawn from a distribution or a reset connection.
_Avoid_: Chaos, toxic, error injection

**Plugin**:
User-supplied Wasm code that extends how Stubs match requests or build responses, run in a sandbox (not implemented).
_Avoid_: Extension, script, injection

**Near miss**:
The Stub that came closest to matching a request that matched nothing, together with the conditions it failed.
_Avoid_: Closest match, mismatch diff

### Operating smock

**Admin API**:
The authenticated interface, on its own port, for inspecting and changing a running smock.
_Avoid_: Management API, control plane

**Session**:
A key carried on requests that scopes Ephemeral Stubs, Scenario state, Variables, the contents of Data buckets and the Journal, so concurrent tests sharing a Mock do not see each other's changes.
_Avoid_: Tenant, namespace, test ID

**Journal**:
The bounded record of the requests smock has received, used to verify calls and diagnose mismatches.
_Avoid_: Request log, history, access log
