--- Helpers over the Eclipsed C syntax tree.

local syntax = {}

function syntax.each(list, visit)
    local ptr = list.ptr
    for i = 0, tonumber(list.len) - 1 do
        visit(ptr[i], i + 1)
    end
end

function syntax.count(list)
    return tonumber(list.len)
end

function syntax.item(list, n)
    return list.ptr[n - 1]
end

function syntax.text(source, range)
    return source:sub(range.start + 1, range["end"])
end

--- Visits every statement and expression under the chunk root, parents
--- first. `on_statement(node)` and `on_expression(node)` may be nil.
function syntax.walk(info, ecl, on_statement, on_expression)
    local K = ecl.const
    local each = syntax.each
    local expression, statements, annotation

    local function arguments(args)
        each(args.values, expression)
    end

    local function body(fn)
        statements(fn.body)
    end

    function expression(node)
        if on_expression then
            on_expression(node)
        end
        local kind, data = node.kind, node.data
        if kind == K.EXPR_KIND_UNARY then
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
            body(data["function"])
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

    local function statement(node)
        if on_statement then
            on_statement(node)
        end
        local kind, data = node.kind, node.data
        if kind == K.STMT_KIND_LOCAL or kind == K.STMT_KIND_CONST or kind == K.STMT_KIND_IN_UNPACK then
            each(data["local"].values, expression)
        elseif kind == K.STMT_KIND_LOCAL_FUNCTION then
            body(data.local_function.body)
        elseif kind == K.STMT_KIND_FUNCTION then
            body(data["function"].body)
        elseif kind == K.STMT_KIND_ASSIGN then
            each(data.assign.values, expression)
            each(data.assign.targets, expression)
        elseif kind == K.STMT_KIND_COMPOUND_ASSIGN then
            expression(data.compound.target)
            expression(data.compound.value)
        elseif kind == K.STMT_KIND_DO then
            statements(data.block)
        elseif kind == K.STMT_KIND_IF then
            local branch = data.if_
            expression(branch.condition)
            statements(branch.then_block)
            each(branch.elseifs, function(arm)
                expression(arm.condition)
                statements(arm.body)
            end)
            statements(branch.else_block)
        elseif kind == K.STMT_KIND_WHILE or kind == K.STMT_KIND_REPEAT then
            expression(data.loop_.condition)
            statements(data.loop_.body)
        elseif kind == K.STMT_KIND_NUMERIC_FOR then
            local loop = data.numeric_for
            expression(loop.start)
            expression(loop.limit)
            if loop.step ~= nil then
                expression(loop.step)
            end
            statements(loop.body)
        elseif kind == K.STMT_KIND_GENERIC_FOR then
            each(data.generic_for.iterators, expression)
            statements(data.generic_for.body)
        elseif kind == K.STMT_KIND_RETURN then
            each(data.return_, expression)
        elseif kind == K.STMT_KIND_CALL then
            expression(data.call)
        end
    end

    function statements(list)
        each(list, statement)
    end

    for i = 0, info.root_count - 1 do
        statement(info.root[i])
    end
end

--- Whether evaluating `node` can have no observable effect.
--- Whether evaluating `node` can neither raise an error nor run code. With
--- `info` from `scope.resolve`, only local names count: a global read may
--- reach an `__index` metamethod, as under strict mode.
function syntax.pure(node, ecl, info)
    local K = ecl.const
    local kind = node.kind
    local function is(n, ...)
        for _, k in ipairs({ ... }) do
            if n.kind == k then return true end
        end
        return false
    end
    local function number(n)
        return is(n, K.EXPR_KIND_INTEGER, K.EXPR_KIND_FLOAT)
    end
    local function text(n)
        return is(n, K.EXPR_KIND_STRING)
    end
    if
        is(node, K.EXPR_KIND_NIL, K.EXPR_KIND_TRUE, K.EXPR_KIND_FALSE, K.EXPR_KIND_INTEGER, K.EXPR_KIND_FLOAT,
            K.EXPR_KIND_STRING, K.EXPR_KIND_VARARG, K.EXPR_KIND_FUNCTION, K.EXPR_KIND_I64, K.EXPR_KIND_U64,
            K.EXPR_KIND_IMAGINARY, K.EXPR_KIND_JENKINS_HASH)
    then
        return true
    elseif kind == K.EXPR_KIND_NAME then
        return not info or info.global[info.at[node.span.start]] == nil
    elseif kind == K.EXPR_KIND_PAREN then
        return syntax.pure(node.data.paren, ecl, info)
    elseif kind == K.EXPR_KIND_UNARY then
        local op, operand = node.data.unary.op, node.data.unary.operand
        if op == K.UNARY_OP_NOT then
            return syntax.pure(operand, ecl, info)
        elseif op == K.UNARY_OP_NEGATE then
            return number(operand)
        elseif op == K.UNARY_OP_LENGTH then
            return text(operand)
        end
        return is(operand, K.EXPR_KIND_INTEGER)
    elseif kind == K.EXPR_KIND_BINARY then
        local op, left, right = node.data.binary.op, node.data.binary.left, node.data.binary.right
        if op == K.BINARY_OP_AND or op == K.BINARY_OP_OR or op == K.BINARY_OP_EQUAL or op == K.BINARY_OP_NOT_EQUAL then
            return syntax.pure(left, ecl, info) and syntax.pure(right, ecl, info)
        elseif op == K.BINARY_OP_CONCATENATE then
            return (number(left) or text(left)) and (number(right) or text(right))
        elseif op == K.BINARY_OP_LESS_THAN or op == K.BINARY_OP_GREATER_THAN
            or op == K.BINARY_OP_LESS_EQUAL or op == K.BINARY_OP_GREATER_EQUAL then
            return (number(left) and number(right)) or (text(left) and text(right))
        elseif op == K.BINARY_OP_BITWISE_AND or op == K.BINARY_OP_BITWISE_OR or op == K.BINARY_OP_BITWISE_XOR
            or op == K.BINARY_OP_SHIFT_LEFT or op == K.BINARY_OP_SHIFT_RIGHT then
            return is(left, K.EXPR_KIND_INTEGER) and is(right, K.EXPR_KIND_INTEGER)
        elseif op == K.BINARY_OP_FLOOR_DIVIDE or op == K.BINARY_OP_MODULO then
            -- Integer division by zero raises.
            return number(left) and number(right)
                and not (is(right, K.EXPR_KIND_INTEGER) and right.data.integer == 0)
        end
        return number(left) and number(right)
    elseif kind == K.EXPR_KIND_TABLE then
        local ok = true
        syntax.each(node.data.table, function(field)
            local key = field.key
            ok = ok
                and (key == nil or (syntax.pure(key, ecl, info) and not is(key, K.EXPR_KIND_NIL, K.EXPR_KIND_BINARY)))
                and syntax.pure(field.value, ecl, info)
        end)
        return ok
    end
    return false
end

--- Tokens that can end an expression a following `(` would call.
local CALLABLE_END = { Identifier = true, RightParenthesis = true, RightSquareBracket = true,
    RightCurlyBrace = true, String = true, LongString = true }

--- `tokens` without those in `drop`. `statements` marks the last token of
--- each whole statement dropped: where one stood between code and a `(`, a
--- `;` keeps the `(` from calling what precedes it.
function syntax.remove(tokens, drop, statements, ecl)
    local callable = {}
    for name in pairs(CALLABLE_END) do
        callable[ecl.T[name]] = true
    end
    local out, previous, pending = {}, nil, false
    for index, token in ipairs(tokens) do
        if drop[index] then
            pending = pending or statements[index] or false
        else
            if pending and not token.is_trivia then
                if token.text == "(" and previous and callable[previous.type] then
                    out[#out + 1] = { text = ";", kind = ecl.SYNTAX, type = ecl.T.Semicolon, is_trivia = false, is_comment = false }
                end
                pending = false
            end
            out[#out + 1] = token
            if not token.is_trivia then previous = token end
        end
    end
    return out
end

return syntax
