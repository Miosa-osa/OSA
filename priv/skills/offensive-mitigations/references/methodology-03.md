### Shadow Call Stack (SCS)

- Linux:
  - Compiler-based CFI mechanism using a shadow stack to protect return addresses.
  - Helps prevent ROP attacks.
  - Ensures only signed and verified code can execute in kernel mode.
  - Blocks RWX pages and unsigned kernel callbacks when **Memory Integrity** is ON (default on 2024‑hardware).
  - Common allocation pattern for executable memory: `PAGE_READWRITE` → write payload → `NtProtectVirtualMemory` → `PAGE_EXECUTE_READ`.
  - WoW64 heaven‑gate patches to `WOW64CFG` are rejected by HVCI; favour direct 64‑bit syscalls (e.g., via `wow64log`).

#### Bypass Techniques

- **Data‑only Attacks** (no return‑address writes).
- **Hypervisor/Kernel Bugs** that corrupt GCS state.

### Guarded Control Stack (GCS)

- Linux/ARM64:
  - Hardware user‑space shadow stack on Armv9‑A CPUs, merged in Linux 6.13 and on by default in modern Android.
  - Complements KCET/CET on x86.

#### PAN‑GCS Dual Enforcement (Android 16, Armv9 Realms)

- From Android 16, GCS (shadow stack) plus Privileged Access Never (PAN) are **mandatory** for all Play‑targetSdk 34+ apps running on Armv9 Realms hardware, providing dual hardware + software enforcement.

#### Bypass Techniques

- **Data‑only Attacks** (no return‑address writes).
- **Hypervisor/Kernel Bugs** that corrupt GCS state.

### FineIBT

- Linux:
  - Enhanced CFI mechanism for indirect branch targets.
  - Provides finer-grained control flow protection than basic CFI.
  - The initial implementation was vulnerable to Branch History Injection (BHI). Hardened FineIBT with serialising `INT3` fences landed upstream in Linux 6.14

### Arbitrary Code Guard (ACG)

- Windows:
  - Prevents processes from allocating or modifying memory to be executable.
  - Mitigates attacks relying on dynamic code generation or modification.

#### Practitioner

- Check ACG: `Get-ProcessMitigation -Name process.exe | Select-Object -ExpandProperty DynamicCode`.
- WDAC policy can enforce ACG: audit with `Get-CIPolicy` and `CodeIntegrity` logs.

### Code Integrity Guard (CIG)

- Windows:
  - Restricts loading of DLLs to only those signed by Microsoft or WHQL.
  - Prevents loading of potentially malicious or untrusted libraries.

#### Practitioner

- PowerShell: `Get-ProcessMitigation -Name process.exe | Select-Object -ExpandProperty BinarySignature`.
- Event Logs: `Microsoft-Windows-CodeIntegrity/Operational` for blocked DLL loads.

### Kernel Control-Flow Guard (kCFG)

- Windows:
  - Kernel-specific implementation and enforcement of Control Flow Guard.
  - Protects against control-flow hijacking within the kernel itself.

### eXtended Flow Guard (XFG)

- Windows:
  - Debuted with Windows 11 23H2. Adds strict function‑prototype hashing to CFG, blocking many type‑confusion escapes.

#### Bypass Techniques

- **Prototype Collisions** (extremely rare).
- **Modules Without XFG** (legacy or JIT code).

### Export Address Filtering (EAF) / Import Address Filtering (IAF)

- Windows:
  - Protects module export and import tables from tampering.
  - Prevents attacks that redirect function calls by modifying these tables.

### Structured Exception Handling Overwrite Protection (SEHOP)

- Windows:
  - Protects the integrity of exception handler chains on the stack.
  - Prevents exploits that overwrite exception handlers to gain control flow.

#### Bypass Techniques

- **Modules Without SafeSEH**: A single module without protection breaks the chain.
- **ROP Chains**: Building ROP chains that don't rely on exception handlers.
- **Alternative Attack Vectors**: Targeting other vulnerable components not protected by SEHOP.
- **Unprotected Exception Handlers**: Finding handlers that are still vulnerable.

### Exploit Address Table Filtering (EAF & EAF+)

- Windows:
  - Blocks access to Export Address Tables of critical DLLs like kernel32.dll and ntdll.dll.
  - EAF+ allows specifying modules not permitted to access the EAT, particularly targeting UAF bugs.
  - Uses hardware breakpoints to filter access attempts.

#### Bypass Techniques

- **Alternative Discovery Methods**: Using different techniques to locate functions.
- **Unprotected Modules**: Targeting modules not covered by EAF protection.

### Import Address Filtering (IAF)

- Windows:
  - Ensures all functions listed in a DLL's IAT exist within the image's load address range.
  - Prevents IAT overwrite attacks.

### Virtual Table Guard

- Windows:
  - Ensures virtual function table pointers point to valid guard pages.
  - Terminates execution if invalid vptrs are detected.
  - Protects against C++ virtual function table overwrites.

### MemGC

- Windows:
  - Replacement for MemProtect technology.
  - Specifically targets mitigation of use-after-free exploitation.

### Kernel Text Read-only Region (KTRR)

- iOS:
  - Prevents modification of the iOS kernel at runtime.
  - Implements hardware-enforced read-only memory for kernel code.

#### KTRR‑v2 & FastPAC (iOS 18, A18/A19)

- Hardware‑enforced cache‑colouring prevents pointer‑authentication re‑spray, complementing traditional KTRR for stricter kernel integrity.

### Intel Memory Protection Extensions (MPX)

> [!NOTE]
> Support was removed from Linux 5.6 (April 2020) and GCC 9.1; no mainstream OS or compiler ships MPX today.

## Heap Protections

### Heap Cookies

- Windows:
  - Places a 1-byte value in the metadata of heap chunks.
  - Detects heap metadata corruption before exploitation.

### AMSI Heap Scanning (Jan 2025)

- Windows:
  - AMSI (Antimalware Scan Interface) scans newly committed **writable** heap pages _before_ they are flipped to `PAGE_EXECUTE_READ` or `PAGE_EXECUTE_WRITECOPY`.
  - **Safer allocation pattern to avoid AMSI heap scanning:** Reserve memory with `PAGE_NOACCESS`, decrypt/deobfuscate payload in‑place, then change protection to `PAGE_EXECUTE_READ`.
  - The classic "patch the `AMSI` ASCII tag in `amsi.dll`" trick no longer works reliably; consider patching the COM VTable entry for `IAmsiStream::QueryInterface` or using a proxy‑DLL hook instead.

### Low Fragmentation Heap (LFH)

- Windows:
  - First 32-bit of metadata gets XORed with canary to ensure integrity.
  - Allocates blocks in predetermined size ranges by organizing blocks into buckets.
  - Reduces heap predictability and exploitation potential.

### Safe Unlink

- Windows/Linux:
  - Checks integrity of pointers before freeing memory chunks.
  - Prevents unlink exploitation in heap management.

#### Bypass Techniques

- **Heap Overflow**: Using malloc maleficarum techniques.
- **Chunk-on-Lookaside Overwrite**: Targeting specific heap management structures.

### Heap and Stack Protections

- Windows:
  - Implements guard pages and heap allocation randomization.
  - Detects and prevents buffer overflows and stack smashing.

## Randomization Techniques

### Address Space Layout Randomization (ASLR)

- Linux & Windows:
  - Randomizes memory addresses used by executables and libraries.
  - Makes it harder for attackers to predict target addresses.

#### Bypass Techniques

- **Information Leaks**: Exploiting vulnerabilities to leak addresses of loaded modules.
- **ROP with PLT/GOT**: Using the Procedure Linkage Table to leak addresses and calculate base addresses.
- **Low Entropy**: Exploiting systems with limited randomization bits.
- **Heap Spraying**: Filling memory with copies of shellcode to increase hit probability.
- **Local Privilege Escalation**: Using local exploits to bypass protection.
- **Partial Overwrite**: Overwriting only part of an address to maintain alignment.
- **Statically Linked Code**: Targeting code that doesn't use ASLR.

#### Practitioner

- you probably first need an information leak to identify the correct memory address and then use it to circumvent ASLR and DEP
- format string bugs also helps trigger an information leak, so you can use them alongside `ropchains` to bypass ASLR and DEP
- information leaks are often happen through logical errors or memory corruption bugs

### Position Independent Executables (PIE)

- Linux/Windows:
  - Compiles executables as position-independent code, enabling ASLR for the main executable.
  - Without PIE, the main executable loads at a fixed base address, providing attackers a reliable target.
  - Essential for full ASLR coverage across all memory regions.

#### Bypass Techniques

- **Information Leaks**: Same techniques as ASLR bypass - leak addresses to calculate base.
- **Partial Overwrites**: Overwriting only the lower bytes of addresses to maintain relative offsets.
- **Non-PIE Dependencies**: Targeting linked libraries that aren't position-independent.
- **GOT/PLT Attacks**: Exploiting Global Offset Table entries before they're resolved.

#### Practitioner

- Check PIE status: `file /path/to/binary` or `readelf -h /path/to/binary | grep Type`
- Compile with PIE: `-fPIE -pie` (GCC) or `-fPIC -shared` for libraries
- Detect at runtime: `/proc/PID/maps` shows randomized executable base addresses
- **checksec**: `checksec --file=/path/to/binary` shows PIE status

### ASCII Armored Address Space

- Windows:
  - Loads all shared libraries in addresses starting with `0x00`.
  - Prevents string manipulation exploits that terminate at null bytes.

#### Bypass Techniques

- **Partial Injection**: Still possible to inject one null byte.
- **Main Executable Attacks**: Main executable is not moved, so attackers can target it instead.

### Function Granular KASLR (FGKASLR)

- Linux:
  - Randomizes kernel functions at a finer granularity.
  - Enhances address space randomization effectiveness.

### Kernel Stack Randomization

- Linux:
  - Randomizes the kernel stack base address per process.
  - Makes stack-based attacks more challenging.

### Mandatory ASLR (MASLR)

- Windows:
  - Forces the rebasing of modules even when they were compiled without ASLR support.
  - Enhances protection against code reuse attacks.

### Bottom-Up ASLR (BASLR)

- Windows:
  - Works alongside MASLR to randomize allocation patterns.
  - Blocks 64KB allocations from requested base address up to a randomly selected number.
  - Repeats randomization each time the process restarts.

## Side-Channel Attack Mitigations

### Speculative Execution Mitigations

- Linux/Windows:
  - Addresses vulnerabilities like Spectre and Meltdown.
  - Includes microcode updates and patches to prevent speculative execution attacks.

### Recent Spectre Mitigations

- **IBPB (Indirect Branch Prediction Barrier)**:
  - Intel/AMD feature that flushes indirect branch predictors.
  - Prevents cross-privilege domain speculation leakage.
  - Controlled via `MSR_IA32_PRED_CMD`.

- **IBRS (Indirect Branch Restricted Speculation)**:
  - Restricts speculation of indirect branches when in higher privilege levels.
  - Mitigates Spectre v2 by preventing user-space speculation attacks on kernel.
  - Performance overhead led to adoption of retpolines as primary mitigation.

- **STIBP (Single Thread Indirect Branch Predictors)**:
  - Prevents sibling threads from controlling each other's indirect branch prediction.
  - Mitigates cross-hyperthread Spectre attacks.
  - Particularly important for SMT (Simultaneous Multi-Threading) environments.

- **SSBD (Speculative Store Bypass Disable)**:
  - Prevents speculative execution of loads that bypass older stores.
  - Mitigates Spectre v4 (Speculative Store Bypass).
  - Can be controlled per-process via `prctl()` on Linux.

#### Bypass Techniques

- **Microarchitectural Timing**: Using cache timing, TLB timing, or other side channels.
- **Cross-Process Leakage**: Exploiting shared microarchitectural state between processes.
- **Hardware Implementation Gaps**: CPU-specific vulnerabilities in mitigation implementations.
- **Performance Optimization Exploitation**: Targeting cases where mitigations are disabled for performance.

