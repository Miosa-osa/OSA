#### Practitioner

- Check mitigations: `cat /proc/cpuinfo | grep -E "(ibpb|ibrs|stibp|ssbd)"`
- Runtime controls: `/sys/devices/system/cpu/vulnerabilities/` directory
- Per-process SSBD: `prctl(PR_SET_SPECULATION_CTRL, PR_SPEC_STORE_BYPASS, ...)`
- Performance impact: Use `perf` to measure mitigation overhead

### Kernel Memory Sanitizer (KMSAN)

- Linux:
  - Detects use of uninitialized memory in the kernel.
  - Helps find and fix initialization bugs.

### Linux Kernel Runtime Guard (LKRG)

- Linux (Module):
  - Loadable kernel module performing runtime integrity checks on critical kernel structures.
  - Aims to detect and prevent various exploits in real-time.

### Spectre-BHB Mitigations

- Linux:
  - Addresses Branch History Injection vulnerabilities on ARM.
  - Prevents certain speculative execution attacks.

## Dynamic Analysis and Detection Tools

### Kernel Address Sanitizer (KASAN)

- Linux:
  - Dynamic memory error detector for the kernel.
  - Identifies use-after-free and out-of-bounds bugs.

### eBPF Verification Enhancements

- Linux:
  - Strengthens verification of eBPF programs loaded into the kernel.
  - Prevents exploitation via the eBPF subsystem.

## Windows Defender Security Features

### Windows Defender Application Control (WDAC)

- Windows:
  - Controls which drivers and applications are allowed to run.
  - Uses code integrity policies to prevent unauthorized code execution.

#### Practitioner

- Enumerate policies: `Get-CIPolicy -Effective` and `Get-ComputerInfo | Select WindowsProductName, WindowsVersion`.
- Validate blocklists: ensure `DriverSiPolicy.p7b` is current; check with `gpresult /r` or MEM policies.

### Exploit Protection

- Windows:
  - System-wide mitigation settings against common exploit techniques.
  - Includes heap spray allocation prevention, mandatory ASLR, etc.

#### Practitioner

- Export/import settings via `Export-ProcessMitigation` / `Set-ProcessMitigation`.
- Audit per‑process: `Get-ProcessMitigation` for DEP/ASLR/SEHOP/CFG/XFG.

### Attack Surface Reduction (ASR) Rules

- Windows:
  - Part of Windows Defender Exploit Guard, providing configurable rules.
  - Blocks specific behaviors often associated with malware or exploits (e.g., Office macro execution, script obfuscation).

#### Practitioner

- Query ASR state: `Get-MpPreference | Select -ExpandProperty AttackSurfaceReductionRules_Ids, AttackSurfaceReductionRules_Actions`.
- Enable common rules in audit first; deploy in enforced after tuning.

### Smart Screen

- Windows:
  - Analyzes files and websites for suspicious characteristics.
  - Warns or blocks potentially malicious content.

### Controlled Folder Access

- Windows:
  - Protects files and folders from unauthorized changes.
  - Helps prevent ransomware from encrypting or deleting data.



---

## Extended reference

This skill's full detail is split: read `references/detail.md` with file_read when you need the deep payload tables, tool matrices, or per-technique checklists that did not fit the skill body.
