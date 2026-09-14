# OpenComputers platform runtime integration

Status: bounded research/design, not a backend implementation or deployment.
OSA evidence is the shared PR274 worktree; backend evidence is `/private/tmp/miosa-oc-handshake-20260912` at `cf3822d6a` plus its concurrent working changes.
These are source observations, not proof of the production revision.

## What exists and what does not

OSA `Session.Hello.capabilities_for_mode/1` advertises direct execution, agent runtime, and native desktop only.
It deliberately advertises no capabilities for `vm_dispatch` or `slicing` because `Executor.mod_for_kind/1` has no create-computer, snapshot, or restore handlers.
The implemented jobs are `exec_on_host`, `dispatch_agent`, and `stream_native_desktop`.

Docker/Podman container and Compose implementations do exist in `executor/direct/container.ex` and `compose.ex`.
However, the active `Session.handle_frames/2` calls `Session.FrameRouter.handle/2`, whose fallback ignores container/Compose frames; their routes are in the separate global `OpenComputers.FrameRouter`.
Registering the active session with that global router supplies outbound delivery, not inbound delegation.
This is a source-level routing gap, not a reproduced live container result.
Do not simply forward every frame: first reconcile authorization, supported codecs, owner-approved mounts/ports, bounded requests, and lifecycle semantics.
The inspected `Container.build_run_args/8` builds mounts and ports but supplies no CPU or memory limit flags, so this is not evidence of resource-bounded multi-tenant slicing.

The backend has progressed beyond earlier notes: `ComputePlacement.do_resolve/3` now calls `OpenComputers.RuntimeBindings.eligible/3`, pins placement to the bound fleet node, and carries binding revision/backend/verification evidence.
`HostSession` now supports explicit `opencomputers` provenance rather than pretending a customer machine is a cloud node.
The static `Engine.Cloud.Capabilities` catalog still labels OpenComputers sandbox and deployment drivers unavailable and computer verification partial.
Reconcile that catalog with the real product consumers before promising availability; neither a new binding schema nor an OSA heartbeat proves workload execution.

## Canonical boundary to retain

Reuse `Engine.Fleet.ManagedHostControl.OutboundAdapter` and its operation contract, command persistence, cold-start mapping, and receipt projection.
Use `Engine.Schemas.HostSession` for tenant, fleet node, cell, pool, provenance, negotiated signing algorithm, and revocation.
Keep a workload-runtime credential separate from the OSA interactive enrollment credential.

Host-side entry remains `MiosaHost.Session`, `MiosaHost.Protocol.Envelope.validate/3`, durable `MiosaHost.Ledger`, then the narrow `MiosaHost.Executor.execute/2` and `reconcile/2` boundary.
The signed envelope includes command/workload/host/tenant/cell/pool identities, generation, lease, fence, deadline, artifact, resources, guest authority, and operation capability.
Ed25519 sessions must not downgrade to the supported legacy HMAC shape.
Preserve exact-field validation, deadline and scope checks, deduplication, crash reconciliation, receipts, and optional signed route permits.
An unknown command outcome must reconcile the same command identity, not create another VM.

Customer hardware must retain the customer runtime's `LeaseGuard` revocation behavior.
Do not copy the managed-fleet supervisor's deliberate absence of `LeaseGuard` onto a personal computer.
Keep host desktop consent independent of workload placement authority and resource approval.

## Existing Linux architecture

`MiosaHost.Executor.Firecracker.Boot` resolves verified artifacts, checks authority, allocates networking, clones the root disk with CoW, sizes it, attaches networking, and launches through its runtime modules with rollback paths.
`RuntimePreflight` checks executable dependencies, immutable kernel/rootfs digests, certified rootfs generation, CoW storage, runtime roots, capacity, and cgroup-v2 CPU/memory/pids/io controllers.
Its KVM check opens the configured path; this alone is not a VM-creation test.
Acceptance still needs a real guest boot and end-to-end guest readiness.
[Firecracker requires Linux KVM](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md).
Reuse this backend on supported Linux rather than creating a second OSA VM command implementation.

## Options and recommendation

### Native platform VM backends: recommended direction

Keep the signed command and ownership boundary stable while separating platform-specific lifecycle, storage, network, and guest transport mechanics.
Retain Linux Firecracker; design a macOS Virtualization.framework implementation and a Windows Hyper-V implementation behind the same executor semantics.
These adapters do not exist in the inspected OSA executor.
First port the smallest full lifecycle: verified image, create, guest-ready, bounded resources, stop, delete owned resources, and restart reconciliation.
Advertise snapshot/restore or warm-pool capability only when that backend implements and passes it.
Do not expose a generic privileged shell as the platform bridge.

[Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization) provides VM lifecycle and virtio devices for supported Macs.
The macOS helper needs signing, the virtualization entitlement, validated VM configuration, matching-architecture Linux images, isolated writable disks, guest transport, and an owner-approved service/resource lifecycle.
Use native VM creation without nesting for the initial macOS path.
[Apple's container project](https://github.com/apple/container) is useful implementation research for OCI images in lightweight Linux VMs, but currently requires Apple silicon and supports macOS 26; it is not a portable Docker/Podman replacement or a HostSession adapter.

[Hyper-V requirements](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements) include a supported Windows edition, SLAT, firmware virtualization, and host memory headroom.
[VM management](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/create-a-virtual-machine-in-hyper-v) also requires appropriate local permissions and VM storage/network configuration.
Use a restricted local service managing only MIOSA-owned VM IDs, disks, and switches with parameterized operations and durable ownership records.
A running Docker Desktop or WSL installation does not establish that this Hyper-V lifecycle or Firecracker is available.
Do not silently enable Windows features, reboot, or modify existing user VMs and virtual switches.

### Nested Linux appliance: conditional, not the universal default

This maximizes reuse of Linux host mechanics, but adds a second hypervisor, capacity accounting, networking, and failure recovery layer.
[Apple's nested-virtualization probe](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported) is available from macOS 15 and documents M3 or later hardware.
Even there, validate the Linux guest kernel, KVM VM creation, Firecracker architecture, and workload lifecycle before advertising support.
[Microsoft explicitly does not support non-Microsoft virtualization inside Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/nested-virtualization), so a KVM-in-Hyper-V appliance is not a supportable universal Windows plan.

### Container management: separate product capability

Restore the existing container path only after contract and authorization tests demonstrate safe routing.
Owner-scoped Docker management is not a hostile multi-tenant sandbox boundary.
The VM-backed compute path needs independent resource enforcement, filesystem isolation, network policy, and guest credentials.
Do not equate a container image, a full desktop VM, and a streamed native desktop.

## Genuine missing prerequisites and acceptance

1. A complete platform executor and runtime service package for each supported OS, including upgrades, ownership-preserving rollback, startup, and removal.
2. Backend-specific signed artifact metadata and images: architecture, boot method, disk format, drivers, guest agent, and digest verification.
3. Backend/architecture/version-compatible snapshot policy; never feed Firecracker memory snapshots to VZ or Hyper-V.
4. Authenticated guest transport and desktop readiness, local network/firewall ownership, storage allocation, quotas, headroom, and runtime usage reporting.
5. Product/catalog/placement agreement tied to fresh verified runtime evidence, not OS labels or OSA hello capabilities.
6. Contract tests rejecting wrong tenant/host/pool/cell, expired or replayed authority, signature downgrade, stale fencing, malformed operation/resource requests, and unauthorized mounts.
7. Real hardware tests for create/ready/exec/desktop/stop/delete, service restart, host reboot, sleep/wake, memory pressure, full disk, network loss, lease expiry, revoked ownership, concurrent placement, and uninstall preserving unrelated data.
8. Measure cold image download, cached cold boot, and warm restore separately at p50/p95; no sub-second promise without measured guest readiness on each backend.

Implementation order: preserve the signed-contract layer; certify Linux end to end; implement one native platform's full cold lifecycle; validate recovery and isolation; then add optional snapshots/warm pools and the other platform.
No fake backend, native VM creation, deployment, new PR, or production mutation was performed for this research.
