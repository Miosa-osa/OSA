---
name: offensive-edr-evasion
description: "EDR evasion offensive checklist: hook unhooking (user/kernel), direct syscalls, PPID spoofing, process injection variants, AMSI bypass, ETW patching, memory encryption, and behavior-based evasion. Use when planning EDR bypass during red team engagements or researching AV/EDR evasion techniques."
category: security
triggers:
  - "edr evasion"
  - "offensive edr evasion"
  - "infrastructure"
  - "infrastructure attack"
  - "infrastructure exploitation"
  - "edr evasion methodology"
tools:
  - file_read
  - file_glob
  - file_grep
  - file_write
  - file_edit
  - dir_list
  - shell_execute
  - web_fetch
  - web_search
  - delegate
---

# SKILL: Endpoint Detection and Response

## Metadata
- **Skill Name**: edr-evasion
- **Folder**: offensive-edr-evasion
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/edr.md

## Description
EDR evasion offensive checklist: hook unhooking (user/kernel), direct syscalls, PPID spoofing, process injection variants, AMSI bypass, ETW patching, memory encryption, and behavior-based evasion. Use when planning EDR bypass during red team engagements or researching AV/EDR evasion techniques.

## Trigger Phrases
Use this skill when the conversation involves any of:
`EDR evasion, EDR bypass, hook unhooking, direct syscalls, PPID spoofing, process injection, AMSI bypass, ETW patch, memory encryption, AV evasion, behavioral evasion, red team evasion`


## Full Methodology

# Endpoint Detection and Response

## Fundamentals

### AV vs EDR

**Antivirus (preventive approach)**:

- Static Analysis: Matching known signatures in files
- Dynamic Analysis: Limited behavioral monitoring/sandboxing
- Effective against known threats, weaker against advanced attacks

**EDR (proactive & investigative approach)**:

- Continuous endpoint monitoring
- Behavioral analysis at kernel level
- Anomaly detection and post-compromise visibility
- Prioritizes incident response and investigation

### Windows Execution Flow

Windows program execution follows a hierarchical flow:

1. **Applications** - User programs like firefox.exe
2. **DLLs** - Libraries providing Windows functionality without direct low-level access
3. **Kernel32.dll** - Core DLL for memory management, process/thread creation
4. **Ntdll.dll** - Lowest user-mode DLL that exposes the NT API interface to the kernel
5. **Kernel** - Core OS component with unrestricted hardware access

Example operation flow (creating a file):

1. Application invokes `CreateFile` function
2. CreateFile forwards to `NtCreateFile`
3. Ntdll.dll triggers `NtCreateFile` syscall
4. Kernel creates the file and returns a handle

## EDR Visibility

### EDR Architecture & Components

EDR solutions consist of multiple components creating a complex attack surface:

**Client-Side Components:**

- **User-space Applications** - Main agent processes and UI components
- **Kernel-space Drivers** - Filter drivers, network drivers, software drivers
- **Communication Interfaces** - IOCTLs, FilterConnectionPorts, ALPC, Named Pipes

**Component Communication Methods:**

- **Kernel-to-Kernel**: Exported functions, IOCTLs
- **User-to-Kernel**: IOCTLs, FilterConnectionPorts (minifilter-specific), ALPC
- **User-to-User**: ALPC, Named Pipes, Files, Registry

**Server-Side Components:**

- Cloud services and management consoles
- On-premise servers (some vendors)
- Custom protocols for agent-to-cloud communication

### EDR Visibility Methods

EDR solutions require extended visibility into system activities:

- Filesystem monitoring via mini-filter drivers
- Process/module loading via image load kernel callbacks
- Process/.NET modules/Registry/kernel object events via ETW Ti
- Network monitoring via NDIS and network filtering drivers

### Static Analysis

- Extract information from binary
  - Known malicious strings
  - Threat actor IP or domains
  - Malware binary hashes

### Dynamic Analysis

- Execute binary in a sandbox environment and observe it
  - Network connections
  - Registry changes
  - Memory access
  - File creation/deletion
- AntiMalware Scan Interface

### Behavioral Analysis

- Observe the binary as its executing, Hook into functions/syscalls
  - User actions
  - System calls
  - Kernel callbacks
  - Commands executed in the command line
  - Which process is executing the code
  - Event Tracing for Windows

## Detection Methods

### AV Signature Scanning

- Scans files using known signatures (YARA rules)
- Typically targets loaders and droppers
- Primarily static analysis of files on disk

### AV Emulation

- Runs suspicious programs in a simulated environment
- Triggers on behaviors without executing real code
- Used to detect obfuscated malware

### Usermode Hooks

- EDR hooks critical API calls in userspace (ntdll.dll)
- Monitors process creation, memory allocations, and network operations
- Allows for inspection before execution continues

### Kernel Telemetry

- Monitors events directly from the kernel
- Captures file, registry, process, and network operations
- Difficult to bypass as it operates at a lower level

### Memory Scanning

- Scans process memory for known signatures
- Triggers based on suspicious behavior
- Looks for shellcode, encryption, malicious strings
- **Modern Context:**
  - Attackers also scan process memory for sensitive artifacts like authentication tokens. Co‑pilot/IDE integrations, chat assistants, and browser extensions frequently cache Bearer/JWT tokens in memory.
  - Practical triage: search for `"Authorization: Bearer"`, `"eyJ"` (base64 JWT prefix), or provider‑specific headers; dump minimal pages to avoid tripping anti‑exfil rules.

## OpSec Quickstart (lab)

- Pre‑run
  - Network: block or sinkhole vendor EDR/XDR endpoints; disable cloud sample submission; tag lab hosts.
  - Mitigations snapshot: `Get-ProcessMitigation -System`; `Get-CimInstance Win32_DeviceGuard` (VBS/HVCI/KDP); `Get-MpPreference` (ASR/Cloud).
  - Events baseline: enable and tail `Microsoft-Windows-CodeIntegrity/Operational`, `Security (4688/4689)`, `Microsoft-Windows-Sense/Operational`, Sysmon (if present).
- Injection hygiene
  - Favor `MEM_IMAGE` mappings (ghosting/herpaderping/overwriting) over `MEM_PRIVATE` RWX to avoid 24H2 hotpatch loader checks.
  - Satisfy XFG/CET: jump via import thunks; ensure IBT `ENDBR64` at indirect targets; maintain plausible stacks for syscalls (replicate `ntdll` frames).
  - Avoid noisy APIs: split `alloc/write/exec` over time; prefer APC+`NtContinue` pivots; keep thread contexts consistent.
- Telemetry minimization
  - Jitter long‑lived channels; prefer named‑pipe/HTTP3 over noisy HTTP1; throttle upload intervals.
  - Use COM/runspace over PowerShell console to reduce script‑block logs; avoid AMSI‑flagged prologues.
- Cleanup
  - Remove services, tasks, drivers; restore SDDL; revert registry policy flips (WDAC/CI/Defender) and re‑enable protections.
  - Purge user caches (Recent Files, Jump Lists) and ETW providers enabled during tests.

### Memory Regions

- Monitors suspicious memory allocation patterns
- Flags RWX (read-write-execute) regions
- Tracks regions that change from RW to RX

### Callstack Analysis

- Examines the call stack of suspicious functions
- Verifies legitimate origin of critical operations
- Detects unusual function call chains

### Hook Implementation

EDRs can't directly hook kernel memory due to PatchGuard, so they:

1. Inject their DLL into newly spawned processes
2. Position before malware can block/unmap it
3. Adjust `_PEB`, hook process's module `IAT`/Imports, and loaded libraries `EAT`/Exports
4. Implement trampolines, hooks, and detours

### ETW Monitoring

- EDR maintains ring-buffer with per-process activities produced by ETW Ti:
  - Processes, command lines, parent-child relationships
  - File/Registry/Process open/write operations
  - Created threads, their call stacks, starting addresses
  - Native functions called
  - Created .NET AppDomains, loaded .NET assemblies, static class names, methods

#### Event Correlation

- High fidelity alert (such as LSASS open) triggers correlation of collected activities
- High memory/resources cost limits preservation of events to a time window
- ML/AI may compute risk scores and isolate TTP (Tactics, Techniques, and Procedures)

#### Shellcode Loaders

Shellcode loaders typically follow this pattern:

```c
char *shellcode = "\xAA\xBB...";
char *dest = VirtualAlloc(NULL, 0x1234, 0x3000, PAGE_READWRITE);
memcpy(dest, shellcode, 0x1234)
VirtualProtect(dest, 0x1234, PAGE_EXECUTE_READ, &result)
(*(void(*)())(dest))();  // jump to dest: execute shellcode
```

## Attacking EDR Infrastructure Directly

### Driver Attack Surface Analysis

A systematic approach to analyzing EDR drivers from a low-privileged user perspective:

#### 1. Driver Discovery

**Static Analysis:**

```powershell
# List loaded drivers
driverquery /v
Get-WindowsDriver -Online -All

# Using WMI
Get-WmiObject Win32_PnPSignedDriver | Select-String "EDR_Vendor"
```

**Dynamic Analysis:**

```powershell
# Using sc command
sc query type= driver state= all

# Process Monitor filtering
# Filter: Process and Thread Activity -> Show Image/DLL
```

#### 2. Interface Enumeration

**Device Driver Interfaces:**

- Listed in WinObj under "GLOBAL??" as Symbolic Links
- Accessible via `\\.\DEVICE_NAME` format
- Tools: WinObj (Sysinternals), DeviceTree (OSR - discontinued)

**Mini-Filter Driver Interfaces:**

- Listed in WinObj as "FilterConnectionPort" objects
- Communication via `FltCreateCommunicationPort` API
- Example paths: `\CyvrFsfd`, `\SophosPortName`

#### 3. Access Permission Analysis

**Device Driver ACL Checking:**

```cpp
// Using DeviceTree (preferred) or kernel debugger
// WinDbg example:
!object \Device\DeviceName
!sd <SecurityDescriptor_Address> 1
```

**FilterConnectionPort ACL Checking:**

```powershell
# Using NtObjectManager (James Forshaw)
Get-FilterConnectionPort -Path "\FilterPortName"
# Error indicates access denied

# In WinDbg:
!object \FilterPortName
dx (((nt!_OBJECT_HEADER*)0xAddress)->SecurityDescriptor & ~0xa)
!sd <SecurityDescriptor_Address> 1
```

#### 4. Interface Functionality Analysis

**Device Driver Communication:**

- Primary method: DeviceIoControl() → IRP_MJ_DEVICE_CONTROL
- IOCTL codes differentiate between functions
- May include process ID verification for authorization

**FilterConnectionPort Communication:**

- Uses callback functions: ConnectNotifyCallback, DisconnectNotifyCallback, MessageNotifyCallback
- Similar to IOCTL dispatch with different message types

#### 5. Common EDR Driver Interfaces

**Examples of accessible interfaces found in research:**

**Palo Alto Cortex XDR:**

- **Device Interfaces**:
  - `\\.\PaloEdrControlDevice` (tedrdrv.sys) - ~20 IOCTL handlers with various functionality
  - `\\.\CyvrMit` (cyvrmtgn.sys) - Legacy Cyvera interface
  - `\\.\PANWEdrPersistentDevice11343` (tedrpers-<version>.sys) - Persistent device interface
- **FilterConnectionPort**: Various ports with different ACLs
- **Research Findings**:
  - IOCTL 0x2260D8 returns 3088 bytes of statistics data (accessible to low-privileged users)
  - IOCTL 0x2260D0 provides initialization status information
  - Some interfaces accessible due to injected DLL architecture requiring broad permissions

**Sophos Intercept X:**

- **FilterConnectionPort**: `\SophosPortName`
- **Analysis Results**: Accessible interfaces for legitimate process communication but limited attack surface

#### 6. Why EDRs Have Open ACLs

EDRs often use an architecture where:

- Agent injects DLLs into processes (including low-privileged ones like `word.exe`)
- Injected DLLs communicate directly with drivers via IOCTLs
- Drivers cannot restrict based solely on process privilege level
- Results in more permissive ACLs to accommodate legitimate injected processes



---

## Extended reference

This skill's full detail is split: read `references/detail.md` with file_read when you need the deep payload tables, tool matrices, or per-technique checklists that did not fit the skill body.
