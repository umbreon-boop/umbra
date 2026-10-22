local new_table = require("table.new")
local syntax = require("process.syntax")

local scope = {}

--- Where each token starts in the rendered source, and the source itself.
function scope.layout(tokens)
    local parts, starts, offset = new_table(#tokens, 0), new_table(#tokens, 0), 0
    for i, token in ipairs(tokens) do
        parts[i] = token.text
        starts[i] = offset
        offset = offset + #token.text
    end
    return table.concat(parts), starts
end

--- Parses `tokens` and indexes the syntax nodes the formatter needs, without
--- resolving names. This is the cheap subset of `scope.resolve` used by the
--- printer.
function scope.index(tokens, ecl, dialect, original_source, parsed, positions)
    ecl = assert(ecl, "Eclipsed is required")
    local source, starts
    local at, ending
    if positions then
        source = original_source
        at, ending = positions.at, positions.ending
    elseif original_source then
        at, ending = new_table(0, #tokens), new_table(0, #tokens)
        for i, token in ipairs(tokens) do
            if not token.start then
                original_source = nil
                at, ending = nil, nil
                break
            end
            if not token.is_trivia then
                local start = token.start - 1
                at[start] = i
                ending[start + #token.text] = i
            end
        end
    end
    if not original_source then
        source, starts = scope.layout(tokens)
    else
        source = original_source
    end
    local chunk, err = parsed, nil
    if not chunk then
        chunk, err = ecl.parse(source, dialect or "luau")
        if not chunk and not dialect then
            chunk, err = ecl.parse(source, "lua")
        end
    end
    if not chunk then
        return nil, err
    end

    if not at then
        at, ending = new_table(0, #tokens), new_table(0, #tokens)
        for i, token in ipairs(tokens) do
            if not token.is_trivia then
                local start = starts[i]
                at[start] = i
                ending[start + #token.text] = i
            end
        end
    end
    if not source then
        return nil, "missing source"
    end

    local collected = {
        if_nodes = {},
        tables = {},
        calls = {},
        binaries = {},
        functions = {},
        function_expressions = {},
        returns = {},
        cast_parens = {},
        structural_spans = {},
    }
    local info = {
        source = source,
        chunk = chunk,
        at = at,
        ending = ending,
        statements = {},
        syntax = collected,
    }
    local K = ecl.const
    info.root, info.root_count = chunk:statements()

    syntax.walk(info, ecl, function(node)
        local first = at[node.span.start]
        local last = ending[node.span["end"]]
        local kind = node.kind
        if kind == K.STMT_KIND_IF or kind == K.STMT_KIND_WHILE then
            info.has_conditionals = true
        elseif kind == K.STMT_KIND_NUMERIC_FOR or kind == K.STMT_KIND_GENERIC_FOR then
            info.has_for = true
        end
        info.statements[#info.statements + 1] = {
            first = first,
            last = last,
            kind = kind,
            node = node,
        }
        if kind == K.STMT_KIND_LOCAL_FUNCTION then
            collected.functions[#collected.functions + 1] = node.data.local_function.body
        elseif kind == K.STMT_KIND_FUNCTION then
            collected.functions[#collected.functions + 1] = node.data["function"].body
        elseif kind == K.STMT_KIND_RETURN then
            collected.returns[#collected.returns + 1] = node
        end
    end, function(node)
        local kind = node.kind
        if kind == K.EXPR_KIND_IF_ELSE then
            collected.if_nodes[#collected.if_nodes + 1] = node
        elseif kind == K.EXPR_KIND_TABLE then
            collected.tables[#collected.tables + 1] = node
        elseif kind == K.EXPR_KIND_CALL or kind == K.EXPR_KIND_METHOD_CALL then
            collected.calls[#collected.calls + 1] = node
        elseif kind == K.EXPR_KIND_BINARY then
            collected.binaries[#collected.binaries + 1] = node
        elseif kind == K.EXPR_KIND_FUNCTION then
            collected.functions[#collected.functions + 1] = node.data["function"]
            collected.function_expressions[#collected.function_expressions + 1] = node
        end
        if kind == K.EXPR_KIND_PAREN and node.data.paren.kind == K.EXPR_KIND_CAST then
            collected.cast_parens[#collected.cast_parens + 1] = node
        end
    end)
    return info
end

--- Resolves every name in `tokens` by parsing their rendering.
---
--- Returns `nil, message` when the tokens do not parse. Otherwise the info
--- table has, keyed by token index: `owner` (binding id), `access`
--- (`declare`, `read`, `write` or `readwrite`), `global` (the name of a
--- global reference) and `func` (the innermost function id). `bindings`
--- lists each binding's `name`, `kind` (`local`, `param`, `function` or
--- `loop`), `declared_at`, `occurrences`, `func` and, for `self`, `implicit`
--- and `receiver`. A binding or global referenced where no token starts,
--- as inside an interpolated string, is `pinned`. `functions[id].parent`
--- links function ids, with 0 for the chunk. `statements` lists every
--- statement's `first` and `last` token index, `kind` and `node`.
--- `local_peaks[func]` is the most locals that function has in scope at once.
function scope.resolve(tokens, ecl, dialect, collect_syntax, original_source, parsed)
    ecl = assert(ecl, "Eclipsed is required")
    local source, starts
    if original_source then
        source = original_source
        starts = new_table(#tokens, 0)
        for i, token in ipairs(tokens) do
            starts[i] = token.start - 1
        end
    else
        source, starts = scope.layout(tokens)
    end
    local chunk, err = parsed, nil
    if not chunk then
        chunk, err = ecl.parse(source, dialect or "luau")
        if not chunk and not dialect then
            chunk, err = ecl.parse(source, "lua")
        end
    end
    if not chunk then
        return nil, err
    end

    local K = ecl.const
    -- Pre-size the maps: growing them one rehash at a time is slow for big bundles.
    local at, ending = new_table(0, #tokens), new_table(0, #tokens)
    for i, token in ipairs(tokens) do
        if not token.is_trivia then
            at[starts[i]] = i
            ending[starts[i] + #token.text] = i
        end
    end

    local used = {}
    for _, token in ipairs(tokens) do
        if token.type == ecl.T.Identifier then
            used[token.text] = true
        end
    end

    local info = {
        bindings = {},
        owner = {},
        access = {},
        global = {},
        func = {},
        used = used,
        pinned_globals = {},
        functions = { [0] = { parent = nil } },
        statements = {},
        chunk = chunk,
        source = source,
        at = at,
        ending = ending,
    }
    local bindings, owner, access = info.bindings, info.owner, info.access
    local collected
    if collect_syntax then
        collected = {
            if_nodes = {},
            tables = {},
            calls = {},
            binaries = {},
            functions = {},
            function_expressions = {},
            returns = {},
            cast_parens = {},
            structural_spans = {},
        }
        info.syntax = collected
    end

    local function text(range)
        return source:sub(range.start + 1, range["end"])
    end
    local function each(list, visit)
        local ptr = list.ptr
        for i = 0, tonumber(list.len) - 1 do
            visit(ptr[i], i + 1)
        end
    end

    local scopes = { { names = {}, count = 0 } }
    local current_function = 0
    -- Locals are registers: every declaration in a live block occupies one
    -- until that block ends, while nested functions have their own budget.
    local local_counts, local_peaks = { [0] = 0 }, { [0] = 0 }

    local function held(count)
        local func = current_function
        local active = (local_counts[func] or 0) + count
        local_counts[func] = active
        if active > (local_peaks[func] or 0) then
            local_peaks[func] = active
        end
    end

    local function lookup(name)
        for level = #scopes, 1, -1 do
            local binding = scopes[level].names[name]
            if binding then
                return binding
            end
        end
    end

    local function declare(range, kind)
        local name = text(range)
        local index = at[range.start]
        local binding = {
            id = #bindings + 1,
            name = name,
            kind = kind,
            declared_at = index,
            occurrences = {},
            func = current_function,
        }
        bindings[binding.id] = binding
        used[name] = true
        if index then
            owner[index] = binding.id
            access[index] = "declare"
            info.func[index] = current_function
            binding.occurrences[1] = index
        else
            binding.pinned = true
        end
        local frame = scopes[#scopes]
        frame.names[name] = binding
        frame.count = frame.count + 1
        held(1)
        return binding
    end

    local function reference(range, mode)
        local name = text(range)
        local index = at[range.start]
        local binding = lookup(name)
        used[name] = true
        if not index then
            if binding then
                binding.pinned = true
            else
                info.pinned_globals[name] = true
            end
            return binding
        end
        access[index] = mode
        info.func[index] = current_function
        if binding then
            owner[index] = binding.id
            binding.occurrences[#binding.occurrences + 1] = index
        else
            info.global[index] = name
        end
        return binding
    end

    local function push()
        scopes[#scopes + 1] = { names = {}, count = 0 }
    end
    local function pop()
        local frame = scopes[#scopes]
        for _ = 1, frame.count do
            held(-1)
        end
        scopes[#scopes] = nil
    end

    local expression, block, statements_of, annotation

    local function expressions(list)
        each(list, function(node)
            expression(node)
        end)
    end

    local function optional_type(pointer)
        if pointer ~= nil then
            annotation(pointer)
        end
    end

    --- Walks a function; `method` adds the implicit `self`, whose receiver
    --- is the binding of the table the method is declared on, if local.
    local function function_body(body, method, receiver)
        local parent = current_function
        local id = #info.functions + 1
        info.functions[id] = { parent = parent, node = body }
        current_function = id
        local_counts[id], local_peaks[id] = 0, 0
        push()
        if method then
            local binding = {
                id = #bindings + 1,
                name = "self",
                kind = "param",
                occurrences = {},
                func = id,
                implicit = true,
                receiver = receiver,
            }
            bindings[binding.id] = binding
            scopes[#scopes].names.self = binding
            scopes[#scopes].count = scopes[#scopes].count + 1
            held(1)
        end
        each(body.type_parameters, function(parameter)
            optional_type(parameter.default_type)
        end)
        each(body.parameters, function(parameter)
            optional_type(parameter.type_annotation)
            declare(parameter.name, "param")
        end)
        optional_type(body.vararg_type)
        each(body.returns, annotation)
        statements_of(body.body)
        pop()
        current_function = parent
        return id
    end

    local function arguments(args)
        each(args.type_arguments, annotation)
        expressions(args.values)
    end

    local skip_collect = 0

    function expression(node)
        local kind = node.kind
        local data = node.data
        if collected and skip_collect == 0 then
            if kind == K.EXPR_KIND_IF_ELSE then
                collected.if_nodes[#collected.if_nodes + 1] = node
            elseif kind == K.EXPR_KIND_TABLE then
                collected.tables[#collected.tables + 1] = node
            elseif kind == K.EXPR_KIND_CALL or kind == K.EXPR_KIND_METHOD_CALL then
                collected.calls[#collected.calls + 1] = node
            elseif kind == K.EXPR_KIND_BINARY then
                collected.binaries[#collected.binaries + 1] = node
            elseif kind == K.EXPR_KIND_FUNCTION then
                collected.functions[#collected.functions + 1] = data["function"]
                collected.function_expressions[#collected.function_expressions + 1] = node
            elseif kind == K.EXPR_KIND_PAREN and data.paren.kind == K.EXPR_KIND_CAST then
                collected.cast_parens[#collected.cast_parens + 1] = node
            end
        end
        if kind == K.EXPR_KIND_NAME then
            reference(node.span, "read")
        elseif kind == K.EXPR_KIND_UNARY then
            expression(data.unary.operand)
        elseif kind == K.EXPR_KIND_BINARY then
            expression(data.binary.left)
            expression(data.binary.right)
        elseif kind == K.EXPR_KIND_TABLE then
            each(data.table, function(field)
                if field.key ~= nil then
                    expression(field.key)
                end
                expression(field.value)
            end)
        elseif kind == K.EXPR_KIND_FUNCTION then
            function_body(data["function"])
        elseif kind == K.EXPR_KIND_CALL then
            expression(data.call.callee)
            arguments(data.call.arguments)
        elseif kind == K.EXPR_KIND_METHOD_CALL then
            expression(data.method_call.receiver)
            arguments(data.method_call.arguments)
        elseif kind == K.EXPR_KIND_FIELD then
            expression(data.field.table)
        elseif kind == K.EXPR_KIND_INDEX then
            expression(data.index.table)
            expression(data.index.key)
        elseif kind == K.EXPR_KIND_CAST then
            expression(data.cast.expression)
            annotation(data.cast.target)
        elseif kind == K.EXPR_KIND_PAREN then
            expression(data.paren)
        elseif kind == K.EXPR_KIND_IF_ELSE then
            local branch = data.if_else
            expression(branch.condition)
            expression(branch.then_branch)
            each(branch.elseifs, function(arm)
                expression(arm.condition)
                expression(arm.result)
            end)
            expression(branch.else_branch)
        elseif kind == K.EXPR_KIND_INTERPOLATED then
            each(data.interpolated, function(part)
                if part.expression ~= nil then
                    expression(part.expression)
                end
            end)
        end
    end

    function annotation(node)
        local kind, data = node.kind, node.data
        if kind == K.TYPE_KIND_TYPEOF then
            skip_collect = skip_collect + 1
            expression(data.typeof_)
            skip_collect = skip_collect - 1
        elseif kind == K.TYPE_KIND_ARRAY or kind == K.TYPE_KIND_OPTIONAL or kind == K.TYPE_KIND_VARIADIC then
            annotation(data.inner)
        elseif kind == K.TYPE_KIND_MAP then
            annotation(data.map.key)
            annotation(data.map.value)
        elseif kind == K.TYPE_KIND_TUPLE or kind == K.TYPE_KIND_UNION or kind == K.TYPE_KIND_INTERSECTION then
            each(data.list, annotation)
        elseif kind == K.TYPE_KIND_FUNCTION then
            each(data["function"].parameters, function(parameter)
                annotation(parameter.type_)
            end)
            each(data["function"].returns, annotation)
        elseif kind == K.TYPE_KIND_GENERIC or kind == K.TYPE_KIND_QUALIFIED then
            each(data.generic.arguments, annotation)
        elseif kind == K.TYPE_KIND_STRUCT then
            each(data.struct_, function(field)
                if field.indexer ~= nil then
                    annotation(field.indexer)
                end
                annotation(field.value)
            end)
        end
    end

    --- Resolves an assignment target; a bare name is written.
    local function target(node, mode)
        if node.kind == K.EXPR_KIND_NAME then
            return reference(node.span, mode)
        end
        expression(node)
    end

    local function locals(list, values, kind)
        local declared = {}
        each(list, function(variable, n)
            optional_type(variable.type_annotation)
            local value = values and n <= tonumber(values.len) and values.ptr[n - 1] or nil
            declared[n] = { variable = variable, value = value }
        end)
        for _, entry in ipairs(declared) do
            local binding = declare(entry.variable.name, kind or "local")
            if entry.value ~= nil and entry.value.kind == K.EXPR_KIND_TABLE then
                binding.constructed = true
            end
        end
    end

    local function statement(node)
        local kind, data = node.kind, node.data
        local first, last = at[node.span.start], ending[node.span["end"]]
        info.statements[#info.statements + 1] = { first = first, last = last, kind = kind, node = node }
        if collected then
            if kind == K.STMT_KIND_LOCAL_FUNCTION then
                collected.functions[#collected.functions + 1] = data.local_function.body
            elseif kind == K.STMT_KIND_FUNCTION then
                collected.functions[#collected.functions + 1] = data["function"].body
            elseif kind == K.STMT_KIND_RETURN then
                collected.returns[#collected.returns + 1] = node
            end
        end

        if kind == K.STMT_KIND_LOCAL or kind == K.STMT_KIND_CONST then
            expressions(data["local"].values)
            locals(data["local"].variables, data["local"].values)
        elseif kind == K.STMT_KIND_IN_UNPACK then
            expressions(data["local"].values)
            locals(data["local"].variables)
        elseif kind == K.STMT_KIND_LOCAL_FUNCTION then
            declare(data.local_function.name, "function")
            function_body(data.local_function.body)
        elseif kind == K.STMT_KIND_FUNCTION then
            local fn = data["function"]
            local path_length = tonumber(fn.path.len)
            local is_method = fn.method["end"] > fn.method.start
            local head = fn.path.ptr[0]
            local binding = reference(head, (path_length == 1 and not is_method) and "write" or "read")
            function_body(fn.body, is_method, binding and binding.id)
        elseif kind == K.STMT_KIND_ASSIGN then
            expressions(data.assign.values)
            each(data.assign.targets, function(node_)
                target(node_, "write")
            end)
        elseif kind == K.STMT_KIND_COMPOUND_ASSIGN then
            expression(data.compound.value)
            target(data.compound.target, "readwrite")
        elseif kind == K.STMT_KIND_DO then
            block(data.block)
        elseif kind == K.STMT_KIND_IF then
            local branch = data.if_
            expression(branch.condition)
            block(branch.then_block)
            each(branch.elseifs, function(arm)
                expression(arm.condition)
                block(arm.body)
            end)
            block(branch.else_block)
        elseif kind == K.STMT_KIND_WHILE then
            expression(data.loop_.condition)
            block(data.loop_.body)
        elseif kind == K.STMT_KIND_REPEAT then
            push()
            statements_of(data.loop_.body)
            expression(data.loop_.condition)
            pop()
        elseif kind == K.STMT_KIND_NUMERIC_FOR then
            local loop = data.numeric_for
            expression(loop.start)
            expression(loop.limit)
            if loop.step ~= nil then
                expression(loop.step)
            end
            push()
            optional_type(loop.variable.type_annotation)
            declare(loop.variable.name, "loop")
            statements_of(loop.body)
            pop()
        elseif kind == K.STMT_KIND_GENERIC_FOR then
            local loop = data.generic_for
            expressions(loop.iterators)
            push()
            each(loop.variables, function(variable)
                optional_type(variable.type_annotation)
                declare(variable.name, "loop")
            end)
            statements_of(loop.body)
            pop()
        elseif kind == K.STMT_KIND_RETURN then
            expressions(data.return_)
        elseif kind == K.STMT_KIND_CALL then
            expression(data.call)
        elseif kind == K.STMT_KIND_TYPE_ALIAS then
            annotation(data.type_alias.value)
        end
    end

    function statements_of(list)
        each(list, statement)
    end

    function block(list)
        push()
        statements_of(list)
        pop()
    end

    local root, count = chunk:statements()
    for i = 0, count - 1 do
        statement(root[i])
    end
    info.root, info.root_count = root, count
    info.local_peaks = local_peaks
    return info
end

local ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

local KEYWORDS = {}
for word in ([[and break do else elseif end false for function goto if in local nil not or repeat return
    then true until while continue export type typeof]]):gmatch("%a+") do
    KEYWORDS[word] = true
end

function scope.fresh_names(used, count)
    local out = {}
    local function try(name)
        if not used[name] and not KEYWORDS[name] then
            out[#out + 1] = name
        end
        return #out >= count
    end
    for i = 1, #ALPHABET do
        if try(ALPHABET:sub(i, i)) then
            return out
        end
    end
    for i = 1, #ALPHABET do
        for j = 1, #ALPHABET do
            if try(ALPHABET:sub(i, i) .. ALPHABET:sub(j, j)) then
                return out
            end
        end
    end
    local n = 0
    while #out < count do
        n = n + 1
        try("_" .. n)
    end
    return out
end

--- Globals worth caching, per dialect: standard libraries that exist before
--- any code runs and that programs do not redefine. A global the runtime
--- lacks is left alone, since code outside the bundle may define it later.
local CACHEABLE = {}
do
    local common = [[assert collectgarbage error getmetatable ipairs next pairs pcall print rawequal rawget
        rawset select setmetatable tonumber tostring type xpcall coroutine io math os string table]]
    local extra = {
        lua = "rawlen utf8",
        cfxlua = "rawlen utf8",
        luajit = "unpack bit",
        luau = [[rawlen unpack utf8 bit32 buffer vector typeof task Instance Vector2 Vector3 CFrame Color3
            UDim UDim2 Enum Ray NumberRange NumberSequence ColorSequence BrickColor TweenInfo tick time warn]],
    }
    for dialect, names in pairs(extra) do
        local set = {}
        for name in (common .. " " .. names):gmatch("[%w_]+") do
            set[name] = true
        end
        CACHEABLE[dialect] = set
    end
end

--- Globals through which a chunk can reach its environment indirectly.
local ESCAPE_HATCH = {
    _G = true,
    _ENV = true,
    setfenv = true,
    getfenv = true,
    load = true,
    loadstring = true,
    loadfile = true,
    dofile = true,
    debug = true,
}

--- `debug` functions that cannot reach an environment or a local.
local DEBUG_SAFE = { traceback = true, info = true, profilebegin = true, profileend = true, resetmemorycategory = true, setmemorycategory = true }

local MAX_UPVALUES = 60
local MAX_CHUNK_LOCALS = 180

--- The functions that would capture a chunk-level local read at `func`.
local function capturing(info, func)
    local out = {}
    while func and func ~= 0 do
        out[#out + 1] = func
        func = info.functions[func].parent
    end
    return out
end

--- Current upvalue count of every function.
local function upvalue_counts(info)
    local seen, counts = {}, {}
    for index, id in pairs(info.owner) do
        local binding = info.bindings[id]
        local func = info.func[index]
        while func and func ~= 0 and func ~= binding.func do
            local key = func .. ":" .. id
            if not seen[key] then
                seen[key] = true
                counts[func] = (counts[func] or 0) + 1
            end
            func = info.functions[func].parent
        end
    end
    return counts
end

local function copy_token(token, text)
    local copy = {}
    for key, value in pairs(token) do
        copy[key] = value
    end
    copy.text = text
    return copy
end

function scope.localize(tokens, opts, ecl)
    opts = opts or {}
    ecl = assert(ecl, "Eclipsed is required")
    local info, err = scope.resolve(tokens, ecl, opts.dialect)
    if not info then
        return tokens, {}, err
    end

    local next_code = {}
    do
        local following
        for index = #tokens, 1, -1 do
            next_code[index] = following
            if not tokens[index].is_trivia then
                following = index
            end
        end
    end
    local function field_after(index)
        local dot = next_code[index]
        local name = dot and next_code[dot]
        if dot and tokens[dot].type == ecl.T.Dot and name then
            return tokens[name].text
        end
    end

    local uses, assigned, order = {}, {}, {}
    for index = 1, #tokens do
        local name = info.global[index]
        if name then
            if ESCAPE_HATCH[name] and not (name == "debug" and DEBUG_SAFE[field_after(index)]) then
                return tokens, {}, "the chunk can reach globals indirectly"
            end
            if not uses[name] then
                uses[name] = {}
                order[#order + 1] = name
            end
            local list = uses[name]
            list[#list + 1] = index
            if info.access[index] ~= "read" then
                assigned[name] = true
            end
        end
    end

    local candidates, cacheable = {}, CACHEABLE[opts.dialect] or CACHEABLE.lua
    for _, name in ipairs(order) do
        if
            cacheable[name]
            and not assigned[name]
            and not info.pinned_globals[name]
            and not (opts.keep and opts.keep[name])
        then
            candidates[#candidates + 1] = name
        end
    end
    local names = scope.fresh_names(info.used, #candidates)

    local chunk_locals = 0
    for _, binding in ipairs(info.bindings) do
        if binding.func == 0 then
            chunk_locals = chunk_locals + 1
        end
    end
    local counts = upvalue_counts(info)

    local take, cached, replacement = 1, {}, {}
    for _, name in ipairs(candidates) do
        local fresh = names[take]
        if fresh and chunk_locals < MAX_CHUNK_LOCALS then
            local sites = #uses[name]
            local cost = #fresh + #name + 7
            local saving = sites * (#name - #fresh)
            local affected, fits = {}, true
            for _, index in ipairs(uses[name]) do
                for _, func in ipairs(capturing(info, info.func[index])) do
                    if not affected[func] then
                        affected[func] = true
                        fits = fits and (counts[func] or 0) < MAX_UPVALUES
                    end
                end
            end
            if saving > cost and fits then
                take = take + 1
                chunk_locals = chunk_locals + 1
                for func in pairs(affected) do
                    counts[func] = (counts[func] or 0) + 1
                end
                cached[#cached + 1] = { name = name, fresh = fresh, uses = sites }
                for _, index in ipairs(uses[name]) do
                    replacement[index] = fresh
                end
            end
        end
    end
    if #cached == 0 then
        return tokens, {}
    end

    local prelude = {}
    local function emit(text, type_name)
        prelude[#prelude + 1] = { text = text, type = ecl.T[type_name], is_trivia = false, is_comment = false }
    end
    for _, entry in ipairs(cached) do
        emit("local", "Local")
        prelude[#prelude + 1] = { text = " ", is_trivia = true, is_comment = false }
        emit(entry.fresh, "Identifier")
        emit("=", "Assign")
        emit(entry.name, "Identifier")
        prelude[#prelude + 1] = { text = "\n", is_trivia = true, is_comment = false, kind = ecl.NEWLINE }
    end

    local out = {}
    local start = 1
    if tokens[1] and tokens[1].kind == ecl.SHEBANG then
        out[1] = tokens[1]
        start = 2
        if tokens[2] and tokens[2].kind == ecl.NEWLINE then
            out[2] = tokens[2]
            start = 3
        end
    end
    for _, token in ipairs(prelude) do
        out[#out + 1] = token
    end
    for i = start, #tokens do
        out[#out + 1] = replacement[i] and copy_token(tokens[i], replacement[i]) or tokens[i]
    end
    return out, cached
end

function scope.rename(tokens, opts, ecl)
    opts = opts or {}
    ecl = assert(ecl, "Eclipsed is required")
    local info = scope.resolve(tokens, ecl, opts.dialect)
    if not info then
        return tokens, nil
    end

    local renameable = {}
    for _, binding in ipairs(info.bindings) do
        if
            not binding.implicit
            and not binding.pinned
            and not (opts.keep and opts.keep[binding.name])
            and #binding.occurrences > 0
        then
            renameable[#renameable + 1] = binding
        end
    end
    table.sort(renameable, function(a, b)
        local wa, wb = #a.name * #a.occurrences, #b.name * #b.occurrences
        if wa ~= wb then
            return wa > wb
        end
        return a.id < b.id
    end)

    local names = scope.fresh_names(info.used, #renameable)
    local replacement = {}
    for rank, binding in ipairs(renameable) do
        local fresh = names[rank]
        if fresh and #fresh < #binding.name then
            for _, at in ipairs(binding.occurrences) do
                replacement[at] = fresh
            end
        end
    end

    local out = {}
    for i, token in ipairs(tokens) do
        out[i] = replacement[i] and copy_token(token, replacement[i]) or token
    end
    return out, info
end

return scope
