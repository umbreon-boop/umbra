local printer = {}

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
    if not tok or tok.text == "export" or tok.text == "type" then
        return false
    end
    local T = ecl.T
    local t = tok.type
    return t == T.Identifier
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
end

local function is_unary(tok, previous, ecl)
    if not tok then
        return false
    end
    local T = ecl.T
    return (tok.type == T.Plus or tok.type == T.Minus or tok.type == T.Tilde) and not can_end_expression(previous, ecl)
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

local function opens_block(token, ecl, if_exprs)
    if if_exprs and if_exprs[token] then
        return false
    end
    return is_type(token, "Then", ecl)
    or is_type(token, "Do", ecl)
    or is_type(token, "Repeat", ecl)
    or is_type(token, "Else", ecl)
    or is_type(token, "Function", ecl)
end

local function closes_block(token, ecl, if_exprs)
    if if_exprs and if_exprs[token] then
        return false
    end
    return is_type(token, "End", ecl)
    or is_type(token, "Until", ecl)
    or is_type(token, "Else", ecl)
    or is_type(token, "Elseif", ecl)
end

local function delimiter_kind(token, ecl)
    if is_type(token, "LeftCurlyBrace", ecl) then
        return "curly", true
    elseif is_type(token, "LeftParenthesis", ecl) then
        return "parenthesis", true
    elseif is_type(token, "LeftSquareBracket", ecl) then
        return "square", true
    elseif is_type(token, "RightCurlyBrace", ecl) then
        return "curly", false
    elseif is_type(token, "RightParenthesis", ecl) then
        return "parenthesis", false
    elseif is_type(token, "RightSquareBracket", ecl) then
        return "square", false
    end
end

local function has_inline_container(body, position, ecl)
    for index = position + 1, #body do
        local token = body[index]
        if is_type(token, "RightParenthesis", ecl) then
            return false
        end
        if is_type(token, "Function", ecl) or is_type(token, "LeftCurlyBrace", ecl) then
            return true
        end
    end
    return false
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
    return is_type(token, "If", ecl)
    or is_type(token, "Elseif", ecl)
    or is_type(token, "For", ecl)
    or is_type(token, "While", ecl)
end

local function contains_header_end(body, ecl)
    for _, token in ipairs(body) do
        if is_type(token, "Then", ecl) or is_type(token, "Do", ecl) then
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

local function reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline)
    opts = opts or {}
    local unit = opts.indent or "\t"
    local out, depth = {}, 0
    local delimiter_stack = {}
    local continued_header = false
    local continued_if_expr = false
    local if_expr_else_pending = false

    for _, line in ipairs(lines) do
        local body, seen = {}, false
        for _, token in ipairs(line) do
            if seen or token.kind ~= ecl.WHITESPACE then
                seen = true
                body[#body + 1] = token
            end
        end
        if opts.force then
            while #body > 0 and body[#body].kind == ecl.WHITESPACE do
                body[#body] = nil
            end
        end

        if #body == 0 then
            out[#out + 1] = ""
        else
            if closes_block(body[1], ecl, if_exprs) then
                depth = depth - 1
            end
            local first_kind, first_open = delimiter_kind(body[1], ecl)
            if first_kind and not first_open then
                local delimiter = pop_delimiter(delimiter_stack, first_kind)
                if delimiter and delimiter.counted then
                    depth = depth - 1
                end
            end
            local indent_depth = depth
            if continued_header and not is_type(body[1], "Then", ecl) and not is_type(body[1], "Do", ecl) then
                indent_depth = indent_depth + 1
            end
            if continued_if_expr then
                if STATEMENT_STARTS[body[1].text] then
                    continued_if_expr = false
                    if_expr_else_pending = false
                elseif if_exprs[body[1]] and (body[1].text == "else" or body[1].text == "elseif") then
                    -- Align else / elseif with the if
                else
                    indent_depth = indent_depth + 1
                end
            end
            local indent = unit:rep(math.max(indent_depth, 0))
            local pieces = { indent }
            local has_if_expr_if = false
            local if_expr_else_token = nil
            for position, token in ipairs(body) do
                if if_exprs[token] then
                    if token.text == "if" then
                        has_if_expr_if = true
                    elseif token.text == "else" then
                        if_expr_else_token = token
                    end
                end

                if token.kind == ecl.LONG_COMMENT then
                    pieces[#pieces + 1] = reflow_long_comment(token.text, indent, unit)
                elseif token.kind == ecl.LINE_COMMENT and opts.force then
                    pieces[#pieces + 1] = token.text:gsub("[ \t]+$", "")
                else
                    pieces[#pieces + 1] = token.text
                end

                if position > 1 and closes_block(token, ecl, if_exprs) then
                    depth = depth - 1
                end

                local kind, opening = delimiter_kind(token, ecl)
                if kind and opening then
                    local counted = not (kind == "parenthesis" and has_inline_container(body, position, ecl))
                    delimiter_stack[#delimiter_stack + 1] = { kind = kind, counted = counted }
                    if counted then
                        depth = depth + 1
                    end
                elseif kind and position > 1 then
                    local delimiter = pop_delimiter(delimiter_stack, kind)
                    if delimiter and delimiter.counted then
                        depth = depth - 1
                    end
                end

                if opens_block(token, ecl, if_exprs) then
                    depth = depth + 1
                end
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
            out[#out + 1] = table.concat(pieces)
        end
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
    if current.type == T.DoubleColon or previous.type == T.DoubleColon then
        return true
    end
    if current.type == T.Comma or current.type == T.Semicolon or current.type == T.RightParenthesis or current.type == T.RightSquareBracket or current.type == T.RightCurlyBrace then
        if current.type == T.RightCurlyBrace then
            return previous.type ~= T.LeftCurlyBrace
        end
        return false
    end
    if previous.type == T.LeftParenthesis or previous.type == T.LeftSquareBracket or previous.type == T.Dot then
        return false
    end
    if previous.type == T.Colon then
        if before_previous
            and not (before_previous.type == T.Local or before_previous.type == T.Comma or before_previous.type == T.LeftParenthesis or before_previous.type == T.LeftCurlyBrace)
            and next_token
            and (next_token.type == T.LeftParenthesis
                or next_token.type == T.LeftCurlyBrace
                or next_token.type == T.String
                or next_token.type == T.LongString
                or next_token.type == T.InterpolatedString)
        then
            return false
        else
            return true
        end
    end
    if current.type == T.Colon then
        return false
    end
    if current.type == T.LeftParenthesis then
        if previous.type == T.If
            or previous.type == T.Elseif
            or previous.type == T.For
            or previous.type == T.While
            or previous.type == T.Until
            or previous.type == T.Return
            or previous.type == T.In
            or previous.type == T.Assign
            or previous.type == T.Comma
            or previous.type == T.Not
            or (is_binary_op(previous.type, T) and not is_unary(previous, before_previous, ecl))
        then
            return true
        end
        return false
    end
    if current.type == T.LeftCurlyBrace then
        return previous.type ~= T.LeftParenthesis and previous.type ~= T.LeftSquareBracket
    end
    if previous.type == T.LeftCurlyBrace then
        return current.type ~= T.RightCurlyBrace
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
    return ecl.needs_space(previous.text, current.text, dialect)
end

--- Whether `--force` puts a space between two tokens: as the layout rules
--- prefer, but never joining two tokens into one, as `[` and `[=[s]=]` would.
local function strict_space(previous, current, before_previous, next_token, dialect, ecl)
    return preferred_space(previous, current, before_previous, next_token, dialect, ecl)
        or (previous ~= nil and not previous.is_trivia and ecl.needs_space(previous.text, current.text, dialect))
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

local function strict_split_lines(tokens, dialect, ecl, if_exprs)
    local T = ecl.T
    local code = {}
    local pending_newlines = 0
    for _, token in ipairs(tokens) do
        if token.kind == ecl.NEWLINE then
            pending_newlines = pending_newlines + 1
        elseif token.kind == ecl.WHITESPACE then
        else
            token.orig_newlines = pending_newlines
            pending_newlines = 0
            code[#code + 1] = token
        end
    end
    local trailing_newlines = pending_newlines

    local lines = {}
    local current_line = {}
    local newlines_emitted = 0
    local function newline()
        lines[#lines + 1] = current_line
        current_line = {}
        newlines_emitted = newlines_emitted + 1
    end

    -- Contextual keywords start a statement only where the parser says one does.
    local statement_start
    local info = require("process.scope").resolve(tokens, ecl, dialect)
    if info then
        statement_start = {}
        for _, statement in ipairs(info.statements) do
            if statement.first then
                statement_start[tokens[statement.first]] = true
            end
        end
    end

    local previous, before_previous = nil, nil
    local parens = 0
    local function_parens = {}
    local header_keyword = nil
    local function_pending = false

    for index, token in ipairs(code) do
        local text = token.text
        local next_token = code[index + 1]

        local starts_statement = false
        if token.type == T.Local
            or token.type == T.For
            or token.type == T.While
            or token.type == T.Repeat
            or token.type == T.Do
            or token.type == T.Return
            or token.type == T.Break
            or token.type == T.Goto
        then
            starts_statement = true
        elseif token.type == T.Identifier and (text == "export" or text == "continue" or text == "type") then
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
        if #current_line > 0 and previous then
            if starts_statement
                or token.type == T.End
                or (token.type == T.Else and not if_exprs[token])
                or (token.type == T.Elseif and not if_exprs[token])
                or token.type == T.Until
            then
                rule_wants_newline = true
            elseif can_end_expression(previous, ecl)
                and (token.type == T.Identifier
                    or token.type == T.Integer
                    or token.type == T.Float
                    or token.type == T.String
                    or token.type == T.LongString
                    or token.type == T.InterpolatedString)
                and token.type ~= T.Then
                and token.type ~= T.Do
                and token.type ~= T.And
                and token.type ~= T.Or
                and token.type ~= T.In
                and token.type ~= T.Until
                and not (
                    previous.type == T.Return
                    or previous.type == T.Local
                    or previous.text == "export"
                    or previous.text == "type"
                    or previous.type == T.Function
                )
            then
                rule_wants_newline = true
            elseif assignment_ahead(code, index, parens, ecl)
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

        local needed_newlines = math.max(token.orig_newlines or 0, rule_wants_newline and 1 or 0)
        while newlines_emitted < needed_newlines do
            newline()
        end

        if #current_line > 0 and previous then
            if strict_space(previous, token, before_previous, next_token, dialect, ecl) then
                current_line[#current_line + 1] = {
                    kind = ecl.WHITESPACE,
                    type = -1,
                    text = " ",
                    is_trivia = true,
                    is_comment = false,
                }
            end
        end

        current_line[#current_line + 1] = token
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
                if is_function then
                    newline()
                end
            elseif token.type == T.Function then
                function_pending = true
            elseif (token.type == T.Then or token.type == T.Do or token.type == T.Repeat) and not if_exprs[token] then
                newline()
            elseif token.type == T.Semicolon then
                newline()
            elseif token.type == T.Else and not if_exprs[token] then
                newline()
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

    if #current_line > 0 then
        newline()
    end
    while newlines_emitted < trailing_newlines do
        newline()
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
        lines = strict_split_lines(tokens, opts.dialect or "lua", ecl, if_exprs)
    else
        lines = split_lines(tokens, ecl)
    end
    return reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline)
end

function printer.format(source, dialect, opts, ecl)
    ecl = assert(ecl, "Eclipsed is required")
    local tokens, err = ecl.tokens(source, dialect)
    if not tokens then
        return nil, err
    end
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
        lines = strict_split_lines(tokens, dialect, ecl, if_exprs)
    else
        lines = split_lines(tokens, ecl)
    end
    return reindent_lines(lines, opts, ecl, if_exprs, has_trailing_newline)
end

return printer
