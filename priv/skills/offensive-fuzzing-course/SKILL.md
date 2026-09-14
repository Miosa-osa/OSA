---
name: offensive-fuzzing-course
description: "Week 2 of the exploit development curriculum. Covers fuzzing methodology: target selection, corpus generation, coverage-guided fuzzing with AFL++/libFuzzer, structured fuzzing, and triage/deduplication. Use when setting up fuzz campaigns, selecting harness strategies, or triaging fuzzer output."
category: security
triggers:
  - "fuzzing course"
  - "offensive fuzzing course"
  - "fuzzing"
  - "fuzzing attack"
  - "fuzzing exploitation"
  - "fuzzing course methodology"
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

# SKILL: Week 2: Finding Vulnerabilities Through Fuzzing

## Metadata
- **Skill Name**: fuzzing-course
- **Folder**: offensive-fuzzing-course
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/2-fuzzing.md

## Description
Week 2 of the exploit development curriculum. Covers fuzzing methodology: target selection, corpus generation, coverage-guided fuzzing with AFL++/libFuzzer, structured fuzzing, and triage/deduplication. Use when setting up fuzz campaigns, selecting harness strategies, or triaging fuzzer output.

## Trigger Phrases
Use this skill when the conversation involves any of:
`fuzzing curriculum, AFL++, libFuzzer, coverage-guided fuzzing, corpus generation, harness, fuzz target, mutation, triage, crash dedup, week 2, exploit dev course`


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

## Day 2: Continue Fuzzing with `AFL++`

- **Goal**: Understand and apply advanced fuzzing techniques.
- **Activities**:
  - _Reading_: Continue with "Fuzzing for Software Security Testing and Quality Assurance" (From 3.3 to 3.9.8).
  - _Real-World Examples_:
    - [AFL++ finds CVE-2020-9385 in ZINT Barcode Generator](https://www.code-intelligence.com/blog/5-cves-found-with-feedback-based-fuzzing) - Stack buffer overflow discovered through fuzzing
    - [AFL++ Fuzzing in Depth](https://aflplus.plus/docs/fuzzing_in_depth/) - How to effectively use afl++
    - [Suricata IDS CVE-2019-16411](https://www.code-intelligence.com/blog/5-cves-found-with-feedback-based-fuzzing) - Out-of-bounds read found via fuzzing
  - _Exercise_:
    - Experiment with different `AFL++` options (for example, dictionary-based fuzzing, persistent mode).
    - Running `AFL++` with a real-world application like a file format parser to mimic real-world scenarios.
    - Optionally, target an image or media parser so you can practice finding heap overflows and out-of-bounds reads similar to the libWebP and GStreamer bugs from Week 1.

```bash
# Fuzzing a image parser (dlib imglab)
# NOTE: you can pull older versions to guarantee vulnerable code paths
cd ~/tuts && git clone --depth 1 --branch v19.24.6 https://github.com/davisking/dlib.git
cd dlib/tools/imglab && mkdir -p build && cd build

# Configure sanitizers for better crash detection
export AFL_USE_UBSAN=1
export AFL_USE_ASAN=1
export ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:allow_user_segv_handler=0:handle_abort=1:symbolize=0"

# Install dependencies
sudo apt install -y libx11-dev libavdevice-dev libavfilter-dev libavformat-dev libavcodec-dev \
libswresample-dev libswscale-dev libavutil-dev libjxl-dev libjxl-tools

# Compile with AFL++ and sanitizers
cmake -DCMAKE_C_COMPILER=afl-clang-fast \
      -DDLIB_NO_GUI_SUPPORT=0 \
      -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
      -DCMAKE_CXX_FLAGS="-fsanitize=address,leak,undefined -g" \
      -DCMAKE_C_FLAGS="-fsanitize=address,leak,undefined -g" ..
make -j$(nproc)

# Prepare seed corpus
mkdir -p fuzz/image/in
cp ../../../examples/faces/testing.xml fuzz/image/in/

# TODO: try to improve the fuzzing speed using https://aflplus.plus/docs/fuzzing_in_depth/#i-improve-the-speed
# Run AFL++ in parallel mode (Master + Slave instances)
# Terminal 1: Master instance
echo core | sudo tee /proc/sys/kernel/core_pattern
afl-fuzz -i fuzz/image/in -o fuzz/image/out -M Master -- ./imglab --stats @@

# Terminal 2: Slave instance (for parallel fuzzing)
afl-fuzz -i fuzz/image/in -o fuzz/image/out -S Slave1 -- ./imglab --stats @@

# Install crash analysis tools
sudo apt install -y gdb python3-pip valgrind
wget -O ~/.gdbinit-gef.py -q https://gef.blah.cat/py
echo "source ~/.gdbinit-gef.py" >> ~/.gdbinit

# Minimize a crashing input while preserving the crashing behavior (afl-tmin)
# NOTE: there might be no crashes, either fuzz longer or go back to an older tag
CRASH=$(ls ~/tuts/dlib/tools/imglab/build/fuzz/image/out/Master/crashes/id* 2>/dev/null | head -n1)
afl-tmin -i "$CRASH" -o ~/tuts/dlib/tools/imglab/build/fuzz/image/out/Master/crashes/minimized_crash -- ./imglab --stats @@

# Cluster and triage crashes with casr-afl (from CASR tools)
# NOTE: there might be no crashes, either fuzz longer or go back to an older tag
CASR_URL="https://github.com/ispras/casr/releases/latest/download/casr-x86_64-unknown-linux-gnu.tar.xz"
INSTALL_DIR="$HOME/.local"
mkdir -p "$INSTALL_DIR"
wget -O "$INSTALL_DIR/casr-x86_64-unknown-linux-gnu.tar.xz" "$CASR_URL"
tar -xJf "$INSTALL_DIR/casr-x86_64-unknown-linux-gnu.tar.xz" -C "$INSTALL_DIR"
export PATH="$INSTALL_DIR/casr-x86_64-unknown-linux-gnu/bin:$PATH"  # provides casr-afl

# Now run casr-afl on the AFL++ output directory
casr-afl -i ~/tuts/dlib/tools/imglab/build/fuzz/image/out/Master -o ~/tuts/dlib/tools/imglab/build/fuzz/image/out/Master_casr_reports
```

**Expected Outputs**:

- AFL++ status screen showing increasing coverage
- Crashes appearing in `fuzz/image/out/Master/crashes/` or `fuzz/image/out/Slave1/crashes/`
- AddressSanitizer reports for memory corruption bugs

**What to Look For**:

- Crashes with `SIGSEGV` or `SIGABRT` signals
- AddressSanitizer reports showing heap buffer overflows, use-after-free, etc.
- Unique crash signatures (different stack traces)

**Troubleshooting**:

- If compilation fails: Check that all dependencies are installed
- If no crashes found: Let fuzzer run longer (hours/days for real targets)
- If crashes are false positives: Review ASAN options and adjust

### Real-World Campaign: Fuzzing Image Parsers

**Case Study - CVE-2023-4863 (libWebP Heap Buffer Overflow)**:

From Week 1, you learned about this critical vulnerability. Let's understand how fuzzing could have (and did) discover similar bugs.

- **The Target**: libWebP image decoder, used by Chrome, Firefox, and countless applications
- **Why It's Fuzzing-Friendly**:
  - Pure input-to-output: takes file bytes, produces image
  - No network/filesystem dependencies
  - Deterministic execution
  - Complex parsing logic with many edge cases

**Fuzzing Campaign Strategy**:

```bash
# Real-world fuzzing setup for image parsers
cd ~/tuts && git clone --depth 1 --branch 1.0.0 https://chromium.googlesource.com/webm/libwebp

cd libwebp && sudo apt-get -y install gcc make autoconf automake libtool

# Compile with AFL++ and all sanitizers
export CC=afl-clang-fast
export CXX=afl-clang-fast++
export AFL_USE_ASAN=1
export AFL_USE_UBSAN=1
export CFLAGS="-fsanitize=address,undefined -g"
export CXXFLAGS="-fsanitize=address,undefined -g"

./autogen.sh
./configure
make -j$(nproc)

# Create fuzzing harness
cat > fuzz_webp.c << 'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <webp/decode.h>
#include <webp/types.h>

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

    // Fuzz target: decode WebP image
    int width, height;
    uint8_t *output = WebPDecodeRGBA(data, size, &width, &height);

    if (output) free(output);
    free(data);
    return 0;
}
EOF

# Compile fuzzing harness
afl-clang-fast -I./src -o fuzz_webp fuzz_webp.c \
    -L./src/.libs -lwebp -fsanitize=address,undefined -g

# Collect seed corpus (valid WebP images)
mkdir -p ~/tuts/libwebp/seeds
# Download some WebP test images
wget -q -O ~/tuts/libwebp/seeds/test1.webp https://www.gstatic.com/webp/gallery/1.webp
wget -q -O ~/tuts/libwebp/O seeds/test2.webp https://www.gstatic.com/webp/gallery/2.webp
wget -q -O ~/tuts/libwebp/O seeds/test3.webp https://www.gstatic.com/webp/gallery/3.webp

# Run AFL++ fuzzer
export LD_LIBRARY_PATH=./src/.libs:$LD_LIBRARY_PATH
afl-fuzz -i seeds/ -o findings/ -m none -d -- ./fuzz_webp @@

# Real campaigns run for weeks. OSS-Fuzz runs 24/7.
# Expected: Crashes in findings/crashes/ directory
# Analysis: ASAN reports showing heap buffer overflows
```

**What Fuzzing Discovered**:

In the real CVE-2023-4863 case:

1. **Initial crash**: Heap buffer overflow in `BuildHuffmanTable()`
2. **Root cause**: Malformed Huffman coding data caused out-of-bounds write
3. **ASAN output**: Immediate detection of corruption with exact location
4. **Exploitability**: Function pointer hijack possible via heap corruption

**Why This Bug Survived Testing**:

- **Unit tests**: Covered valid WebP files, not malformed Huffman tables
- **Static analysis**: Complex pointer arithmetic hard to verify
- **Code review**: Bounds check looked correct in isolation
- **Fuzzing advantage**: Generated millions of mutated WebP files, including edge cases

**Parallel Fuzzing for Speed**:

```bash
# Real campaigns use multiple CPU cores
# Master instance
afl-fuzz -i seeds/ -o findings/ -M master -m none -- ./fuzz_webp @@

# Slave instances (in separate terminals or tmux)
for i in {1..5}; do
    afl-fuzz -i seeds/ -o findings/ -S slave$i -m none -- ./fuzz_webp @@ &
done

# Check status
afl-whatsup findings/

# Expected output:
# Master: 1234 paths, 5 crashes
# Slave1: 987 paths, 2 crashes
# Slave2: 1056 paths, 3 crashes
# ... (instances share corpus and findings)
```

### Corpus Management and Seed Selection

**Why Seed Quality Matters**:

```bash
# Bad seed corpus: random bytes
dd if=/dev/urandom of=bad_seed.webp bs=1024 count=10

# Result: AFL++ spends time on invalid inputs that fail early parsing
# Coverage: Only reaches format validation code

# Good seed corpus: valid WebP files
# Result: AFL++ mutates valid structure, reaches deep parsing logic
# Coverage: Explores Huffman decoding, color space conversion, filters
```

**Building Effective Seed Corpus**:

```bash
# 1. Collect diverse valid inputs
mkdir -p corpus
# - Different sizes (small, medium, large)
# - Different features (lossy, lossless, animated)
# - Different color spaces (RGB, YUV, alpha channel)
wget -r -l1 -A webp https://www.gstatic.com/webp/gallery/ -P corpus/

# 2. Minimize corpus (remove redundant files)
afl-cmin -i corpus/ -o corpus_min/ -- ./fuzz_webp @@

# 3. Minimize individual files (shrink while preserving coverage)
mkdir -p corpus_tmin
for f in corpus_min/*; do
    afl-tmin -i "$f" -o "corpus_tmin/$(basename $f)" -- ./fuzz_webp @@
done

# Result: Smaller corpus = faster fuzzing iterations
# Original: 50 files, 5MB total
# Minimized: 15 files, 500KB total (same coverage)
```

### Key Takeaways

1. **Image parsers are prime fuzzing targets**: Complex, widely-deployed, handle untrusted input
2. **OSS-Fuzz prevents 0-days**: Continuous fuzzing finds bugs before attackers
3. **Parallel fuzzing scales linearly**: 8 cores = ~8x throughput
4. **Corpus quality > corpus size**: Minimized, diverse seeds outperform large random corpus
5. **Dictionaries accelerate discovery**: Format-aware tokens reach deeper code paths faster

### Discussion Questions

1. Why are image/media parsers particularly well-suited for fuzzing compared to other software?
2. How does corpus minimization improve fuzzing efficiency without losing coverage?
3. What trade-offs exist between fuzzing speed (lightweight instrumentation) and bug detection (heavy sanitizers)?
4. Why did OSS-Fuzz find bugs in libwebp that years of production use didn't reveal?
5. How can you determine if a fuzzing campaign has reached diminishing returns and should target a different component?
6. How can you [improve](https://aflplus.plus/docs/fuzzing_in_depth/#i-improve-the-speed) fuzzing speed?

## Day 3: Introduction to Google FuzzTest

- **Goal**: Understand in-process fuzzing with FuzzTest and how to turn unit tests into coverage-guided fuzzers that actually find memory corruption bugs.
- **Activities**:
  - _Reading_: Continue with "Fuzzing for Software Security Testing and Quality Assurance" (From 4.2.1 to 4.4).
  - _Online Resources_:
    - [Google FuzzTest](https://github.com/google/fuzztest) - Read the README and "Getting Started".
    - [Property-based fuzzing vs example-based testing](https://github.com/google/fuzztest#what-is-fuzztest) - Short motivation for FuzzTest.
  - _Exercises_:
    1. Set up FuzzTest in a small CMake project and run a trivial property-based test.
    2. Use FuzzTest + AddressSanitizer to rediscover a simple heap buffer overflow (Week 1 vulnerability class).
    3. Extend the fuzz target to cover a small parser-style function, similar to the image/format parsers from Days 1–2.

### Why FuzzTest in a vulnerability-focused course?

FuzzTest is a **unit-test-style, in-process fuzzing framework** from Google that:

- **Integrates with GoogleTest**: You write `TEST` and `FUZZ_TEST` side by side in the same file.
- **Uses coverage-guided fuzzing under the hood** (libFuzzer-style) but hides boilerplate harness code.
- **Works great for libraries and core logic** (parsers, decoders, crypto helpers) where you already have unit tests.
- **Is ideal for CI**: The same binary can run fast deterministic tests or long-running fuzz campaigns depending on flags.

Where AFL++/Honggfuzz are great for whole programs and black-box binaries, **FuzzTest shines when you have source code and want to fuzz individual C++ functions** directly.

### Lab 1: Set up FuzzTest and run a basic property

```bash
mkdir -p ~/tuts/first_fuzz_project && cd ~/tuts/first_fuzz_project
git clone --branch main --depth 1 https://github.com/google/fuzztest.git

cat <<EOT > CMakeLists.txt
# GoogleTest requires at least C++17
set(CMAKE_CXX_STANDARD 17)

add_subdirectory(fuzztest)

enable_testing()

include(GoogleTest)
fuzztest_setup_fuzzing_flags()
add_executable(
  first_fuzz_test
  first_fuzz_test.cc
)

link_fuzztest(first_fuzz_test)
gtest_discover_tests(first_fuzz_test)
EOT
cat <<EOT > first_fuzz_test.cc
#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

TEST(MyTestSuite, OnePlusTwoIsTwoPlusOne) {
  EXPECT_EQ(1 + 2, 2 + 1);
}

void IntegerAdditionCommutes(int a, int b) {
  EXPECT_EQ(a + b, b + a);
}
FUZZ_TEST(MyTestSuite, IntegerAdditionCommutes);
EOT
mkdir -p build && cd build

# configure with fuzztest
cc=clang-19 cxx=clang++-19 cmake -dcmake_build_type=relwithdebug -dfuzztest_fuzzing_mode=on ..

# Build the project
cmake --build . --parallel $(nproc)

# Run the fuzz test (short sanity run)
./first_fuzz_test --fuzz=MyTestSuite.IntegerAdditionCommutes --max_total_time=10
```

You should see FuzzTest/libFuzzer-style statistics (executions per second, coverage, etc.).
For a correct property like integer commutativity, the fuzzer should **not** find crashes.

### Lab 2: FuzzTest to find a heap buffer overflow

Now turn FuzzTest onto a deliberately vulnerable function that mimics a classic **stack / heap buffer overflow** from Week 1.

```bash
cd ~/tuts/first_fuzz_project

cat <<'EOT' > first_fuzz_test.cc
#include <cstring>
#include <string>
#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

TEST(ArithmeticSuite, OnePlusTwoIsTwoPlusOne) {
  EXPECT_EQ(1 + 2, 2 + 1);
}

void IntegerAdditionCommutes(int a, int b) {
  EXPECT_EQ(a + b, b + a);
}
FUZZ_TEST(ArithmeticSuite, IntegerAdditionCommutes);

void VulnerableHeaderCopy(const std::string& input) {
  char header[32];

  // When input.size() > 32 and ASAN is enabled, this becomes a detectable overflow.
  std::memcpy(header, input.data(), input.size());
}

FUZZ_TEST(OverflowSuite, VulnerableHeaderCopy);
EOT

cd build

# Build the project
cmake --build . --parallel $(nproc)

# Run only the overflow fuzz test to focus on the bug
./first_fuzz_test --fuzz=OverflowSuite.VulnerableHeaderCopy --max_total_time=20
```

**Expected result**: After a short time, FuzzTest should report a crash with an AddressSanitizer message similar to:

```text
==1066==ERROR: AddressSanitizer: stack-buffer-overflow on address 0x76f8218731c0 at pc 0x60a5060193a2 bp 0x7ffc65c1fd10 sp 0x7ffc65c1f4d0
```

At this point you can:

- Open `first_fuzz_test.cc` and **fix the bug** by adding a length check (for example, only copying up to `sizeof(header)`).
- Rebuild and re-run the fuzz target to confirm the crash is gone.

This is exactly the same pattern as our AFL++ labs: **fuzzer + sanitizer → crash → root cause → fix**, but now entirely inside a unit test binary.

### Lab 3: Fuzzing a small parser-style function

To connect FuzzTest to the real-world parsers from Days 1–2, fuzz a tiny length-prefixed parser that can easily go wrong if you mishandle integer arithmetic.

```bash
cd ~/tuts/first_fuzz_project

cat <<'EOT' >> first_fuzz_test.cc

struct Message {
  uint8_t len;
  std::string payload;
};

Message ParseMessage(const std::string& input) {
  Message m{0, ""};
  if (input.empty()) return m;

  uint8_t len = static_cast<uint8_t>(input[0]);

  // BUG -> commenting this would cause fuzzer to find vuln
  // - If len > input.size() - 1, this will either truncate or read garbage.
  // - Here we clamp len to avoid UB, but real code often forgets this check.
  if (static_cast<size_t>(len) > input.size() - 1) {
      len = static_cast<uint8_t>(input.size() - 1);
  }

  m.len = len;
  m.payload.assign(input.data() + 1, input.data() + 1 + m.len);
  return m;
}

void ParseDoesNotCrash(const std::string& input) {
  (void)ParseMessage(input);
}

void LengthFieldRespected(const std::string& input) {
  if (input.size() < 2) return;

  uint8_t claimed_len = static_cast<uint8_t>(input[0]);
  if (static_cast<size_t>(claimed_len) > input.size() - 1) return;

  Message m = ParseMessage(input);
  EXPECT_EQ(m.len, claimed_len);
  EXPECT_EQ(m.payload.size(), claimed_len);
}

FUZZ_TEST(ParserSuite, ParseDoesNotCrash);
FUZZ_TEST(ParserSuite, LengthFieldRespected);
EOT

cd build && cmake --build . --parallel $(nproc)

# Run parser fuzz tests for a short time
./first_fuzz_test --fuzz=ParserSuite.ParseDoesNotCrash --max_total_time=15
./first_fuzz_test --fuzz=ParserSuite.LengthFieldRespected --max_total_time=15
```

**What to look for**:

- If you intentionally break the length check inside `ParseMessage` (for example, remove the `if (len > input.size() - 1)` guard - 3 lines), FuzzTest + ASAN/UBSAN should quickly find crashes or undefined behavior.
- Try modifying the parser to add more fields (flags, type bytes, nested length fields) and see how FuzzTest finds edge cases you did not think about.

### Key Takeaways

1. **FuzzTest brings fuzzing into your unit tests**: You can turn GoogleTest-style tests into coverage-guided fuzzers with `FUZZ_TEST`, using the same build system and test runner.
2. **Sanitizers are critical**: Combining FuzzTest with ASAN/UBSAN turns memory bugs (overflows, UAFs, integer issues) into immediate, reproducible crashes.
3. **Great fit for parsers and core logic**: Short, pure C++ functions (parsers, decoders, protocol handlers) are ideal FuzzTest targets, similar to the real-world parsers from Days 1–2.
4. **Properties > examples**: Expressing invariants like “never crash” or “length field matches payload” lets the fuzzer explore inputs you would never hand-write.
5. **Same workflow as other fuzzers**: Regardless of tool (AFL++, Honggfuzz, FuzzTest), the basic loop is still _fuzz → crash → triage → exploitability → fix_.

### Discussion Questions

1. In what situations would you prefer **FuzzTest** over a process-level fuzzer like **AFL++** or **Honggfuzz**, and why?
2. How would you go about converting an existing **GoogleTest** regression test into an effective `FUZZ_TEST` that can find new bugs, not just regressions?
3. Which vulnerability classes from Week 1 (e.g., buffer overflows, integer overflows, UAF) are especially well-suited to FuzzTest, and which are harder to reach with this style of in-process fuzzing?
4. How could you integrate short, time-bounded FuzzTest runs into a **CI pipeline** without making builds too slow, while still having longer campaigns on dedicated fuzzing machines?
5. When writing properties like `LengthFieldRespected`, what kinds of mistakes in the property itself might cause you to **miss real bugs** or report lots of false positives?

## Day 4: Introduction to `Honggfuzz`

- **Goal**: Understand different fuzzing methods and when to use Honggfuzz vs AFL++.
- **Activities**:
  - _Reading_: Continue with "Fuzzing for Software Security Testing and Quality Assurance" (From 5.1.2 to 5.3.7).
  - _Online Resource_: [Honggfuzz](https://github.com/google/honggfuzz.git)
  - _Real-World Context_:
    - Honggfuzz is used in Google's continuous fuzzing infrastructure
    - [OSS-Fuzz uses Honggfuzz for many projects](https://google.github.io/oss-fuzz/getting-started/new-project-guide/)
    - OpenSSL has extensive fuzzing coverage - [see their fuzzing documentation](https://docs.openssl.org/3.2/man7/ossl-guide-introduction/)
  - _Exercise_: Fuzz OpenSSL server and private key parsing

```bash
# Install Honggfuzz
cd ~/soft && git clone --branch master --depth 1 https://github.com/google/honggfuzz.git
#sudo apt-get install -y binutils-dev libunwind-dev libblocksruntime-dev clang libssl-dev
sudo apt-get install -y binutils-dev libunwind-dev libblocksruntime-dev libssl-dev
cd honggfuzz && make -j$(nproc) && sudo make install

# Verify installation
which honggfuzz
honggfuzz --version

# Clone OpenSSL source
cd ~/tuts && git clone --branch openssl-3.1.2 --depth=1 https://github.com/openssl/openssl.git
cd openssl

# Configure OpenSSL for fuzzing (with all legacy protocols enabled for broader attack surface)
CC=/usr/local/bin/hfuzz-clang CXX="$CC"++ ./config \
  -DPEDANTIC no-shared -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -O0 \
  -fno-sanitize=alignment -lm -ggdb -gdwarf-4 --debug -fno-omit-frame-pointer \
  enable-asan enable-tls1_3 enable-weak-ssl-ciphers enable-rc5 enable-md2 \
  enable-ssl3 enable-ssl3-method enable-nextprotoneg enable-heartbeats \
  enable-aria enable-zlib enable-egd

# Build OpenSSL
make -j$(nproc)

# Build Honggfuzz fuzzers for OpenSSL
# Note: This uses Honggfuzz's example OpenSSL fuzzers
cat > build_fuzzers.sh << 'EOT'
#!/bin/bash
set -x
set -e
echo "Building honggfuzz fuzzers for OpenSSL"
for x in x509 privkey client server; do
    hfuzz-clang \
        -DBORINGSSL_UNSAFE_DETERMINISTIC_MODE \
        -DBORINGSSL_UNSAFE_FUZZER_MODE \
        -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION \
        -DBN_DEBUG \
        -DLIBRESSL_HAS_TLS1_3 \
        -O3 -g \
        -DFuzzerInitialize=LLVMFuzzerInitialize \
        -DFuzzerTestOneInput=LLVMFuzzerTestOneInput \
        -I$(pwd)/include \
        -I"$HOME"/soft/honggfuzz/examples/openssl \
        -I"$HOME"/soft/honggfuzz \
        -g "$HOME/soft/honggfuzz/examples/openssl/$x.c" \
        -o "libfuzzer.openssl-memory.$x" \
        ./libssl.a ./libcrypto.a -lpthread -lz -ldl -fsanitize=address
done
EOT

chmod +x build_fuzzers.sh
./build_fuzzers.sh

# Run Honggfuzz on OpenSSL server parser
honggfuzz --input ~/soft/honggfuzz/examples/openssl/corpus_server/ \
          -- ./libfuzzer.openssl-memory.server

# Run Honggfuzz on OpenSSL private key parser
honggfuzz --input ~/soft/honggfuzz/examples/openssl/corpus_privkey/ \
          -- ./libfuzzer.openssl-memory.privkey
```

**Success Criteria**:

- Honggfuzz compiles and installs successfully
- OpenSSL builds with fuzzing support
- Fuzzers compile without errors
- Honggfuzz starts and shows coverage statistics

**What to Look For**:

- Coverage metrics increasing over time
- Crashes in the working directory
- Different crash types (heap overflow, use-after-free, etc.)

**Note**: Real OpenSSL fuzzing often runs for days/weeks. For this exercise, run for at least 30 minutes to see initial results.

### Real-World Impact: Honggfuzz Finding TLS Vulnerabilities

**Case Study - Heartbleed-Class Bugs in TLS Implementations**:

While Heartbleed (CVE-2014-0160) predates modern fuzzing tools, similar vulnerabilities continue to be found through continuous fuzzing campaigns.

**Why TLS is Hard to Fuzz**:

- **Stateful protocol**: Must complete handshake before reaching deep logic
- **Cryptographic operations**: Random values, signatures, MACs
- **Multiple versions**: TLS 1.0, 1.1, 1.2, 1.3 with different code paths
- **Extensions**: ALPN, SNI, session tickets, early data, etc.

**Honggfuzz Advantages for Network Protocols**:

```bash
# Example: Fuzzing TLS 1.3 handshake
cat > fuzz_tls13_handshake.c << 'EOF'
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <stdint.h>
#include <stddef.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) return 0;

    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
    SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);

    BIO *in_bio = BIO_new(BIO_s_mem());
    BIO *out_bio = BIO_new(BIO_s_mem());

    SSL *ssl = SSL_new(ctx);
    SSL_set_bio(ssl, in_bio, out_bio);
    SSL_set_accept_state(ssl);

    BIO_write(in_bio, data, size);
    SSL_do_handshake(ssl);

    SSL_free(ssl);
    SSL_CTX_free(ctx);
    return 0;
}
EOF

# Compile with Honggfuzz
hfuzz-clang fuzz_tls13_handshake.c \
    -I"$HOME"/tuts/openssl/include \
    -L"$HOME"/tuts/openssl/lib \
    -lssl -lcrypto \
    -fsanitize=address,undefined \
    -o fuzz_tls13

# Run with Honggfuzz
# TODO: use a better corpus to actually find the vulnerabilities in that code
honggfuzz --input ~/soft/honggfuzz/examples/openssl/corpus_server/ \
          --threads 8 \
          --timeout 5 \
          -- ./fuzz_tls13
```

**Real Bugs Found by Protocol Fuzzing**:

From OpenSSL and other TLS implementations:

- **Buffer overflows in certificate parsing**: X.509 extension handling
- **Use-after-free in session resumption**: Ticket lifetime management
- **Integer overflows in record layer**: Length calculations
- **State confusion bugs**: Unexpected message ordering

**Example: CVE-2022-0778 (OpenSSL Infinite Loop)**:

```bash
# Bug: Infinite loop in BN_mod_sqrt() when parsing elliptic curve points
# Discovery: Fuzzing certificate parsing with malformed EC parameters
# Impact: DoS via crafted certificate
# Fixed: OpenSSL 3.0.2, 1.1.1n

# Fuzzing campaign that found similar bugs:
honggfuzz --input certs/ \
          --dict openssl.dict \
          --threads 16 \
          --timeout 10 \
          --rlimit_rss 2048 \
          -- ./openssl x509 -in ___FILE___ -text

# Result: Timeout on malformed EC point → DoS vulnerability
```

**Fuzzing vs Real-World Exposure**:

| Metric               | Production Use (10 years) | OSS-Fuzz (1 year) |
| -------------------- | ------------------------- | ----------------- |
| Total connections    | Billions                  | 0 (pure fuzzing)  |
| Unique inputs tested | ~1,000 (typical sites)    | Trillions         |
| Edge cases covered   | <1%                       | >90%              |
| Bugs found           | ~5 (via exploits)         | ~50               |

**Key Insight**: Fuzzing explores input space breadth that production traffic never reaches.

### Key Takeaways

1. **Honggfuzz excels at complex targets**: Multi-threaded, persistent mode, hardware-assisted coverage
2. **Protocol fuzzing requires stateful harnesses**: Must reach deep code paths beyond initial parsing
3. **Continuous fuzzing prevents regressions**: OSS-Fuzz runs 24/7, catches new bugs in code changes
4. **Cryptographic code is fragile**: Parsers for ASN.1, X.509, PEM frequently have bugs
5. **Timeout detection finds DoS bugs**: Infinite loops, algorithmic complexity issues

### Discussion Questions

1. Why does fuzzing find TLS bugs that years of production use don't reveal?
2. What makes protocol fuzzing (TLS, HTTP/2, DNS) more challenging than file format fuzzing?
3. How does hardware-assisted coverage (Intel PT) improve fuzzing effectiveness?
4. What are the limitations of fuzzing for finding cryptographic vulnerabilities vs implementation bugs?



---

## Extended reference

This skill's full detail is split: read `references/detail.md` with file_read when you need the deep payload tables, tool matrices, or per-technique checklists that did not fit the skill body.
