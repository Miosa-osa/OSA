#### Windows 11 Patch Diffing

This checklist mirrors the Apple IPSW workflow but uses Microsoft tooling and build numbers.

1. Identify the target update
   - Open **Settings → Windows Update → Update history** or consult the Windows Release Health dashboard to note the **KB** and **OS build** numbers (e.g., _KB5037778 → build 22631.3525_).
   - Record the previous build you want to diff against (e.g., _22631.3447_).

2. Collect the binaries

```bash
winbindex download tcpip.sys 10.0.22631.3447 10.0.22631.3525

mkdir pre,post
wget -Uri https://www.catalog.update.microsoft.com/Download.aspx?q=KB5037778 -OutFile kb.msu
expand -F:* .\kb.msu .\post
# repeat for the older KB into .\pre
# Download both *UUP* bundles, then run
uup_download_windows.cmd --extract
# and copy changed PE files to *pre* / *post*
```

3. Fetch matching symbols

```powershell
# Requires Debugging Tools for Windows
foreach ($ver in '3447','3525') {
    symchk /r .\$ver /s SRV*https://msdl.microsoft.com/download/symbols
}
```

4. Load in the disassembler
   - Open _tcpip.sys_ from both **pre** and **post** folders in **IDA 8+** or **Ghidra 11**; ensure PDB symbols resolve.
   - Save the IDA databases (e.g., `tcpip_3447.i64`, `tcpip_3525.i64`).

5. Run the diff
   - **BinDiff 7**: _Tools → BinDiff → Diff Database…_ and select the two IDBs to generate a `.BinDiff` report.
   - **Ghidriff** (headless):
     ```bash
     ghidriff diff pre/tcpip.sys post/tcpip.sys -o tcpip.diff
     ```

6. Triage the results
   - Sort by _Similarity %_ ascending; investigate anything below **95 %**.
   - Focus on functions with names like `Validate`, `Parse`, `Copy`, `Check`, or protocol‑specific handlers (`IppReceiveEsp`, `Ipv6pFragmentReassemble`, etc.).
   - Determine whether changes add bounds checks, size validations, or privilege checks.

7. Validate in a lab VM
   - Snapshot two Windows 11 VMs (build **3447** and **3525**).
   - Attach WinDbg (kernel mode) using `bcdedit /dbgsettings net hostip:<IP> port:<PORT>`.
   - Reproduce the issue against the **pre‑patch** VM; confirm no crash or breakpoint triggers in the **post‑patch** VM.

8. Automate monthly
   - Schedule a PowerShell script that, every Patch Tuesday (second Tuesday), downloads the latest Cumulative Update, extracts changed PE files, retrieves symbols, and launches a headless **Diaphora** diff.
   - Email the generated HTML report to quickly spot new attack surface.

> [!TIP]
> For large modules like **ntoskrnl.exe**, diff only the `.text` section to save RAM:  
> bindiff --primary ntoskrnl_pre.i64 --secondary ntoskrnl_post.i64 --section .text

#### Linux Kernel Patch Diffing

Patch‑diffing Linux kernels is often faster at the source level, but for binary‑only targets (vendor kernels, modules) function‑level diffing is still practical.

1. Identify target builds
   - Note distro and kernel build (e.g., Ubuntu `6.8.0-47-generic`, RHEL `5.14.0-503`).
   - Capture both pre and post versions (package changelogs or CVE bulletins help).

2. Fetch kernel images and debug info
   - Ubuntu/Debian:
     ```bash
     # Discover versions
     apt list -a linux-image-generic | cat
     # Download image + modules dirs (repeat for both versions)
     apt-get download linux-image-unsigned-<ver>-generic linux-modules-<ver>-generic
     # Debug symbols via debuginfod (preferred to ddebs)
     export DEBUGINFOD_URLS="https://debuginfod.ubuntu.com https://debuginfod.debian.net"
     ```
   - Fedora/RHEL/CentOS:
     ```bash
     dnf download kernel-core-<ver> kernel-debuginfo-<ver>
     rpm2cpio kernel-core-<ver>.rpm | cpio -idmv
     rpm2cpio kernel-debuginfo-<ver>.rpm | cpio -idmv
     ```

3. Extract `vmlinux`

   ```bash
   # If only vmlinuz is present, use the upstream helper
   /usr/src/linux-headers-<ver>/scripts/extract-vmlinux /boot/vmlinuz-<ver> > vmlinux-<ver>
   # Or take vmlinux directly from debuginfo package tree
   ```

4. Identify changed modules quickly

   ```bash
   # Compare module trees (pre vs post)
   rsync -rcn --delete /lib/modules/<pre>/ /lib/modules/<post>/ | grep -E "\.ko$" | sed 's/^/chg: /'
   ```

5. Function‑level binary diff
   - Open `vmlinux-<pre>` and `vmlinux-<post>` in Ghidra 11/IDA 8 and run Diaphora/BinDiff/Ghidriff.
   - For hot subsystems (e.g., `io_uring`, `net/ipv6`, `fs/overlayfs`), diff only the relevant `.ko` pairs to reduce noise.

6. Source‑level triage (when sources are available)

   ```bash
   # Ubuntu example: unpack both source trees, then
   git diff --no-index -- function.c.orig function.c.patched | less
   # Or use diffoscope for enriched reports
   ```

7. Symbolization and crash mapping (cheat‑sheet)

   ```bash
   # Decode kernel oops backtraces to lines
   ./scripts/decode_stacktrace.sh vmlinux /lib/modules/<ver>/build < dmesg.log
   # Map PC to file:line quickly
   addr2line -e vmlinux-<ver> 0xffffffff81234567
   ```

> [!TIP]
> For modern distros built with Clang: KCFI and fine‑grained CFI thunks create many small stub changes; filter by real function body deltas to focus on security‑relevant logic.

> [!NOTE]
> Syzkaller routinely bisects kernel bugs; consult syzbot reports for reproducers and fix commits, then confirm your diff isolates the same region before deeper RE.

#### Kernel network parser identification heuristics (SMB2-inspired, broadly applicable)

##### Cross-field invariants (length/offset/next)

- Always validate `(offset + length) <= remaining_buffer` and `<= total_buffer` using a widened type (e.g., `u64`) before arithmetic; reject on overflow with `check_add_overflow()`/`array_size()` helpers.
- For chained entries with a `next` field, assert: `next >= sizeof(entry_header)`, `next <= remaining_buffer`, and that pointer advancement actually makes progress. For entries carrying sub-lengths (e.g., `name_len`, `value_len`), assert `header + name_len + value_len <= next`.
- Do not cast to a struct until the full header is present and aligned; gate recasts with a prior `buf_len` check.

##### Fixed-size buffers vs variable-length payloads

- Ban unbounded copies/crypto/decompression into fixed-size arrays. Require `len <= sizeof(array)` (or clamp with `min_t()` and bail) when writing into in-struct arrays.
- Crypto transforms are just writes with extra steps: if using ARC4/AES helpers that copy `len` bytes into a fixed buffer (e.g., session keys), bound `len` against a named maximum constant and prefer allocating a buffer sized from validated `len`.

##### Type/width hazards

- Normalize parser math to a wide unsigned type before comparisons; avoid truncating `u32/u64` fields into `u16` for size checks. Favor `size_t/u64` for `offset+len` arithmetic, then compare to `buf_len` of the same width.

##### Loop structure around `next`

- Pattern to flag: `e = (struct entry *)((char *)e + next);` without a preceding block that revalidates `buf_len` and the entry’s internal sub-lengths.
- Ensure a break condition on exhaustion and reject zero/negative progress values to avoid infinite loops or pointer stagnation.

##### Allocation-size correlation

- When parser-controlled `len` influences a subsequent write into an object from a fixed SLUB cache (e.g., `kmalloc-512`), ensure the write length is bounded by the destination object field, not just the incoming length.

##### Patch-diff signals to prioritize

- Newly added guards like `if (len > CONST) return -EINVAL;`, `if (buf_len < sizeof(struct foo)) return -EINVAL;`, or conversions to `min_t(size_t, len, sizeof(...))`.
- Insertions of `check_add_overflow(offset, len, &sum)` or `array_size(n, sz)` helpers in hot parse paths.

##### Static query seeds (Semgrep/CodeQL), to tune per codebase

- Unbounded copies into struct fields:
  ```yaml
  rules:
    - id: c-fixed-array-unbounded-copy
      languages: [c, cpp]
      patterns:
        - pattern: memcpy($DST, $SRC, $LEN)
        - pattern-inside: |
            struct $S { ... char $BUF[$N]; ... };
            ...
            $DST = &...->$BUF
        - pattern-not: memcpy($DST, $SRC, MIN($LEN, sizeof(*$DST)))
      message: Unbounded copy into fixed-size struct field
      severity: WARNING
  ```
- Dangerous `next`-driven pointer arithmetic without bounds checks:
  ```yaml
  - id: c-parser-next-missing-bounds
    languages: [c, cpp]
    pattern: |
      $E = (struct $T *)((char *)$E + $NEXT);
    message: Parser advances by user-controlled 'next' without prior buf_len/sizeof checks
    severity: WARNING
  ```
- Crypto/decompression writes to fixed arrays (seed with function names in your tree, e.g., `*_crypt`, `*_decrypt`, `decompress_*`).

##### Dynamic confirmation (cheap)

- Grammar fuzz small invariants: send `next < header`, `next > remaining`, `name_len + value_len > next`, and `len > MAX_CONST` variants; expect `-EINVAL`/reject. If not, investigate.
- Use TUN/TAP + KCOV to drive packet/SMB request paths; enable KASAN/KMSAN to surface overflows/leaks early.

##### Reference (motivating example)

- Lessons distilled from a 2025 ksmbd remote chain writeup combining a fixed-buffer overflow in NTLM auth with an EA `next` validation issue — see Will’s Root: Eternal‑Tux: KSMBD 0‑Click RCE (`https://www.willsroot.io/2025/09/ksmbd-0-click.html`).

#### Case Study: EvilESP Vulnerability (CVE-2022-34718)

This case study demonstrates real-world patch diffing to identify a Windows TCP/IP RCE vulnerability.

##### Vulnerability Overview

- CVE-2022-34718: Critical RCE in `tcpip.sys` discovered in September 2022
- An unauthenticated attacker could send specially crafted IPv6 packets to Windows nodes with IPsec enabled
- Affects the handling of ESP (Encapsulating Security Payload) packets in IPv6 fragmentation

##### Patch Diffing Process

1. **Binary Acquisition**
   - Used Winbindex to obtain sequential versions of `tcpip.sys` (pre-patch and post-patch)
   - Loaded both files in Ghidra with PDB symbols

2. **Diff Analysis**
   - Used BinDiff to compare the binaries
   - Identified only two functions with less than 100% similarity: `IppReceiveEsp` and `Ipv6pReassembleDatagram`

3. **Code Analysis**
   - **Ipv6pReassembleDatagram**: Added bounds check comparing `nextheader_offset` against the header buffer length
   - **IppReceiveEsp**: Added validation for the Next Header field of ESP packets

4. **Root Cause Identification**
   - Found an out-of-bounds 1-byte write vulnerability
   - ESP Next Header field is located after the encrypted payload data
   - A malicious packet could cause `nextheader_offset` to exceed the allocated buffer size

_(Update: Server 2022 build 20349.2300, May 2024, hardened this code path; the original PoC needs a 2-byte pad tweak to reproduce the crash.)_

##### Exploitation

- Required setting up IPsec security association on the victim
- Created fragmented IPv6 packets encapsulated in ESP
- Controlled the offset of the out-of-bounds write through payload and padding size
- Value written is controllable via the Next Header field
- Limited to writing to addresses that are 4n-1 aligned (where n is an integer)
- Initially achieved DoS with potential for RCE through further exploitation

##### Lessons Learned

- Binary patch diffing effectively identified the vulnerability location and nature
- Understanding protocol specifications (ESP and IPv6 fragmentation) was critical
- Simple buffer checks are still overlooked in complex networking code
- Even limited primitives (single byte overwrite at constrained offsets) can be dangerous
- For modern exploitation techniques, see [Modern Samples](/exploit/modern-samples.md)
- For mitigation bypass techniques, see [Modern Mitigations](/exploit/modern-mitigations.md)

When applying patch diffing to networking protocols:

1. Understand the protocol specifications thoroughly
2. Look for missing bounds checks in data processing
3. Pay attention to buffer size calculations
4. Check for proper validation of protocol field values and locations
5. Consider evasion techniques for exploit deployment - see [EDR](/exploit/edr.md)
6. Specs: ESP (RFC 4303) and IPv6 (RFC 8200) are essential references when reasoning about header placement and bounds

#### Semi-Automatic Patch Diffing

- Use [WinbIndex](https://winbindex.m417z.com/) to download the changed binary and then use [BinDiff](https://www.zynamics.com/bindiff.html) or [Ghidriff](https://github.com/clearbluejar/ghidriff) to actually see the diff itself
- You can also use [Diaphora](https://github.com/joxeankoret/diaphora) instead of BinDiff

#### Manual Patch Diffing

- Microsoft releases patches on the second Tuesday of each month
- For Windows you can go to [update catalog](https://www.catalog.update.microsoft.com/Search.aspx) and search for the product version (for example `2022-10 x64 "Windows 10" 22H2`)
- Try to look for smaller updates

```shell
mkdir 2022-09
mv *.msu 2022-09
cd 2022-09
mkdir extract
mkdir patch
expand -F:* .\*.msu .\extract
expand -F:* .\extract\<largest>.cab .\patch
expand -F:* .\patch\<largest>.cab .\patch
expand -F:* .\patch\Cab_* .\patch\
```

You can use [Patch Extract](https://gist.github.com/abzcoding/f6191c3aa9ca6d019f360b429d6b510f) instead

```shell
gci -Recurse c:\windows\WinSxS\ -Filter ntdll.dll
# copy the biggest file somewhere
.\delta_patch.py -i .\NTDLL\ntdll.dll -o ntdll.2020-10.dll .\NTDLL\r\ntdll.dll .\2020-10\x64\ntdll_<stuff>\f\ntdll.dll
.\delta_patch.py -i .\NTDLL\ntdll.dll -o ntdll.2020-11.dll .\NTDLL\r\ntdll.dll .\2020-11\x64\ntdll_<stuff>\f\ntdll.dll
```

Open unpatched version in IDA as the primary and the second, after that use BinDiff add-on to find the differences between them
then right click on a different matched function and see the visual diff in bin diff
also you can uncheck proximity browsing to see the entire function
look at red blocks and then yellow blocks

With patch clean script you can only see the actual changed files

### Static Analysis Tools

