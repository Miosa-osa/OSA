# macOS native VM integration contract

Source implementation and targeted tests are complete; no VM boot or native guest QA was performed.
Lineage update from the parent: OSA PR274 merged at head60afcd16; this uncommitted native helper belongs in the single replacement OSA PR the parent will create.
Keep this worktree in place; only the parent owns branch changes, rebasing, moving integration work and pushing.
No agent messaging is available; this shared file is the handoff, not an acknowledgment.

## Parent-owned host stack

Do not select this backend by OS alone or change only the executor.
Parent must uniformly select preflight, admission recovery evidence, runtime usage, sweeper, revocation, guest transport, and capabilities.
Keep HostSession signature/scope validation, durable Ledger, generation/lease/fence checks and admission outside this local helper protocol.
Do not route native VZ ownership through Firecracker process evidence, Linux cgroups, or PID-kill sweepers.

## Adapter interface implemented

- `MiosaHost.Executor.NativeVM.MacOS.execute(operation, validated_envelope)` supports `start`, `stop`, `delete`; unsupported operations fail closed.
- `reconcile(operation, validated_envelope)` inspects actual helper-owned state without duplicating an uncertain start.
- `inspect_workload(workload_id)` returns backend-tagged observed state, not PID existence.
- `probe/0` returns native capability/prerequisite evidence only, never guest readiness.
- `revoke_all/0` asks the owning helper to stop all its live VMs; it never deletes disks.
- `admission_recovery/1` supplies the parent's exact native reconstruction callback shape and retains unknown intent capacity.
- `recover_all/0` performs startup-only stop/recovery without clearing the revocation latch or deleting disks.
- `MacOS.Server.start_link/1` owns one persistent helper Port; the parent supervises it and must not terminate it as if it were a per-command subprocess.

Configure `:miosa_host, :macos_native_vm` with an absolute helper path, expected helper SHA-256, private runtime root, artifact cache root, and maximum vCPU/memory/disk limits.
The parent passes those resolved options explicitly to Server.start_link/1; this slice does not automatically read or select an OS-based backend.
The server verifies the helper before launch and supports serialized bounded requests with deadlines and response correlation.
No ambient PATH executable or shell is used.
Process lifetime and inspection come from the persistent helper, never an unvalidated PID file.
Helper exit invalidates all live VM evidence; disks remain for explicit cold recovery.

## Local protocol

JSON-lines protocol version 1 supports `probe`, `create`, `start`, `stop`, `delete`, `inspect`, and `stop_all`.
Only create accepts immutable metadata: backend `apple_virtualization`, architecture `arm64`, kernel/rootfs SHA-256 pins, vCPU, memory MiB, and disk MiB.
Files are resolved from trusted cache digest names and copied into helper-owned UUID directories; callers cannot provide arbitrary paths or kernel arguments.
Create prepares disks without booting; start calls real VZ APIs.
Responses carry the request ID, backend, observed state, and `guest_ready: false` until a separate authenticated guest mechanism certifies readiness.
No Firecracker snapshot, guest exec, guest file transport, or IP address is fabricated.

## Required parent checks

Inject backend-specific preflight (helper digest, architecture, entitlement/virtualization probe, private storage and supported limits).
Use per-workload inspect plus durable command/lease ownership for admission recovery; stopped disks remain allocated.
Use stop/delete operations for owned cleanup rather than `/bin/kill`.
Provide native resource accounting or report it unavailable; do not return fake Linux cgroup usage.
Bind admission, expiry, and revocation to stop_all/stop before advertising capacity.
Certified arm64 Linux Image/ext4 guest artifacts, authenticated guest transport, real boot/readiness acceptance, and packaging/signing remain explicit prerequisites.

## Final integration receipt

See compute `apps/miosa_host/lib/miosa_host/executor/native_vm/macos_integration.md` for the complete exact callbacks, startup ordering, durable authority and admission rules.
The adapter now checks persistent tenant/host/cell/pool/generation/lease/artifact/resource identity and monotonic fences on every mutation/reconcile.
It reserves/finishes admission and changes stopped/deleted accounting only after confirmation, retaining unknown outcomes conservatively.
Revocation fences subsequent create/start commands so an in-flight create cannot reboot the machine after lease revocation.
Swift compile, two native test executables, seven real helper IPC tests and eleven Mac-side Elixir tests passed.
The pinned Linux Elixir suite passed one pure authority test and skipped ten Mac-helper tests explicitly.
Native usage remains unavailable, guest_ready remains false, and no capacity advertisement or deployment is authorized by these results.
