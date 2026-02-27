# AutoCodeRover

> Threat Level: **NONE** | ~3K GitHub Stars | Python | Open Source

## Overview

Academic autonomous program improvement system (Princeton, ISSTA 2024). Two-stage pipeline: context retrieval + patch generation. AST-aware code search.

## Notable Pattern

**AST-aware search** — searches methods/classes in abstract syntax tree instead of plain text. Cost: $0.43/fix, 4 min average. SWE-bench: 16-22% (low by 2026 standards).

## Assessment

Research prototype only. The AST-aware search pattern is worth borrowing.

## Sources

- [Paper](https://arxiv.org/abs/2404.05427)
