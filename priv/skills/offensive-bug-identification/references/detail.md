# Extended reference (split from SKILL.md for context economy)

## Fuzzing

Fuzzing is a technique where you feed the application malformed inputs and monitor for crashes or unintended behaviors. See the dedicated [Fuzzing](/exploit/fuzzing.md) document for more detailed techniques.

### Fuzzing Overview

#### What is Fuzzing?

- Target software parses controllable input
- We create and/or mutate input and feed it into program
- Find crashes

#### What a Fuzzer Does

- Generic but platform/architecture specific
- Handles Input Generation/Mutation/Saving (called Corpus)
- Instrumenting Target (running, resetting, getting feedback)
- Reporting Crashes

#### What a Harness Does

- Target Specific
- Handles Feeding the input into the target

#### Fuzzer vs Harness Relationship

- Find Top Level Callable Functions
- Use Harness to Call that Function and Feed Input to it
- Fuzzer Generates and Sends the Input to Harness and Collects Coverage and Detects Crashes

### Crash Detection Techniques

- Paged Heap (heap overflows, UAF)
  - Guard pages between allocations
- Address Sanitizer (overflows + more)
  - Shadow memory (by inserting red zones in-between stack objects)
- Memory Sanitizer (uninitialized variable read)
  - Memory Leak, Used to Break ASLR
- Cluster crashes with token‑based Capstone‑hashing or `gdb‑script dedup.py` before manual analysis.

### Fuzzing Tools

#### Modern Fuzzing Frameworks

- **AFL++ 4.21+** – Unified cross-platform fuzzer with Windows support, CMPLOG, QEMU-mode
- **LibAFL 0.13+** – Rust-native, highly customizable, supports in-process and fork-server modes
- **Honggfuzz** – Persistent-mode Windows support, hardware-based feedback
- **Nyx** – Full-VM snapshot fuzzing with KVM acceleration
- **ICICLE** – Fast Windows kernel fuzzing framework
- **Syzkaller** – Kernel fuzzer with LLM-guided seed selection (2025)

#### Instrumentation & Coverage

- **DynamoRIO** – Used by AFL++, faster than Intel Pin (Note: Intel Pin is now sustain-only)
- **Frida Stalker** – Cross-platform dynamic instrumentation
- **Intel PT** – Hardware-accelerated coverage collection
- **Emerald** – Generates `drcov` data for coverage visualization

#### Specialized Fuzzers

- **ChatAFL / LLM-driller** – LLM-guided corpus expansion (+30% coverage on complex targets)
- **Reads-From Fuzzer (RFF)** – Concurrency fuzzer for race/TOCTOU bugs
- **LibFuzzer** – In-process, coverage-guided fuzzer for source-available targets
- **Radamsa** → **Replaced by LibAFL mutators** (more coverage-aware)

#### Symbolic Execution Engines

- **Triton** – Dynamic binary analysis framework
- **Angr** – Binary analysis platform with symbolic execution
- **Manticore** – Dynamic symbolic execution tool
- **S2E** – Selective symbolic execution platform

### Continuous-Integration Fuzzing

- **ClusterFuzzLite** – GitHub Actions/CI runner that feeds corpora to AFL++, libFuzzer or honggfuzz and files issues automatically.

### Snapshot Fuzzing

#### VMM Snapshot Fuzzing

- **QEMU Snapshots:** Fast restoration for stateful targets
- **KVM Acceleration:** Dirty page tracking for efficient resets
- **Persistent Mode:** Memory-only reset without full VM restore

### Fuzzing Types

#### Dumb Fuzzing

- Just sending random data to the target

#### Smart Fuzzing

- _Mutation Based_: Test cases are obtained by applying mutations to valid, known good samples (e.g., [Radamsa](https://gitlab.com/akihe/radamsa))
- _Generation(Grammar) Based_: Test cases are obtained by modeling files or protocol specifications based on models, templates, RFCs, or documentation (e.g., [Peach Fuzzer](https://peachtech.gitlab.io/peach-fuzzer-community/))
- _Model Based_: Test cases are obtained by modeling the target protocol/file format (when you want to test the target's ability to accept and process invalid sequences of data)
- _Differential Fuzzing_: Comparing outputs of different implementations with the same input

#### Evolutionary Fuzzing

- Test cases and inputs are generated based on the response from the program
- `AFL` is an example
- Or Google ClusterFuzz

#### Concurrency Fuzzing

- Systematically permutes thread scheduling to uncover data‑race, atomicity, and TOCTOU vulnerabilities that traditional coverage‑guided fuzzers miss

#### LLM‑Guided Fuzzing

- **ChatAFL** – integrates an LLM to propose protocol‑aware mutations; boosts state coverage on network daemons by ~40 %.
- **SyzAgent / SyzLLM (2025‑02)** – schedules kernel `syz` programs suggested by an LLM fine‑tuned on the Syzkaller corpus.
- **NumSeed** – leverages natural‑language descriptions of inputs to seed generation for binary‑only targets.

### Combined Method

The most effective approach often combines multiple techniques:

- Reverse engineer first to identify interesting parts
- Fuzz those parts to find crashes
- Investigate crashes to find exploitable vulnerabilities
- For shellcode development, see [Shellcode](/exploit/shellcode.md)

## AI/ML-Assisted Vulnerability Discovery

Modern vulnerability research increasingly leverages machine learning and large language models to accelerate discovery and analysis.

### LLM-Powered Triage and Analysis

- **Automated Crash Analysis:**
  - GPT-4/Claude for interpreting crash dumps and stack traces
  - Automated root-cause hypothesis generation from fuzzer output
  - Natural language queries against large codebases for vulnerability patterns
- **Decompilation Enhancement:**
  - Ghidra's ML-powered function signature recognition (11.2+)
  - Binary Ninja's HLIL AI improvements for cleaner pseudocode
  - Automated variable and function renaming based on context

### AI-Powered Vulnerability Scanners

- **ZeroScan:** Deep learning model trained on CVE datasets to identify vulnerability patterns in binaries
- **BigCode/StarCoder Models:** Fine-tuned on security-relevant code for pattern recognition
- **CodeQL with ML:** GitHub's semantic analysis enhanced with machine learning classifiers

### LLM-Assisted Fuzzing

- **ChatAFL:** Uses LLMs to generate input grammars and seed corpus based on protocol documentation
- **HyLLFuzz:** GPT/Llama-3 generates branch-targeted mutations achieving ~1.3× edge coverage improvement
- **Grammar Inference:** Automatically derive input structure from example files using transformer models

### Practical Integration

```python
# Example: Using local LLM for crash triage (OPSEC-safe)
from transformers import AutoTokenizer, AutoModelForCausalLM

def analyze_crash_local(crash_log, binary_info):
    model = AutoModelForCausalLM.from_pretrained("meta-llama/Llama-3-8b")
    tokenizer = AutoTokenizer.from_pretrained("meta-llama/Llama-3-8b")

    prompt = f"""Analyze this crash and suggest root cause:

Binary: {binary_info}
Crash Log:
{crash_log}

Provide: 1) Root cause hypothesis 2) Exploitability assessment 3) Suggested exploit primitive"""

    inputs = tokenizer(prompt, return_tensors="pt")
    outputs = model.generate(**inputs, max_length=1000)
    return tokenizer.decode(outputs[0])
```

### Limitations and Considerations

- **False Positives:** AI models can hallucinate vulnerabilities; manual verification essential
- **Training Data Bias:** Models trained on public CVEs may miss novel vulnerability classes
- **OPSEC:** Avoid sending proprietary code to cloud LLM APIs; use local models (Llama, Mistral)
- **Context Windows:** Most models have 4K-32K token limits; chunk large binaries/logs appropriately

## Quick Reference: Tool Selection Guide

### By Target Type

| Target               | Primary Tools     | Secondary Tools     |
| -------------------- | ----------------- | ------------------- |
| **Linux Kernel**     | Syzkaller, AFL++  | KASAN, KCOV, ftrace |
| **Windows Kernel**   | ICICLE, WinAFL    | Verifier, KFUZZ     |
| **Browsers**         | LibFuzzer, Domato | ClusterFuzz, Dharma |
| **Network Services** | AFL++, Boofuzz    | Peach, Sulley       |
| **Mobile Apps**      | QARK, Frida       | MobSF, Objection    |
| **Web Apps**         | Burp Suite, FFUF  | Nuclei, Semgrep     |
| **Firmware**         | Binwalk, EMBA     | FACT, Firmwalker    |
| **Containers**       | Trivy, Falco      | Grype, Syft         |

### By Technique

| Technique               | Recommended Tools    | Notes                          |
| ----------------------- | -------------------- | ------------------------------ |
| **Coverage Fuzzing**    | AFL++ 4.21+          | Cross-platform, CMPLOG support |
| **Snapshot Fuzzing**    | Nyx, QEMU+AFL++      | Stateful target support        |
| **Concurrency Fuzzing** | RFF, ThreadSanitizer | Race condition detection       |
| **Symbolic Execution**  | Angr, Triton         | Path exploration               |
| **Taint Analysis**      | DynamoRIO, Triton    | Data flow tracking             |
| **Binary Diffing**      | BinDiff 8, Ghidriff  | Patch analysis                 |
| **Static Analysis**     | CodeQL, Semgrep      | Pattern matching               |
| **Dynamic Analysis**    | Frida, DynamoRIO     | Runtime instrumentation        |

### Tool Migration Path

| Old Tool  | New Alternative    | Migration Notes            |
| --------- | ------------------ | -------------------------- |
| Intel Pin | DynamoRIO          | Pin is sustain-only        |
| WinAFL    | AFL++ 4.x          | Integrated Windows support |
| Radamsa   | LibAFL mutators    | Better coverage awareness  |
| BinDiff 7 | BinDiff 8/Ghidriff | Improved algorithms        |
| IDA 7.x   | IDA 8.x/Ghidra 11  | Better decompilation       |

---

## Attribution

Ported from [SnailSploit/Claude-Red](https://github.com/SnailSploit/Claude-Red)
(`Skills/*/offensive-bug-identification`), Apache-2.0 licensed. Methodology preserved; Claude-specific
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
