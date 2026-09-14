# Native macOS workload helper

This is the sole Swift Virtualization.framework implementation for the OSA native follow-up and compute PR1557 work.
The parent reports PR274 already merged; this uncommitted slice is for the parent's single replacement OSA PR.
The compute adapter lives in `apps/miosa_host/lib/miosa_host/executor/native_vm/macos*.ex` in the compute worktree.
The native desktop ScreenShare helper is separate and is not used for VM execution.

## Build and safe automated tests

```sh
sh native/macos/OpenComputersVM/build.sh
sh native/macos/OpenComputersVM/test.sh
```

The build uses direct swiftc like the existing macOS helper because this CLT installation cannot link SwiftPM manifests.
It targets arm64 macOS 13 or later and links Apple's Virtualization, Security, Foundation and CryptoKit facilities through the SDK.
No third-party native package is required.
The build does not install, sign, launch a VM, or modify an existing OSA installation.
Tests exercise bounded IPC, metadata validation, corrupt artifact rejection, unowned paths, capacity rejection, owner locking, revocation without disk deletion, and protocol lifetimes.
They never supply a bootable image or call VZ start.

## Production signing and launch contract

The helper needs a valid signature with `com.apple.security.virtualization`; `entitlements.plist` supplies only that entitlement.
The final signed/notarized artifact's SHA-256, not the unsigned development build's hash, must be configured in the compute adapter.
The parent release owner must package that artifact and its verified manifest before advertising native runtime support.
No shared release workflow was edited for this helper.

Launch arguments are exactly `--root ABSOLUTE_PRIVATE_ROOT --artifacts ABSOLUTE_PRIVATE_CACHE --max-cpus N --max-memory-mib N --max-disk-mib N`.
Both roots must already exist, belong to the service user, and have mode 0700.
The exclusive root lock prevents two helper processes owning the same VM namespace.
Only the persistent adapter owns stdin/stdout; no listening TCP socket, shell command, arbitrary path, or user-supplied kernel command line is exposed.
`--version` is side-effect free.

JSON-lines version 1 accepts `probe`, `create`, `start`, `stop`, `delete`, `inspect`, and `stop_all`.
Requests are limited to 16 KiB, have a bounded string `id`, and reject unknown fields and malformed UUIDs.
Only create accepts metadata: `backend`, `architecture`, `kernel_sha256`, `rootfs_sha256`, `vcpu_count`, `memory_mib`, `disk_mib`.
The backend and architecture must be `apple_virtualization` and `arm64`.
Every successful response has the matching request ID and a backend-tagged result.
Malformed input is rejected, native errors are bounded codes, and protocol stdout never carries the guest console.

## Actual lifecycle

Create copies the digest-addressed kernel and rootfs into a private UUID directory while hashing the copied bytes.
It requires a raw arm64 Linux Image with built-in virtio/ext4 root support and a raw ext4 rootfs whose byte size equals the requested disk MiB capacity.
It does not download an image, synthesize an image, expand a filesystem, or silently translate a Firecracker snapshot.
Repeated create must match existing immutable metadata.
Start rechecks kernel identity and disk ownership, validates VZ configuration, and invokes real VZ start with a virtio block device, NAT network, entropy and a virtio socket device.
The running VZ object is owned by the persistent helper, never represented by an arbitrary PID file.
Stop uses the VZ stop API; delete refuses a running VM and unlinks only the fixed owned files, not a recursive caller-specified directory.
Stop-all attempts every owned VM, reports failures, and preserves all disks.
Owner EOF and termination signals trigger stop-all with a bounded process-exit fallback.
Helper process loss destroys live VZ ownership but leaves disks for explicit cold recovery.

## Deliberately not ready

A VZ start completion reports `state=running, guest_ready=false`.
There is no fabricated guest IP, authenticated envd session, desktop URL, runtime CPU accounting, snapshot support or sub-second timing claim.
The virtio socket device is provisioned, but authenticated guest transport and guest-credential delivery still require integration.
Missing certified arm64 kernel/rootfs manifests are genuine blockers to usable workload certification.
Native resource usage is unavailable until a real collector is integrated.
Whole-host admission, recovery, sweeper, lease and capability selection must use the native interfaces consistently.
See compute `macos_integration.md` for the exact signatures and security responsibilities.

## Primary API references

- [Apple Virtualization framework](https://developer.apple.com/documentation/virtualization)
- [VZVirtualMachine lifecycle](https://developer.apple.com/documentation/virtualization/vzvirtualmachine)
- [Linux boot loader](https://developer.apple.com/documentation/virtualization/vzlinuxbootloader)
- [Virtualization entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)

No VM creation, desktop capture, production enrollment, deployment, new PR, or hardware acceptance was performed by this slice.
