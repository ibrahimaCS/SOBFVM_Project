# SOBFVM — A Virtual Machine for OCaml Bytecode

> A from-scratch C implementation of a virtual machine that interprets a simplified subset of the OCaml bytecode, with a clean modular architecture, ACSL-style function contracts, and full test coverage including a working `wumpus` game.

[![C](https://img.shields.io/badge/C-C11-blue.svg)](https://en.wikipedia.org/wiki/C11_(C_standard_revision))
[![Build](https://img.shields.io/badge/build-Makefile-orange.svg)]()
[![Tests](https://img.shields.io/badge/tests-7%2F7%20passing-success.svg)]()

---

## Table of contents

1. [What this project does](#what-this-project-does)
2. [The OCaml bytecode model](#the-ocaml-bytecode-model)
3. [Architecture highlights](#architecture-highlights)
4. [Project layout](#project-layout)
5. [Build and run](#build-and-run)
6. [The `.sobf` file format](#the-sobf-file-format)
7. [Memory layout and value encoding](#memory-layout-and-value-encoding)
8. [Instruction set](#instruction-set)
9. [Test programs](#test-programs)
10. [Sample run — the `pinetree` program](#sample-run--the-pinetree-program)
11. [Debugging methodology](#debugging-methodology)
12. [Problem encountered](#problem-encountered)
13. [Limitations and possible extensions](#limitations-and-possible-extensions)
14. [References](#references)

---

## What this project does

OCaml is a functional + imperative language whose compilation chain can produce two kinds of artefacts:

- **Native code** — specific to the host CPU architecture (x86_64, ARM, …).
- **Bytecode** — an intermediate, *machine-independent* code that runs on top of a virtual machine. This is what makes OCaml code **portable**: the same bytecode runs on any platform that has the VM.

**SOBFVM is a C implementation of that virtual machine**, restricted to a simplified subset of the official Caml Virtual Machine (specification by Xavier Clerc, v1.4). The program:

1. **Loads** a binary `.sobf` file produced by the course's bytecode compiler.
2. **Extracts** the code array, the global value array, and the metadata.
3. **Initialises** the VM state (program counter, accumulator, stack, atoms table).
4. **Executes** the program by fetching, decoding and dispatching each instruction, mutating the VM state until a `STOP` instruction (or an unknown opcode) terminates execution.
5. **Optionally prints** the full final machine state for debugging.

The whole project respects two hard constraints imposed by the course:

- **No pointer arithmetic.** All array accesses go through explicit integer indices.
- **No first-class functions.** No `void (*fn)(args)` callbacks or dispatch tables.

These restrictions force the dispatch to be a sequence of `switch` statements, and array traversals to be plain `for` loops — exactly the style expected in an introductory imperative-C course.

---

## The OCaml bytecode model

The virtual machine manipulates **values**, which are 64-bit signed integers (`long int`). Each value is one of two things, distinguished by its lowest bit:

| lowest bit | meaning              | encoding rule          |
|:----------:|----------------------|------------------------|
| `1`        | integer `n`          | stored as `2n + 1`     |
| `0`        | pointer (aligned)    | stored as the address  |

This trick relies on the fact that real memory allocators always return pointers aligned on a 2-byte (or stricter) boundary, so the low bit is "free" for tagging. Examples:

- Integer `0` is encoded as `1`.
- Integer `1` is encoded as `3`.
- Booleans `false`/`true` are the integers `0`/`1`, encoded as `1`/`3`.
- A pointer to a 4-element block at address `0x7FFC...A0` is stored as `0x7FFC...A0` (unchanged, low bit is `0`).

The VM uses two `static inline` helpers to convert:

```c
static inline value encode(long n) { return (value)(2 * n + 1); }
static inline long  decode(value v) { return (long)(v - 1) / 2; }
```

---

## Architecture highlights

Several design decisions distinguish this implementation from a naive monolithic VM:

### No global variables

The 256-entry atoms table (`tab_atoms`) is **encapsulated as a field of the `vm` struct**, not declared as a global. That makes the VM **fully self-contained** — there is no `extern` declaration anywhere in the project. Two `vm` instances running in the same process would have completely independent atom tables. (The course allows the `extern` keyword, but I deliberately avoided it after running into multi-definition issues during early development.)

### Single source of truth for the `vm` type

The `vm` struct is defined **exactly once**, in `include/types.h`. Every `.c` file that includes `types.h` sees the same definition, respecting the C *One Definition Rule*. No header has its own copy of the struct.

### Split dispatch

Instead of one giant 80-case `switch` in a single file, the engine dispatches through **four small sub-switches**:

```
                       ┌────────────────────────┐
                       │  engine.c              │
                       │  fetch-execute loop:   │
                       │  if (eval_base())      │
                       │      continue;         │
                       │  if (eval_arithmetic())│
                       │      continue;         │
                       │  if (eval_control())   │
                       │      continue;         │
                       │  if (eval_memory())    │
                       │      continue;         │
                       └─────────┬──────────────┘
                                 │  one sub-switch per category
            ┌────────────────────┼────────────────────┬────────────────────┐
            ▼                    ▼                    ▼                    ▼
     engine_eval_base      engine_eval_arithmetic  engine_eval_control  engine_eval_memory
   (PUSH, POP, ACC, …)     (ADD, MUL, INTCONST, …) (BRANCH, SWITCH, …) (MAKEBLOCK, GETFIELD, …)
```

Each sub-switch returns `1` if it handled the opcode (so `continue` skips the rest), or `0` if not (so the next dispatcher is tried). This keeps each file readable (≈ 200 lines instead of 1000) without paying any runtime cost.

### ACSL-style function contracts

Every public function in `include/*.h` carries Frama-C-flavoured contracts:

```c
/* @requires  mv != NULL && mv->top < mv->max_stack_size - 1
 * @assigns   mv->stack, mv->top
 * @ensures   the value v has been pushed and top is incremented by 1
 */
void push(vm *mv, value v);
```

These comments document **what the caller must guarantee**, **what the function modifies**, and **what state holds after the call**. While they aren't checked by a verifier in this project, they made debugging dramatically easier: every time a contract was violated, I had a precise place to look.

---

## Project layout

```
.
├── Makefile
├── README.md
├── .gitignore
├── include/                        # public headers
│   ├── types.h                     # `vm` struct + encode/decode (defined once here)
│   ├── stack.h                     # push / pop / peek
│   ├── loader.h                    # reading the .sobf file
│   ├── primitives.h                # atom initialisation + primitive calls
│   ├── vm.h                        # final state pretty-printer
│   ├── engine_eval_base.h          # evaluator: base / stack / accumulator opcodes
│   ├── engine_eval_arithmetic.h    # evaluator: arithmetic and constants
│   ├── engine_eval_control.h       # evaluator: control flow and C-calls
│   ├── engine_eval_memory.h        # evaluator: globals, blocks, atoms
│   ├── instr_base.h                # implementations of base instructions
│   ├── instr_arithmetic.h          # implementations of arithmetic instructions
│   ├── instr_control.h             # implementations of control-flow instructions
│   └── instr_memory.h              # implementations of memory instructions
├── src/                            # implementations (.c)
│   ├── main.c                      # CLI entry point
│   ├── stack.c
│   ├── loader.c
│   ├── primitives.c
│   ├── vm.c
│   ├── engine.c                    # the main fetch-execute loop (small)
│   ├── engine_eval_base.c          # sub-switch for base opcodes
│   ├── engine_eval_arithmetic.c    # sub-switch for arithmetic opcodes
│   ├── engine_eval_control.c       # sub-switch for control-flow opcodes
│   ├── engine_eval_memory.c        # sub-switch for memory opcodes
│   ├── instr_base.c
│   ├── instr_arithmetic.c
│   ├── instr_control.c
│   └── instr_memory.c
└── tests/                          # .sobf binary files + plain-text descriptions
    ├── base.sobf       base.txt
    ├── branchs.sobf    branchs.txt
    ├── ints.sobf       ints.txt
    ├── prims.sobf      prims.txt
    ├── blocks.sobf     blocks.txt
    ├── fact.sobf       fact.txt
    ├── pinetree.sobf   pinetree.txt
    └── wumpus.sobf     wumpus.txt
```

The split into `engine_eval_*` (the dispatchers) and `instr_*` (the actual implementations) is intentional. The dispatchers are *boring* — they just route opcodes. The implementations are *interesting* — they manipulate the stack, the accumulator, the globals.

---

## Build and run

### Build

```bash
make            # builds the sobfvm executable at the project root
make rebuild    # clean then rebuild from scratch
make clean      # remove obj/ and the executable
```

The Makefile auto-discovers every `.c` file in `src/` with `wildcard`, maps each one to its `.o` under `obj/`, and links them into the final `sobfvm` binary. Compiler flags: `-Wall -Wextra -g -Iinclude`. No warnings.

### Run

```bash
./sobfvm path/to/file.sobf
./sobfvm path/to/file.sobf --print-end-machine
```

- The first argument is **mandatory**: the path to a `.sobf` binary file.
- The optional flag `--print-end-machine` dumps the full machine state (program counter, accumulator, stack, globals) at the end of execution.

### Examples

```bash
./sobfvm tests/base.sobf --print-end-machine
./sobfvm tests/fact.sobf                          # asks for n on stdin, prints n!
./sobfvm tests/pinetree.sobf --print-end-machine  # asks for n, draws a pine tree
./sobfvm tests/wumpus.sobf                        # classic interactive game
```

---

## The `.sobf` file format

Every `.sobf` file follows the same simple structure:

| line / region            | content                                                        |
|--------------------------|----------------------------------------------------------------|
| Line 1                   | The literal string `SOBF`                                      |
| Line 2                   | Two integers in text: `c` (number of code cells), `v` (number of global cells) |
| Binary code array        | `c` × `int32` (the bytecode instructions)                      |
| Binary global array      | `v` × `long int` (the program's global values)                 |

The loader's `read_sobf` function:

1. Opens the file in binary mode.
2. Reads and validates the `SOBF` header with `fscanf`.
3. Reads `c` and `v`.
4. **Skips any residual whitespace and newlines** between the textual header and the binary payload.
5. Reads the `c` instructions and `v` globals.
6. Populates the `vm` struct.

---

## Memory layout and value encoding

The VM's memory is split into five distinct regions:

| region                | contents                                              | implementation                  |
|-----------------------|-------------------------------------------------------|---------------------------------|
| **Code array**        | The instructions (32-bit integers)                    | `int *codes` in the `vm` struct |
| **Globals**           | Module-level variables                                | `value *tab_globals`            |
| **Stack**             | Temporary values during evaluation, function frames   | `value *stack`, capped at 1000  |
| **Heap (blocks)**     | Tuples, lists, arrays — allocated by `MAKEBLOCK`      | dynamic `malloc`                |
| **Atoms table**       | 256 unique pointers for zero-sized blocks             | `void *tab_atoms[256]`          |

The stack uses an integer `top` indexing the topmost occupied slot (`top = -1` means empty). At depth `n` from the top, the element is at `stack[top - n]`. This convention is the one used by the official Caml VM.

### Stack operations — safety first

```c
void push(vm *mv, value v) {
    if (mv->top >= mv->max_stack_size - 1) {
        fprintf(stderr, "Error: stack full\n");
        exit(1);
    }
    mv->stack[++mv->top] = v;
}

value pop(vm *mv) {
    if (mv->top < 0) {
        fprintf(stderr, "Error: stack empty\n");
        exit(1);
    }
    return mv->stack[mv->top--];
}

value peek(vm *mv, int depth) {
    if (depth > mv->top) {
        fprintf(stderr, "Error: peek out of stack\n");
        exit(1);
    }
    return mv->stack[mv->top - depth];
}
```

Every stack operation guards against out-of-bounds access and aborts the VM if a contract is violated. This catches bugs in *programs being executed* (e.g. a miscompiled `.sobf` file) early, before they corrupt memory.

---

## Instruction set

The VM handles roughly 80 opcodes, organised into five categories. (Full numeric codes and stack effects are documented in the [Caml Virtual Machine spec, v1.4](http://cadmium.x9c.fr), and reproduced as comments in `instr_*.c`.)

| category               | examples                                                    |
|------------------------|-------------------------------------------------------------|
| **Base**               | `ACC`, `PUSH`, `POP`, `ASSIGN`, `STOP`                      |
| **Arithmetic**         | `ADDINT`, `MULINT`, `DIVINT`, `ANDINT`, `LSLINT`, `EQINT`   |
| **Control flow**       | `BRANCH`, `BRANCHIF`, `BRANCHIFNOT`, `SWITCH`, `BOOLNOT`    |
| **Memory / blocks**    | `MAKEBLOCK`, `GETFIELD`, `SETFIELD`, `GETGLOBAL`, `SETGLOBAL` | 
| **Primitives**         | `C_CALL1`, `C_CALL2`, …                                     | 

### Notable instructions

**`SWITCH n c₀ c₁ … c_{n-1}`** — multi-way branch on the integer in the accumulator. If `i = decode(acc) < n`, jump `c_i + 2` bytes ahead; otherwise skip the whole jump table (`n + 2` ahead). This last case is **not** explicitly mandated by the brief, but I added it defensively so a malformed program doesn't read past the table.

**`MAKEBLOCK n`** — allocate a heap block of size `n`, fill it with the accumulator and the next `n − 1` stack values, store the pointer in the accumulator. Memory is allocated with `malloc` and never freed in this project (see [Limitations](#limitations-and-possible-extensions) for the memory-leak discussion).

**Atoms (zero-size blocks)** — `MAKEBLOCK 0 tag` returns a pointer from the `tab_atoms[tag]` array. The table is filled once at VM startup with 256 unique `malloc(0)` results. This guarantees that every zero-size block with the same tag has the *same* address, which matches OCaml's semantics for constant constructors.

---

## Test programs

The `tests/` directory contains **eight test programs** with paired plain-text descriptions:

| test         | what it does                                                             |
|--------------|--------------------------------------------------------------------------|
| `base`       | exercises every base instruction (push, pop, acc, assign, stop)          |
| `branchs`    | exercises `BRANCH`, `BRANCHIF`, `BRANCHIFNOT`, `SWITCH`, `BOOLNOT`, `EQ` |
| `ints`       | arithmetic and comparison opcodes on integers                            |
| `prims`      | reads a character from stdin, prints it back (primitive C-calls)         |
| `blocks`     | allocates blocks, reads/writes their fields, walks data structures        |
| `fact`       | reads an integer `n` from stdin and prints `n!` (for `0 ≤ n ≤ 20`)       |
| `pinetree`   | reads `n` and draws an ASCII pine tree of height `n`                     |
| `wumpus`     | the classic 1973 Hunt-the-Wumpus game (infinite loop expected)           |

All eight tests pass. The two interactive programs (`fact`, `pinetree`) are the most demanding — they exercise the full VM: primitive calls (`read_int`, `print_char`, `print_int`), control flow, recursion (`APPLY`/`RETURN`), and stack management.

---

## Sample run — the `pinetree` program

Running `./sobfvm tests/pinetree.sobf --print-end-machine` and entering `5` on stdin produces:

```
5
*
**
*
**
***
*
**
***
****
*
**
***
****
*****

Index: 123
Accumulator: 1
Stack:
Global:
0 139859390459264
1 139859390459312
2 139859390459360
3 139859390459408
4 139859390459456
5 139859390459504
6 139859390459560
7 139859390459608
8 139859390459656
9 139859390459704
10 139859390459752
11 139859390459800
12 110654656967152
```

The final state shows:

- **Program counter** at instruction 123 (the `STOP`).
- **Accumulator** = 1 (= encoded `0`, i.e. the unit value returned by the last `print_endline`).
- **Stack** empty — clean shutdown.
- **Globals** 0 through 11 are addresses (atoms and live blocks); global 12 is the `unit` constant.

A clean exit. The same VM also handles 0! = 1 and 20! = 2432902008176640000 in the `fact` test, all the way up to the largest factorial that fits in a signed 64-bit integer.

---

## Debugging methodology

I built an **interactive debugging loop with `gdb`** that became the single most valuable tool of the project. The workflow:

1. Compile with `-g` (already in the Makefile's `CFLAGS`).
2. `gdb ./sobfvm`
3. Set breakpoints on key instructions:
   ```
   break engine_eval_arithmetic.c:42       # the ADDINT case
   break engine_eval_control.c:78          # the SWITCH case
   ```
4. Run with arguments: `run tests/blocks.sobf --print-end-machine`.
5. At each break: inspect `mv->pc`, `mv->acc`, `mv->top`, `mv->stack`, `mv->tab_globals`.
6. `step` through instruction-by-instruction.

Combined with the ACSL contracts in the headers, this made it possible to validate every opcode against the [official Caml VM specification](http://cadmium.x9c.fr) without having to printf-debug each one.

---

## Problem encountered

The two stumbling block I had to overcome:

### The atoms table without `extern`

Two of my `.c` files needed access to the 256-atom table. My first attempt declared `void *tab_atoms[256];` as a *global* in `primitives.c` and `extern void *tab_atoms[256];` in the others. Worked, but the course brief forbade `extern`.

Second attempt: declare it locally in each function that needed it. Crashed — because `malloc(0)` returns *different* addresses on each call, so the table built in `MAKEBLOCK` differed from the one read by `GETFIELD`, even though both were filled with `malloc(0)`. **The whole point of an atoms table is that the addresses are stable**.

The fix: I made `tab_atoms` a field of the `vm` struct itself (`void *tab_atoms[256]` directly inside the struct). No globals, no `extern`, one canonical table per VM, and all the instruction implementations naturally receive it via the `vm *mv` pointer they already take.

---

## Limitations and possible extensions

### Known limitation: heap memory is never freed

The `MAKEBLOCK` instruction allocates memory with `malloc`, but no `OCaml`-style garbage collector reclaims it when the block becomes unreachable. `valgrind` on `tests/blocks.sobf` reports:

```
==31800== HEAP SUMMARY:
==31800==     in use at exit: 16,120 bytes in 7 blocks
==31800==   total heap usage: 268 allocs, 261 frees, 22,112 bytes allocated
==31800==
==31800== LEAK SUMMARY:
==31800==    definitely lost: 16,040 bytes in 4 blocks
==31800==    indirectly lost: 80 bytes in 3 blocks
==31800== ERROR SUMMARY: 0 errors from 0 contexts
```

— that is, **zero memory errors**, but 7 unreclaimed blocks (16 KB). For the test programs this is harmless. For long-running programs it would eventually exhaust memory. The textbook fix is a stop-the-world mark-and-sweep collector, which is a substantial project in itself and was out of scope here.

### Possible extensions

- **Direct reading of OCaml-compiled `.cmo` files** instead of the simplified `.sobf` format.
- **Implementing the remaining ~30 opcodes** of the full Caml VM (exceptions, closures, mutual recursion).
- **A simple mark-and-sweep GC** to fix the memory leak.
- **A statistical profiler** that counts opcode frequencies — useful pedagogical data.

---

## References

- **[1]** OCaml (programming language) — Wikipedia: [fr.wikipedia.org/wiki/OCaml](https://fr.wikipedia.org/wiki/OCaml)
- **[2]** Xavier Clerc — *Caml Virtual Machine — Instruction Set*, v1.4 (2007-2010). [cadmium.x9c.fr](http://cadmium.x9c.fr). Released under the LGPL v3.
- Leroy, Doligez, Frisch, Garrigue, Rémy, Vouillon — *The OCaml System: Documentation and User's Manual*, INRIA.
- Brian Kernighan & Dennis Ritchie — *The C Programming Language*, 2nd ed., Prentice Hall.

---

## Author

**Ibrahima Diaby** — ENSIIE, first-year Computer Science & Applied Mathematics student, PRIM11 project (2025-2026).
