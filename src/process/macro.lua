--- `--@inline` and `--@macro` inlining of functions at their call sites.
---
--- A macro is a `local function` or `function a.b(...)`/`function a:b(...)`
--- declaration marked with `@inline` or `@macro` in the comment before it. A
--- body that is a single `return <expression>` is an expression macro; any
--- other body is a statement macro. Call sites are found by binding, never
--- by name.
---
--- `@inline` is a suggestion: a statement macro expands to
--- `do local <params> = <arguments> <body> end`, so arguments are evaluated
--- once and in order, and an expression macro substitutes its arguments
--- where that evaluates each the same way, or else binds them to fresh locals
--- before the statement that holds the call, where nothing evaluated earlier
--- could observe the move. Every expansion is resolved
--- again, and a site where any copied name would bind to something else is
--- left alone. A site that cannot be inlined safely is reported and kept.
---
--- `@macro` is a forced overwrite: call sites are substituted whether or not
--- that preserves evaluation order, duplication, or binding. It is meant for
--- the cases where the caller accepts those hazards.

local scope = require("process.scope")
local syntax = require("process.syntax")

local macro = {}

local MAX_ROUNDS = 16

--- Lua and LuaJIT give each function at most 200 live local variables.
--- Inlining binds parameters, spills, and hoisted declarations to locals, so
--- an expansion can push a function over that hard limit.
local MAX_LOCALS = 200

--- The inlining marker a comment carries: `macro` for a forced overwrite,
--- `inline` for a suggestion, or nil. The name must end the word, so prose
--- that mentions `@macro` or `@inline` cannot mark the next declaration.
local function marker_of(text)
    for _, name in ipairs({ "macro", "inline" }) do
        local at = text:find("@" .. name, 1, true)
        if at then
            local after = text:sub(at + #name + 1, at + #name + 1)
            if after == "" or after:match("[%s%]]") then
                return name
            end
        end
    end
end

local function warning(name, reason, token, mode)
    local marker = mode == "macro" and "macro" or "inline"
    return {
        text = ("`--@%s %s` was not inlined"):format(marker, name),
        note = reason,
        offset = token and token.start,
        length = token and #token.text,
    }
end

local function limit_error(name, count, token, mode)
    local marker = mode == "macro" and "macro" or "inline"
    return {
        text = ("inlining `--@%s %s` would leave %d locals in scope"):format(marker, name, count),
        note = ("Lua allows at most %d local variables in one function; "
            .. "split the caller or the macro body into smaller functions"):format(MAX_LOCALS),
        offset = token and token.start,
        length = token and #token.text,
    }
end

local function synth(text, type_name, ecl)
    if not type_name then
        return {
            text = text,
            kind = text == "\n" and ecl.NEWLINE or ecl.WHITESPACE,
            is_trivia = true,
            is_comment = false,
        }
    end
    return { text = text, kind = ecl.SYNTAX, type = ecl.T[type_name], is_trivia = false, is_comment = false }
end

local function copy(token, origin)
    local out = {}
    for key, value in pairs(token) do
        out[key] = value
    end
    out.macro_origin = origin
    return out
end

local function range(info, node)
    return info.at[node.span.start], info.ending[node.span["end"]]
end

local function key(node)
    return node.span.start .. ":" .. node.span["end"]
end

--- Every marked declaration, as macro records, and the marks that are not.
local function find(tokens, info, ecl)
    local K = ecl.const
    local marks = {}
    for i, token in ipairs(tokens) do
        if token.is_comment then
            local mode = marker_of(token.text)
            if mode then
                for j = i + 1, #tokens do
                    if not tokens[j].is_trivia then
                        marks[j] = { at = i, mode = mode }
                        break
                    end
                end
            end
        end
    end

    local macros, rejected = {}, {}
    for _, statement in ipairs(info.statements) do
        local mark = statement.first and marks[statement.first]
        if mark then
            marks[statement.first] = nil
            local node, kind = statement.node, statement.kind
            local record = {
                comment_at = mark.at,
                mode = mark.mode,
                force = mark.mode == "macro",
                first = statement.first,
                last = statement.last,
            }
            local body
            if kind == K.STMT_KIND_LOCAL_FUNCTION then
                local declaration = node.data.local_function
                record.name = syntax.text(info.source, declaration.name)
                record.binding = info.owner[info.at[declaration.name.start]]
                body = declaration.body
            elseif kind == K.STMT_KIND_FUNCTION then
                local declaration = node.data["function"]
                local path = {}
                syntax.each(declaration.path, function(part)
                    path[#path + 1] = syntax.text(info.source, part)
                end)
                record.method = declaration.method["end"] > declaration.method.start
                if record.method then
                    path[#path + 1] = syntax.text(info.source, declaration.method)
                end
                record.path = path
                record.name = #path == 1 and path[1]
                or table.concat(path, ".", 1, #path - 1) .. (record.method and ":" or ".") .. path[#path]
                local head = info.at[syntax.item(declaration.path, 1).start]
                record.head_binding = info.owner[head]
                record.head_global = info.global[head]
                body = declaration.body
            end

            local reason
            if not body then
                reason = "not a supported function declaration"
            elseif body.vararg then
                reason = "it takes varargs"
            elseif syntax.count(body.body) == 0 then
                reason = "empty body"
            end
            if reason then
                rejected[#rejected + 1] =
                { name = record.name or "?", reason = reason, at = statement.first, mode = record.mode }
            else
                record.body = body
                record.params = {}
                syntax.each(body.parameters, function(parameter)
                    record.params[#record.params + 1] = {
                        name = syntax.text(info.source, parameter.name),
                        binding = info.owner[info.at[parameter.name.start]],
                    }
                end)
                local statements = body.body
                local first_statement = syntax.item(statements, 1)
                local last_statement = syntax.item(statements, syntax.count(statements))
                record.body_first = info.at[first_statement.span.start]
                record.body_last = info.ending[last_statement.span["end"]]
                record.ends_in_return = last_statement.kind == K.STMT_KIND_RETURN
                if record.ends_in_return then
                    record.return_first = info.at[last_statement.span.start]
                    record.return_last = info.ending[last_statement.span["end"]]
                    record.tail_results = {}
                    syntax.each(last_statement.data.return_, function(value)
                        record.tail_results[#record.tail_results + 1] = value
                    end)
                    if #record.tail_results == 1 then
                        record.tail_result = record.tail_results[1]
                    end
                end
                if
                    syntax.count(statements) == 1
                    and first_statement.kind == K.STMT_KIND_RETURN
                    and syntax.count(first_statement.data.return_) == 1
                then
                    record.kind = "expression"
                    record.result = syntax.item(first_statement.data.return_, 1)
                else
                    record.kind = "statement"
                end
                -- Substitution rewrites tokens, and an interpolation hole has none.
                local pinned = false
                for _, param in ipairs(record.params) do
                    pinned = pinned or (info.bindings[param.binding] or {}).pinned
                end
                for _, binding in ipairs(info.bindings) do
                    pinned = pinned or binding.pinned and binding.declared_at
                    and binding.declared_at >= record.body_first and binding.declared_at <= record.body_last
                end
                if pinned then
                    rejected[#rejected + 1] = {
                        name = record.name or "?",
                        reason = "a name it binds is used inside an interpolated string",
                        at = statement.first,
                        mode = record.mode,
                    }
                else
                    macros[#macros + 1] = record
                end
            end
        end
    end
    for token_index, mark in pairs(marks) do
        rejected[#rejected + 1] = {
            name = tokens[token_index].text,
            reason = "not a supported function declaration",
            at = token_index,
            mode = mark.mode,
        }
    end
    return macros, rejected
end

--- Records what the body refers to, whether it returns, and for expression
--- macros the order parameters are used in and whether any use is deferred.
local function inspect(record, info, ecl)
    local K = ecl.const
    local param_slot = {}
    for slot, parameter in ipairs(record.params) do
        if parameter.binding then
            param_slot[parameter.binding] = slot
        end
    end
    for id, binding in ipairs(info.bindings) do
        if binding.implicit and binding.func and info.functions[binding.func].node == record.body then
            record.self_binding = id
        end
    end
    record.param_slot = param_slot

    for index = record.body_first, record.body_last do
        if record.binding and info.owner[index] == record.binding then
            record.recursive = true
        end
    end

    local returns, return_count = false, 0
    local function scan(list)
        syntax.each(list, function(statement)
            local kind, data = statement.kind, statement.data
            if kind == K.STMT_KIND_RETURN then
                returns = true
                return_count = return_count + 1
            elseif kind == K.STMT_KIND_DO then
                scan(data.block)
            elseif kind == K.STMT_KIND_IF then
                scan(data.if_.then_block)
                syntax.each(data.if_.elseifs, function(arm)
                    scan(arm.body)
                end)
                scan(data.if_.else_block)
            elseif kind == K.STMT_KIND_WHILE or kind == K.STMT_KIND_REPEAT then
                scan(data.loop_.body)
            elseif kind == K.STMT_KIND_NUMERIC_FOR then
                scan(data.numeric_for.body)
            elseif kind == K.STMT_KIND_GENERIC_FOR then
                scan(data.generic_for.body)
            end
        end)
    end
    scan(record.body.body)
    record.returns = returns
    record.tail_count = #(record.tail_results or {})
    record.tail_return = return_count == 1 and record.ends_in_return and record.tail_count > 0

    if record.kind == "expression" then
        local deferred, closure, order, positions, calls = false, false, {}, {}, {}
        syntax.walk({ root = record.body.body.ptr, root_count = 1 }, ecl, nil, function(node)
            local kind = node.kind
            if kind == K.EXPR_KIND_CALL or kind == K.EXPR_KIND_METHOD_CALL then
                calls[#calls + 1] = node.span["end"]
            end
            if kind == K.EXPR_KIND_BINARY then
                local operator = node.data.binary.op
                if operator == K.BINARY_OP_AND or operator == K.BINARY_OP_OR then
                    deferred = true
                end
            elseif kind == K.EXPR_KIND_FUNCTION or kind == K.EXPR_KIND_IF_ELSE then
                deferred = true
                closure = closure or kind == K.EXPR_KIND_FUNCTION
            elseif kind == K.EXPR_KIND_NAME then
                local id = info.owner[info.at[node.span.start]]
                local slot = id and (param_slot[id] or (id == record.self_binding and 0))
                if slot then
                    order[#order + 1] = slot
                    positions[#positions + 1] = node.span.start
                end
            end
        end)
        record.deferred, record.use_order, record.use_positions, record.call_ends = deferred, order, positions, calls
        record.closure = closure
    end
end

--- The names of a plain `a.b.c` chain from its head, and the head's token.
local function chain(node, info, ecl)
    local K = ecl.const
    local names = {}
    while node.kind == K.EXPR_KIND_FIELD or node.kind == K.EXPR_KIND_PAREN do
        if node.kind == K.EXPR_KIND_FIELD then
            table.insert(names, 1, syntax.text(info.source, node.data.field.name))
            node = node.data.field.table
        else
            node = node.data.paren
        end
    end
    if node.kind ~= K.EXPR_KIND_NAME then
        return nil
    end
    table.insert(names, 1, syntax.text(info.source, node.span))
    return names, info.at[node.span.start]
end

--- Bindings that hold another bundled module's exported table:
--- `local X = __bundle_require("path", ...)` where module `path` ends in
--- `return T`. Maps each such binding id to the id of `T`.
local function module_aliases(info, ecl)
    if info.module_aliases then
        return info.module_aliases
    end
    local K = ecl.const
    local ffi = require("ffi")
    local function string_value(node)
        return node.kind == K.EXPR_KIND_STRING and ffi.string(node.data.string.ptr, node.data.string.len) or nil
    end
    local exported, aliases, export_at, requires = {}, {}, {}, {}
    for _, statement in ipairs(info.statements) do
        local node = statement.node
        if statement.kind == K.STMT_KIND_ASSIGN and syntax.count(node.data.assign.targets) == 1 then
            local target = syntax.item(node.data.assign.targets, 1)
            local value = syntax.item(node.data.assign.values, 1)
            if
                target.kind == K.EXPR_KIND_INDEX
                and target.data.index.table.kind == K.EXPR_KIND_NAME
                and syntax.text(info.source, target.data.index.table.span) == "__bundle_modules"
                and value.kind == K.EXPR_KIND_FUNCTION
            then
                local path = string_value(target.data.index.key)
                local body = value.data["function"].body
                local last = syntax.count(body) > 0 and syntax.item(body, syntax.count(body))
                if path and last and last.kind == K.STMT_KIND_RETURN and syntax.count(last.data.return_) == 1 then
                    local returned = syntax.item(last.data.return_, 1)
                    if returned.kind == K.EXPR_KIND_NAME then
                        exported[path] = info.owner[info.at[returned.span.start]]
                        export_at[path] = info.at[returned.span.start]
                    end
                end
            end
        elseif statement.kind == K.STMT_KIND_LOCAL then
            local variables, values = node.data["local"].variables, node.data["local"].values
            if syntax.count(variables) == 1 and syntax.count(values) == 1 then
                local value = syntax.item(values, 1)
                if
                    value.kind == K.EXPR_KIND_CALL
                    and value.data.call.callee.kind == K.EXPR_KIND_NAME
                    and syntax.text(info.source, value.data.call.callee.span) == "__bundle_require"
                    and syntax.count(value.data.call.arguments.values) >= 1
                then
                    local path = string_value(syntax.item(value.data.call.arguments.values, 1))
                    local variable = syntax.item(variables, 1)
                    local id = info.owner[info.at[variable.name.start]]
                    if path and id then
                        aliases[id] = path
                    end
                end
            end
        end
    end
    syntax.walk(info, ecl, nil, function(node)
        if
            node.kind == K.EXPR_KIND_CALL
            and node.data.call.callee.kind == K.EXPR_KIND_NAME
            and syntax.text(info.source, node.data.call.callee.span) == "__bundle_require"
            and syntax.count(node.data.call.arguments.values) >= 1
        then
            local path = string_value(syntax.item(node.data.call.arguments.values, 1))
            if path then
                requires[path] = (requires[path] or 0) + 1
            end
        end
    end)

    local out, exports = {}, {}
    for id, path in pairs(aliases) do
        if exported[path] then
            out[id] = exported[path]
        end
    end
    for path, head in pairs(exported) do
        local export = { at = export_at[path], aliases = {}, closed = true }
        local aliased = 0
        for id, alias_path in pairs(aliases) do
            if alias_path == path then
                export.aliases[#export.aliases + 1] = id
                aliased = aliased + 1
            end
        end
        export.closed = aliased == (requires[path] or 0)
        exports[head] = export
    end
    info.module_aliases, info.module_exports = out, exports
    return out
end

--- Whether `names` is the macro's path, or with `length`, its first
--- `length` names.
local function names_match(record, names, index, info, length)
    if #names ~= (length or #record.path) then
        return false
    end
    for n = 2, #names do
        if names[n] ~= record.path[n] then
            return false
        end
    end
    if record.head_binding then
        local owner = info.owner[index]
        return owner == record.head_binding or (owner and info.module_aliases[owner] == record.head_binding)
    end
    return info.global[index] == record.head_global
end

--- Whether a use of `names` hands out or indexes the table `record` is
--- declared in, through which it could be replaced. The module's own
--- `return T` is exempt.
local function reaches_table(record, names, index, info, indexed)
    if #names >= #record.path or not names_match(record, names, index, info, #names) then
        return false
    end
    local export = #names == 1 and not indexed and info.module_exports[record.head_binding]
    return not (export and export.at == index)
end

local function arguments_of(list)
    local args = {}
    syntax.each(list, function(value)
        args[#args + 1] = value
    end)
    return args
end

--- Finds every macro's call sites, and the first use of each that is not one.
local function sites_of(macros, info, ecl)
    local K = ecl.const
    module_aliases(info, ecl)
    local by_binding, qualified = {}, {}
    for _, record in ipairs(macros) do
        record.sites, record.invalid = {}, nil
        if record.binding then
            by_binding[record.binding] = record
        elseif record.path then
            qualified[#qualified + 1] = record
        end
    end

    local position = {}
    for _, statement in ipairs(info.statements) do
        local node = statement.node
        if statement.kind == K.STMT_KIND_CALL then
            position[key(node.data.call)] = { "statement", statement }
        elseif statement.kind == K.STMT_KIND_RETURN and syntax.count(node.data.return_) == 1 then
            position[key(syntax.item(node.data.return_, 1))] = { "return", statement }
        elseif statement.kind == K.STMT_KIND_LOCAL or statement.kind == K.STMT_KIND_ASSIGN then
            local values = statement.kind == K.STMT_KIND_LOCAL and node.data["local"].values or node.data.assign.values
            if values and syntax.count(values) == 1 then
                position[key(syntax.item(values, 1))] = { "hoist", statement }
            end
        end
    end

    local explained = {}
    local function add(record, node, head_index, args, receiver)
        local placed = position[key(node)]
        local call_first, call_last = range(info, node)
        local first, last = call_first, call_last
        if placed and record.kind == "statement" then
            first, last = placed[2].first, placed[2].last
        end
        record.sites[#record.sites + 1] = {
            record = record,
            first = first,
            last = last,
            call_first = call_first,
            call_last = call_last,
            statement = placed and placed[2],
            args = args,
            receiver = receiver,
            position = placed and placed[1] or "expression",
        }
        explained[head_index] = true
    end

    syntax.walk(info, ecl, nil, function(node)
        if node.kind == K.EXPR_KIND_CALL then
            local call = node.data.call
            -- `f(a)`, `f"s"` and `f{...}` all evaluate their one or more
            -- arguments in order, so binding them to locals handles each.
            local names, index = chain(call.callee, info, ecl)
            if names then
                local args = arguments_of(call.arguments.values)
                local record = #names == 1 and by_binding[info.owner[index]]
                if record then
                    add(record, node, index, args)
                end
                for _, candidate in ipairs(qualified) do
                    if not candidate.method and names_match(candidate, names, index, info) then
                        add(candidate, node, index, args)
                    end
                end
            end
        elseif node.kind == K.EXPR_KIND_METHOD_CALL then
            local call = node.data.method_call
            local names, index = chain(call.receiver, info, ecl)
            if names then
                names[#names + 1] = syntax.text(info.source, call.method)
                local args = arguments_of(call.arguments.values)
                for _, candidate in ipairs(qualified) do
                    if candidate.method and names_match(candidate, names, index, info) then
                        add(candidate, node, index, args, call.receiver)
                    end
                end
            end
        end
    end)

    for _, record in ipairs(macros) do
        if record.binding then
            local binding = info.bindings[record.binding]
            for _, index in ipairs(binding.occurrences) do
                if index ~= binding.declared_at and not explained[index] then
                    record.invalid = record.invalid or index
                end
            end
        end
    end
    if #qualified > 0 then
        -- Only outermost chains count: `M` inside `M.f` is part of `M.f`.
        local inner = {}
        syntax.walk(info, ecl, nil, function(node)
            if node.kind == K.EXPR_KIND_FIELD then
                inner[key(node.data.field.table)] = true
            elseif node.kind == K.EXPR_KIND_METHOD_CALL then
                inner[key(node.data.method_call.receiver)] = true
            end
        end)
        syntax.walk(info, ecl, nil, function(node)
            local indexed = node.kind == K.EXPR_KIND_INDEX
            local chained = (node.kind == K.EXPR_KIND_FIELD or node.kind == K.EXPR_KIND_NAME) and not inner[key(node)]
            if indexed or chained then
                local names, index = chain(indexed and node.data.index.table or node, info, ecl)
                if names and not explained[index] then
                    for _, record in ipairs(qualified) do
                        if names_match(record, names, index, info)
                            or reaches_table(record, names, index, info, indexed) then
                            record.invalid = record.invalid or index
                        end
                    end
                end
            end
        end)
    end
end

local function simple(node, ecl)
    local K = ecl.const
    local kind = node.kind
    return kind == K.EXPR_KIND_NAME
    or kind == K.EXPR_KIND_NIL
    or kind == K.EXPR_KIND_TRUE
    or kind == K.EXPR_KIND_FALSE
    or kind == K.EXPR_KIND_INTEGER
    or kind == K.EXPR_KIND_FLOAT
    or kind == K.EXPR_KIND_STRING
end

--- Why `site` cannot be expanded by substituting its arguments, or nil.
local function substitution_refusal(site, ecl)
    local record = site.record
    if record.kind == "statement" then
        if site.position == "expression" then
            -- A single tail result can supply this value after its earlier
            -- statements hoist above the containing statement. A multi-result
            -- return cannot substitute into an arbitrary expression.
            if record.tail_return and record.tail_count == 1 then
                return nil
            end
            return "a statement macro is used as an expression"
        end
        if site.position == "hoist" then
            -- With no return at all the call supplies nil, which an
            -- initializer can get by running the body and leaving the
            -- declared name unset.
            if not record.tail_return and record.returns then
                return "its body returns before it can supply this value"
            end
            return nil
        end
        if record.force then
            return nil
        end
        if record.returns and site.position ~= "return" then
            return "its body returns, which would return from the caller"
        end
        return nil
    end
    if site.position == "statement" then
        return "an expression macro is called as a statement"
    end
    if record.force then
        return nil
    end
    if #site.args ~= #record.params then
        return "argument count does not match"
    end
    local arguments = { [0] = site.receiver }
    for slot, argument in ipairs(site.args) do
        arguments[slot] = argument
    end
    local uses, in_order, previous = {}, true, -1
    for _, slot in ipairs(record.use_order) do
        uses[slot] = (uses[slot] or 0) + 1
        in_order = in_order and slot >= previous
        previous = slot
    end
    -- A variable may change before a use the body defers, so only literals
    -- are exempt from evaluation order.
    local complex, last_complex_use, variable, variable_before_complex = false, -1, false, false
    local variable_seen = false
    for slot = site.receiver and 0 or 1, #record.params do
        if arguments[slot].kind == ecl.const.EXPR_KIND_NAME then
            variable = true
            variable_seen = true
            for n, used in ipairs(record.use_order) do
                if used == slot then
                    last_complex_use = math.max(last_complex_use, record.use_positions[n])
                end
            end
        elseif not simple(arguments[slot], ecl) then
            complex = true
            variable_before_complex = variable_before_complex or variable_seen
            for n, used in ipairs(record.use_order) do
                if used == slot then
                    last_complex_use = math.max(last_complex_use, record.use_positions[n])
                end
            end
            if (uses[slot] or 0) ~= 1 then
                return ("parameter %s is used %d times, and its argument is not a literal or a name"):format(
                    slot == 0 and "self" or record.params[slot].name,
                    uses[slot] or 0
                )
            end
        end
    end
    if complex and (record.deferred or not in_order) then
        return "its arguments would not be evaluated in order, exactly once"
    end
    if complex and variable_before_complex then
        return "an earlier variable argument would be read after a later argument changes it"
    end
    if variable and record.closure then
        return "a closure in the body would capture the variable, not its value"
    end
    -- In a real call every argument is evaluated before the body runs.
    for _, call_end in ipairs(record.call_ends) do
        if call_end <= last_complex_use then
            return "the body would call something before an argument is evaluated"
        end
    end
end

--- Statement positions where an expression macro can bind its arguments.
local BINDABLE = { hoist = true, ["return"] = true, statement = true }

--- The globals the chunk assigns and the field names it writes, which a
--- moved evaluation could observe. `fields[true]` stands for any field.
local function written(info, ecl)
    if info.written then
        return info.written
    end
    local K = ecl.const
    local globals, fields = {}, {}
    local dynamic_globals = false
    for _, name in pairs(info.global) do
        if name == "_G" or name == "rawset" or name == "setfenv" then
            dynamic_globals = true
            break
        end
    end
    for index, name in pairs(info.global) do
        if info.access[index] ~= "read" then
            globals[name] = true
        end
    end
    local function target(node)
        if node.kind == K.EXPR_KIND_FIELD then
            fields[syntax.text(info.source, node.data.field.name)] = true
        elseif node.kind == K.EXPR_KIND_INDEX then
            local key = node.data.index.key
            if key.kind == K.EXPR_KIND_STRING then
                fields[require("ffi").string(key.data.string.ptr, key.data.string.len)] = true
            else
                fields[true] = true
            end
        end
    end
    for _, statement in ipairs(info.statements) do
        local node = statement.node
        if statement.kind == K.STMT_KIND_ASSIGN then
            syntax.each(node.data.assign.targets, target)
        elseif statement.kind == K.STMT_KIND_COMPOUND_ASSIGN then
            target(node.data.compound.target)
        elseif statement.kind == K.STMT_KIND_FUNCTION then
            local declaration = node.data["function"]
            local count = syntax.count(declaration.path)
            if declaration.method["end"] > declaration.method.start then
                fields[syntax.text(info.source, declaration.method)] = true
            elseif count > 1 then
                fields[syntax.text(info.source, syntax.item(declaration.path, count))] = true
            end
        end
    end
    info.written = { globals = globals, fields = fields, dynamic_globals = dynamic_globals }
    return info.written
end

local function immutable(binding_id, info)
    local binding = info.bindings[binding_id]
    for _, index in ipairs(binding.occurrences) do
        if index ~= binding.declared_at and info.access[index] ~= "read" then
            return false
        end
    end
    return true
end

--- The statement before which the arguments of the call at `site` can be
--- evaluated, as nothing that statement evaluates earlier could observe it.
local function lift_point(site, info, ecl)
    local K = ecl.const
    local facts = written(info, ecl)
    local FOUND, BLOCKED, CLEAN, DIRTY = 1, 2, 3, 4

    local function bounds(node)
        return info.at[node.span.start], info.ending[node.span["end"]]
    end
    local function contains(node)
        local first, last = bounds(node)
        return first ~= nil and last ~= nil and first <= site.call_first and site.call_last <= last
    end
    local function items(list)
        local out = {}
        syntax.each(list, function(item)
            out[#out + 1] = item
        end)
        return out
    end
    local function stable_name(node)
        local index = info.at[node.span.start]
        if info.global[index] then
            return not facts.dynamic_globals and not facts.globals[info.global[index]]
        end
        return info.owner[index] ~= nil and immutable(info.owner[index], info)
    end
    local function stable_field(name)
        return not facts.fields[true] and not facts.fields[name]
    end

    -- A bare local of this function, read only when the operator runs.
    local function late_local(node)
        if node.kind ~= K.EXPR_KIND_NAME then
            return false
        end
        local index = info.at[node.span.start]
        local binding = info.owner[index] and info.bindings[info.owner[index]]
        return binding ~= nil and binding.func == info.func[index]
    end
    local LATE = {
        [K.BINARY_OP_ADD] = true, [K.BINARY_OP_SUBTRACT] = true, [K.BINARY_OP_MULTIPLY] = true,
        [K.BINARY_OP_DIVIDE] = true, [K.BINARY_OP_FLOOR_DIVIDE] = true, [K.BINARY_OP_MODULO] = true,
        [K.BINARY_OP_POWER] = true, [K.BINARY_OP_EQUAL] = true, [K.BINARY_OP_NOT_EQUAL] = true,
        [K.BINARY_OP_LESS_THAN] = true, [K.BINARY_OP_GREATER_THAN] = true, [K.BINARY_OP_LESS_EQUAL] = true,
        [K.BINARY_OP_GREATER_EQUAL] = true,
    }

    -- Each visit gives a status and, once the call is found, the earlier
    -- nodes to bind to fresh locals, in evaluation order.
    local visit
    local function sequence(nodes)
        local before = {}
        for _, node in ipairs(nodes) do
            local status, inner = visit(node)
            if status == FOUND then
                for _, spill in ipairs(inner) do
                    before[#before + 1] = spill
                end
                return FOUND, before
            elseif status == BLOCKED then
                return BLOCKED
            elseif status == DIRTY then
                before[#before + 1] = node
            end
        end
        return #before > 0 and DIRTY or CLEAN
    end
    -- After its operands, an operation that may run a metamethod.
    local function then_dirty(status, spills)
        if status == CLEAN then
            return DIRTY
        end
        return status, spills
    end

    function visit(node)
        local kind = node.kind
        local first, last = bounds(node)
        if (kind == K.EXPR_KIND_CALL or kind == K.EXPR_KIND_METHOD_CALL)
            and first == site.call_first and last == site.call_last then
            return FOUND, {}
        elseif kind == K.EXPR_KIND_NIL or kind == K.EXPR_KIND_TRUE or kind == K.EXPR_KIND_FALSE
            or kind == K.EXPR_KIND_INTEGER or kind == K.EXPR_KIND_FLOAT or kind == K.EXPR_KIND_STRING
            or kind == K.EXPR_KIND_VARARG then
            return CLEAN
        elseif kind == K.EXPR_KIND_NAME then
            return stable_name(node) and CLEAN or DIRTY
        elseif kind == K.EXPR_KIND_FUNCTION then
            return contains(node) and BLOCKED or CLEAN
        elseif kind == K.EXPR_KIND_PAREN then
            return visit(node.data.paren)
        elseif kind == K.EXPR_KIND_CAST then
            return visit(node.data.cast.expression)
        elseif kind == K.EXPR_KIND_FIELD then
            local status, spills = visit(node.data.field.table)
            if status ~= CLEAN then
                return status, spills
            end
            -- A field read can invoke __index, so moving it can move code.
            return DIRTY
        elseif kind == K.EXPR_KIND_INDEX then
            return then_dirty(sequence({ node.data.index.table, node.data.index.key }))
        elseif kind == K.EXPR_KIND_UNARY then
            local status, spills = visit(node.data.unary.operand)
            if node.data.unary.op == K.UNARY_OP_NOT then
                return status, spills
            end
            return then_dirty(status, spills)
        elseif kind == K.EXPR_KIND_BINARY then
            local op, left, right = node.data.binary.op, node.data.binary.left, node.data.binary.right
            if op == K.BINARY_OP_AND or op == K.BINARY_OP_OR then
                local status, spills = visit(left)
                if status == FOUND or status == BLOCKED then
                    return status, spills
                end
                return contains(right) and BLOCKED or DIRTY
            end
            if LATE[op] and late_local(left) and contains(right) then
                return visit(right)
            end
            return then_dirty(sequence({ left, right }))
        elseif kind == K.EXPR_KIND_CALL then
            local call = node.data.call
            local nodes = { call.callee }
            for _, value in ipairs(items(call.arguments.values)) do
                nodes[#nodes + 1] = value
            end
            return then_dirty(sequence(nodes))
        elseif kind == K.EXPR_KIND_METHOD_CALL then
            local call = node.data.method_call
            local status, spills = visit(call.receiver)
            if status == FOUND or status == BLOCKED then
                return status, spills
            end
            local inner, more = sequence(items(call.arguments.values))
            if inner == FOUND then
                -- The method is looked up before the arguments are evaluated.
                if not stable_field(syntax.text(info.source, call.method)) then
                    return BLOCKED
                end
                local spilled = status == DIRTY and { call.receiver } or {}
                for _, spill in ipairs(more) do
                    spilled[#spilled + 1] = spill
                end
                return FOUND, spilled
            end
            return inner == BLOCKED and BLOCKED or DIRTY
        elseif kind == K.EXPR_KIND_TABLE then
            local nodes = {}
            for _, field in ipairs(items(node.data.table)) do
                if field.key ~= nil then
                    nodes[#nodes + 1] = field.key
                end
                nodes[#nodes + 1] = field.value
            end
            return sequence(nodes)
        end
        return contains(node) and BLOCKED or DIRTY
    end

    local statement
    for _, candidate in ipairs(info.statements) do
        if candidate.first and candidate.first <= site.call_first and site.call_last <= candidate.last
            and (not statement or (candidate.first >= statement.first and candidate.last <= statement.last)) then
            statement = candidate
        end
    end
    if not statement then
        return nil
    end
    local node, heads = statement.node, nil
    if statement.kind == K.STMT_KIND_LOCAL then
        heads = items(node.data["local"].values)
    elseif statement.kind == K.STMT_KIND_ASSIGN then
        heads = {}
        for _, target in ipairs(items(node.data.assign.targets)) do
            if target.kind == K.EXPR_KIND_FIELD then
                local table_node = target.data.field.table
                if not late_local(table_node) then
                    heads[#heads + 1] = table_node
                end
            elseif target.kind == K.EXPR_KIND_INDEX then
                local table_node = target.data.index.table
                if not late_local(table_node) then
                    heads[#heads + 1] = table_node
                end
                local key_node = target.data.index.key
                -- Simple local index operands are read at the store. A call
                -- in the RHS can update them before LuaJIT reads the register.
                if not late_local(key_node) then
                    heads[#heads + 1] = key_node
                end
            end
        end
        for _, value in ipairs(items(node.data.assign.values)) do
            heads[#heads + 1] = value
        end
    elseif statement.kind == K.STMT_KIND_RETURN then
        heads = items(node.data.return_)
    elseif statement.kind == K.STMT_KIND_CALL then
        heads = { node.data.call }
    elseif statement.kind == K.STMT_KIND_IF and not node.data.if_.binding.present then
        heads = { node.data.if_.condition }
    elseif statement.kind == K.STMT_KIND_NUMERIC_FOR then
        local loop = node.data.numeric_for
        heads = { loop.start, loop.limit }
        if loop.step ~= nil then
            heads[#heads + 1] = loop.step
        end
    elseif statement.kind == K.STMT_KIND_GENERIC_FOR then
        heads = items(node.data.generic_for.iterators)
    end
    if not heads then
        return nil
    end
    local status, spills = sequence(heads)
    if status ~= FOUND then
        return nil
    end
    for n, spill in ipairs(spills) do
        local from, to = bounds(spill)
        spills[n] = { first = from, last = to }
    end
    return statement, spills
end

--- Why `site` cannot be expanded, or nil. Where substituting the arguments
--- of an `@inline` expression macro would be wrong, they are bound to fresh
--- locals before the statement instead.
local function refusal(site, ecl, info)
    local reason = substitution_refusal(site, ecl)
    local record = site.record
    if record.kind == "statement" and (site.position == "hoist" or site.position == "expression") then
        local supplies = record.tail_return or (site.position == "hoist" and not record.returns)
        if not supplies or reason then
            return reason
        end
        site.statement, site.spills = lift_point(site, info, ecl)
        if not site.statement then
            return "an earlier expression cannot be moved ahead of the hoisted body"
        end
        site.hoisted = true
        site.first, site.last = site.statement.first, site.statement.last
        return nil
    end
    if reason and record.kind == "expression" and not record.force then
        if site.position == "expression" or site.position == "hoist" then
            site.statement, site.spills = lift_point(site, info, ecl)
        end
        if site.statement and (BINDABLE[site.position] or site.position == "expression") then
            site.bound = true
            site.first, site.last = site.statement.first, site.statement.last
            return nil
        end
    end
    return reason
end

--- The replacement tokens for one site.
local function expansion(tokens, info, site, id, ecl, taken)
    local record = site.record
    local out = {}
    local function emit(token)
        out[#out + 1] = token
    end
    local function copied(first, last)
        local list = {}
        for index = first, last do
            list[#list + 1] = copy(tokens[index], { site = id, raw = index })
        end
        return list
    end
    local function argument(node)
        return copied(range(info, node))
    end
    -- Token ranges of the statement replaced by a fresh name, by first token.
    local spilled_at = {}
    -- Emits `statement` with the call replaced by `call()`, after `prefix()`,
    -- keeping what `prefix` declares local to a block unless `@macro` forces.
    local function around(statement, prefix, call)
        local K = ecl.const
        local function prefixed()
            local before = #out
            prefix()
            if #out > before then
                local last = out[#out]
                if last.text ~= "\n" and last.text ~= ";" then
                    emit(synth(";", "Semicolon", ecl))
                end
                emit(synth("\n", nil, ecl))
            end
        end
        local function rest(from)
            local index = from
            while index <= statement.last do
                if index == site.call_first then
                    call()
                    index = site.call_last + 1
                elseif spilled_at[index] then
                    emit(synth(spilled_at[index].name, "Identifier", ecl))
                    index = spilled_at[index].last + 1
                else
                    emit(copy(tokens[index], { site = id, raw = index }))
                    index = index + 1
                end
            end
        end
        if record.force then
            prefixed()
            rest(statement.first)
            return
        end
        if statement.kind == K.STMT_KIND_LOCAL then
            local variables, plain = {}, true
            syntax.each(statement.node.data["local"].variables, function(variable)
                variables[#variables + 1] = info.at[variable.name.start]
                plain = plain and variable.attribute == K.ATTRIBUTE_NONE
            end)
            local assign
            for index = statement.first, statement.last do
                if tokens[index].type == ecl.T.Assign then
                    assign = index
                    break
                end
            end
            if not plain or not assign or assign > site.call_first then
                prefixed()
                rest(statement.first)
                return
            end
            -- `local x = v` as `local x do ... x = v end`.
            for index = statement.first, assign - 1 do
                emit(copy(tokens[index], { site = id, raw = index }))
            end
            emit(synth(" ", nil, ecl))
            emit(synth("do", "Do", ecl))
            emit(synth(" ", nil, ecl))
            prefixed()
            for n, index in ipairs(variables) do
                if n > 1 then
                    emit(synth(",", "Comma", ecl))
                    emit(synth(" ", nil, ecl))
                end
                emit(copy(tokens[index], { site = id, raw = index }))
            end
            emit(synth(" ", nil, ecl))
            rest(assign)
        else
            emit(synth("do", "Do", ecl))
            emit(synth(" ", nil, ecl))
            prefixed()
            rest(statement.first)
        end
        emit(synth("\n", nil, ecl))
        emit(synth("end", "End", ecl))
    end

    if record.kind == "expression" and site.bound then
        local params, values = {}, {}
        if record.method then
            params[#params + 1] = { binding = record.self_binding, slot = 0 }
            values[#values + 1] = site.receiver
        end
        for slot, parameter in ipairs(record.params) do
            params[#params + 1] = { binding = parameter.binding, slot = slot }
        end
        for _, value in ipairs(site.args) do
            values[#values + 1] = value
        end
        local fresh = scope.fresh_names(taken, #params + 1)
        for _, name in ipairs(fresh) do
            taken[name] = true
        end
        local renamed = {}
        for n, param in ipairs(params) do
            if param.binding then
                renamed[param.binding] = fresh[n]
            end
        end
        local spare = fresh[#params + 1]
        local spills = site.spills or {}
        local spill_names = scope.fresh_names(taken, #spills)
        for n, spill in ipairs(spills) do
            taken[spill_names[n]] = true
            spilled_at[spill.first] = { last = spill.last, name = spill_names[n] }
        end
        local K = ecl.const
        local call = record.result.kind == K.EXPR_KIND_CALL or record.result.kind == K.EXPR_KIND_METHOD_CALL
        local function result()
            if not call then
                emit(synth("(", "LeftParenthesis", ecl))
            end
            local first, last = range(info, record.result)
            for at = first, last do
                local token = copy(tokens[at], { site = id, raw = at })
                token.text = renamed[info.owner[at]] or token.text
                emit(token)
            end
            if not call then
                emit(synth(")", "RightParenthesis", ecl))
            end
        end

        local function bind()
            if #spills > 0 then
                emit(synth("local", "Local", ecl))
                for n, name in ipairs(spill_names) do
                    if n > 1 then
                        emit(synth(",", "Comma", ecl))
                    end
                    emit(synth(" ", nil, ecl))
                    emit(synth(name, "Identifier", ecl))
                end
                emit(synth(" ", nil, ecl))
                emit(synth("=", "Assign", ecl))
                for n, spill in ipairs(spills) do
                    if n > 1 then
                        emit(synth(",", "Comma", ecl))
                    end
                    emit(synth(" ", nil, ecl))
                    for _, token in ipairs(copied(spill.first, spill.last)) do
                        emit(token)
                    end
                end
                emit(synth(";", "Semicolon", ecl))
                emit(synth("\n", nil, ecl))
            end
            if #params > 0 or #values > 0 then
                emit(synth("local", "Local", ecl))
                for n = 1, math.max(#params, 1) do
                    if n > 1 then
                        emit(synth(",", "Comma", ecl))
                    end
                    emit(synth(" ", nil, ecl))
                    local token = synth(params[n] and fresh[n] or spare, "Identifier", ecl)
                    if params[n] then
                        token.macro_origin = { site = id, param = params[n].slot }
                    end
                    emit(token)
                end
                if #values > 0 then
                    emit(synth(" ", nil, ecl))
                    emit(synth("=", "Assign", ecl))
                    emit(synth(" ", nil, ecl))
                    for n, value in ipairs(values) do
                        if n > 1 then
                            emit(synth(",", "Comma", ecl))
                            emit(synth(" ", nil, ecl))
                        end
                        for _, token in ipairs(argument(value)) do
                            emit(token)
                        end
                    end
                end
            end
        end

        if site.position == "statement" then
            emit(synth("do", "Do", ecl))
            emit(synth(" ", nil, ecl))
            bind()
            emit(synth(";", "Semicolon", ecl))
            emit(synth("\n", nil, ecl))
            if not call then
                emit(synth("local", "Local", ecl))
                emit(synth(" ", nil, ecl))
                emit(synth(spare, "Identifier", ecl))
                emit(synth(" ", nil, ecl))
                emit(synth("=", "Assign", ecl))
                emit(synth(" ", nil, ecl))
            end
            result()
            emit(synth("\n", nil, ecl))
            emit(synth("end", "End", ecl))
        else
            around(site.statement, bind, result)
        end
        return out
    end

    if record.kind == "expression" then
        local by_slot = { [0] = site.receiver }
        for slot, value in ipairs(site.args) do
            by_slot[slot] = value
        end
        local starts_statement = false
        for _, statement in ipairs(info.statements) do
            if statement.first == site.first then
                starts_statement = true
                break
            end
        end
        if starts_statement then
            local previous = site.first - 1
            while previous >= 1 and tokens[previous].is_trivia do
                previous = previous - 1
            end
            -- A semicolon separates this statement from the one before it,
            -- but a leading one is invalid at the start of a block.
            for _, statement in ipairs(info.statements) do
                if statement.last == previous then
                    emit(synth(";", "Semicolon", ecl))
                    break
                end
            end
        end
        -- A call replaces a call exactly and keeps all its results.
        local K = ecl.const
        local call = record.result.kind == K.EXPR_KIND_CALL or record.result.kind == K.EXPR_KIND_METHOD_CALL
        if not call then
            emit(synth("(", "LeftParenthesis", ecl))
        end
        local first, last = range(info, record.result)
        for index = first, last do
            local owner = info.owner[index]
            local slot = owner and (record.param_slot[owner] or (owner == record.self_binding and 0))
            if slot and by_slot[slot] then
                emit(synth("(", "LeftParenthesis", ecl))
                for _, token in ipairs(argument(by_slot[slot])) do
                    emit(token)
                end
                emit(synth(")", "RightParenthesis", ecl))
            else
                emit(copy(tokens[index], { site = id, raw = index }))
            end
        end
        if not call then
            emit(synth(")", "RightParenthesis", ecl))
        end
        return out
    end

    -- A statement macro that ends in a return can supply a value: its earlier
    -- statements move above the statement holding the call and the call
    -- becomes the returned expression. A body with no return supplies nil in
    -- an initializer or assignment after its side effects run.
    if site.hoisted then
        local by_slot = { [0] = site.receiver }
        for slot, value in ipairs(site.args) do
            by_slot[slot] = value
        end
        -- `@inline` hoists each name under a fresh one, so nothing in the
        -- caller is shadowed and each argument is evaluated once.
        local renamed = {}
        if not record.force then
            local ids = {}
            if record.method and record.self_binding then
                ids[#ids + 1] = record.self_binding
            end
            for _, parameter in ipairs(record.params) do
                ids[#ids + 1] = parameter.binding
            end
            for binding_id, binding in ipairs(info.bindings) do
                local at = binding.declared_at
                if at and record.return_first and at >= record.body_first and at < record.return_first then
                    ids[#ids + 1] = binding_id
                end
            end
            local fresh = scope.fresh_names(taken, #ids)
            for n, binding_id in ipairs(ids) do
                if fresh[n] then
                    renamed[binding_id] = fresh[n]
                    taken[fresh[n]] = true
                end
            end
        end
        local function hoisted(index)
            local token = copy(tokens[index], { site = id, raw = index })
            local fresh = renamed[info.owner[index]]
            if fresh then
                token.text = fresh
            end
            return token
        end
        local bind_names, bind_values = {}, {}
        if record.method then
            bind_names[#bind_names + 1] = { text = renamed[record.self_binding] or "self", slot = 0 }
            bind_values[#bind_values + 1] = site.receiver
        end
        for slot, parameter in ipairs(record.params) do
            bind_names[#bind_names + 1] = { text = renamed[parameter.binding] or parameter.name, slot = slot }
        end
        for _, value in ipairs(site.args) do
            bind_values[#bind_values + 1] = value
        end
        if #bind_names == 0 and #bind_values > 0 then
            local discard = scope.fresh_names(taken, 1)[1]
            taken[discard] = true
            bind_names[1] = { text = discard, slot = nil }
        end
        local spills = site.spills or {}
        local spill_names = scope.fresh_names(taken, #spills)
        for n, spill in ipairs(spills) do
            taken[spill_names[n]] = true
            spilled_at[spill.first] = { last = spill.last, name = spill_names[n] }
        end
        local function prefix()
            if #spills > 0 then
                emit(synth("local", "Local", ecl))
                for n, name in ipairs(spill_names) do
                    if n > 1 then emit(synth(",", "Comma", ecl)) end
                    emit(synth(" ", nil, ecl))
                    emit(synth(name, "Identifier", ecl))
                end
                emit(synth(" ", nil, ecl))
                emit(synth("=", "Assign", ecl))
                for n, spill in ipairs(spills) do
                    if n > 1 then emit(synth(",", "Comma", ecl)) end
                    emit(synth(" ", nil, ecl))
                    for _, token in ipairs(copied(spill.first, spill.last)) do emit(token) end
                end
                emit(synth(";", "Semicolon", ecl))
                emit(synth("\n", nil, ecl))
            end
            if #bind_names > 0 then
                emit(synth("local", "Local", ecl))
                for n, name in ipairs(bind_names) do
                    if n > 1 then
                        emit(synth(",", "Comma", ecl))
                    end
                    emit(synth(" ", nil, ecl))
                    local token = synth(name.text, "Identifier", ecl)
                    token.macro_origin = { site = id, param = name.slot }
                    emit(token)
                end
                if #bind_values > 0 then
                    emit(synth(" ", nil, ecl))
                    emit(synth("=", "Assign", ecl))
                    emit(synth(" ", nil, ecl))
                    for n, value in ipairs(bind_values) do
                        if n > 1 then
                            emit(synth(",", "Comma", ecl))
                            emit(synth(" ", nil, ecl))
                        end
                        for _, token in ipairs(argument(value)) do
                            emit(token)
                        end
                    end
                end
                emit(synth(";", "Semicolon", ecl))
                emit(synth("\n", nil, ecl))
            end
            local body_end = record.return_first and record.return_first - 1 or record.body_last
            for index = record.body_first, body_end do
                emit(hoisted(index))
            end
        end
        local function tail()
            local results = record.tail_results or {}
            if #results == 0 then
                -- A function that never returns supplies nil to the
                -- initializer or assignment after its side effects.
                emit(synth("nil", "Nil", ecl))
                return
            end
            for n, result in ipairs(results) do
                if n > 1 then
                    emit(synth(",", "Comma", ecl))
                    emit(synth(" ", nil, ecl))
                end
                local first, last = range(info, result)
                for at = first, last do
                    local owner = info.owner[at]
                    local slot = owner and (record.param_slot[owner] or (owner == record.self_binding and 0))
                    if record.force and slot and by_slot[slot] then
                        emit(synth("(", "LeftParenthesis", ecl))
                        for _, token in ipairs(argument(by_slot[slot])) do
                            emit(token)
                        end
                        emit(synth(")", "RightParenthesis", ecl))
                    else
                        emit(hoisted(at))
                    end
                end
            end
        end
        around(site.statement, prefix, tail)
        return out
    end

    local names, values = {}, {}
    if record.method then
        names[#names + 1] = { text = "self", slot = 0 }
        values[#values + 1] = site.receiver
    end
    for slot, parameter in ipairs(record.params) do
        names[#names + 1] = { text = parameter.name, slot = slot }
    end
    for _, value in ipairs(site.args) do
        values[#values + 1] = value
    end
    if #names == 0 and #values > 0 then
        -- The macro takes no arguments, but Lua still evaluates them. Give
        -- the first value a local so the rest are evaluated and discarded.
        local discard = scope.fresh_names(taken, 1)[1]
        taken[discard] = true
        names[1] = { text = discard, slot = nil }
    end

    emit(synth("do", "Do", ecl))
    if #names > 0 then
        emit(synth(" ", nil, ecl))
        emit(synth("local", "Local", ecl))
        for n, name in ipairs(names) do
            if n > 1 then
                emit(synth(",", "Comma", ecl))
            end
            emit(synth(" ", nil, ecl))
            local token = synth(name.text, "Identifier", ecl)
            token.macro_origin = { site = id, param = name.slot }
            emit(token)
        end
        if #values > 0 then
            emit(synth(" ", nil, ecl))
            emit(synth("=", "Assign", ecl))
            emit(synth(" ", nil, ecl))
            for n, value in ipairs(values) do
                if n > 1 then
                    emit(synth(",", "Comma", ecl))
                    emit(synth(" ", nil, ecl))
                end
                for _, token in ipairs(argument(value)) do
                    emit(token)
                end
            end
        end
    end
    emit(synth("\n", nil, ecl))
    for _, token in ipairs(copied(record.body_first, record.body_last)) do
        emit(token)
    end
    if site.position == "return" and not record.ends_in_return then
        emit(synth("\n", nil, ecl))
        emit(synth("return", "Return", ecl))
    end
    emit(synth("\n", nil, ecl))
    emit(synth("end", "End", ecl))
    return out
end

--- The ids of expanded sites where a copied name binds differently in `out`,
--- and the scope info of `out`.
local function unhygienic(tokens, info, out, expanded, dialect, ecl)
    local bad = {}
    local after = scope.resolve(out, ecl, dialect)
    if not after then
        for id in pairs(expanded) do
            bad[id] = true
        end
        return bad
    end
    local copied_in = {}
    for _, token in ipairs(out) do
        local origin = token.macro_origin
        if origin and origin.raw then
            copied_in[origin.site .. ":" .. origin.raw] = true
        end
    end
    for index, token in ipairs(out) do
        local origin = token.macro_origin
        local site = origin and expanded[origin.site]
        if site and origin.raw and token.type == ecl.T.Identifier then
            local old_id, old_global = info.owner[origin.raw], info.global[origin.raw]
            local new_id = after.owner[index]
            local new = new_id and after.bindings[new_id]
            local declared = new and new.declared_at and out[new.declared_at]
            local from = declared and declared.macro_origin
            local record = site.record
            local fine = true
            if old_global then
                fine = after.global[index] == old_global
            elseif old_id then
                local old = info.bindings[old_id]
                local slot = record.param_slot[old_id] or (old_id == record.self_binding and 0)
                if slot and (record.kind == "statement" or site.bound) then
                    fine = from ~= nil and from.site == origin.site and from.param == slot
                elseif old.implicit then
                    fine = new ~= nil and new.implicit == true
                elseif old.declared_at and copied_in[origin.site .. ":" .. old.declared_at] then
                    fine = from ~= nil and from.site == origin.site and from.raw == old.declared_at
                else
                    fine = declared ~= nil and declared == tokens[old.declared_at]
                end
            end
            if not fine then
                bad[origin.site] = true
            end
        end
    end
    return bad, after
end

local function splice(tokens, replacements, drop)
    local out, index = {}, 1
    while index <= #tokens do
        local replacement = replacements[index]
        if replacement then
            for _, token in ipairs(replacement.tokens) do
                out[#out + 1] = token
            end
            index = replacement.last + 1
        else
            if not drop[index] then
                out[#out + 1] = tokens[index]
            end
            index = index + 1
        end
    end
    return out
end

--- Errors for functions that still have more than `MAX_LOCALS` locals in
--- scope once every expansion has run and unused macro declarations have been
--- dropped. Each expanded token remembers the site that produced it, so the
--- error points at a call in the function that is too large.
local function limit_errors(tokens, after)
    local errors, seen = {}, {}
    local functions = {}
    for func, peak in pairs(after.local_peaks or {}) do
        if peak > MAX_LOCALS then
            functions[#functions + 1] = { func = func, count = peak }
        end
    end
    table.sort(functions, function(a, b)
        return a.func < b.func
    end)
    local function fallback()
        local site
        for _, token in ipairs(tokens) do
            local candidate = token.macro_site
            if candidate and (not site or candidate.first < site.first) then
                site = candidate
            end
        end
        return site
    end
    local default = fallback()
    for _, entry in ipairs(functions) do
        local site
        for index, token in ipairs(tokens) do
            if after.func[index] == entry.func then
                local candidate = token.macro_site
                if candidate and (not site or candidate.first < site.first) then
                    site = candidate
                end
            end
        end
        site = site or default
        if site and not seen[site] then
            seen[site] = true
            local token = site.limit_token or tokens[site.call_first or site.first]
            errors[#errors + 1] = limit_error(site.record.name, entry.count, token, site.record.mode)
        end
    end
    return errors
end

local function prepare(tokens, info, ecl, warnings)
    local macros, rejected = find(tokens, info, ecl)
    for _, entry in ipairs(rejected) do
        if warnings then
            warnings[#warnings + 1] = warning(entry.name, entry.reason, tokens[entry.at], entry.mode)
        end
    end
    local usable = {}
    for _, record in ipairs(macros) do
        inspect(record, info, ecl)
        local token = tokens[record.first]
        if record.recursive then
            if warnings then
                warnings[#warnings + 1] = warning(
                    record.name,
                    "it refers to itself, so expanding would never finish",
                    token,
                    record.mode
                )
            end
        else
            usable[#usable + 1] = record
        end
    end
    sites_of(usable, info, ecl)
    return usable
end

--- `info` is the scope info of `tokens` when the caller already has it. The
--- report's `info` is the scope info of the returned tokens, if known.
function macro.expand_once(tokens, dialect, ecl, info)
    ecl = assert(ecl, "Eclipsed is required")
    local warnings = {}
    info = info or scope.resolve(tokens, ecl, dialect)
    if not info then
        return tokens, { warnings = warnings, expanded = 0 }
    end
    local usable = prepare(tokens, info, ecl, warnings)

    local candidates = {}
    for _, record in ipairs(usable) do
        if record.invalid and not record.force then
            warnings[#warnings + 1] = warning(
                record.name, "it is used other than as a parenthesised call", tokens[record.invalid], record.mode
            )
        else
            for _, site in ipairs(record.sites) do
                local reason = refusal(site, ecl, info)
                if reason then
                    warnings[#warnings + 1] =
                    warning(record.name, reason .. " at this call", tokens[site.first], record.mode)
                elseif site.first and site.last then
                    site.limit_token = site.limit_token or tokens[site.call_first or site.first]
                    candidates[#candidates + 1] = site
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.first ~= b.first then
            return a.first < b.first
        end
        return a.last > b.last
    end)

    local excluded = {}
    while true do
        local replacements, expanded, taken_until, count = {}, {}, 0, 0
        local taken = setmetatable({}, { __index = info.used })
        for id, site in ipairs(candidates) do
            if not excluded[id] and site.first > taken_until then
                local generated = expansion(tokens, info, site, id, ecl, taken)
                for _, token in ipairs(generated) do
                    token.macro_site = site
                end
                replacements[site.first] = { last = site.last, tokens = generated }
                expanded[id] = site
                taken_until = site.last
                count = count + 1
            end
        end
        if count == 0 then
            return tokens, { warnings = warnings, expanded = 0, info = info }
        end
        local out = splice(tokens, replacements, {})
        local bad, after = unhygienic(tokens, info, out, expanded, dialect, ecl)
        local excluded_any = false
        for id in pairs(bad) do
            local site = candidates[id]
            if not site.record.force then
                excluded[id] = true
                excluded_any = true
                warnings[#warnings + 1] = warning(
                    site.record.name,
                    "a name in it would refer to something else at this call",
                    tokens[site.first],
                    site.record.mode
                )
            end
        end
        if not excluded_any then
            return out, { warnings = warnings, expanded = count, info = after }
        end
    end
end

--- Whether a qualified macro's table is only ever used through fields, so
--- no alias can still reach the declaration.
local function only_fields(record, info, ecl)
    if not record.head_binding then
        return record.binding ~= nil
    end
    local K = ecl.const
    module_aliases(info, ecl)
    local heads = {}
    syntax.walk(info, ecl, function(statement)
        if statement.kind == K.STMT_KIND_FUNCTION then
            heads[info.at[syntax.item(statement.data["function"].path, 1).start]] = true
        end
    end, function(node)
        if node.kind == K.EXPR_KIND_FIELD or node.kind == K.EXPR_KIND_METHOD_CALL then
            local base = node.kind == K.EXPR_KIND_FIELD and node.data.field.table or node.data.method_call.receiver
            if base.kind == K.EXPR_KIND_NAME then
                heads[info.at[base.span.start]] = true
            end
        end
    end)
    local function field_uses_only(id, allowed)
        local binding = info.bindings[id]
        for _, index in ipairs(binding.occurrences) do
            if index ~= binding.declared_at and not heads[index] and index ~= allowed then
                return false
            end
        end
        return true
    end
    -- A module's exported table may be dropped from only if every importer
    -- binds it to a local and uses nothing but its fields.
    local export = info.module_exports[record.head_binding]
    if export and export.closed then
        for _, alias in ipairs(export.aliases) do
            if not field_uses_only(alias) then
                return false
            end
        end
        return field_uses_only(record.head_binding, export.at)
    end
    return field_uses_only(record.head_binding)
end

--- Drops declarations of macros that no longer have any use. `info` is the
--- scope info of `tokens` when the caller already has it.
local function drop_unused(tokens, dialect, ecl, info)
    for _ = 1, MAX_ROUNDS do
        info = info or scope.resolve(tokens, ecl, dialect)
        if not info then
            return tokens
        end
        local drop, statements = {}, {}
        for _, record in ipairs(prepare(tokens, info, ecl)) do
            if #record.sites == 0 and not record.invalid and only_fields(record, info, ecl) then
                for index = record.comment_at, record.last do
                    drop[index] = true
                end
                statements[record.last] = true
                local following = tokens[record.last + 1]
                if following and following.kind == ecl.NEWLINE then
                    drop[record.last + 1] = true
                end
            end
        end
        if next(drop) == nil then
            return tokens
        end
        tokens = syntax.remove(tokens, drop, statements, ecl)
        info = nil
    end
    return tokens
end

function macro.expand(tokens, dialect, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    local warnings, errors, expanded, info = {}, {}, 0, nil
    -- `macro_site` survives between expansion rounds so the final local limit
    -- check can point at a call; it must not survive a new invocation.
    for _, token in ipairs(tokens) do
        token.macro_site = nil
    end
    for _ = 1, MAX_ROUNDS do
        for _, token in ipairs(tokens) do
            token.macro_origin = nil
        end
        local out, report = macro.expand_once(tokens, dialect, ecl, info)
        warnings = report.warnings
        for _, entry in ipairs(report.errors or {}) do
            errors[#errors + 1] = entry
        end
        tokens, expanded, info = out, expanded + report.expanded, report.info
        if report.expanded == 0 then
            break
        end
    end
    if expanded > 0 and #errors == 0 then
        tokens = drop_unused(tokens, dialect, ecl, info)
        local after = scope.resolve(tokens, ecl, dialect)
        if after then
            errors = limit_errors(tokens, after)
        end
    end

    local seen, unique, seen_errors, unique_errors = {}, {}, {}, {}
    for _, entry in ipairs(warnings) do
        local id = entry.text .. "|" .. tostring(entry.note) .. "|" .. tostring(entry.offset)
        if not seen[id] then
            seen[id] = true
            unique[#unique + 1] = entry
        end
    end
    for _, entry in ipairs(errors) do
        local id = entry.text .. "|" .. tostring(entry.note) .. "|" .. tostring(entry.offset)
        if not seen_errors[id] then
            seen_errors[id] = true
            unique_errors[#unique_errors + 1] = entry
        end
    end
    return tokens, { warnings = unique, errors = unique_errors, expanded = expanded }
end

return macro
