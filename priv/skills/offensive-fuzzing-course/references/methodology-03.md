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

