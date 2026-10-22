local printer = {}

local layout_flags = { other = false }

local new_table = require("table.new")
local syntax = require("process.syntax")
local scope = require("process.scope")

local function synthetic_token(ecl, type, text)
    return {
        kind = ecl.SYNTAX,
        type = type,
        text = text,
        is_trivia = false,
        is_comment = false,
    }
end

--- StyLua writes every call with parentheses. Sugar calls (`f "x"` and
--- `f {}`) are re-tokenised here so the rest of the layout can treat them
--- as ordinary argument lists.
local function normalize_sugar_calls(tokens, dialect, ecl, original_source, parsed)
    local info = scope.index(tokens, ecl, dialect, original_source, parsed)
    if not info then
        return tokens, nil, false
    end
    local K = ecl.const
    local before, after, drop = {}, {}, {}
    local changed = false
    syntax.walk(info, ecl, nil, function(node)
        local arguments, callee_end
        if node.kind == K.EXPR_KIND_CALL then
            arguments = node.data.call.arguments
            callee_end = info.ending[node.data.call.callee.span["end"]]
        elseif node.kind == K.EXPR_KIND_METHOD_CALL then
            arguments = node.data.method_call.arguments
            callee_end = info.ending[node.data.method_call.method["end"]]
        else
            return
        end
        if arguments.kind ~= K.ARGUMENTS_KIND_STRING and arguments.kind ~= K.ARGUMENTS_KIND_TABLE then
            return
        end
        if tonumber(arguments.values.len) ~= 1 or not callee_end then
            return
        end
        local value = arguments.values.ptr[0]
        local first = info.at[value.span.start]
        local last = info.ending[value.span["end"]]
        if not first or not last or first <= callee_end then
            return
        end
        for index = callee_end + 1, first - 1 do
            local token = tokens[index]
            if token.is_comment or not token.is_trivia then
                return
            end
            drop[index] = true
        end
        changed = true
        before[first] = synthetic_token(ecl, ecl.T.LeftParenthesis, "(")
        after[last] = synthetic_token(ecl, ecl.T.RightParenthesis, ")")
    end)

    if not changed then
        return tokens, info, false
    end

    local out = new_table(#tokens + 2, 0)
    for index, token in ipairs(tokens) do
        if before[index] then
            out[#out + 1] = before[index]
        end
        if not drop[index] then
            out[#out + 1] = token
        end
        if after[index] then
            out[#out + 1] = after[index]
        end
    end
    return out, nil, true
end

local function is_type(token, name, ecl)
    return token.kind == ecl.SYNTAX and token.type == ecl.T[name]
end

local BINARY_OPS = nil
local function is_binary_op(tok_type, T)
    if not BINARY_OPS then
        BINARY_OPS = {
            [T.Plus] = true,
            [T.Minus] = true,
            [T.Star] = true,
            [T.Slash] = true,
            [T.DoubleSlash] = true,
            [T.Percent] = true,
            [T.Caret] = true,
            [T.DoubleDot] = true,
            [T.Equal] = true,
            [T.NotEqual] = true,
            [T.LessThan] = true,
            [T.GreaterThan] = true,
            [T.LessThanOrEqual] = true,
            [T.GreaterThanOrEqual] = true,
            [T.Assign] = true,
            [T.PlusAssign] = true,
            [T.MinusAssign] = true,
            [T.StarAssign] = true,
            [T.SlashAssign] = true,
            [T.DoubleSlashAssign] = true,
            [T.PercentAssign] = true,
            [T.CaretAssign] = true,
            [T.DoubleDotAssign] = true,
            [T.Ampersand] = true,
            [T.Pipe] = true,
            [T.Tilde] = true,
            [T.ShiftLeft] = true,
            [T.ShiftRight] = true,
            [T.ShiftLeftAssign] = true,
            [T.ShiftRightAssign] = true,
            [T.AmpersandAssign] = true,
            [T.PipeAssign] = true,
            [T.And] = true,
            [T.Or] = true,
            [T.Arrow] = true,
        }
    end
    return BINARY_OPS[tok_type] == true
end

local function can_end_expression(tok, ecl)
    if not tok then
        return false
    end
    local cached = tok.can_end_expression
    if cached ~= nil then
        return cached
    end
    local value
    if tok.text ~= "export" and tok.text ~= "type" then
        local T = ecl.T
        local t = tok.type
        value = t == T.Identifier
            or t == T.Integer
            or t == T.Float
            or t == T.String
            or t == T.LongString
            or t == T.InterpolatedString
            or t == T.HashString
            or t == T.True
            or t == T.False
            or t == T.Nil
            or t == T.TripleDot
            or t == T.RightParenthesis
            or t == T.RightSquareBracket
            or t == T.RightCurlyBrace
            or t == T.End
    else
        value = false
    end
    tok.can_end_expression = value
    return value
end

local function might_have_sugar_calls(tokens, ecl)
    local T = ecl.T
    local previous
    for _, token in ipairs(tokens) do
        if not token.is_trivia then
            local type_ = token.type
            if previous
                and (type_ == T.String
                    or type_ == T.LongString
                    or type_ == T.InterpolatedString
                    or type_ == T.LeftCurlyBrace)
                and can_end_expression(previous, ecl)
            then
                return true
            end
            previous = token
        end
    end
    return false
end

local function is_unary(tok, previous, ecl)
    if not tok then
        return false
    end
    local T = ecl.T
    return (tok.type == T.Plus or tok.type == T.Minus or tok.type == T.Tilde) and not can_end_expression(previous, ecl)
end


local binary_precedence
local flat_width
local binary_range_operators

local function source_has_newline(info, from_, to_)
    local found = info.source:find("\n", from_, true)
    return found ~= nil and found <= to_
end

local function find_if_expressions(tokens, ecl)
    local T = ecl.T
    local if_exprs = {}
    local stack = {}
    local curly_depth = 0
    local func_curly = {}

    for i, token in ipairs(tokens) do
        if not token.is_trivia then
            if token.type == T.Function then
                table.insert(stack, { token = token, is_stmt = true })
                table.insert(func_curly, curly_depth)
                curly_depth = 0
            elseif token.type == T.While or token.type == T.For then
                table.insert(stack, { token = token, is_stmt = true, awaits_do = true })
            elseif token.type == T.Do then
                -- A loop's `do` belongs to its `while` or `for`; one `end` closes both.
                local loop
                for j = #stack, 1, -1 do
                    if stack[j].awaits_do then
                        loop = stack[j]
                        break
                    elseif stack[j].is_stmt then
                        break
                    end
                end
                if loop then
                    loop.awaits_do = false
                else
                    table.insert(stack, { token = token, is_stmt = true })
                end
            elseif token.type == T.Repeat then
                table.insert(stack, { token = token, is_stmt = true })
            elseif token.type == T.LeftCurlyBrace then
                curly_depth = curly_depth + 1
            elseif token.type == T.RightCurlyBrace then
                curly_depth = math.max(0, curly_depth - 1)
            elseif token.type == T.If then
                local prev = nil
                for j = i - 1, 1, -1 do
                    if not tokens[j].is_trivia then
                        prev = tokens[j]
                        break
                    end
                end

                local is_expr = false
                if prev then
                    local pt = prev.type
                    if pt == T.Assign or pt == T.Return or pt == T.Comma
                        or pt == T.LeftParenthesis or pt == T.LeftCurlyBrace or pt == T.LeftSquareBracket
                        or is_binary_op(pt, T) or pt == T.Not or pt == T.DoubleDot or pt == T.Hash
                        or pt == T.In or pt == T.While or pt == T.Until or pt == T.If or pt == T.Elseif
                    then
                        is_expr = true
                    elseif pt == T.Semicolon and curly_depth > 0 then
                        is_expr = true
                    elseif pt == T.Then or pt == T.Else then
                        for j = #stack, 1, -1 do
                            if stack[j].token.type == T.If then
                                is_expr = stack[j].is_expr
                                break
                            end
                        end
                    end
                end

                if is_expr then
                    if_exprs[token] = true
                end
                table.insert(stack, { token = token, is_expr = is_expr, has_then = false, has_else = false, is_stmt = not is_expr })

            elseif token.type == T.Then then
                for j = #stack, 1, -1 do
                    if stack[j].token.type == T.If and not stack[j].has_then then
                        stack[j].has_then = true
                        if stack[j].is_expr then if_exprs[token] = true end
                        break
                    end
                end
            elseif token.type == T.Else then
                for j = #stack, 1, -1 do
                    if stack[j].token.type == T.If and not stack[j].has_else then
                        stack[j].has_else = true
                        if stack[j].is_expr then if_exprs[token] = true end
                        break
                    end
                end
            elseif token.type == T.Elseif then
                for j = #stack, 1, -1 do
                    if stack[j].token.type == T.If and not stack[j].has_else then
                        stack[j].has_then = false
                        if stack[j].is_expr then if_exprs[token] = true end
                        break
                    end
                end

            elseif token.type == T.End or token.type == T.Until then
                for j = #stack, 1, -1 do
                    if stack[j].is_stmt then
                        if stack[j].token.type == T.Function and #func_curly > 0 then
                            curly_depth = table.remove(func_curly)
                        end
                        for k = #stack, j, -1 do
                            table.remove(stack, k)
                        end
                        break
                    end
                end
            end
        end
    end
    return if_exprs
end

--- Marks the tokens that belong to Luau type syntax, so layout rules do not
--- treat names inside a type as statements or split generic brackets.
local function annotate_types(tokens, dialect, ecl, info)
    local spans
    if info then
        spans = info.chunk:type_spans()
    else
        local parts = {}
        for i, token in ipairs(tokens) do
            parts[i] = token.text
        end
        local source = table.concat(parts)
        spans = ecl.type_spans(source, dialect)
    end
    if not spans or #spans == 0 then
        if info then
            info.alias_count = 0
        end
        return
    end

    local by_start = {}
    for i, token in ipairs(tokens) do
        by_start[token.start] = i
    end
    local function covered(start_offset, end_offset)
        local i = by_start[start_offset]
        if not i then
            for index, token in ipairs(tokens) do
                if token.start >= start_offset then
                    i = index
                    break
                end
            end
        end
        local first, last
        while i and i <= #tokens and tokens[i].end_ <= end_offset do
            if not tokens[i].is_trivia then
                first = first or i
                last = i
            end
            i = i + 1
        end
        return first, last
    end

    local aliases = 0
    for _, span in ipairs(spans) do
        local first, last = covered(span.start, span.end_)
        if first then
            if span.kind == ecl.TYPE_ALIAS_STMT then
                aliases = aliases + 1
                for i = first, last do
                    tokens[i].in_type = true
                    tokens[i].alias_id = aliases
                end
                tokens[first].alias_start = aliases
            elseif span.kind == ecl.TYPE_ANNOTATION then
                for i = first, last do
                    tokens[i].in_type = true
                end
            elseif span.kind == ecl.TYPE_PARAM then
                for i = first, last do
                    tokens[i].in_type = true
                    tokens[i].type_param = true
                end
                -- The parameter span covers only its name. Mark the pair of
                -- angle brackets around the run so they stay tight.
                local open = first - 1
                while open >= 1 and tokens[open].is_trivia do
                    open = open - 1
                end
                if open >= 1 and tokens[open].text == "<" then
                    tokens[open].angle_open = true
                    local depth = 1
                    for i = open + 1, #tokens do
                        if tokens[i].text == "<" then
                            depth = depth + 1
                        elseif tokens[i].text == ">" then
                            depth = depth - 1
                            if depth == 0 then
                                tokens[i].angle_close = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    for _, token in ipairs(tokens) do
        if token.in_type then
            if token.text == "<" then
                token.angle_open = true
            elseif token.text == ">" then
                token.angle_close = true
            end
        end
    end
    if info then
        info.alias_count = aliases
    end
end

local function opens_block(token, ecl, if_exprs)
    if if_exprs and if_exprs[token] then
        return false
    end
    if token.kind ~= ecl.SYNTAX then
        return false
    end
    local type_, T = token.type, ecl.T
    return type_ == T.Then
        or type_ == T.Do
        or type_ == T.Repeat
        or type_ == T.Else
        or type_ == T.Function
end

local function closes_block(token, ecl, if_exprs)
    if if_exprs and if_exprs[token] then
        return false
    end
    if token.kind ~= ecl.SYNTAX then
        return false
    end
    local type_, T = token.type, ecl.T
    return type_ == T.End
        or type_ == T.Until
        or type_ == T.Else
        or type_ == T.Elseif
end

local function delimiter_kind(token, ecl)
    if token.kind ~= ecl.SYNTAX then
        return nil
    end
    local type_, T = token.type, ecl.T
    if type_ == T.LeftCurlyBrace then
        return "curly", true
    elseif type_ == T.LeftParenthesis then
        return "parenthesis", true
    elseif type_ == T.LeftSquareBracket then
        return "square", true
    elseif type_ == T.RightCurlyBrace then
        return "curly", false
    elseif type_ == T.RightParenthesis then
        return "parenthesis", false
    elseif type_ == T.RightSquareBracket then
        return "square", false
    end
end

local function has_inline_container(body, position, ecl)
    local cached = body.__inline_container
    if not cached then
        cached = {}
        local T = ecl.T
        local stack = {}
        local blocks = 0
        for index = 1, #body do
            local token = body[index]
            if token.kind == ecl.SYNTAX then
                local type_ = token.type
                if type_ == T.LeftParenthesis then
                    stack[#stack + 1] = { position = index, blocks = blocks }
                elseif type_ == T.RightParenthesis then
                    local open = table.remove(stack)
                    if open then
                        cached[open.position] = blocks > open.blocks
                    end
                elseif type_ == T.Function or type_ == T.LeftCurlyBrace then
                    blocks = blocks + 1
                end
            end
        end
        for _, open in ipairs(stack) do
            cached[open.position] = blocks > open.blocks
        end
        body.__inline_container = cached
    end
    return cached[position] or false
end

local function pop_delimiter(stack, kind)
    for index = #stack, 1, -1 do
        if stack[index].kind == kind then
            return table.remove(stack, index)
        end
    end
end

local function starts_header(token, ecl, if_exprs)
    if if_exprs and if_exprs[token] then
        return false
    end
    if token.kind ~= ecl.SYNTAX then
        return false
    end
    local type_, T = token.type, ecl.T
    return type_ == T.If
        or type_ == T.Elseif
        or type_ == T.For
        or type_ == T.While
end

local function contains_header_end(body, ecl)
    local T = ecl.T
    for _, token in ipairs(body) do
        if token.kind == ecl.SYNTAX and (token.type == T.Then or token.type == T.Do) then
            return true
        end
    end
    return false
end

function printer.minify(tokens, dialect, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    local out, previous = {}, nil
    for _, token in ipairs(tokens) do
        if not token.is_trivia then
            if previous and ecl.needs_space(previous, token.text, dialect) then
                out[#out + 1] = " "
            end
            out[#out + 1] = token.text
            previous = token.text
        end
    end
    return table.concat(out)
end

local function covered(tokens, by_start, span)
    local first = by_start[span.start]
    if not first then
        return nil
    end
    local last = first - 1
    local i = first
    while i <= #tokens and tokens[i].end_ <= span.end_ do
        last = i
        i = i + 1
    end
    if last < first then
        return nil
    end
    return first, last
end

local function back_over_space(tokens, from, ecl)
    while from >= 1 and tokens[from].kind == ecl.WHITESPACE do
        from = from - 1
    end
    return from
end

local function forward_over_space(tokens, from, ecl)
    while from <= #tokens and tokens[from].kind == ecl.WHITESPACE do
        from = from + 1
    end
    return from
end

local function open_angle(tokens, from)
    local depth = 0
    for i = from, 1, -1 do
        local text = tokens[i].text
        if text == ">" then
            depth = depth + 1
        elseif text == ">>" then
            depth = depth + 2
        elseif text == "<" then
            if depth == 0 then
                return i
            end
            depth = depth - 1
        elseif text == "<<" then
            if depth <= 1 then
                return nil
            end
            depth = depth - 2
        end
    end
    return nil
end

local function close_angle(tokens, from)
    local depth = 0
    for i = from, #tokens do
        local text = tokens[i].text
        if text == "<" then
            depth = depth + 1
        elseif text == "<<" then
            depth = depth + 2
        elseif text == ">" then
            if depth == 0 then
                return i
            end
            depth = depth - 1
        elseif text == ">>" then
            if depth == 0 then
                return nil
            end
            depth = depth - 2
            if depth < 0 then
                return i
            end
        end
    end
    return nil
end

local function range(from, to)
    local out = {}
    for i = from, to do
        out[#out + 1] = i
    end
    return out
end

local function annotation_indices(tokens, first, last, ecl)
    local indices = range(first, last)
    local lead = back_over_space(tokens, first - 1, ecl)
    if lead < 1 then
        return indices
    end

    local probe = lead
    while probe >= 1 and (tokens[probe].text == "|" or tokens[probe].text == "&") do
        probe = back_over_space(tokens, probe - 1, ecl)
    end
    if probe >= 1 and (tokens[probe].text == ":" or tokens[probe].text == "::") then
        lead = probe
    end

    local text = tokens[lead].text
    if text == ":" or text == "::" then
        for _, i in ipairs(range(lead, first - 1)) do
            indices[#indices + 1] = i
        end
    elseif text == "<<" then
        local tail = forward_over_space(tokens, last + 1, ecl)
        if tail > #tokens or tokens[tail].text ~= ">>" then
            return nil
        end
        for _, i in ipairs(range(lead, tail)) do
            indices[#indices + 1] = i
        end
    end
    return indices
end

local function alias_indices(tokens, first, last, ecl)
    local indices = range(first, last)
    local head = back_over_space(tokens, first - 1, ecl)
    local tail = forward_over_space(tokens, last + 1, ecl)
    if (head < 1 or tokens[head].kind == ecl.NEWLINE) and tail <= #tokens and tokens[tail].kind == ecl.NEWLINE then
        for _, i in ipairs(range(head + 1, first - 1)) do
            indices[#indices + 1] = i
        end
        for _, i in ipairs(range(last + 1, tail)) do
            indices[#indices + 1] = i
        end
    end
    return indices
end

local function parameter_indices(tokens, first, last)
    local open = open_angle(tokens, first - 1)
    local close = close_angle(tokens, last + 1)
    if not open or not close then
        return nil
    end
    return range(open, close)
end

function printer.strip_types(tokens, source, dialect, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    local spans, err = ecl.type_spans(source, dialect)
    if not spans then
        return nil, err
    end

    local by_start = {}
    for i, token in ipairs(tokens) do
        by_start[token.start] = i
    end

    local drop, statements = {}, {}
    for _, span in ipairs(spans) do
        local first, last = covered(tokens, by_start, span)
        if first then
            local indices
            if span.kind == ecl.TYPE_ANNOTATION then
                indices = annotation_indices(tokens, first, last, ecl)
            elseif span.kind == ecl.TYPE_ALIAS_STMT then
                indices = alias_indices(tokens, first, last, ecl)
                statements[last] = true
            elseif span.kind == ecl.TYPE_PARAM then
                indices = parameter_indices(tokens, first, last)
            end
            if indices then
                for _, i in ipairs(indices) do
                    drop[i] = true
                end
            end
        end
    end

    return require("process.syntax").remove(tokens, drop, statements, ecl)
end

local function split_lines(tokens, ecl)
    local lines, current = {}, {}
    for _, token in ipairs(tokens) do
        if token.kind == ecl.NEWLINE then
            lines[#lines + 1] = current
            current = {}
        else
            current[#current + 1] = token
        end
    end
    if #current > 0 then
        lines[#lines + 1] = current
    end
    return lines
end

local function reflow_long_comment(text, indent, unit)
    if not text:find("\n") then
        return text
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("%s+$", ""))
    end
    local function closing(i)
        return i == #lines and lines[i]:match("^%s*%]=*%]$")
    end
    -- Only the indentation every line shares is replaced, so nested
    -- lines, as in a commented-out block, keep their relative indent.
    local common
    for i = 2, #lines do
        if lines[i] ~= "" and not closing(i) then
            local lead = lines[i]:match("^%s*")
            local n = 0
            while n < #lead and (not common or n < #common) and (not common or common:byte(n + 1) == lead:byte(n + 1)) do
                n = n + 1
            end
            common = lead:sub(1, n)
        end
    end
    local out = { (text:gmatch("([^\n]*)")()) }
    for i = 2, #lines do
        local body = lines[i]
        if body == "" then
            out[i] = ""
        elseif closing(i) then
            out[i] = indent .. body:match("^%s*(.*)")
        else
            out[i] = indent .. unit .. body:sub(#(common or "") + 1)
        end
    end
    return table.concat(out, "\n")
end

local STATEMENT_STARTS = {
    ["local"] = true,
    ["function"] = true,
    ["if"] = true,
    ["for"] = true,
    ["while"] = true,
    ["repeat"] = true,
    ["do"] = true,
    ["return"] = true,
    ["break"] = true,
    ["continue"] = true,
    ["goto"] = true,
    ["export"] = true,
    ["type"] = true,
}

local function pop_persistent(stack, kind)
    if not stack then
        return nil, nil
    end
    if stack.kind == kind then
        return stack.prev, stack
    end
    local prefix = {}
    local current = stack
    while current do
        if current.kind == kind then
            local result = current.prev
            for index = #prefix, 1, -1 do
                local node = prefix[index]
                result = {
                    kind = node.kind,
                    counted = node.counted,
                    function_header = node.function_header,
                    prev = result,
                }
            end
            return result, current
        end
        prefix[#prefix + 1] = current
        current = current.prev
    end
    return stack, nil
end

local function new_reindenter(opts, ecl, if_exprs, explicit_if_expr)
    opts = opts or {}
    local unit = opts.indent or "\t"
    local depth = 0
    local delimiter_stack = {}
    local continued_header = false
    local continued_if_expr = false
    local if_expr_else_pending = false
    local alias_depths = {}
    local alias_offsets = {}
    local function_pending = false
    local function_parens = 0
    local indent_cache = {}

    local has_if_exprs = if_exprs and next(if_exprs) ~= nil
    local plain_bad = {
        [ecl.T.LeftParenthesis] = true,
        [ecl.T.RightParenthesis] = true,
        [ecl.T.LeftCurlyBrace] = true,
        [ecl.T.RightCurlyBrace] = true,
        [ecl.T.LeftSquareBracket] = true,
        [ecl.T.RightSquareBracket] = true,
        [ecl.T.Then] = true,
        [ecl.T.Do] = true,
        [ecl.T.Repeat] = true,
        [ecl.T.Else] = true,
        [ecl.T.Function] = true,
        [ecl.T.End] = true,
        [ecl.T.Until] = true,
        [ecl.T.Elseif] = true,
    }
    local function render_line(line)
        local body = line.__body
        if not body then
            local seen = false
            local plain = not has_if_exprs
            local texts = plain and {} or nil
            body = {}
            for _, token in ipairs(line) do
                if seen or token.kind ~= ecl.WHITESPACE then
                    seen = true
                    body[#body + 1] = token
                    if plain then
                        if token.is_comment then
                            plain = false
                        else
                            texts[#texts + 1] = token.text
                            if token.kind == ecl.SYNTAX and plain_bad[token.type] then
                                plain = false
                            end
                        end
                    end
                end
            end
            if opts.force then
                while #body > 0 and body[#body].kind == ecl.WHITESPACE do
                    body[#body] = nil
                end
            end
            if plain and body[1] then
                if body[1].alias_start or starts_header(body[1], ecl, if_exprs) then
                    plain = false
                end
            end
            if plain then
                body.__plain = true
                body.__joined = table.concat(texts)
            end
            line.__body = body
        end

        if #body == 0 then
            return ""
        end
        do
            if closes_block(body[1], ecl, if_exprs) then
                depth = depth - 1
            end
            local first_kind, first_open = delimiter_kind(body[1], ecl)
            local closed_function_header = false
            if first_kind and not first_open then
                local next_stack, delimiter = pop_persistent(delimiter_stack, first_kind)
                delimiter_stack = next_stack
                if delimiter and delimiter.counted then
                    depth = depth - 1
                end
                if delimiter and delimiter.function_header then
                    function_parens = function_parens - 1
                    closed_function_header = true
                end
            end
            local line_depth = depth
            local indent_depth = depth
            if body[1].alias_start then
                alias_depths[body[1].alias_start] = line_depth
            elseif body[1].alias_id then
                local base = alias_depths[body[1].alias_id]
                indent_depth = indent_depth - (alias_offsets[body[1].alias_id] or 0)
                local first = body[1]
                local closing = first.type == ecl.T.RightParenthesis
                    or first.type == ecl.T.RightCurlyBrace
                    or first.type == ecl.T.RightSquareBracket
                if base and not closing and indent_depth <= base then
                    indent_depth = base + 1
                end
            end
            if continued_header and not is_type(body[1], "Then", ecl) and not is_type(body[1], "Do", ecl) then
                indent_depth = indent_depth + 1
            end
            if continued_if_expr and not explicit_if_expr then
                if STATEMENT_STARTS[body[1].text] then
                    continued_if_expr = false
                    if_expr_else_pending = false
                else
                    indent_depth = indent_depth + 1
                end
            end
            if body[1].if_expr_indent then
                indent_depth = indent_depth + body[1].if_expr_indent
            end
            if body[1].binary_continuation and not continued_header
                and not body[1].extra_indent
            then
                indent_depth = indent_depth + 1
            end
            if body[1].nested_binary_continuation then
                indent_depth = indent_depth + 1
            end
            if body[1].assignment_continuation and not body[1].extra_indent
                and not body[1].binary_continuation
            then
                indent_depth = indent_depth + 1
            end
            if body[1].extra_indent then
                indent_depth = indent_depth + body[1].extra_indent
            end
            if body[1].continuation_indent then
                indent_depth = indent_depth + body[1].continuation_indent
            end
            -- `function` opens a block as well as its parameter list. Lines
            -- inside a multiline parameter list belong one level in, not two.
            if function_parens > 0 or closed_function_header then
                indent_depth = indent_depth - 1
            end
            local indent = indent_cache[indent_depth]
            if not indent then
                indent = unit:rep(math.max(indent_depth, 0))
                indent_cache[indent_depth] = indent
            end
            if body.__plain then
                return indent .. body.__joined
            end
            local pieces = { indent }
            local has_if_expr_if = false
            local if_expr_else_token = nil
            for position, token in ipairs(body) do
                if has_if_exprs and token.kind == ecl.SYNTAX and if_exprs[token] then
                    if token.text == "if" then
                        has_if_expr_if = true
                    elseif token.text == "else" then
                        if_expr_else_token = token
                    end
                end

                if token.kind == ecl.LONG_COMMENT then
                    -- StyLua keeps the interior of a block comment exactly as
                    -- written; only the comment's first line is reindented.
                    pieces[#pieces + 1] = token.text
                elseif token.kind == ecl.LINE_COMMENT and opts.force then
                    local text = token.text
                    local last = text:sub(-1)
                    if last == " " or last == "\t" then
                        text = text:gsub("[ \t]+$", "")
                    end
                    pieces[#pieces + 1] = text
                else
                    pieces[#pieces + 1] = token.text
                end

                if token.kind == ecl.SYNTAX then
                    if position > 1 and closes_block(token, ecl, if_exprs) then
                        depth = depth - 1
                    end

                    local kind, opening = delimiter_kind(token, ecl)
                    if kind and opening then
                        local counted = not token.uncounted
                            and not (kind == "parenthesis" and has_inline_container(body, position, ecl))
                        local function_header = kind == "parenthesis" and function_pending
                        delimiter_stack = {
                            kind = kind,
                            counted = counted,
                            function_header = function_header,
                            prev = delimiter_stack,
                        }
                        if function_header then
                            function_pending = false
                            function_parens = function_parens + 1
                        end
                        if counted then
                            depth = depth + 1
                        end
                    elseif kind and position > 1 then
                        local next_stack, delimiter = pop_persistent(delimiter_stack, kind)
                        delimiter_stack = next_stack
                        if delimiter and delimiter.counted then
                            depth = depth - 1
                        end
                        if delimiter and delimiter.function_header then
                            function_parens = function_parens - 1
                        end
                    end

                    if token.type == ecl.T.Function then
                        function_pending = true
                    end
                    if opens_block(token, ecl, if_exprs) then
                        depth = depth + 1
                    end
                end
            end
            if body[1].alias_start then
                alias_offsets[body[1].alias_start] = math.max(depth - (line_depth + 1), 0)
            end
            if starts_header(body[1], ecl, if_exprs) then
                continued_header = not contains_header_end(body, ecl)
            elseif continued_header and contains_header_end(body, ecl) then
                continued_header = false
            end
            if has_if_expr_if then
                continued_if_expr = true
                if_expr_else_pending = false
            end
            if if_expr_else_token then
                local last_non_comment
                for i = #body, 1, -1 do
                    if not body[i].is_comment then
                        last_non_comment = body[i]
                        break
                    end
                end
                if last_non_comment == if_expr_else_token then
                    continued_if_expr = true
                    if_expr_else_pending = true
                else
                    continued_if_expr = false
                    if_expr_else_pending = false
                end
            elseif if_expr_else_pending then
                continued_if_expr = false
                if_expr_else_pending = false
            end
            return table.concat(pieces)
        end
    end

    local function copy_map(source)
        local copy = {}
        for key, value in pairs(source) do
            copy[key] = value
        end
        return copy
    end

    local function checkpoint()
        return {
            depth = depth,
            delimiter_stack = delimiter_stack,
            continued_header = continued_header,
            continued_if_expr = continued_if_expr,
            if_expr_else_pending = if_expr_else_pending,
            alias_depths = next(alias_depths) and copy_map(alias_depths) or nil,
            alias_offsets = next(alias_offsets) and copy_map(alias_offsets) or nil,
            function_pending = function_pending,
            function_parens = function_parens,
        }
    end

    local function restore(state)
        depth = state.depth
        delimiter_stack = state.delimiter_stack
        continued_header = state.continued_header
        continued_if_expr = state.continued_if_expr
        if_expr_else_pending = state.if_expr_else_pending
        alias_depths = state.alias_depths and copy_map(state.alias_depths) or {}
        alias_offsets = state.alias_offsets and copy_map(state.alias_offsets) or {}
        function_pending = state.function_pending
        function_parens = state.function_parens
    end

    return {
        render_line = render_line,
        checkpoint = checkpoint,
        restore = restore,
    }
end

local function reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline, want_rows, explicit_if_expr)
    local renderer = new_reindenter(opts, ecl, if_exprs, explicit_if_expr)
    local out = new_table(#lines, 0)
    for _, line in ipairs(lines) do
        out[#out + 1] = renderer.render_line(line)
    end
    if want_rows then
        return out
    end
    if has_trailing_newline or (opts and opts.force) then
        return table.concat(out, "\n") .. "\n"
    else
        return table.concat(out, "\n")
    end
end



local function preferred_space(previous, current, before_previous, next_token, dialect, ecl)
    if not previous then
        return false
    end
    local T = ecl.T
    if current.is_comment or previous.is_comment then
        return true
    end
    -- Generic brackets are part of a name, not comparison operators.
    if current.angle_open or current.angle_close then
        return false
    end
    if previous.angle_open then
        return false
    end
    if previous.angle_close
        and (current.type == T.LeftParenthesis
            or current.type == T.LeftCurlyBrace
            or current.type == T.Dot
            or current.type == T.Colon
            or current.type == T.LessThan)
    then
        return false
    end
    if current.type == T.DoubleColon or previous.type == T.DoubleColon then
        return true
    end
    if current.type == T.Comma or current.type == T.Semicolon or current.type == T.RightParenthesis or current.type == T.RightSquareBracket or current.type == T.RightCurlyBrace then
        if current.type == T.RightCurlyBrace then
            return previous.type ~= T.LeftCurlyBrace, true
        end
        return false, true
    end
    if previous.type == T.LeftParenthesis or previous.type == T.LeftSquareBracket or previous.type == T.Dot then
        if (previous.type == T.LeftSquareBracket
                and (current.type == T.LeftSquareBracket or current.type == T.LongString))
            or (previous.type == T.Dot and (current.type == T.Integer or current.type == T.Float))
        then
            return false
        end
        return false, true
    end
    if previous.type == T.Colon and current.type == T.LeftParenthesis then
        -- Luau return annotations: `function f(): (A, B)`.
        return true
    end
    if previous.type == T.Colon then
        if before_previous
            and not (before_previous.type == T.Local or before_previous.type == T.Comma or before_previous.type == T.LeftParenthesis or before_previous.type == T.LeftCurlyBrace)
            and next_token
            and (next_token.type == T.LeftParenthesis
                or next_token.type == T.String
                or next_token.type == T.LongString
                or next_token.type == T.InterpolatedString
                or next_token.type == T.LessThan)
        then
            return false, true
        else
            return true
        end
    end
    if current.type == T.Colon then
        return false, true
    end
    if current.type == T.LeftParenthesis then
        if previous.type == T.If
            or previous.type == T.Elseif
            or previous.type == T.Else
            or previous.type == T.Then
            or previous.type == T.For
            or previous.type == T.While
            or previous.type == T.Until
            or previous.type == T.Return
            or previous.type == T.In
            or previous.type == T.Assign
            or previous.type == T.Comma
            or previous.type == T.Not
            or previous.type == T.Colon
            or (is_binary_op(previous.type, T) and not is_unary(previous, before_previous, ecl))
        then
            return true
        end
        return false, true
    end
    if current.type == T.LeftCurlyBrace then
        return previous.type ~= T.LeftParenthesis and previous.type ~= T.LeftSquareBracket, true
    end
    if previous.type == T.LeftCurlyBrace then
        return current.type ~= T.RightCurlyBrace, true
    end
    if previous.type == T.Comma then
        return true
    end
    if current.type == T.Not or previous.type == T.Not then
        return true
    end
    if previous.type == T.Return
        or previous.type == T.If
        or previous.type == T.Elseif
        or previous.type == T.Else
        or previous.type == T.Then
        or previous.type == T.Do
        or previous.type == T.While
        or previous.type == T.Until
        or previous.type == T.Local
        or previous.type == T.For
        or previous.type == T.In
    then
        return true
    end
    if current.type == T.Then
        or current.type == T.Do
        or current.type == T.Else
        or current.type == T.Elseif
        or current.type == T.Until
        or current.type == T.End
    then
        return true
    end
    if is_binary_op(current.type, T) and not is_unary(current, previous, ecl) then
        return true
    end
    if is_binary_op(previous.type, T) and not is_unary(previous, before_previous, ecl) then
        return true
    end
    if current.type == T.TripleDot or previous.type == T.TripleDot then
        return false
    end
    return ecl.needs_space(previous.text, current.text, dialect), true
end

--- Whether `--force` puts a space between two tokens: as the layout rules
--- prefer, but never joining two tokens into one, as `[` and `[=[s]=]` would.
local function strict_space(previous, current, before_previous, next_token, dialect, ecl)
    local preferred, checked = preferred_space(previous, current, before_previous, next_token, dialect, ecl)
    if preferred then
        return true
    end
    if checked then
        return false
    end
    return previous ~= nil and not previous.is_trivia and ecl.needs_space(previous.text, current.text, dialect)
end

local SPACE_RULE_NONE = {}
local SPACE_RULES = {}

local function static_space_rule(previous_type, current_type, T)
    if current_type == T.DoubleColon or previous_type == T.DoubleColon then
        return true
    end
    if current_type == T.RightCurlyBrace then
        return previous_type ~= T.LeftCurlyBrace
    end
    if current_type == T.Comma or current_type == T.Semicolon
        or current_type == T.RightParenthesis or current_type == T.RightSquareBracket
    then
        return false
    end
    if previous_type == T.LeftSquareBracket then
        if current_type == T.LeftSquareBracket or current_type == T.LongString then
            return nil
        end
        return false
    end
    if previous_type == T.LeftParenthesis then
        return false
    end
    if previous_type == T.Dot then
        if current_type == T.Integer or current_type == T.Float then
            return nil
        end
        return false
    end
    if previous_type == T.Colon or current_type == T.Colon then
        return nil
    end
    if current_type == T.LeftParenthesis then
        if previous_type == T.If or previous_type == T.Elseif or previous_type == T.Else
            or previous_type == T.Then or previous_type == T.For or previous_type == T.While
            or previous_type == T.Until or previous_type == T.Return or previous_type == T.In
            or previous_type == T.Assign or previous_type == T.Comma or previous_type == T.Not
        then
            return true
        end
        if is_binary_op(previous_type, T) then
            return nil
        end
        return false
    end
    if current_type == T.LeftCurlyBrace then
        return previous_type ~= T.LeftParenthesis and previous_type ~= T.LeftSquareBracket
    end
    if previous_type == T.LeftCurlyBrace then
        return current_type ~= T.RightCurlyBrace
    end
    if previous_type == T.Comma then
        return true
    end
    if current_type == T.Not or previous_type == T.Not then
        return true
    end
    if previous_type == T.Return or previous_type == T.If or previous_type == T.Elseif
        or previous_type == T.Else or previous_type == T.Then or previous_type == T.Do
        or previous_type == T.While or previous_type == T.Until or previous_type == T.Local
        or previous_type == T.For or previous_type == T.In
    then
        return true
    end
    if current_type == T.Then or current_type == T.Do or current_type == T.Else
        or current_type == T.Elseif or current_type == T.Until or current_type == T.End
    then
        return true
    end
    if is_binary_op(current_type, T) or is_binary_op(previous_type, T) then
        if current_type == T.Plus or current_type == T.Minus or current_type == T.Tilde
            or previous_type == T.Plus or previous_type == T.Minus or previous_type == T.Tilde
        then
            return nil
        end
        return true
    end
    if current_type == T.TripleDot or previous_type == T.TripleDot then
        return nil
    end
    return nil
end

local COLUMN_WIDTH = 120

-- Large files can split thousands of lines. Updating every token's line
-- number after each split would make layout quadratic, so past a threshold a
-- token points at its line table and reads that table's current index. Only
-- the line array is renumbered, not every token on every following line.
local LAZY_POSITION_LINES = 1000
local TOKEN_POSITION_MT = {
    __index = function(token, key)
        if key == "line" then
            local line = rawget(token, "__line")
            if line then
                return line.__line_index
            end
        end
    end,
}

local function update_line_indices(lines, from)
    for index = from, #lines do
        lines[index].__line_index = index
    end
end

local function set_token_position(token, line, line_index, position, lazy)
    if lazy then
        token.__line = line
    else
        token.line = line_index
    end
    token.position = position
end

local function enable_lazy_positions(lines, tokens)
    if lines.__lazy_positions or #lines < LAZY_POSITION_LINES then
        return
    end
    lines.__lazy_positions = true
    lines.__deferred_from = nil
    update_line_indices(lines, 1)
    for _, token in ipairs(tokens) do
        rawset(token, "line", nil)
        setmetatable(token, TOKEN_POSITION_MT)
    end
    for line_index, line in ipairs(lines) do
        for position, token in ipairs(line) do
            token.__line = line
            token.position = position
        end
    end
end

local function insert_line_at(lines, index, line)
    table.insert(lines, index, line)
    if lines.__lazy_positions then
        update_line_indices(lines, index)
    end
end

local function remove_line_at(lines, index)
    table.remove(lines, index)
end

local function flush_positions(lines)
    local first_line = lines.__deferred_from
    if not first_line then
        return
    end
    lines.__deferred_from = nil
    local positions = lines.__positions
    if not positions then
        return
    end
    local lazy = lines.__lazy_positions
    for line_index = first_line, #lines do
        local line = lines[line_index]
        for position = 1, #line do
            local token = line[position]
            set_token_position(token, line, line_index, position, lazy)
            positions[token] = token
        end
    end
end

local function token_positions(lines)
    local positions = lines.__positions
    if positions then
        if lines.__deferred_from then
            flush_positions(lines)
        end
        return positions
    end
    local count = 0
    for _, line in ipairs(lines) do
        count = count + #line
    end
    positions = new_table(0, count)
    local lazy = lines.__lazy_positions
    for line_index, line in ipairs(lines) do
        for position, token in ipairs(line) do
            set_token_position(token, line, line_index, position, lazy)
            positions[token] = token
        end
    end
    lines.__positions = positions
    return positions
end

local function reindex_positions(lines, first_line)
    local positions = lines.__positions
    if not positions or lines.__lazy_positions then
        return
    end
    if lines.__defer_positions then
        local deferred = lines.__deferred_from
        if not deferred or first_line < deferred then
            lines.__deferred_from = first_line
        end
        return
    end
    for line_index = first_line, #lines do
        local line = lines[line_index]
        for position = 1, #line do
            local token = line[position]
            token.line = line_index
            token.position = position
            positions[token] = token
        end
    end
end

local function reindex_line_positions(lines, line_index)
    local positions = lines.__positions
    if not positions then
        return
    end
    local line = lines[line_index]
    local lazy = lines.__lazy_positions
    for position = 1, #line do
        local token = line[position]
        set_token_position(token, line, line_index, position, lazy)
        positions[token] = token
    end
end

local function refresh_line_positions(lines, line_index)
    if lines.__positions and not lines.__deferred_from then
        reindex_line_positions(lines, line_index)
    else
        lines.__positions = nil
        lines.__deferred_from = nil
    end
end

local function collapse_blank_lines(lines, ecl)
    local T = ecl.T
    local closing = {
        [T.RightCurlyBrace] = true,
        [T.RightParenthesis] = true,
        [T.RightSquareBracket] = true,
        [T.End] = true,
        [T.Else] = true,
        [T.Elseif] = true,
        [T.Until] = true,
    }
    local next_content, previous_content = {}, {}
    local next_line, previous_line
    for index = #lines, 1, -1 do
        next_content[index] = next_line
        if #lines[index] > 0 then
            next_line = index
        end
    end
    for index = 1, #lines do
        previous_content[index] = previous_line
        if #lines[index] > 0 then
            previous_line = index
        end
    end
    local out = {}
    local blank = false
    for index, line in ipairs(lines) do
        if #line > 0 then
            blank = false
            out[#out + 1] = line
        elseif not blank then
            blank = true
            local following = next_content[index]
            local first
            if following then
                for _, token in ipairs(lines[following]) do
                    if token.kind ~= ecl.WHITESPACE then
                        first = token
                        break
                    end
                end
            end
            local after_opener = false
            local previous = previous_content[index]
            if previous then
                local last_code, has_function = nil, false
                for _, token in ipairs(lines[previous]) do
                    if token.kind ~= ecl.WHITESPACE and not token.is_comment then
                        last_code = token
                        if token.type == T.Function then
                            has_function = true
                        end
                    end
                end
                if last_code then
                    after_opener = last_code.type == T.Then or last_code.type == T.Do
                        or last_code.type == T.Repeat or last_code.type == T.Else
                        or (has_function and last_code.type ~= T.End)
                end
            end
            if not (first and closing[first.type]) and not after_opener then
                out[#out + 1] = line
            end
        end
    end
    return out
end

local function display_width(text)
    if not text:find("[\128-\255\t]") then
        return #text
    end
    local width = 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte == 9 then
            width = width + 4
        elseif byte < 128 or byte >= 192 then
            width = width + 1
        end
    end
    return width
end

local function fits_line(row)
    local width = display_width(row)
    if row:sub(-1) == "," then
        width = width - 1
    end
    return width <= COLUMN_WIDTH
end

local function mark_render_dirty(lines, from)
    lines.__render_version = (lines.__render_version or 0) + 1
    local current = lines.__render_dirty_from
    if not current or from < current then
        lines.__render_dirty_from = from
    end
end

local function new_row_provider(lines, opts, ecl, if_exprs)
    local provider = { opts = opts, if_exprs = if_exprs }
    provider.rows = setmetatable({}, {
        __index = function(_, index)
            if type(index) ~= "number" then
                return nil
            end
            return provider:get(index)
        end,
    })

    function provider:reset()
        self.renderer = new_reindenter(opts, ecl, if_exprs, false)
        self.cache = {}
        self.checkpoints = {}
        self.cursor = 1
        self.rendered_to = 0
    end

    function provider:sync()
        local version = lines.__render_version or 0
        if version == self.version then
            return
        end
        local from = lines.__render_dirty_from or 1
        if from <= self.rendered_to then
            local checkpoint = self.checkpoints[from]
            for index = from, self.rendered_to do
                self.cache[index] = nil
                self.checkpoints[index] = nil
            end
            self.rendered_to = from - 1
            if checkpoint then
                self.renderer.restore(checkpoint)
                self.cursor = from
            else
                self:reset()
            end
        end
        self.version = version
        lines.__render_dirty_from = nil
    end

    function provider:get(index)
        self:sync()
        if index < 1 or index > #lines then
            return nil
        end
        if index < self.cursor then
            local row = rawget(self.cache, index)
            if row ~= nil then
                return row
            end
            self:reset()
        end
        while self.cursor <= index do
            self.checkpoints[self.cursor] = self.renderer.checkpoint()
            local row = self.renderer.render_line(lines[self.cursor])
            self.cache[self.cursor] = row
            self.rendered_to = self.cursor
            self.cursor = self.cursor + 1
        end
        return rawget(self.cache, index)
    end

    provider:reset()
    provider.version = lines.__render_version or 0
    lines.__render_dirty_from = nil
    lines.__row_provider = provider
    return provider
end

local function rendered_rows(lines, opts, ecl, if_exprs)
    local provider = lines.__row_provider
    if not provider or provider.opts ~= opts or provider.if_exprs ~= if_exprs then
        provider = new_row_provider(lines, opts, ecl, if_exprs)
    end
    return provider.rows
end

local function remove_redundant_cast_parens(lines, tokens, info, parens, ecl)
    for _, node in ipairs(parens) do
        local open = info.at[node.span.start]
        local close = info.ending[node.span["end"]]
        local positions = token_positions(lines)
        local open_position = open and positions[tokens[open]]
        local close_position = close and positions[tokens[close]]
        if open_position and close_position and open_position.line == close_position.line then
            local previous, following
            for index = open - 1, 1, -1 do
                if not tokens[index].is_trivia then
                    previous = tokens[index]
                    break
                end
            end
            for index = close + 1, #tokens do
                if not tokens[index].is_trivia then
                    following = tokens[index]
                    break
                end
            end
            local context = previous and (previous.type == ecl.T.Assign or previous.text == "else")
            local attached = following and (following.type == ecl.T.Dot or following.type == ecl.T.Colon
                or following.type == ecl.T.LeftSquareBracket or following.type == ecl.T.LeftParenthesis
                or binary_precedence(following.type, ecl))
            if context and not attached then
                local line = lines[open_position.line]
                local positions = lines.__positions
                if positions then
                    positions[line[close_position.position]] = nil
                    positions[line[open_position.position]] = nil
                end
                table.remove(line, close_position.position)
                if line[close_position.position - 1] and line[close_position.position - 1].kind == ecl.WHITESPACE then
                    table.remove(line, close_position.position - 1)
                end
                table.remove(line, open_position.position)
                if line[open_position.position] and line[open_position.position].kind == ecl.WHITESPACE then
                    table.remove(line, open_position.position)
                end
                line.__body = nil
                refresh_line_positions(lines, open_position.line)
                mark_render_dirty(lines, open_position.line)
            end
        end
    end
    return lines
end

local function remove_redundant_condition_parens(lines, tokens, ecl)
    local T = ecl.T
    for index, token in ipairs(tokens) do
        if not token.is_trivia and (token.type == T.If or token.type == T.Elseif or token.type == T.While) then
            local open
            for inner = index + 1, #tokens do
                if not tokens[inner].is_trivia then
                    open = inner
                    break
                end
            end
            if open and tokens[open].type == T.LeftParenthesis then
                local close, depth
                for inner = open, #tokens do
                    if tokens[inner].type == T.LeftParenthesis then
                        depth = (depth or 0) + 1
                    elseif tokens[inner].type == T.RightParenthesis then
                        depth = (depth or 0) - 1
                        if depth == 0 then
                            close = inner
                            break
                        end
                    end
                end
                local following
                if close then
                    for inner = close + 1, #tokens do
                        if not tokens[inner].is_trivia then
                            following = inner
                            break
                        end
                    end
                end
                if close and following and (tokens[following].type == T.Then or tokens[following].type == T.Do) then
                    local positions = token_positions(lines)
                    local open_position = positions[tokens[open]]
                    local close_position = positions[tokens[close]]
                    if open_position and close_position then
                        local function remove_paren(line, index)
                            positions[line[index]] = nil
                            table.remove(line, index)
                            line.__body = nil
                            local before = line[index - 1]
                            local after = line[index]
                            if before and after
                                and before.kind == ecl.WHITESPACE and after.kind == ecl.WHITESPACE
                            then
                                table.remove(line, index)
                            elseif not before and after and after.kind == ecl.WHITESPACE then
                                table.remove(line, index)
                            elseif before and before.kind == ecl.WHITESPACE and not after then
                                table.remove(line, index - 1)
                            elseif before and after
                                and before.kind ~= ecl.WHITESPACE and after.kind ~= ecl.WHITESPACE
                            then
                                table.insert(line, index, {
                                    kind = ecl.WHITESPACE,
                                    type = -1,
                                    text = " ",
                                    is_trivia = true,
                                    is_comment = false,
                                })
                            end
                        end
                        remove_paren(lines[close_position.line], close_position.position)
                        remove_paren(lines[open_position.line], open_position.position)
                        refresh_line_positions(lines, close_position.line)
                        refresh_line_positions(lines, open_position.line)
                        mark_render_dirty(lines, open_position.line)
                    end
                end
            end
        end
    end
    return lines
end

local shared_space
local function new_space(ecl)
    if not shared_space then
        shared_space = {
            kind = ecl.WHITESPACE,
            type = -1,
            text = " ",
            is_trivia = true,
            is_comment = false,
        }
    end
    return shared_space
end

--- Joins every line touched by `first_token` and `last_token`, inserting the
--- spaces the strict layout rules would put between newly adjacent tokens.
local function flatten_token_range(lines, first_token, last_token, dialect, ecl)
    local positions = token_positions(lines)
    local first = positions[first_token]
    local last = positions[last_token]
    if not first or not last or first.line == last.line then
        return false
    end

    local merged = {}
    local previous_code, before_previous_code
    local function append(token, boundary)
        if boundary and previous_code and not token.is_comment and token.kind ~= ecl.WHITESPACE then
            if strict_space(previous_code, token, before_previous_code, nil, dialect, ecl) then
                merged[#merged + 1] = new_space(ecl)
            end
        end
        merged[#merged + 1] = token
        if not token.is_trivia then
            before_previous_code, previous_code = previous_code, token
        end
    end

    for line_index = first.line, last.line do
        local line = lines[line_index]
        local from = line_index == first.line and first.position or 1
        local to = line_index == last.line and last.position or #line
        for position = from, to do
            local token = line[position]
            if position == from and line_index > first.line and token.kind == ecl.WHITESPACE then
                -- Indentation is added again by reindent_lines.
            elseif token.kind == ecl.WHITESPACE then
                if #merged > 0 then
                    merged[#merged + 1] = token
                end
            else
                append(token, line_index > first.line and position == from)
            end
        end
    end

    local combined = {}
    for position = 1, first.position - 1 do
        combined[#combined + 1] = lines[first.line][position]
    end
    for _, token in ipairs(merged) do
        combined[#combined + 1] = token
    end
    for position = last.position + 1, #lines[last.line] do
        combined[#combined + 1] = lines[last.line][position]
    end

    lines[first.line] = combined
    for line_index = last.line, first.line + 1, -1 do
        remove_line_at(lines, line_index)
    end
    mark_render_dirty(lines, first.line)
    if lines.__lazy_positions then
        update_line_indices(lines, first.line)
        reindex_line_positions(lines, first.line)
    else
        reindex_positions(lines, first.line)
    end
    return true
end

local function split_before_token(lines, token, ecl, continuation, known_positions)
    local position = known_positions and known_positions[token] or token_positions(lines)[token]
    if not position or position.position <= 1 then
        return false
    end
    local line = lines[position.line]
    local before, after = {}, {}
    for index = 1, position.position - 1 do
        before[#before + 1] = line[index]
    end
    while #before > 0 and before[#before].kind == ecl.WHITESPACE do
        before[#before] = nil
    end
    for index = position.position, #line do
        after[#after + 1] = line[index]
    end
    while #after > 0 and after[1].kind == ecl.WHITESPACE do
        table.remove(after, 1)
    end
    if #before == 0 or #after == 0 then
        return false
    end
    if continuation and after[1] then
        after[1].extra_indent = (after[1].extra_indent or 0) + 1
        layout_flags.other = true
    end
    if after[1] and after[1].text == ":" then
        layout_flags.other = true
    end
    local before_token = before[#before]
    if before_token and (before_token.type == ecl.T.Assign
        or (before_token.type >= ecl.T.PlusAssign and before_token.type <= ecl.T.ShiftRightAssign))
    then
        layout_flags.other = true
    end
    before.__node = line.__node
    before.__line_index = position.line
    lines[position.line] = before
    insert_line_at(lines, position.line + 1, after)
    mark_render_dirty(lines, position.line)
    if lines.__lazy_positions then
        reindex_line_positions(lines, position.line)
        reindex_line_positions(lines, position.line + 1)
    else
        reindex_positions(lines, position.line)
    end
    return true
end

local function code_index(tokens, from, to)
    for index = from, to do
        if not tokens[index].is_trivia then
            return index
        end
    end
end

local function collapse_empty_functions(lines, tokens, info, functions, dialect, ecl)
    for _, fn in ipairs(functions) do
        if tonumber(fn.body.len) == 0 then
            local first = info.at[fn.span.start]
            local last = info.ending[fn.span["end"]]
            if first and last then
                local open
                for index = first, last do
                    if tokens[index].type == ecl.T.LeftParenthesis then
                        open = index
                        break
                    end
                end
                local close
                if open then
                    local depth = 0
                    for index = open, last do
                        if tokens[index].type == ecl.T.LeftParenthesis then
                            depth = depth + 1
                        elseif tokens[index].type == ecl.T.RightParenthesis then
                            depth = depth - 1
                            if depth == 0 then
                                close = index
                                break
                            end
                        end
                    end
                end
                local positions = token_positions(lines)
                local close_position = close and positions[tokens[close]]
                local end_position = positions[tokens[last]]
                if close_position and end_position and close_position.line < end_position.line then
                    local commented = false
                    for index = close, last do
                        if tokens[index].is_comment then
                            commented = true
                            break
                        end
                    end
                    if not commented then
                        flatten_token_range(lines, tokens[close], tokens[last], dialect, ecl)
                    end
                end
            end
        end
    end
    return lines
end

local function field_start_index(info, field, tokens, ecl)
    local K = ecl.const
    if field.kind == K.FIELD_KIND_KEYED and field.key ~= nil then
        local index = info.at[field.key.span.start]
        if index then
            local prior = index - 1
            while prior >= 1 and tokens[prior].is_trivia do
                prior = prior - 1
            end
            if prior >= 1 and tokens[prior].type == ecl.T.LeftSquareBracket then
                return prior
            end
        end
        return index
    elseif field.kind == K.FIELD_KIND_NAMED then
        return info.at[field.name.start]
    end
    return info.at[field.value.span.start]
end

local function field_source_start(field, ecl)
    if field.kind == ecl.const.FIELD_KIND_KEYED and field.key ~= nil then
        return field.key.span.start
    elseif field.kind == ecl.const.FIELD_KIND_NAMED and field.name ~= nil then
        return field.name.start
    elseif field.value ~= nil then
        return field.value.span.start
    end
end

local function normalize_multiline_tables(lines, tokens, info, expressions, ecl)
    local runtime = {}
    for _, node in ipairs(expressions.tables) do
        local open = info.at[node.span.start]
        if open then
            runtime[open] = node
        end
    end

    local braces = {}
    local stack = {}
    for _, token in ipairs(expressions.curlies or {}) do
        if token.type == ecl.T.LeftCurlyBrace then
            stack[#stack + 1] = token.index
        elseif token.type == ecl.T.RightCurlyBrace then
            local open = table.remove(stack)
            if open then
                braces[#braces + 1] = { open, token.index }
            end
        end
    end

    local function newline_between(from, to)
        return source_has_newline(info, from, to)
    end

    local function split_all(targets)
        for _, target in ipairs(targets) do
            split_before_token(lines, tokens[target], ecl)
        end
    end

    for _, pair in ipairs(braces) do
        local open_token, close_token = tokens[pair[1]], tokens[pair[2]]
        if newline_between(open_token.start + #open_token.text, close_token.start) then
            local node = runtime[pair[1]]
            local targets = {}
            local normalized = true
            if node then
                local count = tonumber(node.data.table.len)
                local skip_nested = false
                if count == 1 then
                    local field = node.data.table.ptr[0]
                    if field.kind == ecl.const.FIELD_KIND_POSITIONAL
                        and field.value and field.value.kind == ecl.const.EXPR_KIND_TABLE
                    then
                        local start = field_source_start(field, ecl)
                        skip_nested = start and not newline_between(open_token.start + #open_token.text, start)
                    end
                end
                if not skip_nested then
                    local previous = open_token.start + #open_token.text
                    for index = 0, count - 1 do
                        local field = node.data.table.ptr[index]
                        local start = field_source_start(field, ecl)
                        local value_end = field.value and field.value.span["end"] or start
                        if start and not newline_between(previous, start) then
                            normalized = false
                        end
                        local target = field_start_index(info, field, tokens, ecl)
                        if target then
                            targets[#targets + 1] = target
                        end
                        previous = value_end
                    end
                    if not newline_between(previous, close_token.start) then
                        normalized = false
                    end
                end
            else
                local depth = 0
                local first = code_index(tokens, pair[1] + 1, pair[2] - 1)
                if first and not newline_between(open_token.start + #open_token.text, tokens[first].start) then
                    normalized = false
                end
                local last = nil
                for index = pair[1] + 1, pair[2] - 1 do
                    local token = tokens[index]
                    if not token.is_trivia then
                        local kind, opening = delimiter_kind(token, ecl)
                        if kind then
                            depth = opening and depth + 1 or math.max(depth - 1, 0)
                        elseif depth == 0 and (token.type == ecl.T.Comma or token.type == ecl.T.Semicolon) then
                            local following = code_index(tokens, index + 1, pair[2] - 1)
                            if following and tokens[following].type ~= ecl.T.RightCurlyBrace then
                                if not newline_between(token.start + #token.text, tokens[following].start) then
                                    normalized = false
                                end
                                targets[#targets + 1] = following
                            end
                        end
                        last = token
                    end
                end
                if last and not newline_between(last.start + #last.text, close_token.start) then
                    normalized = false
                end
            end
            if not normalized then
                local positions = token_positions(lines)
                local open_position = positions[open_token]
                local close_position = positions[close_token]
                if open_position and close_position and open_position.line < close_position.line then
                    targets[#targets + 1] = pair[2]
                    split_all(targets)
                end
            end
        end
    end
    return lines
end

local function keyword_index(tokens, from, to, text)
    for index = from, to do
        local token = tokens[index]
        if not token.is_trivia then
            if token.text == text then
                return index
            end
            return nil
        end
    end
end

local function span_indices(info, span)
    local first = info.at[span.start]
    local last = info.ending[span["end"]]
    return first, last
end

local function if_expression_parts(node, tokens, info)
    local branch = node.data.if_else
    local limit = info.ending[node.span["end"]] or #tokens
    local first = info.at[node.span.start]
    if not first then
        return nil
    end

    local condition_first, condition_last = span_indices(info, branch.condition.span)
    if not condition_first or not condition_last then
        return nil
    end
    local then_index = keyword_index(tokens, condition_last + 1, limit, "then")
    local then_first, then_last = span_indices(info, branch.then_branch.span)
    if not then_index or not then_first or not then_last then
        return nil
    end

    local breakpoints = { then_index }
    local previous = then_last
    local arms = {}
    for index = 0, tonumber(branch.elseifs.len) - 1 do
        local arm = branch.elseifs.ptr[index]
        local elseif_index = keyword_index(tokens, previous + 1, limit, "elseif")
        local arm_condition_first, arm_condition_last = span_indices(info, arm.condition.span)
        if not elseif_index or not arm_condition_first or not arm_condition_last then
            return nil
        end
        local arm_then_index = keyword_index(tokens, arm_condition_last + 1, limit, "then")
        local result_first, result_last = span_indices(info, arm.result.span)
        if not arm_then_index or not result_first or not result_last then
            return nil
        end
        arms[#arms + 1] = {
            keyword = elseif_index,
            condition_first = arm_condition_first,
            condition_last = arm_condition_last,
            then_index = arm_then_index,
            result_first = result_first,
            result_last = result_last,
            result_node = arm.result,
        }
        breakpoints[#breakpoints + 1] = elseif_index
        previous = result_last
    end

    local last = previous
    local else_index, else_first, else_last, else_node
    if branch.else_branch ~= nil then
        else_index = keyword_index(tokens, previous + 1, limit, "else")
        else_first, else_last = span_indices(info, branch.else_branch.span)
        if not else_index or not else_first or not else_last then
            return nil
        end
        breakpoints[#breakpoints + 1] = else_index
        last = else_last
        else_node = branch.else_branch
    end

    return {
        first = first,
        last = last,
        condition_first = condition_first,
        condition_last = condition_last,
        then_index = then_index,
        then_first = then_first,
        then_last = then_last,
        then_node = branch.then_branch,
        arms = arms,
        breakpoints = breakpoints,
        else_index = else_index,
        else_first = else_first,
        else_last = else_last,
        else_node = else_node,
    }
end

local function has_structural_newline(info, node, tokens, first, last, structural_spans)
    for _, span in ipairs(structural_spans) do
        if span.start >= node.span.start and span["end"] <= node.span["end"] then
            return true
        end
    end
    for index = first, last do
        local token = tokens[index]
        if token.is_comment or (not token.is_trivia and token.text:find("\n", 1, true)) then
            return true
        end
    end
    return false
end

binary_range_operators = function(tokens, first, last, ecl)
    local found, depth = {}, 0
    local previous
    for index = first, last do
        local token = tokens[index]
        if not token.is_trivia then
            local kind, opening = delimiter_kind(token, ecl)
            if kind then
                depth = opening and depth + 1 or math.max(depth - 1, 0)
            else
                local precedence = binary_precedence(token.type, ecl)
                if precedence and depth == 0 and not is_unary(token, previous, ecl) then
                    found[#found + 1] = { token = token, precedence = precedence }
                end
            end
            previous = token
        end
    end
    local lowest
    for _, operator in ipairs(found) do
        if not lowest or operator.precedence < lowest then
            lowest = operator.precedence
        end
    end
    local out = {}
    for _, operator in ipairs(found) do
        if operator.precedence == lowest then
            out[#out + 1] = operator.token
        end
    end
    return out
end

local function if_result_header_end(node, info, tokens, ecl)
    if not node then
        return nil
    end
    local first = info.at[node.span.start]
    if node.kind == ecl.const.EXPR_KIND_FUNCTION then
        local fn = node.data["function"]
        if tonumber(fn.body.len) > 0 then
            local body_first = info.at[fn.body.ptr[0].span.start]
            if body_first then
                local header_end = body_first - 1
                while header_end > first and tokens[header_end].is_trivia do
                    header_end = header_end - 1
                end
                return header_end
            end
        end
        return info.ending[fn.span["end"]]
    elseif node.kind == ecl.const.EXPR_KIND_TABLE then
        return first
    end
    local last = info.ending[node.span["end"]]
    if first and last then
        for index = first, last do
            local type_ = tokens[index].type
            if type_ == ecl.T.LeftParenthesis or type_ == ecl.T.LeftCurlyBrace then
                return index
            end
        end
    end
    return first
end

local function grouping_parenthesis(element, tokens, info, ecl)
    local first = info.at[element.span.start]
    local last = info.ending[element.span["end"]]
    if not first or not last then
        return nil
    end
    local open = first - 1
    while open > 0 and tokens[open].is_trivia do
        open = open - 1
    end
    if open < 1 or tokens[open].type ~= ecl.T.LeftParenthesis then
        return nil
    end
    local before = open - 1
    while before > 0 and tokens[before].is_trivia do
        before = before - 1
    end
    if before > 0 and can_end_expression(tokens[before], ecl) then
        return nil
    end
    local depth = 0
    for index = open, #tokens do
        local type_ = tokens[index].type
        if type_ == ecl.T.LeftParenthesis then
            depth = depth + 1
        elseif type_ == ecl.T.RightParenthesis then
            depth = depth - 1
            if depth == 0 then
                if index > last then
                    return open, index
                end
                return nil
            end
        end
    end
    return nil
end

local function layout_if_expressions(lines, tokens, info, if_nodes, structural_spans, opts, ecl, if_exprs, dialect)
    if #if_nodes == 0 then
        return lines
    end
    local unit_width = display_width(opts.indent or "\t")
    local renderer = new_reindenter(opts, ecl, if_exprs, false)
    local cursor = 1
    local last_line, last_checkpoint
    local mutated = false

    local function prepare(target)
        if not target then
            return
        end
        if target < cursor then
            if target == last_line and last_checkpoint then
                renderer.restore(last_checkpoint)
                cursor = target
            else
                renderer = new_reindenter(opts, ecl, if_exprs, false)
                cursor = 1
                last_line, last_checkpoint = nil, nil
            end
        end
        while cursor < target do
            renderer.render_line(lines[cursor])
            cursor = cursor + 1
        end
        last_line = target
        last_checkpoint = renderer.checkpoint()
    end

    local function row_at(target)
        if mutated then
            renderer.restore(last_checkpoint)
            cursor = last_line
            mutated = false
        end
        while cursor < target do
            renderer.render_line(lines[cursor])
            cursor = cursor + 1
        end
        local row = renderer.render_line(lines[cursor])
        cursor = cursor + 1
        return row
    end

    local function finish()
        if mutated then
            renderer.restore(last_checkpoint)
            cursor = last_line
            mutated = false
        end
    end

    local function flatten_range(first, last)
        if flatten_token_range(lines, first, last, dialect, ecl) then
            mutated = true
        end
    end
    local function split_token(token)
        if split_before_token(lines, token, ecl) then
            mutated = true
        end
    end
    for _, node in ipairs(if_nodes) do
        local parts = if_expression_parts(node, tokens, info)
        if parts then
            local first_position = token_positions(lines)[tokens[parts.first]]
            local target = first_position and first_position.line
            prepare(target)
            local grouping_open, grouping_close = grouping_parenthesis(node, tokens, info, ecl)
            local grouping_split = false
            if grouping_open and grouping_close then
                local before
                for index = grouping_open - 1, 1, -1 do
                    if not tokens[index].is_trivia then
                        before = tokens[index]
                        break
                    end
                end
                grouping_split = before and (before.type == ecl.T.And or before.type == ecl.T.Or)
            end
            local structural = has_structural_newline(info, node, tokens, parts.first, parts.last, structural_spans)
            if not structural then
                flatten_range(tokens[parts.first], tokens[parts.last], dialect, ecl)
            else
                flatten_range(tokens[parts.condition_first], tokens[parts.condition_last], dialect, ecl)
                local then_structural = has_structural_newline(
                    info,
                    parts.then_node,
                    tokens,
                    parts.then_first,
                    parts.then_last,
                    structural_spans
                )
                if then_structural then
                    local header_end = if_result_header_end(parts.then_node, info, tokens, ecl)
                    flatten_range(tokens[parts.then_index], tokens[header_end], dialect, ecl)
                else
                    flatten_range(tokens[parts.condition_first], tokens[parts.then_last], dialect, ecl)
                end
                for _, arm in ipairs(parts.arms) do
                    local arm_structural = has_structural_newline(
                        info,
                        arm.result_node,
                        tokens,
                        arm.result_first,
                        arm.result_last,
                        structural_spans
                    )
                    if arm_structural then
                        local header_end = if_result_header_end(arm.result_node, info, tokens, ecl)
                        flatten_range(tokens[arm.keyword], tokens[header_end], dialect, ecl)
                    else
                        flatten_range(tokens[arm.keyword], tokens[arm.result_last], dialect, ecl)
                    end
                end
                if parts.else_node then
                    local else_structural = has_structural_newline(
                        info,
                        parts.else_node,
                        tokens,
                        parts.else_first,
                        parts.else_last,
                        structural_spans
                    )
                    if else_structural then
                        local header_end = if_result_header_end(parts.else_node, info, tokens, ecl)
                        flatten_range(tokens[parts.else_index], tokens[header_end], dialect, ecl)
                    else
                        flatten_range(tokens[parts.else_index], tokens[parts.else_last], dialect, ecl)
                    end
                end
            end
            local split = structural
            if not split then
                local line_index = target
                local row = line_index and row_at(line_index)
                if not line_index or not row or display_width(row) > COLUMN_WIDTH then
                    local indent = row and (row:match("^[ \t]*") or "") or ""
                    local first = tokens[parts.first].index
                    local line_first = first
                    for _, token in ipairs(lines[line_index]) do
                        if token.kind ~= ecl.WHITESPACE then
                            line_first = token.index or first
                            break
                        end
                    end
                    local line_start = 1
                    for position in info.source:sub(1, tokens[first].start - 1):gmatch("()\n") do
                        line_start = position + 1
                    end
                    local source_line_first = first
                    for index = first - 1, 1, -1 do
                        if tokens[index].start < line_start then
                            break
                        end
                        if not tokens[index].is_trivia then
                            source_line_first = index
                        end
                    end
                    local own_grouping = false
                    if grouping_open then
                        local after = grouping_open + 1
                        while after <= #tokens and tokens[after].is_trivia do
                            after = after + 1
                        end
                        own_grouping = after == parts.first
                    end
                    local depth_at_first, scan_depth = 0, 0
                    for index = source_line_first, first do
                        local kind, opening = delimiter_kind(tokens[index], ecl)
                        if kind then
                            scan_depth = opening and scan_depth + 1 or math.max(scan_depth - 1, 0)
                        end
                    end
                    depth_at_first = scan_depth
                    local target_depth = own_grouping and math.max(depth_at_first - 1, 0) or depth_at_first
                    local last_logical, scan_depth = nil, 0
                    for index = source_line_first, first - 1 do
                        local token = tokens[index]
                        local kind, opening = delimiter_kind(token, ecl)
                        if kind then
                            scan_depth = opening and scan_depth + 1 or math.max(scan_depth - 1, 0)
                        elseif scan_depth == target_depth
                            and (token.type == ecl.T.And or token.type == ecl.T.Or)
                        then
                            last_logical = index
                        end
                    end
                    if last_logical then
                        source_line_first = last_logical
                    end
                    local prefix = flat_width(tokens, source_line_first, first - 1, dialect, ecl)
                    local enclosing = false
                    local depth = 0
                    for index = line_first, first - 1 do
                        local kind, opening = delimiter_kind(tokens[index], ecl)
                        if kind then
                            depth = opening and depth + 1 or math.max(depth - 1, 0)
                        end
                    end
                    enclosing = depth > 0 and not own_grouping
                    local available = COLUMN_WIDTH
                        - (display_width(indent) + (enclosing and unit_width or prefix))
                    local flat = flat_width(tokens, first, tokens[parts.last].index, dialect, ecl)
                    split = flat > available
                end
            end
            if split then
                for _, index in ipairs(parts.breakpoints) do
                    split_token(tokens[index], ecl)
                end
                local conditions = {
                    { parts.condition_first, parts.condition_last },
                }
                for _, arm in ipairs(parts.arms) do
                    conditions[#conditions + 1] = { arm.condition_first, arm.condition_last }
                end
                for _, condition in ipairs(conditions) do
                    local operators = binary_range_operators(tokens, condition[1], condition[2], ecl)
                    if #operators >= 2 then
                        for _, operator in ipairs(operators) do
                            split_token(operator, ecl)
                        end
                    end
                end
                if grouping_split and grouping_open and grouping_close then
                    split_token(tokens[parts.first], ecl)
                    split_token(tokens[grouping_close], ecl)
                end
            end
            finish()
        end
    end
    return lines
end

local function mark_if_expression_indents(lines, tokens, info, if_nodes, ecl)
    if #if_nodes == 0 then
        return lines
    end
    mark_render_dirty(lines, 1)
    for _, token in ipairs(tokens) do
        token.if_expr_indent = nil
    end
    local positions = token_positions(lines)
    for _, node in ipairs(if_nodes) do
        local first_token = tokens[info.at[node.span.start]]
        local last_token = tokens[info.ending[node.span["end"]]]
        local first = first_token and positions[first_token]
        local last = last_token and positions[last_token]
        if first and last then
            local grouping_open = grouping_parenthesis(node, tokens, info, ecl)
            local inline_grouping = grouping_open and positions[tokens[grouping_open]]
                and positions[tokens[grouping_open]].line == first.line
            local added = inline_grouping and 0 or 1
            for line = first.line + 1, last.line do
                for _, token in ipairs(lines[line]) do
                    if token.kind ~= ecl.WHITESPACE then
                        token.if_expr_indent = (token.if_expr_indent or 0) + added
                        break
                    end
                end
            end
        end
    end
    return lines
end

local function matching_delimiter(tokens, open_index, last, ecl)
    local depth = 0
    for index = open_index, last do
        local token = tokens[index]
        if not token.is_trivia then
            local kind, opening = delimiter_kind(token, ecl)
            if kind then
                if opening then
                    depth = depth + 1
                else
                    depth = depth - 1
                    if depth == 0 then
                        return index
                    end
                end
            end
        end
    end
end

local function layout_type_aliases(lines, tokens, opts, ecl, if_exprs, dialect)
    local rows
    local firsts, lasts = {}, {}
    for index, token in ipairs(tokens) do
        if not token.is_trivia then
            if token.alias_start then
                firsts[token.alias_start] = index
            end
            if token.alias_id then
                lasts[token.alias_id] = index
            end
        end
    end

    for alias = 1, #firsts do
        local first = firsts[alias]
        local last = lasts[alias]
        if first and last then
            local positions = token_positions(lines)
            local structural, has_comment = false, false
            local stack = {}
            for index = first, last do
                local token = tokens[index]
                if token.is_comment then
                    has_comment = true
                end
                if not token.is_trivia then
                    if token.type == ecl.T.LeftCurlyBrace then
                        stack[#stack + 1] = index
                    elseif token.type == ecl.T.RightCurlyBrace then
                        local open = table.remove(stack)
                        if open and positions[tokens[open]] and positions[token]
                            and positions[tokens[open]].line ~= positions[token].line
                        then
                            structural = true
                        end
                    end
                end
            end

            if not structural and not has_comment then
                flatten_token_range(lines, tokens[first], tokens[last], dialect, ecl)
                local position = token_positions(lines)[tokens[first]]
                rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                if position and rows[position.line] and display_width(rows[position.line]) > COLUMN_WIDTH then
                    local equals
                    for index = first, last do
                        if not tokens[index].is_trivia and tokens[index].type == ecl.T.Assign then
                            equals = index
                            break
                        end
                    end
                    if equals then
                        local value_first = code_index(tokens, equals + 1, last)
                        if value_first and tokens[value_first].type == ecl.T.LeftCurlyBrace then
                            local close = matching_delimiter(tokens, value_first, last, ecl)
                            if close then
                                local first_field = code_index(tokens, value_first + 1, close - 1)
                                if first_field then
                                    split_before_token(lines, tokens[first_field], ecl)
                                    rows = nil
                                end
                                local depth = 0
                                for index = value_first + 1, close - 1 do
                                    local token = tokens[index]
                                    if not token.is_trivia then
                                        local kind, opening = delimiter_kind(token, ecl)
                                        if kind then
                                            if opening then
                                                depth = depth + 1
                                            else
                                                depth = math.max(depth - 1, 0)
                                            end
                                        elseif depth == 0 and (token.type == ecl.T.Comma or token.type == ecl.T.Semicolon) then
                                            local following = code_index(tokens, index + 1, close - 1)
                                            if following and tokens[following].type ~= ecl.T.RightCurlyBrace then
                                                split_before_token(lines, tokens[following], ecl)
                                            end
                                        end
                                    end
                                end
                                split_before_token(lines, tokens[close], ecl)
                            end
                        else
                            local operators, depth = {}, 0
                            if value_first then
                                for index = value_first, last do
                                    local token = tokens[index]
                                    if not token.is_trivia then
                                        local kind, opening = delimiter_kind(token, ecl)
                                        if kind then
                                            if opening then
                                                depth = depth + 1
                                            else
                                                depth = math.max(depth - 1, 0)
                                            end
                                        elseif depth == 0 and (token.text == "|" or token.text == "&") then
                                            operators[#operators + 1] = index
                                        end
                                    end
                                end
                                if #operators > 0 then
                                    split_before_token(lines, tokens[value_first], ecl)
                                    for _, index in ipairs(operators) do
                                        split_before_token(lines, tokens[index], ecl)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- A cast table in a call is printed as a multiline argument list,
            -- even when the surrounding type alias otherwise fits.
            positions = token_positions(lines)
            for index = first, last - 1 do
                local token = tokens[index]
                if not token.is_trivia and token.text == "setmetatable" then
                    local open = code_index(tokens, index + 1, last)
                    if open and tokens[open].type == ecl.T.LeftParenthesis then
                        local close = matching_delimiter(tokens, open, last, ecl)
                        if close then
                            local depth, cast, cast_open = 1, false, nil
                            local separators = {}
                            for inner = open + 1, close - 1 do
                                local current = tokens[inner]
                                if not current.is_trivia then
                                    if depth == 1 and cast and current.type == ecl.T.LeftCurlyBrace then
                                        cast_open = inner
                                    end
                                    local kind, opening = delimiter_kind(current, ecl)
                                    if kind then
                                        if opening then
                                            depth = depth + 1
                                        else
                                            depth = depth - 1
                                        end
                                    elseif depth == 1 and current.type == ecl.T.DoubleColon then
                                        cast = true
                                    elseif depth == 1 and current.type == ecl.T.Comma then
                                        separators[#separators + 1] = inner
                                    end
                                end
                            end
                            if cast and cast_open then
                                local cast_close = matching_delimiter(tokens, cast_open, close, ecl)
                                local open_line = positions[tokens[cast_open]]
                                local close_line = cast_close and positions[tokens[cast_close]]
                                if open_line and close_line and open_line.line ~= close_line.line then
                                    local first_argument = code_index(tokens, open + 1, close)
                                    if first_argument then
                                        split_before_token(lines, tokens[first_argument], ecl)
                                    end
                                    for _, separator in ipairs(separators) do
                                        local argument = code_index(tokens, separator + 1, close)
                                        if argument then
                                            split_before_token(lines, tokens[argument], ecl)
                                        end
                                    end
                                    split_before_token(lines, tokens[close], ecl)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return lines
end

binary_precedence = function(token_type, ecl)
    local T = ecl.T
    if token_type == T.Or then
        return 1
    elseif token_type == T.And then
        return 2
    elseif token_type == T.Equal or token_type == T.NotEqual
        or token_type == T.LessThan or token_type == T.GreaterThan
        or token_type == T.LessThanOrEqual or token_type == T.GreaterThanOrEqual
    then
        return 3
    elseif token_type == T.Pipe then
        return 4
    elseif token_type == T.Tilde then
        return 5
    elseif token_type == T.Ampersand then
        return 6
    elseif token_type == T.ShiftLeft or token_type == T.ShiftRight then
        return 7
    elseif token_type == T.DoubleDot then
        return 8
    elseif token_type == T.Plus or token_type == T.Minus then
        return 9
    elseif token_type == T.Star or token_type == T.Slash or token_type == T.DoubleSlash
        or token_type == T.Percent
    then
        return 10
    elseif token_type == T.Caret then
        return 11
    end
end

local function first_code_on_line(line, ecl)
    for _, token in ipairs(line) do
        if token.kind ~= ecl.WHITESPACE then
            return token
        end
    end
end

--- The operators on `line` that Stylua would break before: those at the
--- lowest precedence present outside any delimiters.
local function line_binary_operators(line, ecl)
    local T = ecl.T
    local found, depth = {}, 0
    local previous, before_previous
    for _, token in ipairs(line) do
        if token.kind ~= ecl.WHITESPACE then
            local kind, opening = delimiter_kind(token, ecl)
            if kind then
                if opening then
                    depth = depth + 1
                else
                    depth = math.max(depth - 1, 0)
                end
            else
                local precedence = binary_precedence(token.type, ecl)
                if precedence and depth == 0 and not is_unary(token, previous, ecl) then
                    found[#found + 1] = { token = token, precedence = precedence }
                end
            end
            before_previous, previous = previous, token
        end
    end
    local first_code = first_code_on_line(line, ecl)
    local relevant = {}
    for _, operator in ipairs(found) do
        if operator.token ~= first_code then
            relevant[#relevant + 1] = operator
        end
    end
    local lowest
    for _, operator in ipairs(relevant) do
        if not lowest or operator.precedence < lowest then
            lowest = operator.precedence
        end
    end
    local out = {}
    for _, operator in ipairs(relevant) do
        if operator.precedence == lowest then
            out[#out + 1] = operator.token
        end
    end
    return out
end

local function mark_binary_continuations(lines, tokens, ecl, has_binary)
    if not has_binary and not layout_flags.other then
        local previous_marked = lines.__continuation_tokens
        if previous_marked then
            for index = 1, #previous_marked do
                local token = previous_marked[index]
                token.binary_continuation = nil
                token.assignment_continuation = nil
                token.continuation_indent = nil
            end
        end
        lines.__continuation_tokens = {}
        return
    end
    mark_render_dirty(lines, 1)
    local previous
    local previous_precedence
    local stack = {}
    local active = 0
    local whitespace = ecl.WHITESPACE
    local previous_marked = lines.__continuation_tokens
    if previous_marked then
        for index = 1, #previous_marked do
            local token = previous_marked[index]
            token.binary_continuation = nil
            token.assignment_continuation = nil
            token.continuation_indent = nil
        end
    end
    local marked = {}
    lines.__continuation_tokens = marked
    for _, line in ipairs(lines) do
        local first, last
        for _, token in ipairs(line) do
            if token.kind ~= whitespace then
                first = first or token
                if not token.is_comment then
                    last = token
                end
            end
        end
        if first and not first.is_comment and first.text == ":" and not first.extra_indent then
            first.extra_indent = 1
        end
        local precedence = first and not first.is_comment
            and not is_unary(first, previous, ecl) and binary_precedence(first.type, ecl) or nil
        if precedence and can_end_expression(previous, ecl)
            and not first.condition_continuation
        then
            first.binary_continuation = true
            marked[#marked + 1] = first
        end
        if precedence and previous_precedence and precedence > previous_precedence then
            first.nested_binary_continuation = true
        end
        if first and previous and (previous.type == ecl.T.Assign
            or (previous.type >= ecl.T.PlusAssign and previous.type <= ecl.T.ShiftRightAssign))
        then
            first.assignment_continuation = true
            marked[#marked + 1] = first
        end
        previous_precedence = precedence
        if last then
            previous = last
        end

        if first and active > 0 then
            first.continuation_indent = math.max(first.continuation_indent or 0, active)
            marked[#marked + 1] = first
        end
        local line_extra = 0
        if first then
            line_extra = first.extra_indent or 0
            if first.binary_continuation then
                line_extra = line_extra + 1
            end
            if first.extra_indent and (first.text == ":" or first.text == ".") then
                line_extra = 1
            end
        end
        if active > 0 or line_extra > 0 then
            local chain_line = first and first.extra_indent and (first.text == ":" or first.text == ".")
            local chain_extra_used = false
            for _, token in ipairs(line) do
                local kind, opening = delimiter_kind(token, ecl)
                if kind and opening then
                    local extra = line_extra
                    if chain_line then
                        if chain_extra_used then
                            extra = 0
                        else
                            chain_extra_used = true
                        end
                    end
                    stack[#stack + 1] = { kind = kind, extra = extra }
                    active = active + extra
                elseif kind then
                    for index = #stack, 1, -1 do
                        if stack[index].kind == kind then
                            local removed = table.remove(stack, index)
                            active = active - removed.extra
                            break
                        end
                    end
                end
            end
        end
    end
end

flat_width = function(tokens, first, last, dialect, ecl)
    local width, previous, before_previous = 0, nil, nil
    for index = first, last do
        local token = tokens[index]
        if not token.is_trivia then
            if previous and strict_space(previous, token, before_previous, nil, dialect, ecl) then
                width = width + 1
            end
            width = width + display_width(token.text)
            before_previous, previous = previous, token
        end
    end
    return width
end

local function indent_width(rows, line)
    local text = rows[line] or ""
    local indent = text:match("^[ \t]*") or ""
    return display_width(indent)
end

local function ensure_statement_at(info)
    if info.statement_at or info.statement_at_ready then
        return
    end
    info.statement_at_ready = true
    if #info.statements <= 4 then
        return
    end
    local statements_at, active = {}, {}
    for _, statement in ipairs(info.statements) do
        if statement.first and statement.last then
            local list = statements_at[statement.first]
            if not list then
                list = {}
                statements_at[statement.first] = list
            end
            list[#list + 1] = statement
        end
    end
    local first = info.statements[1]
    local last = info.statements[#info.statements]
    local statement_at = {}
    for index = first and first.first or 1, last and last.last or 0 do
        local starting = statements_at[index]
        if starting then
            for _, statement in ipairs(starting) do
                active[#active + 1] = statement
            end
        end
        while #active > 0 and active[#active].last < index do
            active[#active] = nil
        end
        statement_at[index] = active[#active]
    end
    info.statement_at = statement_at
end

local function statement_on_line(info, tokens, lines, line)
    ensure_statement_at(info)
    local statement_at = info.statement_at
    if statement_at then
        local target = lines[line]
        if target then
            for _, token in ipairs(target) do
                if token.index then
                    return statement_at[token.index]
                end
            end
        end
        return nil
    end
    local positions = token_positions(lines)
    local best
    for _, statement in ipairs(info.statements) do
        local first = positions[tokens[statement.first]]
        local last = positions[tokens[statement.last]]
        if first and last and first.line <= line and last.line >= line then
            if not best or statement.first > best.first then
                best = statement
            end
        end
    end
    return best
end

local function top_level_assign(tokens, first, last, ecl)
    local depth = 0
    for index = first, last do
        local token = tokens[index]
        if not token.is_trivia then
            local kind, opening = delimiter_kind(token, ecl)
            if kind then
                if opening then
                    depth = depth + 1
                else
                    depth = math.max(depth - 1, 0)
                end
            elseif depth == 0 and token.type == ecl.T.Assign then
                return index
            end
        end
    end
end

local function expand_table_node(lines, node, tokens, info, ecl)
    if tonumber(node.data.table.len) == 0 then
        return false
    end
    local positions = token_positions(lines)
    local open = info.at[node.span.start]
    local close = info.ending[node.span["end"]]
    if not open or not close or close <= open then
        return false
    end
    local first_field = field_start_index(info, node.data.table.ptr[0], tokens, ecl)
    if not first_field or not positions[tokens[open]] or not positions[tokens[first_field]] then
        return false
    end
    if positions[tokens[first_field]].line > positions[tokens[open]].line then
        return false
    end

    local changed = false
    local starts = {}
    for index = 0, tonumber(node.data.table.len) - 1 do
        local field = node.data.table.ptr[index]
        local start = field_start_index(info, field, tokens, ecl)
        if start then
            starts[#starts + 1] = start
        end
    end
    lines.__defer_positions = not lines.__lazy_positions
    if split_before_token(lines, tokens[close], ecl, nil, positions) then
        changed = true
    end
    for index = #starts, 1, -1 do
        if split_before_token(lines, tokens[starts[index]], ecl, nil, positions) then
            changed = true
        end
    end
    lines.__defer_positions = false
    if not lines.__lazy_positions then
        flush_positions(lines)
    end
    return changed
end

local function table_value_is_multiline(info, node)
    local multiline = false
    syntax.each(node.data.table, function(field)
        local span = field.value.span
        if source_has_newline(info, span.start + 1, span["end"]) then
            multiline = true
        end
    end)
    return multiline
end

local function matching_open_parenthesis(tokens, close, first, ecl)
    local depth = 0
    for index = close, first, -1 do
        local token = tokens[index]
        if token.type == ecl.T.RightParenthesis then
            depth = depth + 1
        elseif token.type == ecl.T.LeftParenthesis then
            depth = depth - 1
            if depth == 0 then
                return index
            end
        end
    end
end

local function call_arguments(node, ecl)
    if node.kind == ecl.const.EXPR_KIND_CALL then
        return node.data.call.arguments
    end
    return node.data.method_call.arguments
end

local function expand_call_node(lines, node, tokens, info, ecl)
    local arguments = call_arguments(node, ecl)
    if arguments.kind ~= ecl.const.ARGUMENTS_KIND_LIST or tonumber(arguments.values.len) == 0 then
        return false
    end
    local first = info.at[node.span.start]
    local close = info.ending[node.span["end"]]
    if not first or not close then
        return false
    end
    local open = matching_open_parenthesis(tokens, close, first, ecl)
    if not open then
        return false
    end
    local positions = token_positions(lines)
    if not positions[tokens[open]] or not positions[tokens[close]] then
        return false
    end
    local first_argument = info.at[arguments.values.ptr[0].span.start]
    if not first_argument then
        return false
    end
    -- Already formatted with one argument per line.
    if positions[tokens[first_argument]].line > positions[tokens[open]].line then
        return false
    end

    local values = arguments.values
    if tonumber(values.len) == 1 then
        local only = values.ptr[0]
        if only.kind == ecl.const.EXPR_KIND_TABLE or only.kind == ecl.const.EXPR_KIND_FUNCTION then
            return false
        end
    end

    local changed = false
    local starts = {}
    for index = 0, tonumber(values.len) - 1 do
        local argument = values.ptr[index]
        local start = info.at[argument.span.start]
        if start then
            starts[#starts + 1] = start
        end
    end
    lines.__defer_positions = not lines.__lazy_positions
    if split_before_token(lines, tokens[close], ecl, nil, positions) then
        changed = true
    end
    for index = #starts, 1, -1 do
        if split_before_token(lines, tokens[starts[index]], ecl, nil, positions) then
            changed = true
        end
    end
    lines.__defer_positions = false
    if not lines.__lazy_positions then
        flush_positions(lines)
    end
    return changed
end

local function break_function_header(lines, target, tokens, info, expressions, ecl)
    local positions = token_positions(lines)
    local function_node
    for _, fn in ipairs(expressions.functions) do
        local start = info.at[fn.span.start]
        if start and positions[tokens[start]] and positions[tokens[start]].line == target then
            if not function_node or start < info.at[function_node.span.start] then
                function_node = fn
            end
        end
    end
    if not function_node then
        return false
    end

    local start = info.at[function_node.span.start]
    local open
    for index = start, #tokens do
        if tokens[index].type == ecl.T.LeftParenthesis then
            open = index
            break
        end
    end
    if not open or not positions[tokens[open]] or positions[tokens[open]].line ~= target then
        return false
    end

    local close, depth = nil, 0
    for index = open, #tokens do
        local type_ = tokens[index].type
        if type_ == ecl.T.LeftParenthesis then
            depth = depth + 1
        elseif type_ == ecl.T.RightParenthesis then
            depth = depth - 1
            if depth == 0 then
                close = index
                break
            end
        end
    end
    if not close then
        return false
    end

    local values = function_node.parameters
    local first
    if tonumber(values.len) > 0 then
        first = info.at[values.ptr[0].name.start]
    else
        for index = open + 1, close - 1 do
            if tokens[index].type == ecl.T.TripleDot then
                first = index
                break
            end
        end
    end
    if not first or not positions[tokens[first]] then
        return false
    end
    if positions[tokens[first]].line > positions[tokens[open]].line then
        return false
    end

    local changed = false
    for index = 0, tonumber(values.len) - 1 do
        local parameter = info.at[values.ptr[index].name.start]
        if parameter and split_before_token(lines, tokens[parameter], ecl) then
            changed = true
        end
    end
    for index = open + 1, close - 1 do
        if tokens[index].type == ecl.T.TripleDot then
            if split_before_token(lines, tokens[index], ecl) then
                changed = true
            end
            break
        end
    end
    if split_before_token(lines, tokens[close], ecl) then
        changed = true
    end
    return changed
end

local function range_has_structural(tokens, first, last, if_exprs, ecl)
    for index = first, last do
        local token = tokens[index]
        if token.is_comment or token.type == ecl.T.Function or token.type == ecl.T.LeftCurlyBrace
            or (if_exprs and if_exprs[token])
        then
            return true
        end
    end
    return false
end

local function line_span_width(lines, rows, tokens, first, last, opts, ecl, dialect)
    local positions = token_positions(lines)
    local first_position = positions[tokens[first]]
    local last_position = positions[tokens[last]]
    if not first_position or not last_position then
        return math.huge
    end
    local line_first = first
    for _, token in ipairs(lines[first_position.line]) do
        if token.kind ~= ecl.WHITESPACE then
            line_first = token.index or first
            break
        end
    end
    local line = lines[last_position.line]
    local last_token = tokens[last]
    for index = #line, 1, -1 do
        if line[index].kind ~= ecl.WHITESPACE and not line[index].is_comment then
            last_token = line[index]
            break
        end
    end
    local last_index = last_token.index or last
    local row = rows[first_position.line] or ""
    local indent = row:match("^[ \t]*") or ""
    return display_width(indent) + flat_width(tokens, line_first, last_index, dialect, ecl)
end

local function collapse_binary_expressions(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
    local rows
    local nodes, active_end = {}, -1
    for _, node in ipairs(expressions.binaries) do
        if node.span.start > active_end then
            nodes[#nodes + 1] = node
            active_end = node.span["end"]
        end
    end
    for _, node in ipairs(nodes) do
        local first = info.at[node.span.start]
        local last = info.ending[node.span["end"]]
        local source_multiline = source_has_newline(info, node.span.start + 1, node.span["end"])
        local previous
        for index = (first or 1) - 1, 1, -1 do
            if not tokens[index].is_trivia then
                previous = tokens[index]
                break
            end
        end
        local expression_position = previous
            and (previous.type == ecl.T.Assign or previous.text == "return"
                or previous.type == ecl.T.LeftParenthesis or previous.type == ecl.T.Comma)
        local source_broken = false
        if source_multiline and first and last then
            local operators = binary_range_operators(tokens, first, last, ecl)
            for _, operator in ipairs(operators) do
                local operator_index
                for index = first, last do
                    if tokens[index] == operator then
                        operator_index = index
                        break
                    end
                end
                if operator_index then
                    local before, after
                    for index = operator_index - 1, first, -1 do
                        if not tokens[index].is_trivia then
                            before = tokens[index]
                            break
                        end
                    end
                    for index = operator_index + 1, last do
                        if not tokens[index].is_trivia then
                            after = tokens[index]
                            break
                        end
                    end
                    if before and source_has_newline(info, before.start + #before.text, operator.start) then
                        source_broken = true
                        break
                    elseif after and source_has_newline(info, operator.start + #operator.text, after.start) then
                        source_broken = true
                        break
                    end
                end
            end
        end
        if source_broken and expression_position and first and last then
            local positions = token_positions(lines)
            local first_position = positions[tokens[first]]
            local last_position = positions[tokens[last]]
            if first_position and last_position and first_position.line < last_position.line then
                rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                local width = line_span_width(lines, rows, tokens, first, last, opts, ecl, dialect)
                local block_literal = false
                for index = first, last do
                    if tokens[index].type == ecl.T.Function or tokens[index].type == ecl.T.LeftCurlyBrace then
                        block_literal = true
                        break
                    end
                end
                if width <= COLUMN_WIDTH and not block_literal then
                    flatten_token_range(lines, tokens[first], tokens[last], dialect, ecl)
                else
                    for _, operator in ipairs(binary_range_operators(tokens, first, last, ecl)) do
                        split_before_token(lines, operator, ecl)
                    end
                end
                rows = nil
            end
        end
    end
    return lines
end

local function collapse_return_statements(lines, tokens, info, returns, opts, ecl, if_exprs, dialect)
    local rows
    for _, statement in ipairs(returns) do
        do
            local first = info.at[statement.span.start]
            local last = info.ending[statement.span["end"]]
            if first and last then
                local positions = token_positions(lines)
                local first_position = positions[tokens[first]]
                local last_position = positions[tokens[last]]
                if first_position and last_position and first_position.line < last_position.line
                    and not range_has_structural(tokens, first, last, if_exprs, ecl)
                then
                    rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                    local width = line_span_width(lines, rows, tokens, first, last, opts, ecl, dialect)
                    if width <= COLUMN_WIDTH then
                        flatten_token_range(lines, tokens[first], tokens[last], dialect, ecl)
                        rows = nil
                    end
                end
            end
        end
    end
    return lines
end

local function collapse_function_headers(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
    local positions = token_positions(lines)
    local rows
    for _, fn in ipairs(expressions.functions) do
        local start = info.at[fn.span.start]
        local open
        for index = start or 1, #tokens do
            if tokens[index].type == ecl.T.LeftParenthesis then
                open = index
                break
            end
        end
        if open then
            local close, depth = nil, 0
            for index = open, #tokens do
                local type_ = tokens[index].type
                if type_ == ecl.T.LeftParenthesis then
                    depth = depth + 1
                elseif type_ == ecl.T.RightParenthesis then
                    depth = depth - 1
                    if depth == 0 then
                        close = index
                        break
                    end
                end
            end
            local first_position = positions[tokens[open]]
            local close_position = close and positions[tokens[close]]
            if first_position and close_position and first_position.line < close_position.line then
                local line = lines[close_position.line]
                local last_token = tokens[close]
                for index = #line, 1, -1 do
                    if line[index].kind ~= ecl.WHITESPACE and not line[index].is_comment then
                        last_token = line[index]
                        break
                    end
                end
                local last_header_index = close
                for index = close, #tokens do
                    if tokens[index] == last_token then
                        last_header_index = index
                        break
                    end
                end

                local body_first
                if tonumber(fn.body.len) > 0 then
                    body_first = info.at[fn.body.ptr[0].span.start]
                end
                if not body_first or not positions[tokens[body_first]]
                    or positions[tokens[body_first]].line > close_position.line
                then
                    local commented = false
                    for index = open, last_header_index do
                        if tokens[index].is_comment then
                            commented = true
                            break
                        end
                    end
                    if not commented then
                        local line_first = open
                        while line_first > 1 and positions[tokens[line_first - 1]]
                            and positions[tokens[line_first - 1]].line == first_position.line
                        do
                            line_first = line_first - 1
                        end
                        rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                        local row = rows[first_position.line] or ""
                        local indent = row:match("^[ \t]*") or ""
                        local width = display_width(indent)
                            + flat_width(tokens, line_first, last_header_index, dialect, ecl)
                        if width <= COLUMN_WIDTH then
                            flatten_token_range(lines, tokens[open], tokens[last_header_index], dialect, ecl)
                            positions = token_positions(lines)
                            rows = nil
                        end
                    end
                end
            end
        end
    end
    return lines
end

local function break_condition(lines, target, ecl, if_exprs)
    local line = lines[target]
    local first = first_code_on_line(line, ecl)
    if not first or if_exprs[first] then
        return false
    end
    local T = ecl.T
    if first.type ~= T.If and first.type ~= T.Elseif and first.type ~= T.While then
        return false
    end

    local terminator, depth = nil, 0
    for _, token in ipairs(line) do
        if token.kind ~= ecl.WHITESPACE then
            local kind, opening = delimiter_kind(token, ecl)
            if kind then
                if opening then
                    depth = depth + 1
                else
                    depth = math.max(depth - 1, 0)
                end
            elseif depth == 0 and (token.type == T.Then or token.type == T.Do) then
                terminator = token
            end
        end
    end
    if not terminator then
        return false
    end

    local operators = line_binary_operators(line, ecl)
    local changed = false
    local condition
    for _, token in ipairs(line) do
        if token.kind ~= ecl.WHITESPACE and token ~= first then
            condition = token
            break
        end
    end
    if condition and split_before_token(lines, condition, ecl) then
        changed = true
    end
    for _, operator in ipairs(operators) do
        if split_before_token(lines, operator, ecl) then
            changed = true
        end
    end
    if split_before_token(lines, terminator, ecl) then
        changed = true
    end
    return changed
end

local function condition_terminators(tokens, ecl, if_exprs)
    local T = ecl.T
    local stack = {}
    local terminators = {}
    local depth = 0
    for index, token in ipairs(tokens) do
        if not token.is_trivia and not if_exprs[token] then
            local kind, opening = delimiter_kind(token, ecl)
            if kind then
                if opening then
                    depth = depth + 1
                else
                    depth = math.max(depth - 1, 0)
                end
            elseif token.type == T.If or token.type == T.Elseif or token.type == T.While
                or token.type == T.For
            then
                stack[#stack + 1] = { index = index, depth = depth, type = token.type }
            elseif token.type == T.Then or token.type == T.Do then
                for position = #stack, 1, -1 do
                    local header = stack[position]
                    if header.depth == depth then
                        local matches = (token.type == T.Then and header.type ~= T.While)
                            or (token.type == T.Do and header.type == T.While)
                        table.remove(stack, position)
                        if matches then
                            terminators[header.index] = index
                        end
                        break
                    end
                end
            end
        end
    end
    return terminators
end

local function normalize_multiline_conditions(lines, tokens, opts, ecl, if_exprs, dialect)
    local T = ecl.T
    local rows
    local terminators = condition_terminators(tokens, ecl, if_exprs)
    for index, token in ipairs(tokens) do
        if not token.is_trivia and not if_exprs[token]
            and (token.type == T.If or token.type == T.Elseif or token.type == T.While)
        then
            local terminator = terminators[index]
            if terminator then
                local positions = token_positions(lines)
                local condition
                for inner = index + 1, terminator - 1 do
                    if not tokens[inner].is_trivia and positions[tokens[inner]] then
                        condition = inner
                        break
                    end
                end
                local last_condition = terminator - 1
                while last_condition > index and (tokens[last_condition].is_trivia
                    or not positions[tokens[last_condition]]) do
                    last_condition = last_condition - 1
                end
                local keyword_position = positions[token]
                local condition_position = condition and positions[tokens[condition]]
                local last_position = positions[tokens[last_condition]]
                local terminator_position = positions[tokens[terminator]]
                if keyword_position and condition_position and last_position and terminator_position
                    and (keyword_position.line < condition_position.line
                        or last_position.line > condition_position.line
                        or terminator_position.line > last_position.line)
                then
                    local commented = false
                    for inner = index, terminator do
                        if tokens[inner].is_comment then
                            commented = true
                            break
                        end
                    end
                    rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                    local width = commented and math.huge
                        or line_span_width(lines, rows, tokens, index, terminator, opts, ecl, dialect)
                    if width <= COLUMN_WIDTH then
                        flatten_token_range(lines, tokens[index], tokens[terminator], dialect, ecl)
                        rows = nil
                    else
                        split_before_token(lines, tokens[condition], ecl)
                        rows = nil
                        split_before_token(lines, tokens[terminator], ecl)
                        local depth = 0
                        for inner = index + 1, terminator - 1 do
                            local current = tokens[inner]
                            if not current.is_trivia then
                                local kind, opening = delimiter_kind(current, ecl)
                                if kind then
                                    if opening then
                                        depth = depth + 1
                                    else
                                        depth = math.max(depth - 1, 0)
                                    end
                                elseif depth == 0 and (current.type == T.And or current.type == T.Or) then
                                    split_before_token(lines, current, ecl)
                                    current.condition_continuation = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return lines
end

local function break_assignment(lines, target, tokens, info, expressions, ecl, dialect, rows)
    local positions = token_positions(lines)
    local statement = statement_on_line(info, tokens, lines, target)
    if not statement then
        return false
    end
    local assign = top_level_assign(tokens, statement.first, statement.last, ecl)
    if not assign or not positions[tokens[assign]] or positions[tokens[assign]].line ~= target then
        return false
    end
    local rhs = code_index(tokens, assign + 1, statement.last)
    if not rhs or not positions[tokens[rhs]] then
        return false
    end
    if tokens[rhs].type == ecl.T.If then
        return false
    end

    local operators = line_binary_operators(lines[target], ecl)
    if #operators > 0 then
        local changed = false
        for _, operator in ipairs(operators) do
            if split_before_token(lines, operator, ecl, true) then
                changed = true
            end
        end
        return changed
    end

    if tokens[rhs].type == ecl.T.LeftCurlyBrace then
        local node = expressions.tables_by_start and expressions.tables_by_start[rhs]
        if node then
            return expand_table_node(lines, node, tokens, info, ecl)
        end
        return false
    end

    local is_call = expressions.calls_by_start and expressions.calls_by_start[rhs] ~= nil

    local available = COLUMN_WIDTH - (indent_width(rows, target) + 4)
    local width = flat_width(tokens, rhs, statement.last, dialect, ecl)
    if is_call and width > available then
        return false
    end
    return split_before_token(lines, tokens[rhs], ecl, not is_call or width <= available)
end

local function reduce_calls_and_tables(lines, target, tokens, info, expressions, ecl)
    local positions = token_positions(lines)
    local call
    local sorted, starts = expressions.calls_sorted, expressions.call_starts
    if sorted then
        local target_line = lines[target]
        local first_index, last_index
        for _, token in ipairs(target_line) do
            local index = token.index
            if index then
                if not first_index or index < first_index then
                    first_index = index
                end
                if not last_index or index > last_index then
                    last_index = index
                end
            end
        end
        if first_index then
            local low, high = 1, #starts
            while low <= high do
                local middle = math.floor((low + high) / 2)
                if starts[middle] < first_index then
                    low = middle + 1
                else
                    high = middle - 1
                end
            end
            local index = low
            while index <= #sorted and starts[index] <= last_index do
                local node = sorted[index]
                local first = starts[index]
                if positions[tokens[first]] and positions[tokens[first]].line == target then
                    local close = info.ending[node.span["end"]]
                    local open = close and matching_open_parenthesis(tokens, close, first, ecl)
                    if open and positions[tokens[open]] and positions[tokens[open]].line == target then
                        call = node
                        break
                    end
                end
                index = index + 1
            end
        end
    else
        for _, node in ipairs(expressions.calls) do
            local first = info.at[node.span.start]
            if first and positions[tokens[first]] and positions[tokens[first]].line == target then
                local close = info.ending[node.span["end"]]
                local open = close and matching_open_parenthesis(tokens, close, first, ecl)
                if open and positions[tokens[open]] and positions[tokens[open]].line == target then
                    if not call or first < info.at[call.span.start] then
                        call = node
                    end
                end
            end
        end
    end
    if call then
        local arguments = call_arguments(call, ecl)
        if tonumber(arguments.values.len) > 1
            or (tonumber(arguments.values.len) == 1
                and arguments.values.ptr[0].kind ~= ecl.const.EXPR_KIND_TABLE
                and arguments.values.ptr[0].kind ~= ecl.const.EXPR_KIND_FUNCTION)
        then
            if expand_call_node(lines, call, tokens, info, ecl) then
                return true
            end
        end
    end

    local table_node
    for _, node in ipairs(expressions.tables) do
        local open = info.at[node.span.start]
        if open and positions[tokens[open]] and positions[tokens[open]].line == target then
            if not table_node or open < info.at[table_node.span.start] then
                table_node = node
            end
        end
    end
    if table_node then
        return expand_table_node(lines, table_node, tokens, info, ecl)
    end
    return false
end

local function collapse_short_tables(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
    local rows
    for _, node in ipairs(expressions.tables) do
        local open = info.at[node.span.start]
        local close = info.ending[node.span["end"]]
        local count = tonumber(node.data.table.len)
        local first_field = count > 0 and field_start_index(info, node.data.table.ptr[0], tokens, ecl) or nil
        local source_multiline = source_has_newline(info, node.span.start + 1, node.span["end"])
        local partial_source = false
        if count > 0 then
            local field = node.data.table.ptr[0]
            local field_start
            if field.kind == ecl.const.FIELD_KIND_KEYED and field.key ~= nil then
                field_start = field.key.span.start
            elseif field.kind == ecl.const.FIELD_KIND_NAMED and field.name ~= nil then
                field_start = field.name.start
            elseif field.value ~= nil then
                field_start = field.value.span.start
            end
            if field_start then
                partial_source = not source_has_newline(info, node.span.start + 1, field_start - 1)
            end
        end
        if source_multiline and partial_source and open and close then
            local positions = token_positions(lines)
            local open_position = positions[tokens[open]]
            local close_position = positions[tokens[close]]
            local first_position = first_field and positions[tokens[first_field]]
            if open_position and close_position and first_position
                and open_position.line < close_position.line
                and open_position.line == first_position.line
            then
                local allowed = true
                for index = open, close do
                    if tokens[index].is_comment or tokens[index].type == ecl.T.Function then
                        allowed = false
                        break
                    end
                end
                if allowed then
                    rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                    local width = line_span_width(lines, rows, tokens, open, close, opts, ecl, dialect)
                    if width <= COLUMN_WIDTH then
                        flatten_token_range(lines, tokens[open], tokens[close], dialect, ecl)
                        rows = nil
                    end
                end
            end
        end
    end
    return lines
end

local function collapse_hugging_calls(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
    local rows
    for _, node in ipairs(expressions.calls) do
        local arguments = call_arguments(node, ecl)
        local count = tonumber(arguments.values.len)
        if arguments.kind == ecl.const.ARGUMENTS_KIND_LIST and count > 0 then
            local last = arguments.values.ptr[count - 1]
            if last.kind == ecl.const.EXPR_KIND_FUNCTION then
                local first = info.at[node.span.start]
                local close = info.ending[node.span["end"]]
                local open = close and matching_open_parenthesis(tokens, close, first, ecl)
                local positions = token_positions(lines)
                local first_argument = info.at[arguments.values.ptr[0].span.start]
                local open_position = open and positions[tokens[open]]
                local argument_position = first_argument and positions[tokens[first_argument]]
                if open_position and argument_position and argument_position.line > open_position.line then
                    local well_formed = true
                    for index = 0, count - 2 do
                        local span = arguments.values.ptr[index].span
                        if arguments.values.ptr[index].kind == ecl.const.EXPR_KIND_FUNCTION
                            or source_has_newline(info, span.start + 1, span["end"])
                        then
                            well_formed = false
                            break
                        end
                    end
                    local fn = last.data["function"]
                    local header_end
                    if tonumber(fn.body.len) > 0 then
                        header_end = info.at[fn.body.ptr[0].span.start]
                        header_end = header_end and header_end - 1
                        while header_end and header_end > open and tokens[header_end].is_trivia do
                            header_end = header_end - 1
                        end
                    end
                    if well_formed and header_end then
                        for index = open, header_end do
                            if tokens[index].is_comment then
                                well_formed = false
                                break
                            end
                        end
                    end
                    if well_formed and header_end then
                        rows = rows or rendered_rows(lines, opts, ecl, if_exprs)
                        local width = line_span_width(lines, rows, tokens, open, header_end, opts, ecl, dialect)
                        local function_end = info.ending[fn.span["end"]]
                        if width <= COLUMN_WIDTH and function_end then
                            flatten_token_range(lines, tokens[open], tokens[header_end], dialect, ecl)
                            flatten_token_range(lines, tokens[function_end], tokens[close], dialect, ecl)
                            rows = nil
                        end
                    end
                end
            end
        end
    end
    return lines
end

local function break_method_chain(lines, target, tokens, info, expressions, ecl)
    local positions = token_positions(lines)
    local candidate
    for _, node in ipairs(expressions.calls) do
        if node.kind == ecl.const.EXPR_KIND_METHOD_CALL then
            local receiver = node.data.method_call.receiver
            local first = info.at[node.span.start]
            local receiver_end = info.ending[receiver.span["end"]]
            local colon = receiver_end and code_index(tokens, receiver_end + 1, #tokens)
            if first and colon and tokens[colon].text == ":" then
                local first_position = positions[tokens[first]]
                local colon_position = positions[tokens[colon]]
                if first_position and colon_position and first_position.line == target
                    and colon_position.line == target
                    and (receiver.kind == ecl.const.EXPR_KIND_CALL
                        or receiver.kind == ecl.const.EXPR_KIND_METHOD_CALL)
                then
                    if not candidate or colon > candidate then
                        candidate = colon
                    end
                end
            end
        end
    end
    return candidate ~= nil and split_before_token(lines, tokens[candidate], ecl, true)
end

local function split_function_body(lines, node, tokens, info, ecl)
    local body = node.data["function"].body
    if tonumber(body.len) == 0 then
        return
    end
    local first = info.at[body.ptr[0].span.start]
    local last = info.ending[node.span["end"]]
    if first and last and tokens[last].type == ecl.T.End then
        split_before_token(lines, tokens[first], ecl)
        split_before_token(lines, tokens[last], ecl)
    end
end

local function expand_for_table(lines, node, tokens, info, expressions, ecl)
    local open = info.at[node.span.start]
    local close = info.ending[node.span["end"]]
    if not open or not close then
        return
    end
    for index = 0, tonumber(node.data.table.len) - 1 do
        local field = node.data.table.ptr[index]
        if field.value and field.value.kind == ecl.const.EXPR_KIND_TABLE then
            expand_table_node(lines, field.value, tokens, info, ecl)
        end
    end
    for index = 0, tonumber(node.data.table.len) - 1 do
        local field = node.data.table.ptr[index]
        local value = field.value
        if value and value.kind == ecl.const.EXPR_KIND_TABLE then
            for inner = 0, tonumber(value.data.table.len) - 1 do
                local child = value.data.table.ptr[inner]
                if child.value and child.value.kind == ecl.const.EXPR_KIND_FUNCTION then
                    split_function_body(lines, child.value, tokens, info, ecl)
                end
            end
        end
    end
    expand_table_node(lines, node, tokens, info, ecl)
end

local function layout_for_in_tables(lines, tokens, info, expressions, ecl)
    for index, token in ipairs(tokens) do
        if not token.is_trivia and token.type == ecl.T.For then
            local depth, in_token, do_token = 0, nil, nil
            for inner = index + 1, #tokens do
                local current = tokens[inner]
                if not current.is_trivia then
                    local kind, opening = delimiter_kind(current, ecl)
                    if kind then
                        if opening then
                            depth = depth + 1
                        else
                            depth = math.max(depth - 1, 0)
                        end
                    elseif depth == 0 and current.type == ecl.T.In then
                        in_token = inner
                    elseif depth == 0 and current.type == ecl.T.Do then
                        do_token = inner
                        break
                    end
                end
            end
            if in_token and do_token then
                local expression = code_index(tokens, in_token + 1, do_token - 1)
                if expression and tokens[expression].type == ecl.T.LeftCurlyBrace then
                    local node
                    for _, table_node in ipairs(expressions.tables) do
                        if info.at[table_node.span.start] == expression then
                            node = table_node
                            break
                        end
                    end
                    if node then
                        local positions = token_positions(lines)
                        local open_position = positions[tokens[expression]]
                        local close = info.ending[node.span["end"]]
                        local close_position = close and positions[tokens[close]]
                        if open_position and close_position and open_position.line < close_position.line then
                            split_before_token(lines, tokens[expression], ecl)
                            split_before_token(lines, tokens[do_token], ecl)
                            expand_for_table(lines, node, tokens, info, expressions, ecl)
                        end
                    end
                end
            end
        end
    end
    return lines
end

local function expand_table_on_line(lines, target, tokens, info, expressions, ecl)
    local positions = token_positions(lines)
    local candidate
    for _, node in ipairs(expressions.tables) do
        local open = info.at[node.span.start]
        local close = info.ending[node.span["end"]]
        if open and close and open < close and tonumber(node.data.table.len) > 0 then
            local open_position = positions[tokens[open]]
            local close_position = positions[tokens[close]]
            if open_position and close_position and open_position.line == target
                and close_position.line == target
            then
                if not candidate or open < candidate then
                    candidate = open
                end
            end
        end
    end
    if candidate then
        for _, node in ipairs(expressions.tables) do
            if info.at[node.span.start] == candidate then
                return expand_table_node(lines, node, tokens, info, ecl)
            end
        end
    end
    return false
end

local function layout_long_lines(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
    if not info then
        return lines
    end
    mark_binary_continuations(lines, tokens, ecl, #expressions.binaries > 0)

    -- A table written with a multiline value (`{ Callback = function() ...`)
    -- is always expanded, even when its first line is short.
    local layout_changed = false
    local changed = true
    while changed do
        changed = false
        for _, node in ipairs(expressions.tables) do
            local open = info.at[node.span.start]
            local close = info.ending[node.span["end"]]
            local count = tonumber(node.data.table.len)
            local first_field = count > 0 and field_start_index(info, node.data.table.ptr[0], tokens, ecl) or nil
            local last_field = count > 0 and field_start_index(info, node.data.table.ptr[count - 1], tokens, ecl) or nil
            local source_multiline = source_has_newline(info, node.span.start + 1, node.span["end"])
            local partial_source = false
            if count > 0 then
                local field = node.data.table.ptr[0]
                local field_start
                if field.kind == ecl.const.FIELD_KIND_KEYED and field.key ~= nil then
                    field_start = field.key.span.start
                elseif field.kind == ecl.const.FIELD_KIND_NAMED and field.name ~= nil then
                    field_start = field.name.start
                elseif field.value ~= nil then
                    field_start = field.value.span.start
                end
                if field_start then
                    partial_source = not source_has_newline(info, node.span.start + 1, field_start - 1)
                end
            end
            local single_nested = false
            if count == 1 and partial_source then
                local field = node.data.table.ptr[0]
                if field.kind == ecl.const.FIELD_KIND_POSITIONAL
                    and field.value and field.value.kind == ecl.const.EXPR_KIND_TABLE
                then
                    single_nested = true
                end
            end
            if source_multiline and partial_source and not single_nested and open and close and first_field then
                local positions = token_positions(lines)
                if positions[tokens[open]] and positions[tokens[first_field]]
                    and positions[tokens[open]].line == positions[tokens[first_field]].line
                and ((last_field and positions[tokens[last_field]]
                        and positions[tokens[last_field]].line > positions[tokens[open]].line)
                    or (positions[tokens[close]] and positions[tokens[close]].line > positions[tokens[open]].line)
                    or table_value_is_multiline(info, node))
                then
                    if expand_table_node(lines, node, tokens, info, ecl) then
                        changed = true
                        layout_changed = true
                    end
                end
            end
        end
    end

    -- A multi-argument call expands when an argument is already multiline:
    -- nested calls, binary conditions, and calls with more than one function
    -- literal. A single trailing table or function still hugs the call.
    changed = true
    while changed do
        changed = false
        local positions = token_positions(lines)
        for _, node in ipairs(expressions.calls) do
            local arguments = call_arguments(node, ecl)
            local count = tonumber(arguments.values.len)
            if count > 1 then
                local first = info.at[node.span.start]
                local close = info.ending[node.span["end"]]
                local first_position = first and positions[tokens[first]]
                local close_position = close and positions[tokens[close]]
                if first_position and close_position and first_position.line < close_position.line then
                    local function_count = 0
                    local table_count = 0
                    local partial_table = false
                    local other_multiline = false
                    for index = 0, count - 1 do
                        local argument = arguments.values.ptr[index]
                        local start = info.at[argument.span.start]
                        local finish = info.ending[argument.span["end"]]
                        local start_position = start and positions[tokens[start]]
                        local finish_position = finish and positions[tokens[finish]]
                        local multiline = start_position and finish_position
                            and start_position.line < finish_position.line
                        if argument.kind == ecl.const.EXPR_KIND_FUNCTION then
                            if multiline then
                                function_count = function_count + 1
                            end
                        elseif argument.kind == ecl.const.EXPR_KIND_TABLE then
                            if multiline then
                                table_count = table_count + 1
                                local field = tonumber(argument.data.table.len) > 0
                                    and argument.data.table.ptr[0] or nil
                                local field_start = field and field_source_start(field, ecl) or nil
                                if field_start and not source_has_newline(info, argument.span.start + 1, field_start - 1) then
                                    partial_table = true
                                end
                            end
                        elseif multiline then
                            other_multiline = true
                        end
                    end
                    local hug = function_count + table_count > 0 and function_count <= 1
                        and not partial_table and not other_multiline
                    if not hug and expand_call_node(lines, node, tokens, info, ecl) then
                        changed = true
                        layout_changed = true
                    end
                end
            end
        end
    end
    local renderer = new_reindenter(opts, ecl, if_exprs, false)
    local cursor = 1
    while cursor <= #lines do
        local checkpoint = renderer.checkpoint()
        local row = renderer.render_line(lines[cursor])
        local did = false
        if not row:find("\n", 1, true) and not fits_line(row) then
            did = break_condition(lines, cursor, ecl, if_exprs)
            if not did then
                did = break_assignment(lines, cursor, tokens, info, expressions, ecl, dialect, { [cursor] = row })
            end
            if not did then
                did = break_method_chain(lines, cursor, tokens, info, expressions, ecl)
            end
            if not did then
                local operators = line_binary_operators(lines[cursor], ecl)
                local first = first_code_on_line(lines[cursor], ecl)
                local line_positions = {}
                for position, token in ipairs(lines[cursor]) do
                    line_positions[token] = position
                end
                local first_operator, first_operator_position
                local previous
                for position, token in ipairs(lines[cursor]) do
                    if token.kind ~= ecl.WHITESPACE then
                        if token.type ~= nil and binary_precedence(token.type, ecl)
                            and not is_unary(token, previous, ecl) and not first_operator
                        then
                            first_operator = token
                            first_operator_position = position
                        end
                        previous = token
                    end
                end
                local first_operator_is_lowest = false
                for _, operator in ipairs(operators) do
                    if operator == first_operator then
                        first_operator_is_lowest = true
                        break
                    end
                end
                local bare_call = false
                if first_operator_is_lowest and first_operator_position then
                    local before
                    for position = first_operator_position - 1, 1, -1 do
                        if lines[cursor][position].kind ~= ecl.WHITESPACE then
                            before = lines[cursor][position]
                            break
                        end
                    end
                    if before and before.type == ecl.T.RightParenthesis then
                        for _, node in ipairs(expressions.calls) do
                            local call_end = info.ending[node.span["end"]]
                            local call_first = info.at[node.span.start]
                            if call_end and tokens[call_end] == before
                                and call_first and line_positions[tokens[call_first]]
                            then
                                bare_call = true
                                break
                            end
                        end
                    end
                end
                if bare_call then
                    did = reduce_calls_and_tables(lines, cursor, tokens, info, expressions, ecl)
                end
                if not did then
                    for _, operator in ipairs(operators) do
                        if split_before_token(lines, operator, ecl, true) then
                            if first and first ~= operator and binary_precedence(first.type, ecl) then
                                operator.nested_binary_continuation = true
                            end
                            did = true
                        end
                    end
                end
            end
            if not did and first_code_on_line(lines[cursor], ecl)
                and first_code_on_line(lines[cursor], ecl).type == ecl.T.LeftCurlyBrace
            then
                did = expand_table_on_line(lines, cursor, tokens, info, expressions, ecl)
            end
            if not did then
                did = reduce_calls_and_tables(lines, cursor, tokens, info, expressions, ecl)
            end
            if not did then
                did = expand_table_on_line(lines, cursor, tokens, info, expressions, ecl)
            end
            if not did then
                did = break_function_header(lines, cursor, tokens, info, expressions, ecl)
            end
        end
        if did then
            layout_changed = true
            renderer.restore(checkpoint)
        else
            cursor = cursor + 1
        end
    end
    if layout_changed then
        mark_binary_continuations(lines, tokens, ecl, #expressions.binaries > 0)
    end
    return lines
end

local function assignment_ahead(code, first, parens, ecl)
    if parens ~= 0 then
        return false
    end
    local T = ecl.T
    if code[first].type ~= T.Identifier or code[first].text == "type" then
        return false
    end
    local index = first + 1
    local limit = math.min(#code, first + 15)
    while index <= limit do
        local tok = code[index]
        if tok.type == T.Assign or (tok.type >= T.PlusAssign and tok.type <= T.ShiftRightAssign) then
            return true
        end
        if tok.type == T.Dot or tok.type == T.Colon then
            index = index + 1
        elseif tok.type == T.Comma then
            index = index + 1
            if code[index] and code[index].type == T.Identifier then
                index = index + 1
            else
                return false
            end
        elseif tok.type == T.LeftSquareBracket then
            local depth = 1
            index = index + 1
            while index <= #code and depth > 0 do
                if code[index].type == T.LeftSquareBracket then
                    depth = depth + 1
                elseif code[index].type == T.RightSquareBracket then
                    depth = depth - 1
                end
                index = index + 1
            end
        else
            return false
        end
    end
    return false
end

local function strict_split_lines(tokens, dialect, ecl, if_exprs, info)
    local T = ecl.T
    local statement_starters = {
        [T.Local] = true,
        [T.For] = true,
        [T.While] = true,
        [T.Repeat] = true,
        [T.Do] = true,
        [T.Return] = true,
        [T.Break] = true,
        [T.Goto] = true,
    }
    local name_like = {
        [T.Identifier] = true,
        [T.Integer] = true,
        [T.Float] = true,
        [T.String] = true,
        [T.LongString] = true,
        [T.InterpolatedString] = true,
    }
    layout_flags.other = false
    local code = new_table(#tokens, 0)
    local curly_tokens = {}
    local pending_newlines = 0
    local curly_depth = 0
    for index, token in ipairs(tokens) do
        if token.kind == ecl.NEWLINE then
            pending_newlines = pending_newlines + 1
        elseif token.kind == ecl.WHITESPACE then
        elseif token.type == T.Semicolon then
            if curly_depth > 0 then
                token.index = index
                token.text = ","
                token.orig_newlines = pending_newlines
                pending_newlines = 0
                code[#code + 1] = token
            end
        else
            token.index = index
            if token.type == T.LeftCurlyBrace then
                curly_depth = curly_depth + 1
                curly_tokens[#curly_tokens + 1] = token
            elseif token.type == T.RightCurlyBrace then
                curly_depth = math.max(curly_depth - 1, 0)
                curly_tokens[#curly_tokens + 1] = token
            end
            token.orig_newlines = pending_newlines
            pending_newlines = 0
            code[#code + 1] = token
        end
    end
    local trailing_newlines = pending_newlines

    local lines = {}
    local current_line = {}
    local line_count = 0
    local line_total = 0
    local newlines_emitted = 0
    local space_token = new_space(ecl)
    local function newline()
        line_total = line_total + 1
        lines[line_total] = current_line
        current_line = {}
        line_count = 0
        newlines_emitted = newlines_emitted + 1
    end

    -- Contextual keywords start a statement only where the parser says one does.
    local statement_start
    if not info then
        info = scope.index(tokens, ecl, dialect)
    end
    local if_nodes, structural_spans = {}, {}
    local tables, calls, binaries, functions, returns, cast_parens = {}, {}, {}, {}, {}, {}
    local function_expressions = {}
    local tables_by_start, calls_by_start
    local calls_sorted, call_starts
    if info then
        statement_start = {}
        for _, statement in ipairs(info.statements) do
            if statement.first then
                statement_start[tokens[statement.first]] = true
            end
        end

        local collected = info.syntax
        if collected then
            if_nodes = collected.if_nodes
            tables = collected.tables
            calls = collected.calls
            binaries = collected.binaries
            functions = collected.functions
            function_expressions = collected.function_expressions
            returns = collected.returns
            cast_parens = collected.cast_parens
        else
            local K = ecl.const
            syntax.walk(info, ecl, function(node)
                if node.kind == K.STMT_KIND_LOCAL_FUNCTION then
                    functions[#functions + 1] = node.data.local_function.body
                elseif node.kind == K.STMT_KIND_FUNCTION then
                    functions[#functions + 1] = node.data["function"].body
                elseif node.kind == K.STMT_KIND_RETURN then
                    returns[#returns + 1] = node
                end
            end, function(node)
                local kind = node.kind
                if kind == K.EXPR_KIND_IF_ELSE then
                    if_nodes[#if_nodes + 1] = node
                elseif kind == K.EXPR_KIND_TABLE then
                    tables[#tables + 1] = node
                elseif kind == K.EXPR_KIND_CALL or kind == K.EXPR_KIND_METHOD_CALL then
                    calls[#calls + 1] = node
                elseif kind == K.EXPR_KIND_BINARY then
                    binaries[#binaries + 1] = node
                elseif kind == K.EXPR_KIND_FUNCTION then
                    functions[#functions + 1] = node.data["function"]
                    function_expressions[#function_expressions + 1] = node
                end
                if kind == K.EXPR_KIND_PAREN and node.data.paren.kind == K.EXPR_KIND_CAST then
                    cast_parens[#cast_parens + 1] = node
                end
            end)
        end

        tables_by_start, calls_by_start = {}, {}
        for _, node in ipairs(tables) do
            local first = info.at[node.span.start]
            if first and not tables_by_start[first] then
                tables_by_start[first] = node
            end
        end
        for _, node in ipairs(calls) do
            local first = info.at[node.span.start]
            if first and not calls_by_start[first] then
                calls_by_start[first] = node
            end
        end
        for _, node in ipairs(tables) do
            local span = node.span
            if source_has_newline(info, span.start + 1, span["end"]) then
                structural_spans[#structural_spans + 1] = span
            end
        end
        for _, node in ipairs(function_expressions) do
            local span = node.span
            if source_has_newline(info, span.start + 1, span["end"]) then
                structural_spans[#structural_spans + 1] = span
            end
        end

        calls_sorted, call_starts = {}, {}
        local ordered, last_start = true, 0
        for _, node in ipairs(calls) do
            local first = info.at[node.span.start]
            if first then
                if first < last_start then
                    ordered = false
                end
                last_start = first
                calls_sorted[#calls_sorted + 1] = node
                call_starts[#call_starts + 1] = first
            end
        end
        if not ordered then
            local decorated = {}
            for order = 1, #calls_sorted do
                decorated[order] = {
                    node = calls_sorted[order],
                    first = call_starts[order],
                    order = order,
                }
            end
            table.sort(decorated, function(a, b)
                if a.first == b.first then
                    return a.order < b.order
                end
                return a.first < b.first
            end)
            for index, item in ipairs(decorated) do
                calls_sorted[index] = item.node
                call_starts[index] = item.first
            end
        end
    end

    local previous, before_previous = nil, nil
    local last_code = nil
    local parens = 0
    local function_parens = {}
    local header_keyword = nil
    local function_pending = false

    for index, token in ipairs(code) do
        local text = token.text
        local next_token = code[index + 1]

        local starts_statement = statement_starters[token.type] == true
        if not starts_statement and token.type == T.Identifier
            and (text == "export" or text == "continue" or text == "type")
        then
            if statement_start then
                starts_statement = statement_start[token] == true
            elseif dialect == "luau" then
                starts_statement = text ~= "type" or not previous or previous.text ~= "export"
            end
        end

        if token.type == T.Function then
            starts_statement = not previous
            or (previous.type ~= T.Local
                and previous.type ~= T.Assign
                and previous.type ~= T.Return
                and previous.type ~= T.LeftParenthesis
                and previous.type ~= T.Comma
                and previous.type ~= T.LeftCurlyBrace)
        elseif token.type == T.If then
            starts_statement = not if_exprs[token]
            and (not previous
                or (previous.type ~= T.Return
                    and previous.type ~= T.Assign
                    and previous.type ~= T.LeftParenthesis
                    and previous.type ~= T.Comma
                    and previous.type ~= T.LeftCurlyBrace))
        elseif token.type == T.Do then
            starts_statement = header_keyword == nil
        end

        local rule_wants_newline = false
        if line_count > 0 and previous then
            if starts_statement
                or token.type == T.End
                or (token.type == T.Else and not if_exprs[token])
                or (token.type == T.Elseif and not if_exprs[token])
                or token.type == T.Until
            then
                rule_wants_newline = true
            elseif name_like[token.type] and can_end_expression(previous, ecl)
                and not token.in_type
                and not previous.in_type
                and not (
                    previous.type == T.Return
                    or previous.type == T.Local
                    or previous.text == "export"
                    or previous.text == "type"
                    or previous.type == T.Function
                    or (previous.type == T.TripleDot and token.type == T.Identifier)
                )
            then
                rule_wants_newline = true
            elseif token.type == T.Identifier and assignment_ahead(code, index, parens, ecl)
                and can_end_expression(previous, ecl)
                and not (
                    previous.type == T.Return
                    or previous.type == T.Local
                    or previous.text == "export"
                    or previous.text == "type"
                    or previous.type == T.Function
                )
            then
                rule_wants_newline = true
            end
        end

        local needed_newlines = token.orig_newlines or 0
        if rule_wants_newline and needed_newlines < 1 then
            needed_newlines = 1
        end
        while newlines_emitted < needed_newlines do
            newline()
        end
        if line_count == 0 and last_code then
            if last_code.type == T.Assign
                or (last_code.type >= T.PlusAssign and last_code.type <= T.ShiftRightAssign)
                or token.text == ":"
            then
                layout_flags.other = true
            end
        end

        if line_count > 0 and previous then
            local space
            if not previous.is_comment and not token.is_comment
                and not token.angle_open and not token.angle_close
                and not previous.angle_open and not previous.angle_close
            then
                local ct, pt = token.type, previous.type
                local by_current = SPACE_RULES[pt]
                if not by_current then
                    by_current = {}
                    SPACE_RULES[pt] = by_current
                end
                local value = by_current[ct]
                if value == nil then
                    value = static_space_rule(pt, ct, T)
                    if value == nil then
                        value = SPACE_RULE_NONE
                    end
                    by_current[ct] = value
                end
                if value ~= SPACE_RULE_NONE then
                    space = value
                end
            end
            if space == nil then
                space = strict_space(previous, token, before_previous, next_token, dialect, ecl)
            end
            if space then
                line_count = line_count + 1
                current_line[line_count] = space_token
            end
        end

        line_count = line_count + 1
        current_line[line_count] = token
        if not token.is_comment then
            last_code = token
        end
        newlines_emitted = 0

        if token.kind == ecl.SHEBANG or token.kind == ecl.LINE_COMMENT then
            newline()
        elseif token.kind == ecl.SYNTAX then
            if token.type == T.LeftParenthesis then
                parens = parens + 1
                function_parens[#function_parens + 1] = (previous and previous.type == T.Function) or function_pending
                function_pending = false
            elseif token.type == T.RightParenthesis then
                local is_function = function_parens[#function_parens]
                function_parens[#function_parens] = nil
                parens = math.max(parens - 1, 0)
                -- A Luau return annotation continues the function header;
                -- breaking at the parameter list would split it from its `:`.
                if is_function and not (next_token and next_token.type == T.Colon) then
                    newline()
                end
            elseif token.type == T.Function then
                function_pending = true
            elseif (token.type == T.Then or token.type == T.Do or token.type == T.Repeat) and not if_exprs[token] then
                if not (next_token and next_token.is_comment and (next_token.orig_newlines or 0) == 0) then
                    newline()
                end
            elseif token.type == T.Semicolon and token.text == ";" then
                newline()
            elseif token.type == T.Else and not if_exprs[token] then
                if not (next_token and next_token.is_comment and (next_token.orig_newlines or 0) == 0) then
                    newline()
                end
            end
            if token.type == T.For or token.type == T.While then
                header_keyword = text
            elseif token.type == T.Do then
                header_keyword = nil
            end
            before_previous, previous = previous, token
        else
            before_previous, previous = previous, token
        end
    end

    if line_count > 0 then
        newline()
    end
    while newlines_emitted < trailing_newlines do
        newline()
    end

    if not info then
        local parts = {}
        for _, token in ipairs(tokens) do
            parts[#parts + 1] = token.text
        end
        info = { source = table.concat(parts), statements = {}, at = {}, ending = {} }
    end

    return lines, info, if_nodes, structural_spans, {
        tables = tables,
        calls = calls,
        binaries = binaries,
        functions = functions,
        returns = returns,
        parens = cast_parens,
        tables_by_start = tables_by_start,
        calls_by_start = calls_by_start,
        calls_sorted = calls_sorted,
        call_starts = call_starts,
        curlies = curly_tokens,
        comma_done = {},
    }
end

local function mark_compact_nested_tables(lines, tokens, info, expressions, ecl)
    local positions = token_positions(lines)
    local changed = false
    for _, node in ipairs(expressions.tables) do
        if tonumber(node.data.table.len) == 1 then
            local field = node.data.table.ptr[0]
            if field.kind == ecl.const.FIELD_KIND_POSITIONAL
                and field.value and field.value.kind == ecl.const.EXPR_KIND_TABLE
            then
                local open = info.at[node.span.start]
                local close = info.ending[node.span["end"]]
                local field_token = field_start_index(info, field, tokens, ecl)
                local field_start = field_source_start(field, ecl)
                local compact = field_start and not source_has_newline(info, node.span.start + 1, field_start - 1)
                if compact and open and close and field_token and positions[tokens[open]]
                    and positions[tokens[field_token]]
                    and positions[tokens[open]].line == positions[tokens[field_token]].line
                then
                    tokens[open].uncounted = true
                    tokens[open].no_trailing_comma = true
                    tokens[close].uncounted = true
                    if not changed or positions[tokens[open]].line < changed then
                        changed = positions[tokens[open]].line
                    end
                end
            end
        end
    end
    if changed then
        mark_render_dirty(lines, changed)
    end
    return lines
end

--- StyLua separates every entry of a multiline table with a comma, including
--- the last one, and keeps the comma before a trailing comment.
local function add_trailing_commas(lines, ecl, tokens, expressions)
    local T = ecl.T
    local syntax = ecl.SYNTAX
    local curlies = expressions.curlies or {}
    local done = expressions.comma_done
    local positions = token_positions(lines)
    local stack = {}
    local inserts = {}

    for _, token in ipairs(curlies) do
        if token.type == T.LeftCurlyBrace then
            stack[#stack + 1] = token
        elseif token.type == T.RightCurlyBrace then
            local open = table.remove(stack)
            if open and not done[open] then
                local open_position = positions[open]
                local close_position = positions[token]
                if open_position and close_position and open_position.line < close_position.line then
                    done[open] = true
                    if not open.no_trailing_comma then
                        local index = (token.index or 0) - 1
                        local last
                        while index >= 1 do
                            local candidate = tokens[index]
                            if not candidate.is_trivia and positions[candidate] then
                                last = candidate
                                break
                            end
                            index = index - 1
                        end
                        if last and last ~= open then
                            local at = positions[last]
                            if last.text == "," then
                                -- Already separated.
                            elseif last.text == ";" then
                                last.text = ","
                                inserts[#inserts + 1] = {
                                    line = at.line,
                                    index = at.position,
                                    token = last,
                                    replace = true,
                                }
                            else
                                inserts[#inserts + 1] = {
                                    line = at.line,
                                    index = at.position,
                                    token = last,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(inserts, function(a, b)
        if a.line == b.line then
            return a.index > b.index
        end
        return a.line > b.line
    end)
    local dirty_from
    local dirty_lines
    for _, at in ipairs(inserts) do
        if not dirty_from or at.line < dirty_from then
            dirty_from = at.line
        end
        local line = lines[at.line]
        if not at.replace then
            table.insert(line, at.index + 1, {
                kind = syntax,
                type = T.Comma,
                text = ",",
                is_trivia = false,
                is_comment = false,
            })
            line.__body = nil
        else
            line.__body = nil
        end
        dirty_lines = dirty_lines or {}
        dirty_lines[at.line] = true
    end
    if #inserts > 0 then
        if lines.__positions and not lines.__deferred_from then
            for line_index in pairs(dirty_lines) do
                reindex_line_positions(lines, line_index)
            end
        else
            lines.__positions = nil
            lines.__deferred_from = nil
        end
        mark_render_dirty(lines, dirty_from or 1)
    end
    return lines
end

function printer.reindent(tokens, opts, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    opts = opts or {}
    if opts.strip_comments then
        local kept = {}
        for _, token in ipairs(tokens) do
            if not token.is_comment then
                kept[#kept + 1] = token
            end
        end
        tokens = kept
    end
    local if_exprs = find_if_expressions(tokens, ecl)
    local has_trailing_newline = false
    for i = #tokens, 1, -1 do
        if tokens[i].kind == ecl.NEWLINE then
            has_trailing_newline = true
            break
        elseif not tokens[i].is_trivia then
            break
        end
    end
    local lines
    if opts.force then
        local dialect = opts.dialect or "lua"
        local info = scope.index(tokens, ecl, dialect)
        annotate_types(tokens, dialect, ecl, info)
        local if_nodes, structural_spans, expressions
        lines, info, if_nodes, structural_spans, expressions = strict_split_lines(tokens, dialect, ecl, if_exprs, info)
        lines = collapse_blank_lines(lines, ecl)
        if not info or info.has_conditionals then
            lines = remove_redundant_condition_parens(lines, tokens, ecl)
            lines = collapse_blank_lines(lines, ecl)
        end
        enable_lazy_positions(lines, tokens)
        lines = remove_redundant_cast_parens(lines, tokens, info, expressions.parens, ecl)
        lines = collapse_empty_functions(lines, tokens, info, expressions.functions, dialect, ecl)
        lines = layout_if_expressions(lines, tokens, info, if_nodes, structural_spans, opts, ecl, if_exprs, dialect)
        lines = collapse_short_tables(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        lines = normalize_multiline_tables(lines, tokens, info, expressions, ecl)
        lines = collapse_hugging_calls(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        if not info or info.has_conditionals then
            lines = normalize_multiline_conditions(lines, tokens, opts, ecl, if_exprs, dialect)
        end
        if #expressions.binaries > 0 then
            lines = collapse_binary_expressions(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        end
        lines = collapse_return_statements(lines, tokens, info, expressions.returns, opts, ecl, if_exprs, dialect)
        lines = collapse_function_headers(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        if not info or not info.alias_count or info.alias_count > 0 then
            lines = layout_type_aliases(lines, tokens, opts, ecl, if_exprs, dialect)
        end
        lines = mark_compact_nested_tables(lines, tokens, info, expressions, ecl)
        lines = add_trailing_commas(lines, ecl, tokens, expressions)
        if not info or info.has_for then
            lines = layout_for_in_tables(lines, tokens, info, expressions, ecl)
        end
        lines = layout_long_lines(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        lines = add_trailing_commas(lines, ecl, tokens, expressions)
        lines = mark_if_expression_indents(lines, tokens, info, if_nodes, ecl)
        return reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline, nil, true), nil, source_code
    else
        lines = split_lines(tokens, ecl)
    end
    return reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline), nil, source_code
end

function printer.format(source, dialect, opts, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    opts = opts or {}
    local tokens, err, parsed, token_positions_map
    if opts.force then
        parsed, err = ecl.parse(source, dialect)
        if parsed then
            local at, ending
            tokens, at, ending = parsed:tokens(true, true)
            if not opts.strip_comments then
                token_positions_map = { at = at, ending = ending }
            end
        else
            tokens, err = ecl.tokens(source, dialect, true)
        end
    else
        tokens, err = ecl.tokens(source, dialect)
    end
    if not tokens then
        return nil, err
    end
    if opts.strip_comments then
        local kept = {}
        for _, token in ipairs(tokens) do
            if not token.is_comment then
                kept[#kept + 1] = token
            end
        end
        tokens = kept
    end
    local source_code
    if opts.code then
        source_code = opts.code(tokens, dialect, ecl)
    end
    local info
    if opts.force and might_have_sugar_calls(tokens, ecl) then
        tokens, info = normalize_sugar_calls(tokens, dialect, ecl, source, parsed)
        if not info then
            parsed = nil
            token_positions_map = nil
        end
    end
    local if_exprs = find_if_expressions(tokens, ecl)
    local has_trailing_newline = false
    for i = #tokens, 1, -1 do
        if tokens[i].kind == ecl.NEWLINE then
            has_trailing_newline = true
            break
        elseif not tokens[i].is_trivia then
            break
        end
    end
    local lines
    if opts.force then
        if not info then
            info = scope.index(tokens, ecl, dialect, source, parsed, token_positions_map)
        end
        annotate_types(tokens, dialect, ecl, info)
        local if_nodes, structural_spans, expressions
        lines, info, if_nodes, structural_spans, expressions = strict_split_lines(tokens, dialect, ecl, if_exprs, info)
        lines = collapse_blank_lines(lines, ecl)
        if not info or info.has_conditionals then
            lines = remove_redundant_condition_parens(lines, tokens, ecl)
            lines = collapse_blank_lines(lines, ecl)
        end
        enable_lazy_positions(lines, tokens)
        lines = remove_redundant_cast_parens(lines, tokens, info, expressions.parens, ecl)
        lines = collapse_empty_functions(lines, tokens, info, expressions.functions, dialect, ecl)
        lines = layout_if_expressions(lines, tokens, info, if_nodes, structural_spans, opts, ecl, if_exprs, dialect)
        lines = collapse_short_tables(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        lines = normalize_multiline_tables(lines, tokens, info, expressions, ecl)
        lines = collapse_hugging_calls(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        if not info or info.has_conditionals then
            lines = normalize_multiline_conditions(lines, tokens, opts, ecl, if_exprs, dialect)
        end
        if #expressions.binaries > 0 then
            lines = collapse_binary_expressions(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        end
        lines = collapse_return_statements(lines, tokens, info, expressions.returns, opts, ecl, if_exprs, dialect)
        lines = collapse_function_headers(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        if not info or not info.alias_count or info.alias_count > 0 then
            lines = layout_type_aliases(lines, tokens, opts, ecl, if_exprs, dialect)
        end
        lines = mark_compact_nested_tables(lines, tokens, info, expressions, ecl)
        lines = add_trailing_commas(lines, ecl, tokens, expressions)
        if not info or info.has_for then
            lines = layout_for_in_tables(lines, tokens, info, expressions, ecl)
        end
        lines = layout_long_lines(lines, tokens, info, expressions, opts, ecl, if_exprs, dialect)
        lines = add_trailing_commas(lines, ecl, tokens, expressions)
        lines = mark_if_expression_indents(lines, tokens, info, if_nodes, ecl)
        return reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline, nil, true)
    else
        lines = split_lines(tokens, ecl)
    end
    return reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline)
end

return printer
