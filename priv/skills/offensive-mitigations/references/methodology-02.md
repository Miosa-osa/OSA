#### Bypass Techniques

- **Hypervisor Vulnerabilities:** Exploiting bugs in the underlying hypervisor (Hyper-V) to escape the VBS container.
- **Misconfiguration:** Weaknesses in VBS configuration or deployment.
- **Physical Access:** Hardware-level attacks (e.g., DMA attacks if not mitigated by Kernel DMA Protection).
- **Compromised Signed Components:** Exploiting vulnerabilities in trusted components running within VBS.

#### Practitioner

- Confirm VBS/HVCI: `Core isolation` settings or PowerShell `Get-CimInstance -ClassName Win32_DeviceGuard` (look for `VirtualizationBasedSecurityStatus` and `SecurityServicesConfigured`).

### AMD Secure Encrypted Virtualization – Secure Nested Paging (SEV‑SNP)

- Linux guest support since 6.11; provides full memory encryption + integrity with an SVSM.
- Shipping today in major cloud "confidential VM" SKUs.

### Intel Trust Domain Extensions (TDX)

- Guest driver landed in 6.11; host enablement queued for 6.16.
- Protects guest memory against a compromised hypervisor.

#### Practitioner

- Cloud: verify TDX/SEV‑SNP instance type (`Azure DCasv5/ECasv5`, `GCP C3`, `AWS C7g` variants); attest via platform‑specific tools (e.g., `az confcom attestation`).

### Arm Confidential Compute Architecture (CCA) Realms

- Realm VM support merged in 6.13 for Arm v9 CPUs, giving encrypted, isolated guest environments.

### Hypervisor-Enforced Code Integrity (HVCI)

- Windows:
  - Uses VBS to enforce code integrity checks on kernel-mode drivers and binaries.
  - Ensures only signed and verified code can execute in kernel mode.

#### Bypass Techniques

- **Signed Malicious Drivers:** Obtaining signing certificates (stolen or illicitly acquired) to sign malicious code.
- **Exploiting Allowed Drivers:** Finding vulnerabilities in legitimate, signed drivers already running on the system ("Bring Your Own Vulnerable Driver" - BYOVD).
- **Hypervisor Vulnerabilities:** Exploiting the underlying hypervisor (see VBS bypasses).
- **Configuration Issues:** Weaknesses in Code Integrity policies.

### Mode Based Execution Control (MBEC)

- Windows:
  - Ensures driver code can only be executed in kernel mode.
  - Available in hardware and software (emulated) forms.
  - Prevents user-mode execution of kernel code.

### Kernel Mode Code Integrity (KMCI)

- Windows:
  - Ensures kernel pages can only become executable with proper signing.
  - Enforces driver signing enforcement and vulnerable driver blocklists.
  - Implements software SMEP (Supervisor Mode Execution Prevention).
  - `DriverSiPolicy.p7b` now refreshes **weekly** via Windows Update and MEM Configuration Manager, accelerating the BYOVD blocklist cadence.

### User Mode Code Integrity (UMCI)

- Windows:
  - Ensures user mode pages can only become executable with proper signing.
  - CI validates the signaturees of EXE and DLL before allowing them to load.
  - Enforces protected processes and protected process light signature requirements
  - Enforces `/INTEGRITYCHECK` for `FIPS 140-2` modules
  - Exposed to consumers as _Smart App Control_ and businesses as _App Control for Business_.
  - Part of the Device Guard technology stack.

### Windows Defender System Guard

- Windows:
  - Monitors system integrity during boot and runtime.
  - Protects against rootkits and bootkits by verifying system integrity.

### Windows Defender Application Guard

- Windows:
  - Runs untrusted content in isolated containers.
  - Protects the host from potentially malicious websites and documents.

### Credential Guard

- Windows:
  - Uses VBS to isolate and protect credentials.
  - Prevents attacks like Pass-the-Hash or Pass-the-Ticket.

### Device Guard

- Windows:
  - Combines WDAC and virtualization-based security to lock down devices.
  - Ensures only trusted applications can run.

## OS Loader and Hotpatching Changes (Windows 11 24H2+)

- Recent Windows versions (24H2 and later) introduced changes that impact classic process injection techniques like Process Hollowing (RunPE).
- **Status:** Client Hotpatching availability and cadence depend on SKU/servicing channel. Validate GA status in current Microsoft documentation.
- Windows Server 2025 requires an Azure Arc subscription for hotpatch servicing.

### Impact on Process Hollowing (MEM_PRIVATE Payloads)

- **Root Cause 1 (Error `0xC0000141`):** Native Hotpatching support added a new function `RtlpInsertOrRemoveScpCfgFunctionTable` during process initialization (`LdrpInitializeProcess -> LdrpProcessMappedModule`). This function calls `ZwQueryVirtualMemory` with a new `MemoryImageExtensionInformation` class, which _only_ works on `MEM_IMAGE` memory regions.
  - Classic Process Hollowing stores the payload in `MEM_PRIVATE` memory (either by unmapping the original PE or allocating a new region).
  - The `ZwQueryVirtualMemory` call fails with `STATUS_INVALID_ADDRESS` for the `MEM_PRIVATE` payload region, causing process loading to terminate.
- **Root Cause 2 (Error `0xC00004AC`, Memory Integrity Enabled):** If Memory Integrity (HVCI) is enabled, another check occurs later in the loading process.
  - `LdrpQueryCurrentPatch` is called on the payload's memory region.
  - This leads to a call to `NtManageHotPatch`, which fails with `STATUS_CONFLICTING_ADDRESSES` for the `MEM_PRIVATE` payload.
  - This error also terminates the process loading.

### Solutions and Bypasses

1.  **Use Alternative Techniques (Recommended):** Employ methods that map the payload as `MEM_IMAGE`, which are unaffected by these specific checks.
    - Examples: Process Doppelganging, Process Ghosting, Process Herpaderping, Transacted Hollowing, Ghostly Hollowing, Herpaderply Hollowing, Process Overwriting.
    - These techniques generally interact more naturally with the loader and newer OS features.
2.  **Patch NTDLL (If sticking to Classic RunPE):**
    - **For `0xC0000141`:** Hook `ZwQueryVirtualMemory`.
      - Check if the OS is Win11 24H2+ (64-bit).
      - If the `MemoryInformationClass` is `MemoryImageExtensionInformation` AND the query targets the base address of the `MEM_PRIVATE` payload:
        - Return a benign error like `STATUS_NOT_SUPPORTED` instead of calling the original function.
      - Otherwise, call the original `ZwQueryVirtualMemory`.
      - [Implementation Example](https://github.com/hasherezade/libpeconv/blob/master/run%5Fpe/patch%5Fntdll.cpp#L91)
    - **For `0xC00004AC` (Memory Integrity):** Hook `NtManageHotPatch`.
      - Patch the function to immediately return a benign error like `STATUS_NOT_SUPPORTED`.
      - Apply this patch early in the process creation, for both 32-bit and 64-bit.
      - Ensure `FlushInstructionCache` is called if patching after the function might have been cached.
      - [32-bit Example](https://github.com/hasherezade/libpeconv/blob/master/run%5Fpe/patch%5Fntdll.cpp#L4)
      - [64-bit Example](https://github.com/hasherezade/libpeconv/blob/master/run%5Fpe/patch%5Fntdll.cpp#L43)

## Control Flow Integrity and Execution Protections

### Data Execution Prevention (DEP)

- Windows/Linux:
  - Marks certain memory regions as non-executable.
  - Prevents execution of code from data pages, mitigating buffer overflow attacks.

#### Bypass Techniques

- **Return-oriented Programming (ROP)**: Using existing code fragments to create attack chains without injecting code.
- **ret2libc**: Jump directly to code in libc.
- **ret2data**: Place shellcode in the data section.
- **ret2strcpy**: Place shellcode on the stack and use strcpy to move it somewhere executable.
- **ret2gets**: Read from stdin to gain control.
- **VirtualProtect/VirtualAlloc**: Call these functions to change memory permissions.
- **JIT Spraying**: Leverage Just-In-Time compilation to get executable memory.

#### Practitioner

- use `!vprot rip` or `!vpro rsp` to check for protections inside WinDbg
- `.scriptload G:\Projects\narly.js; !nmod` also helps you to see which modules have DEP protection
- `Data Execution Prevention` settings inside `Windows Exploit Guard` can be used to force DEP protection on an executable
- pivot with `VirtualProtect` / `NtProtectVirtualMemory` (or pre‑ACG RWX section) from a ROP/JOP chain.
- Modern Windows 10/11 enforce **CET (Shadow Stack)** and **XFG (Cross‑Function Guard)**, which break classic ROP; successful chains must first disable CET (for example with `SetProcessMitigationPolicy`) or switch to JOP/SCS gadgets.
- an example would be `pop rcx; retn; pop rcx; retn; mov [rcx], rax; pop rbp; retn;`
- we can use `IAT` to identify and call `WriteProcessMemory` which can be used to circumvent DEP protection through `NtProtectVirtualMemory` API
- [Ropper 2.0](https://github.com/sashs/Ropper) **or Rizin‑ropper** — both support CET/XFG‑aware gadget filtering.

### Control Flow Integrity (CFI)

- Windows:
  - Ensures kernel execution follows legitimate paths.
  - Thwarts control-flow hijacking attacks like function pointer overwrites.

#### Bypass Techniques

- **Similar Function Prototypes**: For XFG (Extreme Flow Guard), functions with similar prototypes may be exploitable.
- **Data-Only Attacks**: Manipulating program state without violating CFI constraints.
- **Implementation Weaknesses**: Exploiting gaps in the implementation of CFI.
- **JIT Compilation**: Just-in-time compiled code may bypass CFI checks.

#### Practitioner

- Windows build: enable CFG/XFG via `/guard:cf /guard:xfg` and `/Qspectre` where applicable; inspect PE `LoadConfig` for CFG/XFG metadata.
- Linux build: Clang `-fsanitize=cfi` (user space) or `CONFIG_CFI_CLANG=y` (kernel), with LTO; verify symbols contain CFI jump tables.

### kCFI

- Linux
  - Clang-based forward-edge Control-Flow Integrity that verifies indirect function calls at runtime in the kernel.
  - Enabled by default in Android GKI kernels and ChromeOS since early 2024; available upstream via `CONFIG_CFI_CLANG`.
  - Complements FineIBT and hardware CET by protecting software-only control-flow edges.
  - **BHI Hardening (Linux 6.9/6.10):** FineIBT now incorporates indirect‑branch serialization to mitigate Branch History Injection.

### Control Flow Guard (CFG)

- Windows:
  - Ensures indirect calls go only to valid, predefined locations.
  - Helps prevent control-flow hijacking attacks.

#### Bypass Techniques

- **JIT Code Execution**: Using Just-In-Time compiled code which may not be properly protected.
- **Import Address Table (IAT) Manipulation**: Inserting entries in IAT since these aren't checked.
- **Data-only Attacks**: Modifying program data to influence control flow without redirecting execution.
- **Type Confusion**: Exploiting type confusion to bypass CFG checks.

#### Practitioner

- Check process mitigation: `Get-ProcessMitigation -Name process.exe` (PowerShell) → CFG/strictCFG/XFG states.
- PE inspection: `dumpbin /loadconfig` shows GuardCFFunctionTable and flags.

### Stack Canaries

- Linux/Windows:
  - Inserts random values before return addresses on the stack.
  - Detects stack buffer overflows before they overwrite return addresses.

#### Bypass Techniques

- **Leaking Canary Values**: Using format string or other information disclosure vulnerabilities.
- **Overwriting Non-return Variables**: Attacking function pointers or other control flow variables not protected by canaries.
- **Brute Force**: On systems with low entropy canaries or predictable generation.
- **Exception Handler Attacks**: Targeting exception registration records which may not be protected.
- **Unprotected Functions**: Exploiting functions not protected by canaries (often due to performance considerations).

### Stack Clash Protection

- Linux/GCC:
  - Prevents stack and heap collisions by probing stack pages during large allocations.
  - Mitigates privilege escalation attacks that rely on stack/heap layout manipulation.
  - Enabled with `-fstack-clash-protection` compiler flag.

#### Bypass Techniques

- **Precise Heap Layout**: Carefully crafting heap allocations to avoid clash detection.
- **Small Allocations**: Using allocations smaller than the probe size to avoid triggering protection.
- **Alternative Memory Regions**: Targeting other memory regions not protected by stack clash detection.
- **Implementation Gaps**: Exploiting edge cases in the probing logic.

### Hardware‑Enforced Stack Protection

- Windows:
  - Utilizes Intel CET (specifically the Shadow Stack feature, referred to as Kernel Mode Hardware-enforced Stack Protection or KCET) and AMD Shadow Stack features.
  - Requires Hypervisor-Enforced Code Integrity (HVCI) / Virtualization-Based Security (VBS) to be enabled.
  - Provides a hardware-backed shadow stack to protect return addresses against ROP/JOP attacks.
  - Applies to kernel-mode stacks, including those associated with user-mode threads executing in kernel mode (e.g., during system calls).
  - Hardware-Enforced Stack Protection is enabled by default on compatible hardware with Windows 11, version 24H2, when VBS/HVCI is active. The `IMAGE_GUARD_SHADOW_STACK` PE flag indicates compatibility and is increasingly adopted for key binaries, with Windows components widely enabling it.

#### Bypass Techniques

- **Increased Difficulty with HVCI:** When combined with Hypervisor-Enforced Code Integrity (HVCI), bypassing hardware-enforced shadow stacks becomes significantly more challenging. HVCI leverages virtualization (Hyper-V) to protect the shadow stack's integrity via the Secure Kernel (VTL1). The Secure Kernel manages the shadow stack pointer (`VMX_GUEST_SSP` in the VMCS for VTL0) through hypercalls, preventing even kernel-mode code (VTL0) from directly tampering with it.
- **Return Address Protection:** The hardware compares the return address on the main stack with the one stored on the protected shadow stack before executing a `RET` instruction. Mismatches typically cause a fault (system crash for KCET), mitigating standard ROP/JOP attacks that rely on overwriting the return address on the main stack.
- **Secure Kernel Validation:** The Secure Kernel is involved in validating and restoring shadow stack context (e.g., during exception handling via functions like `nt!KeKernelShadowStackRestoreContext` and secure system calls like `securekernel!SkmmNtKernelShadowStackAssist`), adding another layer of integrity checking.
- **Potential (Difficult) Vectors:** Bypasses would likely require exploiting vulnerabilities in the hypervisor (Hyper-V) or the Secure Kernel itself, finding flaws in the hardware CET implementation, or developing sophisticated data-only attacks that achieve control without corrupting the stack's return addresses. These are considerably harder than bypassing software-based or unprotected hardware stack protections.
- **Limited Scope:** Like other CFI mechanisms, attacks targeting non-control data or logic bugs may still be possible if they don't violate the protected control flow.

### Pointer Authentication (ARM64)

- Linux/iOS:
  - Uses cryptographic signatures to protect pointers.
  - Mitigates attacks like Return-Oriented Programming (ROP).

#### Bypass Techniques

- **Unprotected Assembly Code**: Assembly code often lacks PAC protection.
- **Raw Function Pointers**: Recovery handlers and other mechanisms that use raw pointers.
- **Signing Gadgets**: Using existing code that signs pointers.
- **Switch Case Branches**: Unprotected indirect branches in switch case implementations.
- **Authentication Failure Handling**: Exploiting cases where authentication failures don't trigger exceptions.
- **Thread State Manipulation**: Incorrect handling of thread state during context switches.

### Intel Control‑flow Enforcement Technology (CET)

- Hardware feature providing protections against control-flow hijacking.
- Includes Shadow Stack and Indirect Branch Tracking.
- Enabled by default starting with Windows 11 build 26100 (Win11 24H2+). Any stack pivot or `ret` without a valid shadow‑stack token raises `STATUS_STACK_BUFFER_OVERRUN` (0xC0000409).
- **Detect CET:** Read the `IMAGE_DLLCHARACTERISTICS_GUARD_CF` flag in the PE header or `PEB→LdrDataTableEntry.GuardFlags`.
  - Windows: `Get-ProcessMitigation -System` shows `UserShadowStack` and `UserCetEnabled`.
  - Linux: check `cet_ss` in `/proc/cpuinfo` and `prctl(PR_SET_SHADOW_STACK_STATUS, ...)`.
- **Bypass tips for CET in shellcode:**
  1. Align the shellcode entry to a valid call target and emit `ENDBR64`/`SETSSP` before the first `ret`.
  2. Use ROP‑less staging (queued APC, `NtContinue`, or `NtTestAlert`) so the kernel performs the first return.

### Intel Indirect Branch Tracking (IBT)

- Linux/Windows:
  - Part of Intel CET that enforces legitimate indirect branch targets.
  - Requires `ENDBR32` or `ENDBR64` instructions at valid indirect call/jump destinations.
  - Prevents JOP (Jump-Oriented Programming) attacks by validating branch targets.
  - Available on Tiger Lake+ CPUs, enabled via `CET_IBT` bit in MSR.

#### Bypass Techniques

- **ENDBR Gadgets**: Finding existing code sequences that start with valid `ENDBR32/64` instructions.
- **ENDBR Spraying**: Injecting or finding multiple `ENDBR` instructions to create gadget chains.
- **Unprotected Modules**: Targeting libraries or code not compiled with IBT support.
- **Legacy Code Paths**: Exploiting code paths that bypass IBT checks (e.g., signal handlers, exception contexts).
- **Hardware Quirks**: Exploiting CPU-specific implementation differences or errata.

#### Practitioner

- Check IBT status: `cat /proc/cpuinfo | grep cet_ibt` (Linux) or inspect `cr4.cet` bit
- Compile with IBT: `-fcf-protection=branch` (GCC) or `-mcet` flag
- Binary analysis: Look for `ENDBR64` (0xF3 0x0F 0x1E 0xFA) or `ENDBR32` (0xF3 0x0F 0x1E 0xFB) instructions

