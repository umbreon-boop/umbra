local scope = require("process.scope")
local syntax = require("process.syntax")
local ffi = require("ffi")

local function ffi_string(bytes)
    return ffi.string(bytes.ptr, bytes.len)
end

local shake = {}

function shake.directives(tokens)
    local forced = {}
    for _, token in ipairs(tokens) do
        if token.is_comment then
            for entry in token.text:gmatch("@use%s+([%w_%.:]+)") do
                forced[(entry:gsub(":", "."))] = true
            end
        end
    end
    return forced
end

function shake.analyse(tokens, dialect, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    local K = ecl.const
    local forced = shake.directives(tokens)
    local info = scope.resolve(tokens, ecl, dialect)
    local tables, warnings = {}, {}
    if not info then
        return { tables = tables, warnings = warnings, forced = forced }
    end
    local source = info.source

    for id, binding in ipairs(info.bindings) do
        if binding.constructed then
            tables[id] = { name = binding.name, dynamic = false, fields = {}, constructed = true }
        end
    end

    --- The tracked table a name expression denotes, through `self` in a
    --- method declared on it.
    local function tracked(node)
        if node.kind ~= K.EXPR_KIND_NAME then
            return nil
        end
        local index = info.at[node.span.start]
        local binding = index and info.bindings[info.owner[index]]
        if not binding then
            return nil
        end
        local id = binding.implicit and binding.receiver or binding.id
        return tables[id], index, binding.implicit
    end
    local function field(t, name)
        local f = t.fields[name]
        if not f then
            f = { writes = {}, reads = 0, forced = forced[t.name .. "." .. name] or false }
            t.fields[name] = f
        end
        return f
    end
    local function span_of(node)
        return info.at[node.span.start], info.ending[node.span["end"]]
    end

    local explained, handled = {}, {}
    local function key(node)
        return node.span.start .. ":" .. node.span["end"] .. ":" .. tonumber(node.kind)
    end

    local function static_key(index_node)
        local k = index_node.data.index.key
        if k.kind == K.EXPR_KIND_STRING then
            return ffi_string(k.data.string)
        end
    end

    local function write(target, statement, removable, also_read)
        local t, index, via_self
        local name
        if target.kind == K.EXPR_KIND_FIELD then
            t, index, via_self = tracked(target.data.field.table)
            name = syntax.text(source, target.data.field.name)
        elseif target.kind == K.EXPR_KIND_INDEX then
            t, index, via_self = tracked(target.data.index.table)
            name = t and static_key(target)
            if t and not name then
                t.dynamic = true
                t.dynamic_at = t.dynamic_at or index
            end
        end
        if not t then
            return
        end
        explained[index] = true
        handled[key(target)] = true
        if not name then
            return
        end
        local f = field(t, name)
        if also_read then
            f.reads = f.reads + 1
        end
        if not via_self then
            local first, last = span_of(statement)
            f.writes[#f.writes + 1] = { at = index, first = first, last = last, removable = removable }
        end
    end

    syntax.walk(info, ecl, function(statement)
        local kind, data = statement.kind, statement.data
        if kind == K.STMT_KIND_ASSIGN then
            local targets, values = data.assign.targets, data.assign.values
            local single = syntax.count(targets) == 1 and syntax.count(values) == 1
            local removable = single and syntax.pure(syntax.item(values, 1), ecl, info)
            syntax.each(targets, function(target)
                write(target, statement, removable)
            end)
        elseif kind == K.STMT_KIND_COMPOUND_ASSIGN then
            write(data.compound.target, statement, false, true)
        elseif kind == K.STMT_KIND_FUNCTION then
            local fn = data["function"]
            local path_length = syntax.count(fn.path)
            local is_method = fn.method["end"] > fn.method.start
            local head = syntax.item(fn.path, 1)
            local index = info.at[head.start]
            local t = index and tables[info.owner[index]]
            if t and (path_length == 2 and not is_method or path_length == 1 and is_method) then
                explained[index] = true
                local name = syntax.text(source, is_method and fn.method or syntax.item(fn.path, 2))
                local first, last = span_of(statement)
                local f = field(t, name)
                f.writes[#f.writes + 1] = { at = index, first = first, last = last, removable = true }
            elseif t and path_length >= 2 then
                explained[index] = true
                local f = field(t, syntax.text(source, syntax.item(fn.path, 2)))
                f.reads = f.reads + 1
            end
        end
    end, function(expression)
        if handled[key(expression)] then
            return
        end
        local kind = expression.kind
        local t, index, name
        if kind == K.EXPR_KIND_FIELD then
            t, index = tracked(expression.data.field.table)
            name = t and syntax.text(source, expression.data.field.name)
        elseif kind == K.EXPR_KIND_METHOD_CALL then
            t, index = tracked(expression.data.method_call.receiver)
            name = t and syntax.text(source, expression.data.method_call.method)
        elseif kind == K.EXPR_KIND_INDEX then
            t, index = tracked(expression.data.index.table)
            name = t and static_key(expression)
            if t and not name then
                t.dynamic = true
                t.dynamic_at = t.dynamic_at or index
            end
        end
        if t then
            explained[index] = true
            if name then
                local f = field(t, name)
                f.reads = f.reads + 1
            end
        end
    end)

    for id, binding in ipairs(info.bindings) do
        local t = tables[binding.implicit and binding.receiver or id]
        -- A use inside an interpolated string has no token to explain it.
        if t and binding.pinned and not t.escapes then
            t.escapes = true
            t.escaped_at = binding.declared_at
        end
        if t then
            for _, index in ipairs(binding.occurrences) do
                if index ~= binding.declared_at and not explained[index] and not t.escapes then
                    t.escapes = true
                    t.escaped_at = index
                end
            end
        end
    end

    for _, t in pairs(tables) do
        if t.dynamic then
            local named = false
            for _, f in pairs(t.fields) do
                if #f.writes > 0 then
                    named = true
                    break
                end
            end
            if named then
                local token = tokens[t.dynamic_at]
                warnings[#warnings + 1] = {
                    name = t.name,
                    at = t.dynamic_at,
                    offset = token and token.start,
                    length = token and #token.text,
                    text = ("`%s` is indexed dynamically, so its fields are kept"):format(t.name),
                    note = "a runtime key could reach any field, so none can be removed",
                }
            end
        end
    end

    return { tables = tables, warnings = warnings, info = info, forced = forced }
end

function shake.unreachable(report)
    local out = {}
    for id, t in pairs(report.tables) do
        if not t.dynamic and not t.escapes and t.constructed then
            for name, f in pairs(t.fields) do
                local metamethod = name:sub(1, 2) == "__"
                if #f.writes > 0 and f.reads == 0 and not f.forced and not metamethod then
                    out[#out + 1] = { table_id = id, table_name = t.name, field = name, writes = f.writes }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.table_name ~= b.table_name then
            return a.table_name < b.table_name
        end
        return a.field < b.field
    end)
    return out
end

function shake.remove(tokens, report, ecl)
    local dead = shake.unreachable(report)
    local drop, statements, dropped = {}, {}, {}
    for _, entry in ipairs(dead) do
        for _, write in ipairs(entry.writes) do
            if write.removable and write.first and write.last then
                for i = write.first, write.last do
                    drop[i] = true
                end
                statements[write.last] = true
                local token = tokens[write.at]
                dropped[#dropped + 1] = {
                    name = ("%s.%s"):format(entry.table_name, entry.field),
                    offset = token and token.start,
                    length = token and #token.text,
                }
            end
        end
    end
    if #dropped == 0 then
        return tokens, 0, {}
    end
    return syntax.remove(tokens, drop, statements, ecl), #dropped, dropped
end

return shake
