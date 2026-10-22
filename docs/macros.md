# Macros

Umbra can inline a function at its call sites when the declaration carries
`@inline` or `@macro` in the comment before it. This happens in the bundle
pipeline, so it needs no runtime support.

```lua
--@inline
local function double(x)
    return x * 2
end

print(double(21)) -- becomes print((21) * 2)
```

Both `local function name(...)` and `function table.name(...)` /
`function table:name(...)` declarations are recognised. Call sites are found
by binding, never by name, so another function that happens to be called
`double` is untouched.

## `@inline` is a suggestion

`@inline` substitutes only where the meaning is preserved. A statement macro
comes out as `do local <params> = <arguments> <body> end`, so each argument is
evaluated once and in order. An expression macro substitutes its arguments
where each is evaluated in the same order and the same number of times. Extra
arguments are evaluated and discarded, missing ones are `nil`, and both
`f(a)` and the `f"text"` / `f{...}` call forms are recognised. A macro that
takes no parameters still evaluates the arguments given to it before its body.

Where that is not true, the arguments are bound to fresh locals in a block
before the statement that holds the call:

```lua
local s = square(f()) * 10
```

becomes

```lua
local s do local a = f();
s = (a * a) * 10
end
```

The call can be the statement itself, a returned or assigned value, or part
of a larger expression in a `local`, an assignment, a `return`, a call
statement, the first condition of an `if`, or a numeric or generic `for`
header. In a larger expression, the parts that the statement evaluates before
the call are bound to fresh locals
first, in the same order, unless they cannot change: constants, locals that
are never assigned again, and globals the chunk never assigns. If the chunk
uses `_G`, `rawset`, or `setfenv`, globals are treated as changeable. Field
reads are bound early because `__index` can run code. Assignment target
expressions that can run code are also bound before a hoisted body, while a
local target index is left for the assignment to read at the store. A local
of the same function that is an operand of an arithmetic or comparison
operator stays in place, because Lua and Luau read
it only when the operator runs:

```lua
return n + twice(f())
-- becomes
do local a = f();
return n + (a + a)
end
```

A call in a `while` condition, an `elseif`, the right side of `and` or `or`,
or an `if` expression branch is evaluated only sometimes, so it is left as a
normal call with a warning. So is a method call whose method name the chunk
assigns, because the method is looked up before its arguments run. Every
expansion is parsed again, and a site where a copied name would bind
differently is also left alone with a warning.

Because inlining binds arguments, spills, hoisted locals, and parameters to
locals, it can push a function past Lua's hard limit of 200 variables in
scope. Umbra measures that after macro declarations that are no longer used
have been dropped, then reports which call would exceed the limit and stops
instead of writing a bundle that LuaJIT cannot load. That is a compile error
rather than an optimisation opportunity.

## `@macro` overwrites

`@macro` expands the call whether or not that preserves evaluation order,
duplication, or binding. Use it for metaprogramming, where the caller wants
the tokens copied as written and accepts those hazards:

```lua
--@macro
local function twice(x)
    return x + x
end

local n = 0
local function bump()
    n = n + 1
    return n
end

print(twice(bump()), n) -- prints 3  2; bump runs twice
```

A `@macro` site that cannot be represented at all, such as a statement macro
used as a bare expression, is still left alone with a warning.

## Assignment hoisting

A statement macro that ends in a single `return` can supply a value anywhere
its earlier statements can move above the statement holding the call. The
statements before the return move first and the call is replaced by the
returned expression:

```lua
--@inline
local function scaled(x)
    local y = x * 2
    print("scaling", y)
    return y + 1
end

local a = scaled(3)
```

becomes

```lua
local a do local b = 3;
local c = b * 2
print("scaling", c);
a = c + 1
end
```

`@inline` gives the parameters and the hoisted locals fresh names in a block
of their own, so they cannot shadow or overwrite a name of the caller, and
each argument is evaluated once. The names do not matter, because the
minifier renames them. A `local` with an attribute such as `<const>` cannot
be assigned later, so its hoisted names stay in the caller's block, still
under fresh names. `@macro` keeps the names as written, in the caller's
block, and copies the arguments into the returned expression, so it can
shadow names and evaluate an argument twice.

A body with no returns at all supplies `nil` to an initializer or assignment
after its side effects run. A body with more than one return, or with a
return that is not last, cannot supply a value this way and is refused with a
warning. That is one more reason `@inline` reports what it leaves alone.
