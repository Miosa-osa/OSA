### Supply Chain Attack Surface

#### Package Manager Vulnerabilities

- **Dependency Confusion:** Internal vs public package name conflicts
- **Typosquatting:** Similar package names (numpy vs numpi)
- **Manifest Manipulation:** Lock file poisoning, version pinning bypass
- **Build-time Injection:** Malicious install scripts, post-install hooks

#### CI/CD Pipeline Analysis

- **GitHub Actions:** Workflow poisoning via PR from forked repos
- **Jenkins:** Groovy script injection, plugin vulnerabilities
- **Docker:** Build argument exploitation, base image substitution
- **Secrets Exposure:** Environment variables in build logs, artifact leakage

### AI & LLM Application Security

- Prompt‑injection, sandbox boundary escapes, hidden‑channel data exfil
- See [AI Security](/pentest/ai.md) for a deeper checklist

### Confidential‑Computing / TEE Surface

- **Intel TDX**: diff `tdx.ko` or `tdx_psci.c` between kernel LTS branches to spot new GPA→HPA validation checks.
- **AMD SEV‑SNP**: look for unchecked `VMGEXIT` leafs in PSP firmware; `sevtool --decode` helps locate IDA entry points.
- **Arm CCA / RMM**: analyze SMC handlers inside Realm Management Monitor (RMM) EL3 firmware.
- **Cloud offerings (Azure CCE, Google C3)**: focus on paravirtualised MMIO and attestation report flows exposed to guests.
- For TEE-specific exploitation, see [Secure Enclaves](/exploit/secure-enclaves.md)

### GPU & vGPU Surface

- **HGX HMC (verify CVE/advisories)**: research indicates malformed NVLINK‑C2C packets can corrupt HMC register space; confirm against vendor advisories for the specific platform.
- **vGPU manager IOCTLs**: diff `nvidia‑vgpu‑mgr` monthly; watch `VGPU_PLUGIN_IOCTL_GET_STATE` and similar calls for unchecked buffers.
- **LeftoverLocals info‑leak**: contiguous VRAM allocations can leak data from prior tenants in multi‑tenant AI clusters.

### Hardware Security Attack Surface

#### Side-Channel Analysis

- **Power Analysis:** DPA/SPA attacks on cryptographic operations
- **Electromagnetic (EM):** Near-field probing of processor emissions
- **Timing Attacks:** Cache timing, branch prediction analysis
- **Acoustic:** Key extraction via CPU sound emissions

#### Fault Injection

- **Voltage Glitching:** Brown-out attacks on secure boot
- **Clock Glitching:** Skip instruction execution
- **Laser Fault Injection (LFI):** Targeted bit flips
- **EM Pulse Injection:** Wider area fault induction

#### Hardware Implants & Supply Chain

- **PCB Modification:** Added components, trace rerouting
- **Firmware Backdoors:** UEFI/BMC persistent implants
- **Hardware Trojans:** Malicious logic in ICs
- **DMA Attacks:** PCIe, Thunderbolt, FireWire exploitation

### EDR Driver Vulnerability Research

#### Common vulnerability types in EDR drivers

- Authorization bypass issues
- Memory corruption in IOCTL handlers
- Race conditions in driver communication
- Improper input validation
- For detailed EDR analysis techniques, see [EDR](/exploit/edr.md)

#### Research methodology

1. Identify accessible driver interfaces
2. Reverse engineer IOCTL/message handlers
3. Analyze authorization mechanisms
4. Test for input validation flaws
5. Look for race conditions and memory corruption

#### Tools for driver analysis

- IDA Pro / Ghidra for reverse engineering
- WinDbg for dynamic analysis
- Process Monitor for behavior analysis
- Custom fuzzing tools for interface testing

#### Quick triage rubric (post‑crash)

- Buffer overflow vs UAF: check access type, allocation lifetime, and red‑zones (ASan/KASAN reports)
- Integer issues: trace size/length and allocation math; look for truncation/casts
- Logic bugs: unexpected state transitions without memory errors; validate auth/flags
- Info‑leaks: uninitialized reads, OOB reads, pointer/string formatters

#### Coverage‑first recon checklist

- Produce one baseline coverage run (e.g., `drcov`, Intel® PT, or Lighthouse import)
- Identify cold paths reachable from attacker inputs
- Seed corpus: include minimal valid examples that traverse target parsers
- Enable lightweight oracles (ASan/UBSan/KASAN) where feasible to maximize signal

## Static Analysis Methods

Static analysis examines code without execution to identify potential vulnerabilities.

### Manual Code Review

- Installing the target application and examining its structure
- Enumerating the ways to feed input to it
- Examine the file formats and network protocols that the application uses
- Locating logical vulnerabilities or memory corruptions
- For Windows-specific techniques, see [Windows Kernel](/exploit/windows-kernel.md)
- For Linux-specific techniques, see [Linux](/exploit/linux.md)

### Patch Diffing

Patch diffing compares vulnerable and patched versions of binaries to identify security changes.

#### What is Patch Diffing

Patch diffing is a technique to identify changes across versions of binaries related to security patches. It compares a vulnerable version of a binary with a patched one to highlight the changes, helping to discover new, missing, and interesting functionality across versions.

##### Benefits

- **Single Source of Truth**: Without a CVE blog post or sample POC, a patch diff can be the only source of information to determine changes and deduce the original issue.
- **Vulnerability Discovery**: While understanding the original issue, you may discover additional vulnerabilities in the troubled code area.
- **Skill Development**: Patch diffing provides focused practice in reverse engineering and helps build mental models for various vulnerability classes.

##### Challenges

- **Asymmetry**: Small source code changes can drastically affect compiled binaries.
- **Finding Security-Related Changes**: Security patches often include other changes like new features, bug fixes, and performance improvements.
- **Minimizing Noise**:
  - Diff the correct binaries to avoid analyzing unrelated updates
  - Reduce the time delta between compared versions
  - Use binary symbols when available to add precision to comparisons

#### Tools

- IDA Pro with plugins like DarunGrim and Diaphora
- BinDiff Works with analysis output from IDA or Ghidra
- [Ghidriff](https://github.com/clearbluejar/ghidriff): Ghidra binary diffing engine
- Radare2 (radiff2)
- Ghidra Version Tracking Tool
- Ghidra 11 built-in Partial Match Correlator

#### Patch Diffing Workflow

The process of patch diffing typically follows these steps:

1. **Preparation**
   - Create a diffing session
   - Load binary versions (vulnerable and patched)
   - Ensure binaries pass preconditions
   - Run auto-analysis on both binaries

2. **Evaluation**
   - Run correlators to find similarities
   - Generate associations between binaries
   - Evaluate matches between functions
   - Accept matching functions
   - Analyze differences until sufficient understanding is reached

3. **Function Analysis**
   - **Identify new functions**: Functions in the patched binary with no match in the original
   - **Identify deleted functions**: Functions in the original binary with no match in the patched version
   - **Identify changed functions**: Functions that exist in both versions but have been modified
   - Focus on functions with security relevance (often indicated by their names or based on CVE descriptions)

4. **Interpreting Results**
   - New functions often indicate added security checks or validation
   - Changed functions may show modified logic for handling edge cases
   - Correlate changes with public CVE information when available
   - Remember that patches are not necessarily atomic - multiple issues may be fixed in one update

When using Ghidra's Version Tracking:

- Use "Show Only Unmatched Functions" filter to identify new or deleted functions
- Look for functions with a similarity score below 1.0 to find modified functions
- Examine the modified functions to understand what security checks were added

Starting with Ghidra 11 (December 2024) a built-in _Partial Match Correlator_ covers most PatchDiffCorrelator use-cases; install the plugin only if you need bulk-mnemonics scoring.

#### Case Study: 7‑Zip Symlink Path Traversal

- Target: 7‑Zip 24.09 (vulnerable) → 25.00 (fixed)
- File of interest: `CPP/7zip/UI/Common/ArchiveExtractCallback.cpp`
- High‑signal edits: absolute‑path detection and link‑path validation for WSL/Linux symlinks converted on Windows.

##### Minimal security‑relevant diff (simplified):

```cpp
-bool IsSafePath(const UString &path)
+static bool IsSafePath(const UString &path, bool isWSL)
{
  CLinkLevelsInfo levelsInfo;
-  levelsInfo.Parse(path);
+  levelsInfo.Parse(path, isWSL);
  return !levelsInfo.IsAbsolute
      && levelsInfo.LowLevel >= 0
      && levelsInfo.FinalLevel > 0;
}

+bool IsSafePath(const UString &path);
+bool IsSafePath(const UString &path)
+{
+  return IsSafePath(path, false); // isWSL
+}

-void CLinkLevelsInfo::Parse(const UString &path)
+void CLinkLevelsInfo::Parse(const UString &path, bool isWSL)
{
-  IsAbsolute = NName::IsAbsolutePath(path);
+  IsAbsolute = isWSL ? IS_PATH_SEPAR(path[0]) : NName::IsAbsolutePath(path);
  LowLevel = 0;
  FinalLevel = 0;
}
```

##### Root cause (logic):

- Linux/WSL symlink data containing a Windows‑style path (e.g., `C:\...`) was treated as relative by the Linux absolute‑path check, setting `linkInfo.isRelative = true`.
- `SetFromLinkPath` prefixed the symlink’s zip‑internal directory when building `relatPath`, letting `IsSafePath(relatPath)` pass despite an absolute Windows target.
- A subsequent “dangerous link” guard checked `_item.IsDir`; non‑directory symlinks skipped the validation.
- Result: symlink creation to arbitrary absolute Windows paths; extracted files written into the link target.

##### Practical triage checklist:

- Search this file for: `IsSafePath`, `CLinkLevelsInfo::Parse`, `SetFromLinkPath`, `CloseReparseAndFile`, `FillLinkData`, `CLinkInfo::Parse`, `_ntOptions.SymLinks_AllowDangerous`.
- Verify absolute‑path detection across OS semantics (Linux vs Windows) and that relative/absolute status cannot be desynced by mixed‑style paths.
- Ensure “dangerous link” checks run for both files and directories; avoid `_item.IsDir` short‑circuiting validation for file symlinks.
- Confirm `IsSafePath` evaluates the final target path after concatenations; normalize before validation.

##### Quick repro (Windows, developer mode or elevated):

- Create zip structure:
  - `data/link` → symlink to `C:\Users\<USER>\Desktop`
  - `data/link\calc.exe` → payload file
- If `link` is extracted first, subsequent writes follow the symlink into the absolute target directory.

#### Apple Patch Diffing

- Identify a CVE of interest
- Download corresponding IPSW and update and N-1
  - use [ipsw.me](https://ipsw.me/) to download those files
  - convert the downloaded `.ipsw` to `.zip`
- Determine changes for update
  - you can use [IPSW tool](https://github.com/blacktop/ipsw) to download and diff
- Map binaries to CVE
- Extract the related file(s)
- Diff the binaries
  - In Ghidra set Decompiler Parameter ID to true
  - Leverage [IDAObjectTypes](https://github.com/PoomSmart/IDAObjcTypes)
- Root cause the vulnerability

```bash
# Downloading the correct IPSWs
ipsw download --device Macmini9,1 -V -b 23A344
ipsw download --device Macmini9,1 -V -b 23B74

# Comparing two different IPSWs
ipsw diff UniversalMac_14.0_23A344.ipsw UniversalMac_14.1_23B74.ipsw

# What is inside the DSC
ipsw extract -d IPSW

# Extracting files
ipsw extract -f -p file

# Extracting specific architecture file
ipsw macho lipo Contacts
```

