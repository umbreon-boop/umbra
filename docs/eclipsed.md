# The eclipsed binding

`eclipsed` is Umbra's LuaJIT FFI binding to the Eclipsed C ABI. It loads a
shared library and its matching `eclipsed.h`, then exposes lexer, parser, and
source-query functions to Umbra and plugins. The generated function list is
under [`eclipsed`](API/eclipsed.md) and the parsed-chunk object under
[`Chunk`](API/Chunk.md).

## Loading the native library

Call `require("eclipsed").load()` once before using the API. The library and
header default to `libeclipsed.so` and `eclipsed.h` beside the Umbra
executable on Linux, or `libeclipsed.dylib` on macOS. If those files are not
there, Umbra checks `$HOME/.local/lib` for the platform library and header
(including the older `eclipsed.so` Linux library name).

The short environment variables are `ECL_LIB` and `ECL_H`. Relative values
are resolved from the executable's directory, so a portable package can keep
the binary, library, and header together. The older `ECLIPSED_LIB` and
`ECLIPSED_HEADER` names still work as fallbacks. Explicit arguments override
the environment:

```lua
local ecl = require("eclipsed").load("lib/libeclipsed.so", "include/eclipsed.h")
```

The header and library must come from the same Eclipsed build. Loading checks
the ABI version and reports a useful error when either file is incompatible.

## Parsed chunks

A chunk keeps the native tree alive for repeated queries:

```lua
local ecl = require("eclipsed").load()
local chunk, message = ecl.parse(source, "luau")
assert(chunk, message)

print(chunk:statement_count())
local statements, count = chunk:statements()
local tokens = chunk:tokens()
local declarations = chunk:declarations()
local type_spans = chunk:type_spans()

chunk:free()
```

On failure, `ecl.parse`, `ecl.declarations` and `ecl.type_spans` return
`nil, message, start, end`, with a 1-based inclusive byte range.

`chunk:free()` is optional; garbage collection releases the native allocation
when the chunk becomes unreachable. Calling it explicitly is useful in long
running tools that process many files. The `declarations` and `type_spans`
convenience functions parse, query, and free in one call.
