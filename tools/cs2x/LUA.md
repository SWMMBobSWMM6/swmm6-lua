# C# to Lua: how tools/cs2x/Cs2Lua.cs maps the generated engine

The Lua engine is written from the verified C# engine (`cs/gen`, 480/480 against the SWMM6 reference) the way the
Python, Ruby and Perl engines are: Roslyn's semantic model, one IOperation tree per method, printed as Lua 5.4. The
translator began as a copy of the Perl back end (`Cs2Pl.cs`, `PlTypes.cs`, `PlFn.cs`; `PL.md`), so the analysis
(written fields, makers, overload names) and the runtime names are the Python, Ruby and Perl ports', and every runtime
name the engine uses has their spelling. The runtime (`lua/rt`) is written in Lua for this port. What is Lua's is
recorded here.

    tools/cs2x/build_lua.sh && dotnet tools/cs2x/bin/cs2lua.dll cs lua/gen

writes `lua/gen/engine.lua` (one file, 168,101 lines), `lua/gen/literals.txt` (every double literal, as written and as
the bits of the C# double), `lua/cs2lua_runtime.txt` (every runtime name the file uses, with the C# member it stands
for: 608), `lua/cs2lua_todo.txt` (untranslated constructs: none) and `lua/cs2lua_stats.txt` (how often each
translation choice was made). The counts below are from that file.

## Output

- Lua 5.4.8 as lupa 2.8 embeds it, with only Lua's standard libraries. Every runtime file and the engine are chunks
  run with one shared environment table `E` (`lua/runswmm6.lua`): a chunk takes the standard functions it needs as
  locals, then `local _ENV = ...`, so that its globals are E's. The engine's classes, functions and static fields are
  globals of E; the engine aliases about thirty hot runtime functions as locals (`L_idiv`, `L_f2i32`, `L_pow`, ...).
- An engine object is a table whose metatable is its class table `O_<Type>` (`lua_class`: `__index` is the class,
  `__isa` the set of the class, its bases and its runtime interfaces, which `isa_` tests). Inherited methods are copied
  down into each class once the engine is loaded (`inherit_all`), so a method lookup is one `__index` step.
  `O_<Type>._new` makes a table of every field of the hierarchy at its C# default (`0`, `0.0`, `false`, `nil`, a
  runtime struct's `_ZERO`); each C# constructor is `O_<Type>.ctor_<Type><sfx>` and a factory `<Type>__new<sfx>(...)`
  allocates, runs the constructor and returns the object. Type names that start with a lower-case letter get a `T`.
- Calls: a non-virtual method is called as a function, `O_<Decl>.m(recv, ...)` (7,446 sites); virtual, abstract and
  override methods and interface implementations are method calls `recv:m(...)`; a `base.` call is a direct call of
  the base class's function (35). Free functions and static methods are `F_<file>_<name>` and `<Type>_<name>`;
  static fields are globals `S_<Type>_<name>`, set in C#'s dependency order at load time (one `do ... end` block per
  class). A static field whose C# default is null is declared to the strict-globals guard (`declare_global`).
- Small methods (a single `return` of an expression with no side effects, arguments that are simple or used once) are
  inlined at their call sites (3,284 calls).
- Lua's limits: at most 200 locals per function (temporaries are pooled per function, `t_N`, declared at its top; an
  array initializer whose elements need statements is built element by element, 25 sites), `goto` may not jump into
  the scope of a local (the locals of a block with a label are declared at its start, 4 blocks), and a `return` must end
  its block (written `do return x end`). A statement that starts with `(` is written after `;`.

## Numbers

A Lua 5.4 number is a 64-bit integer or a double, and the two subtypes stay apart: `1 + 2` is an integer, `1 + 2.0`
a double, `7 // 2` integer floor division, `/` always a double.

- C# `int` arithmetic is wrapped to 32 bits where the result is stored or its width matters:
  `(((x + 0x80000000) & 0xFFFFFFFF) - 0x80000000)`; 8 and 16 bits likewise, unsigned widths by a mask. `long` is Lua's
  integer, which wraps as C#'s unchecked arithmetic does. `ulong` is held as the same 64 bits (compared with
  `math.ult`, divided by `udiv64`/`umod64`, converted to double by `u2d`); a ulong constant of 2^63 or more is a
  hexadecimal literal, `long.MinValue` is `(-9223372036854775807 - 1)`. C#'s integer division and remainder truncate
  toward zero: `idiv`/`imod` (Lua's `//` and `%` floor). `>>` of a signed long is `sar` (Lua's `>>` is logical); of a
  signed int, `x // 2^n`. A conversion of a signed index to `ulong` is left out where the value is an array index
  (4,789 sites): a negative index would have stopped the C# engine.
- Doubles are always Lua floats. An integer converted to double is made a float (`(x + 0.0)` or a literal with a
  point) where it is stored, passed, returned or combined with another such value, so no double-typed value is ever a
  Lua integer (an integer-valued float prints and compares like an integer, but `math.type`, `//`, string.format and
  table keys tell them apart). Double `%` is C's `fmod`. Conversions to integers are `f2i32`/`f2i64` (x86's
  truncation, the "integer indefinite" for NaN and out-of-range values), `float` (C# single) rounds through
  `string.pack('f')` after every operation (`f32`).
- Double literals are C#'s round-trip text (`ToString("R")`, `.0` added to a whole number);
  `lua/test/literals_check.lua` reads all 2,002 back through Lua's parser: every one has the C# double's bits and is a
  float.
- Math: Lua's `math.exp`, `sin`, `cos`, `tan`, `asin`, `acos`, `sqrt`, `math.log(x)`, `math.log(x, 2)`,
  `math.log(x, 10)`, `math.atan(y, x)`, `math.fmod` and `x ^ y` call the C library. lupa's Lua refers to them without
  symbol versions, so the dynamic linker binds each to its oldest version; where that is an SVID compatibility wrapper
  whose result differs (log and log2 of a negative number, the NaN fmod returns when both arguments are NaNs) the
  runtime gives glibc's current result. Lua's `x ^ 2` is `x * x`, not `pow`, so `Math.Pow` is `Math_Pow_d`, which calls
  glibc's translated `pow` when the exponent is 2; `math.atan(x)` is `atan2(x, 1)`, so `Math.Atan` is glibc's translated
  `atan`; `sinh`, `cosh`, `tanh`, `expm1`, `log1p`, `cbrt` and `hypot`, which Lua does not have, are glibc's translated
  routines (`lua/rt/glibm.lua`, made by `tools/libm/gim2lua.py` and `lua/make_glibm.sh`). `lua/test/run_libm_tests.sh`
  checks every function as the engine calls it against the system libm (`lua/results/libm_tests.txt`).

## Values, references, lambdas

- Arrays are tables with the elements at 0 .. n-1 and the length in the field `n` (`{[0] = a, b, c, n = 3}`,
  `newA(n, default)`); pointers into arrays are runtime `Ptr` tables (`a` the array, `o` the offset), read inline as
  `p.a[p.o + i]`; byte buffers and C strings are `CPtr` (`B` the byte array, `O` the offset).
- `ref T` and `out T` are a pair of values, a table and a key, passed as two arguments (`t, k`; a parameter `p` becomes
  `p, p_k`): a field is `(obj, "name")`, an array element `(arr, i)`, a static field `(_ENV, "S_...")`. A local or
  parameter whose address is taken lives in a one-element table, a cell `{v}`, read as `x[1]` (290 cells). A method
  that returns a reference returns the pair; `L_deref2` reads it. A runtime method returns a value under its plain name
  and the pair under a `ref_` name.
- C# structs are copied with `Clone` / `CopyFrom` at assignment, as in the Python and Perl ports; generics are erased
  and element makers (`MK_D`, `K_MKn`) are passed as there.
- Statements: loops are `while`, `repeat ... until` and numeric `for` (a `for (int i = a; i < n; i++)` whose counter is
  declared in the loop and that the body cannot change: 832 loops); `continue` is `goto contN` to the end of the body,
  which is wrapped in `do ... end`; `switch` is an `if`/`elseif` chain, with `goto swN` where a `break` is not the
  case's last statement (79); the seven C# `goto`s are Lua's. A lambda is an anonymous function written in place; Lua's
  `local` in a loop body is a fresh variable each iteration, so a lambda captures as C#'s does.
- Expressions: Lua's `a and b or c` is a conditional only when `b` cannot be `false` or `nil`; a conditional whose
  arm may be (152) or that needs statements (83) is hoisted into an `if` on a temporary, as are assignments used as
  values (30) and operands spilled to keep C#'s order of evaluation (132).
- Exceptions: `try` is `local ok, tag, val = L_pcall(function() ... end)`; a `return` inside it returns a tag and the
  value, a `break` or `continue` out of it a tag the caller turns into the jump. Exceptions derive from the runtime's
  `CppException`; a .NET exception the C# throws itself is a `SysException` (kind, message), and Lua's own errors
  (an arithmetic error, an index of nil) become `SysException`s too (`exc_of`), so `catch (Exception)` sees them all.
  `using` declarations are a `pcall` and a call of `Dispose`.

## Checks

The engine loads over the runtime; `lua/runswmm6.lua`'s strict-globals guard (on in every run, the gates included)
stops any read of a global that the runtime or the engine never defined; `lua/test` checks the runtime against glibc
and libstdc++ (`lua/README.md`). Then the gate.

Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.
