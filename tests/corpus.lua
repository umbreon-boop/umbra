return function(h, corpus)
    local ecl, printer = h.ecl, h.printer
    local scope = h.scope
    local fail = h.fail
    local code_tokens, same, subsequence = h.code_tokens, h.same, h.subsequence

    local files = h.corpus_files(corpus)
    if #files == 0 then
        io.stderr:write(("no files under %s\n"):format(corpus))
        os.exit(1)
    end

    local lexable, parsable, typed = 0, 0, 0

    for _, path in ipairs(files) do
        local handle = io.open(path, "rb")
        local source = handle:read("*a")
        handle:close()

        local tokens = ecl.tokens(source, "luau")
        if tokens then
            lexable = lexable + 1
            if ecl.render(tokens) ~= source then
                fail("round-trip", path)
            end
        end

        if ecl.check(source, "luau") then
            parsable = parsable + 1

            local minified = printer.minify(tokens, "luau", ecl)
            local after = code_tokens(minified)
            if not after then
                fail("minify output does not lex", path)
            elseif not same(code_tokens(source), after) then
                fail("minify changed the code tokens", path)
            end

            if loadstring and loadstring(source) then
                local ok_min, why = loadstring(minified)
                if not ok_min then
                    fail("luajit rejects the minified output", ("%s: %s"):format(path, tostring(why)))
                end
            end

            local formatted = printer.format(source, "luau", nil, ecl)
            if not formatted then
                fail("format returned nothing", path)
            else
                if not ecl.check(formatted, "luau") then
                    fail("format broke the parse", path)
                elseif not same(code_tokens(source), code_tokens(formatted)) then
                    fail("format changed the code tokens", path)
                end
                if printer.format(formatted, "luau", nil, ecl) ~= formatted then
                    fail("format is not idempotent", path)
                end
                if loadstring and loadstring(source) and not loadstring(formatted) then
                    fail("luajit rejects the formatted output", path)
                end
            end

            local spans = ecl.type_spans(source, "luau")
            if spans and #spans > 0 then
                typed = typed + 1
            end
            local ok, stripped = pcall(function()
                return ecl.render(printer.strip_types(ecl.tokens(source, "luau"), source, "luau", ecl))
            end)
            if not ok then
                fail("strip_types errored", ("%s: %s"):format(path, stripped))
            elseif not ecl.check(stripped, "luau") then
                fail("strip_types broke the parse", path)
            else
                if not subsequence(code_tokens(stripped), code_tokens(source)) then
                    fail("strip_types invented or reordered tokens", path)
                end
                local left = ecl.type_spans(stripped, "luau")
                if left and #left > 0 then
                    fail("strip_types left a type behind", path)
                end
            end

            local renamed_ok, renamed = pcall(scope.rename, tokens, { dialect = "luau" }, ecl)
            if not renamed_ok then
                fail("rename errored", ("%s: %s"):format(path, renamed))
            else
                local out = ecl.render(renamed)
                if not ecl.check(out, "luau") then
                    fail("rename broke the parse", path)
                elseif loadstring and loadstring(source) and not loadstring(out) then
                    fail("luajit rejects the renamed output", path)
                else
                    local a = scope.resolve(tokens, ecl)
                    local b = scope.resolve(renamed, ecl)
                    local map, rmap = {}, {}
                    for i = 1, #tokens do
                        local x, y = a.owner[i], b.owner[i]
                        if (x == nil) ~= (y == nil) then
                            fail("rename changed what an identifier resolves to", path)
                            break
                        end
                        if x then
                            if (map[x] and map[x] ~= y) or (rmap[y] and rmap[y] ~= x) then
                                fail("rename captured a binding", path)
                                break
                            end
                            map[x], rmap[y] = y, x
                        end
                    end
                end
            end
        end
    end

    return { files = #files, lexable = lexable, parsable = parsable, typed = typed }
end
