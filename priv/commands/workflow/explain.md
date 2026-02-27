---
name: explain
description: Explain code, concepts, or decisions in detail
arguments:
  - name: target
    required: true
    description: File path, function name, concept, or issue number
---

# Explain - Deep Understanding

Provide detailed explanations of code, concepts, or decisions.

## Target Types

### 1. File
```
/explain src/auth/login.ts

Explains:
- Purpose of the file
- Key functions/classes
- How it fits in architecture
- Dependencies and dependents
- Usage examples
```

### 2. Function/Method
```
/explain validateUser

Explains:
- What it does
- Parameters and return values
- Algorithm used
- Edge cases handled
- Example usage
```

### 3. Code Block (with context)
```
/explain lines 45-67 in api.ts

Explains:
- What this block does
- Why it's implemented this way
- Potential improvements
- Related code
```

### 4. Concept
```
/explain "dependency injection"

Explains:
- What it is
- Why it's useful
- How it's used in this codebase
- Practical examples
```

### 5. Issue (from review)
```
/explain issue 3

Explains:
- What the issue is
- Why it's a problem
- Impact if not fixed
- How to fix it
- Prevention strategies
```

### 6. Error
```
/explain "TypeError: Cannot read property 'x' of undefined"

Explains:
- What causes this error
- Common scenarios
- How to debug it
- How to fix it
```

## Output Format

```
EXPLANATION
===========
Target: [what's being explained]

Overview:
---------
[High-level summary in 2-3 sentences]

Details:
--------
[Detailed explanation with code examples]

In This Codebase:
-----------------
[How this applies to the current project]

Related:
--------
- [Related files/concepts]
- [Further reading]

Examples:
---------
[Practical code examples]

Common Pitfalls:
----------------
- [Things to watch out for]

Best Practices:
---------------
- [Recommended approaches]
```

## Explanation Depth Levels

### Quick (default)
- 1-2 paragraphs
- Key points only
- One example

### Deep
```
/explain --deep validateUser
```
- Full analysis
- Multiple examples
- Edge cases
- History/rationale

### Beginner
```
/explain --beginner "async/await"
```
- Assumes no prior knowledge
- Step-by-step
- Analogies
- Simple examples

## Agent Dispatch

Primary: @explorer (for code navigation)
Support: @technical-writer (for clear explanations)
