# Native macOS workload slice receipt

## Implemented source

The arm64 helper compiles with Swift 6.3.1 in Swift 5 language mode, targeting macOS 13 and linking the real Apple Virtualization APIs.
Four Swift implementation files separate protocol validation, owned artifact storage, VZ lifecycle, and process/IPC lifetime.
No test-only VM backend or synthetic successful VZ response exists in production code.
The helper is built locally under `.build/osa-opencomputers-vm`, not installed or published.

Compute contains the MacOS adapter, persistent hash-pinned Server, pinned Artifact manifest reader, durable Identity store, admitted Lifecycle, and native Recovery hook.
Identity changes, stale fences, deleted-workload resurrection, expired commands, untrusted helper bytes, malformed replies and resource over-admission fail closed.
Revocation fences later create/start requests and stops helper-owned VMs while retaining disks.
The canonical HostSession signature verification and generic host stack were not modified by this slice.

## Automated evidence

```text
protocol paths and unknown fields: PASS
store digest rejection and symlink isolation: PASS
Ran 7 tests ... OK
11 tests, 0 failures
```

The first two lines are native Swift protocol/storage test executables.
Seven Python tests drive the actual compiled helper through stdin/stdout, exercising prerequisite probe, missing artifacts, bounds, unowned deletion protection, exclusive ownership, stop-all preservation, and oversized input termination.
Eleven Elixir tests exercise durable identity and the actual helper IPC with the real AdmissionController, including failed-import release, confirmed stopped-disk retention, confirmed deletion release, reconstruction and revocation fencing.
The stopped-disk test uses an explicitly nonbootable filesystem fixture; it never requests start.
No certified image, VZVirtualMachine instance, VM boot, desktop capture, or input injection was used in these tests.

RED/GREEN: protocol/store tests initially failed for missing implementations; the durable authority test initially failed for the missing Identity module and then passed.
A test-harness linked-exit issue in the rejected-helper-hash case was corrected to exercise supervisor startup rejection; the complete eleven-test suite then passed.

The local Mac Elixir is 1.19.5/OTP28, while compute pins 1.18.2/OTP27.3.4.
`scripts/preflight.sh` reported that mismatch; Mac IPC results are native supporting evidence, not a matching CI/toolchain claim.
Source formatting and pure authority checks are additionally run in the pinned Linux/x64 image.
Mac-only helper tests are explicitly skipped in that environment, not relabeled as Linux or hardware success.

Final pinned Linux result: `11 tests, 0 failures, 10 skipped` (one real pure-authority test, ten Mac-helper tests skipped).
Final local Mac result: `11 tests, 0 failures`.
Pinned Elixir formatting, Swift warnings-as-errors compilation, shell syntax and Git whitespace checks passed.
Development helper SHA-256, before release entitlement signing:

```text
ee8de1c4b2841a82470e7aadbde68b2aaae5189f3017f1821273ce5baf05197b
```

## Exact remaining blockers

1. Parent generic startup must start the native Server before its probe and consistently select native preflight, recovery, admission reconstruction, sweeper evidence, lease revocation and usage policy.
2. Certified SHA-pinned arm64 Linux Image/ext4 manifests are not supplied; the disk image must match the requested byte capacity and kernel drivers must support this VZ configuration.
3. Authenticated guest credential delivery, vsock/outbound transport, guest readiness and desktop/application endpoint verification are not implemented by this helper.
4. Native CPU/memory/disk I/O usage collection is unavailable and is returned as an explicit error, not fabricated accounting.
5. Final release signing with the virtualization entitlement, notarization, helper packaging and final signed-artifact hash distribution remain release-owner integration.
6. Real hardware cold boot, stop, owner revocation, reboot/sleep recovery, guest isolation and failure-pressure acceptance remain unperformed.

No native capacity advertisement, Firecracker snapshot compatibility, warm restore, sub-second launch, deployed readiness, new PR or deployment is claimed.
The exact parent interface lives at compute `apps/miosa_host/lib/miosa_host/executor/native_vm/macos_integration.md`.
