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

