return function(h)
    local ecl = h.ecl

    local function expect(what, actual, expected)
        if actual ~= expected then
            h.fail(what, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
        end
    end

    expect("valid source checks", ecl.check("local x = 1", "lua"), true)
    local ok, message, first, last = ecl.check("local = 1", "lua")
    expect("invalid source fails", ok, false)
    expect("errors carry a message", type(message), "string")
    expect("errors carry a range", ("%s-%s"):format(first, last), "7-7")
    ok, message = ecl.check("x = '\255'", "lua")
    expect("invalid UTF-8 fails", ok, false)
    if not tostring(message):find("UTF-8", 1, true) then
        h.fail("invalid UTF-8 is named", tostring(message))
    end
    if pcall(ecl.check, "", "perl") then
        h.fail("unknown dialects are rejected", "perl")
    end

    local source = "#!/usr/bin/env lua\n-- note\nlocal s = 'a\0b' --[[ x ]]\n"
    local tokens = ecl.tokens(source, "lua")
    expect("tokens tile the source", ecl.render(tokens), source)
    expect("shebang is trivia", tokens[1].kind, ecl.SHEBANG)
    expect("comments are flagged", #ecl.comments(source, "lua"), 2)
    local keyword
    for _, token in ipairs(tokens) do
        if not token.is_trivia then
            keyword = token
            break
        end
    end
    expect("token types are named", ecl.type_name[keyword.type], "Local")
    expect("token types are looked up", ecl.T.Local, keyword.type)
    if pcall(function()
        return ecl.T.NotAType
    end) then
        h.fail("unknown token type names raise", "NotAType")
    end

    expect("words fuse", ecl.needs_space("local", "x", "lua"), true)
    expect("minus fuses into a comment", ecl.needs_space("-", "-x", "lua"), true)
    expect("punctuation does not fuse", ecl.needs_space("x", "=", "lua"), false)

    local declarations = ecl.declarations(
        table.concat({
            "--- Adds.",
            "function M.add(a, b) end",
            "function M:method(...) end",
            "local f = function(x) end",
            "if c then elseif d then function M.late() end end",
            "",
        }, "\n"),
        "lua"
    )
    local summary = {}
    for _, decl in ipairs(declarations) do
        summary[#summary + 1] = ("%s %s(%s)"):format(decl.kind, decl.name, table.concat(decl.params, ","))
    end
    expect(
        "declarations",
        table.concat(summary, "; "),
        "function M.add(a,b); function M:method(...); function f(x); function M.late()"
    )
    expect("doc comments", declarations[1].doc[1], "--- Adds.")
    expect("method owner", declarations[2].owner, "M")
    expect("method flag", declarations[2].method, true)
    expect("member", declarations[2].member, "method")
    local nothing, parse_error = ecl.declarations("local =", "lua")
    expect("declarations report parse errors", nothing, nil)
    expect("declarations report parse errors", type(parse_error), "string")

    local luau = "local x: number = 1\ntype T = string\ntype function g(t) end\n"
    local spans = ecl.type_spans(luau, "luau")
    expect("type spans", #spans, 3)
    expect("annotation span", luau:sub(spans[1].start, spans[1].end_), "number")
    expect("annotation kind", spans[1].kind, ecl.TYPE_ANNOTATION)
    expect("alias kind", spans[2].kind, ecl.TYPE_ALIAS_STMT)
    local kinds = {}
    for _, decl in ipairs(ecl.declarations(luau, "luau")) do
        kinds[#kinds + 1] = decl.kind
    end
    expect("luau declaration kinds", table.concat(kinds, ","), "type,type_function")

    if not ecl.version():match("^%d+%.%d+%.%d+") then
        h.fail("version is semantic", ecl.version())
    end
    expect("dialect names", ecl.dialect_name(1), "luau")
    expect("unknown dialect ids have no name", ecl.dialect_name(99), nil)
    expect("minify", ecl.minify("local  x = 1 -- c\nreturn  x", "lua"), "local x=1 return x")

    local chunk = assert(ecl.parse(luau, "luau"))
    expect("chunk statement count", chunk:statement_count(), 3)
    expect("chunk tokens tile the source", ecl.render(chunk:tokens()), luau)
    expect("chunk answers several queries", #chunk:type_spans() + #chunk:declarations(), 5)
    chunk:free()
    chunk:free()
    if pcall(chunk.tokens, chunk) then
        h.fail("a freed chunk refuses queries", "tokens")
    end
    local unparsed, parse_message, parse_first, parse_last = ecl.parse("local =", "lua")
    expect("parse failures", unparsed, nil)
    expect("parse failures carry a message", type(parse_message), "string")
    expect("parse failures carry a range", ("%s-%s"):format(parse_first, parse_last), "7-7")
    local _, _, query_first = ecl.declarations("local = 1", "lua")
    expect("query failures carry a range", query_first, 7)
end
