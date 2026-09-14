## Full Methodology

# Week 2: Finding Vulnerabilities Through Fuzzing

## Overview

_created by AnotherOne from @Pwn3rzs Telegram channel_.

This document is Week 2 of a multi‑week exploit development course, focusing on discovering vulnerabilities through fuzzing techniques and analyzing the crashes to determine exploitability.

Last week we studied vulnerability classes through real-world examples. This week we'll learn to find these vulnerabilities ourselves using fuzzing - the automated technique that has discovered thousands of critical security bugs in production software.

Fuzzing can feel a bit front‑loaded: you may spend time wiring harnesses and running campaigns without immediately finding exciting new bugs, especially on hardened or well‑tested targets. That’s normal, and it's one reason the next week on patch diffing often feels more directly "practical" — many companies already run large fuzzing setups and need people who can understand and exploit the bugs those systems uncover. Still, working through this week is important: it teaches you how fuzzers actually discover real vulnerabilities, so when you later triage crashes or study patches, you'll have a solid intuition for how those bugs were found and how to reproduce them.

### Prerequisites

Before starting this week, ensure you have:

- A Linux virtual machine (Ubuntu 24.04 recommended) with at least 8GB RAM and 8 cpu cores
- Basic understanding of C/C++ programming
- Familiarity with command-line tools and debugging (GDB basics)
- Understanding of memory corruption vulnerabilities (from Week 1)

## Day 1: Introduction to Fuzzing

- **Goal**: Understand the fundamentals of fuzzing and get hands-on experience with `AFL++`.
- **Activities**:
  - _Reading_: "Fuzzing for Software Security Testing and Quality Assurance" by `Ari Takanen`(From 1.3.2 to 1.3.8 and 2.4.1 to 2.7.5).
  - _Online Resource_:
    - [Fuzzing Book by `Andreas Zeller`](https://www.fuzzingbook.org/) - Read "Introduction" and "Fuzzing Basics."
    - [`AFL++` Documentation](https://aflplus.plus/docs/) - Follow the quick start guide.
    - [Interactive Module to Learn Fuzzing](https://github.com/alex-maleno/Fuzzing-Module.git)
  - _Real-World Context_:
    - [Google OSS-Fuzz: Finding 36,000+ bugs across 1,000+ projects](https://google.github.io/oss-fuzz/)
    - [AFL Success Stories](https://lcamtuf.blogspot.com/2014/11/afl-fuzz-nobody-expects-cdata-sections.html) - Real vulnerabilities found by AFL
  - _Exercise_:
    - Set up a Linux virtual machine (VM) with the necessary tools installed, including compilers and debuggers
    - Run `AFL++` on a C program
    - If possible, use or write a small C program that contains a simple version of one of the Week 1 vulnerability classes (for example, a stack buffer overflow or integer overflow) so you can see fuzzing rediscover it.

```bash
# Setting up AFL++

# Install build dependencies
sudo apt update
sudo apt install -y build-essential gcc-13-plugin-dev cpio python3-dev libcapstone-dev \
    pkg-config libglib2.0-dev libpixman-1-dev automake autoconf python3-pip \
    ninja-build cmake git wget python3.12-venv meson

# Install LLVM (check latest version at https://apt.llvm.org/)
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 19 all

# Verify LLVM installation
clang-19 --version
llvm-config-19 --version

# Install Rust (required for some AFL++ components)
curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh
source ~/.cargo/env

# Build and install AFL++
mkdir -p ~/soft && cd ~/soft
git clone --depth 1 https://github.com/AFLplusplus/AFLplusplus.git
cd AFLplusplus
# NOTE: unicorn support might fail(you need to add the env or run ./build_unicorn_support.py and fix issues yourself)
make distrib
sudo make install

# Verify installation
which afl-fuzz
afl-fuzz --version

# Phase 1: Simple crash example
cd ~/ && mkdir -p tuts && cd tuts
git clone --branch main --depth 1 https://github.com/alex-maleno/Fuzzing-Module.git
cd Fuzzing-Module/exercise1 && mkdir -p build && cd build

# Compile with AFL++ instrumentation
CC=/usr/local/bin/afl-clang-fast CXX=/usr/local/bin/afl-clang-fast++ cmake ..
make

# Create seed inputs
cd .. && mkdir -p seeds && cd seeds
for i in {0..4}; do
    dd if=/dev/urandom of=seed_$i bs=64 count=10 2>/dev/null
done

# Run AFL++ fuzzer
cd ../build
echo core | sudo tee /proc/sys/kernel/core_pattern
afl-fuzz -i ../seeds/ -o out -m none -d -- ./simple_crash

# Expected output: AFL++ interface showing coverage, crashes, etc.
# Look for crashes in out/crashes/ directory

# Phase 2: Medium complexity example
cd ~/tuts/Fuzzing-Module/exercise2 && mkdir -p build && cd build
CC=/usr/local/bin/afl-clang-lto CXX=/usr/local/bin/afl-clang-lto++ cmake ..
make

cd .. && mkdir -p seeds && cd seeds
for i in {0..4}; do
    dd if=/dev/urandom of=seed_$i bs=64 count=10 2>/dev/null
done

cd ../build
afl-fuzz -i ../seeds/ -o out -m none -d -- ./medium
```

**Success Criteria**:

- AFL++ compiles and installs without errors
- Both fuzzing sessions start successfully
- You can see the AFL++ status screen showing paths found, crashes, etc.
- Check `out/crashes/` directory for any discovered crashes

**Troubleshooting**:

- If `afl-clang-fast` not found: Check `/usr/local/bin/` is in PATH
- If compilation fails: Ensure LLVM 19 is properly installed (`clang-19 --version`)
- If fuzzer doesn't start: Check CPU scaling governor (`echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`)

### Real-World Impact: AFL++ Finding CVE-2024-47606 (GStreamer)

**Background**: AFL++ and similar fuzzers are actively used to find vulnerabilities in production software. Let's examine a real case from Week 1.

**Case Study - CVE-2024-47606 (GStreamer Signed-to-Unsigned Integer Underflow)**:

- **Discovery Method**: Continuous fuzzing campaigns by security researchers using AFL++ on media parsers
- **The Bug**: GStreamer's `qtdemux_parse_theora_extension` had a signed integer underflow that became massive unsigned value
- **Attack Surface**: MP4/MOV files processed automatically by browsers, media players, messaging apps
- **Fuzzing Approach**:
  1. Target: GStreamer's QuickTime demuxer (`qtdemux`)
  2. Seed corpus: Valid MP4 files from public datasets
  3. Instrumentation: Compiled with AFL++ and AddressSanitizer
  4. Mutation strategy: Structure-aware (understanding MP4 atoms)
  5. Result: Heap buffer overflow crash after ~48 hours of fuzzing

**Why Fuzzing Found It**:

- **Rare Input Combination**: Required specific Theora extension size values that underflow
- **Static Analysis Limitation**: Signed-to-unsigned conversion buried in complex parsing logic
- **Code Review Miss**: Integer arithmetic looked correct without considering negative values
- **Automated Testing Gap**: Unit tests didn't cover malformed Theora extensions

**The Discovery Process**:

```bash
# 1) Generate a structured MP4 seed corpus (GitHub Security Lab generator)
cd ~/tuts && git clone --depth 1 https://github.com/github/securitylab.git
cd ~/tuts/securitylab/Fuzzing/GStreamer
make
mkdir -p corpus/mp4
./generator -o corpus/mp4

# 2) Build a vulnerable GStreamer (< 1.24.10) with AFL++ + ASan
cd ~/tuts
git clone --branch 1.24.9 --depth 1 https://gitlab.freedesktop.org/gstreamer/gstreamer.git
cd gstreamer
export CC=afl-clang-fast
export CXX=afl-clang-fast++
export CFLAGS="-O1 -g"
export CXXFLAGS="-O1 -g"
sudo apt-get install -y flex bison
# NOTE: this might take a while so you can just build parts of it, not all
meson setup build-afl --buildtype=debug -Db_sanitize=address
ninja -C build-afl -j"$(nproc)"

# 3) Fuzz the QuickTime demuxer pipeline with AFL++
mkdir -p findings
# NOTE: you can fuzz other binaries as well to find bugs
echo core | sudo tee /proc/sys/kernel/core_pattern
afl-fuzz -i ~/tuts/securitylab/Fuzzing/GStreamer/corpus/mp4 \
         -o findings -m none -- \
         ./build-afl/subprojects/gstreamer/tools/gst-launch-1.0 \
         filesrc location=@@ ! qtdemux ! fakesink

# Typical outcome after hours of fuzzing:
#   - ASan crash inside qtdemux_parse_theora_extension()
#   - heap-buffer-overflow in gst_buffer_fill() when copying attacker-controlled data
# Root cause (CVE-2024-47606 / GHSL-2024-166, fixed in 1.24.10):
#   - 32-bit signed 'size' underflows → huge unsigned value
#   - _sysmem_new_block() overflows when adding alignment/header → tiny (0x89-byte) allocation
#   - memcpy() writes the huge size, corrupting GstMapInfo and allocator function pointers
```

**Key Insight**: Fuzzing excels at finding edge cases in complex parsers that humans would never manually test. The combination of:

- Coverage-guided mutation (AFL++ exploring new code paths)
- AddressSanitizer (detecting memory corruption immediately)
- Persistent fuzzing (running for days/weeks)

...makes it more effective than manual testing for this vulnerability class.

### Key Takeaways

1. **Fuzzing finds real vulnerabilities**: Not just theoretical crashes, but exploitable bugs in production software
2. **Coverage-guided fuzzing is powerful**: AFL++ intelligently explores code paths rather than random mutation
3. **Sanitizers are essential**: ASAN, UBSAN turn subtle bugs into immediate crashes
4. **Time matters**: Many bugs require hours/days of fuzzing to discover
5. **Seed corpus quality affects results**: Starting with valid inputs helps reach deeper code paths

### Discussion Questions

1. Why did fuzzing find `CVE-2024-47606` when code review and unit testing didn't?
2. What advantages does coverage-guided fuzzing have over purely random fuzzing?
3. How do sanitizers (ASAN, UBSAN) enhance fuzzing effectiveness?
4. What types of vulnerabilities are fuzzing best suited to find? What types does it miss?
5. How can seed corpus selection impact fuzzing effectiveness?

