local shell = require("shell")
local diagnostics = require("diag")

local documentation = {}

function documentation.run(library, options)
    local ecl = library
    local dialect, out_dir = options.dialect, options.output
    local root, show_private = options.root, options.private

    local function read(path)
        local handle = io.open(path, "rb")
        if not handle then
            return nil
        end
        local text = handle:read("*a")
        handle:close()
        return text
    end

    local function files(path)
        local out = {}
        local pipe = io.popen("find " .. shell.quote(path) .. ' -type f \\( -name "*.lua" -o -name "*.luau" \\) | sort')
        for line in pipe:lines() do
            out[#out + 1] = line
        end
        pipe:close()
        return out
    end

    local function trim(s)
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function comment_body(raw)
        if raw:sub(1, 3) == "---" then
            return { (raw:gsub("^%-%-%-?", "")) }
        elseif raw:sub(1, 3) == "--[" then
            local inner = raw:gsub("^%-%-%[=*%[", ""):gsub("%]=*%]$", "")
            local lines = {}
            for line in (inner .. "\n"):gmatch("([^\n]*)\n") do
                lines[#lines + 1] = line
            end
            return lines
        end
        return {}
    end

    local function escape_cell(text)
        text = trim(tostring(text):gsub("\n", " "))
        local out, at = {}, 1
        while at <= #text do
            local first = text:find("`", at, true)
            if not first then
                out[#out + 1] = text:sub(at):gsub("|", "&#124;")
                break
            end
            out[#out + 1] = text:sub(at, first - 1):gsub("|", "&#124;")
            local after = first
            while text:sub(after, after) == "`" do
                after = after + 1
            end
            local ticks = text:sub(first, after - 1)
            local search, last = after, nil
            while true do
                local candidate = text:find("`", search, true)
                if not candidate then
                    break
                end
                local finish = candidate
                while text:sub(finish, finish) == "`" do
                    finish = finish + 1
                end
                if finish - candidate == #ticks then
                    last = candidate
                    break
                end
                search = finish
            end
            if last then
                out[#out + 1] = text:sub(first, last + #ticks - 1)
                at = last + #ticks
            else
                out[#out + 1] = ticks
                at = after
            end
        end
        return table.concat(out)
    end

    local function fmt_type(text)
        text = trim(text or "")
        if text == "" then
            text = "any"
        end
        if text:match("%[[^%]]+%]%([^%)]+%)") then
            return text
        end
        return "`" .. text .. "`"
    end

    local function safe_filename(name)
        return (name:gsub("[^%w%-_]", "_"))
    end

    local function safe_location(location)
        local parts = {}
        for part in tostring(location or ""):gmatch("[^/\\]+") do
            if part ~= "." and part ~= ".." then
                parts[#parts + 1] = safe_filename(part)
            end
        end
        return table.concat(parts, "/")
    end

    local function parse_block(lines)
        local block = {
            desc = {},
            params = {},
            returns = {},
            props = {},
            types = {},
            errors = {},
            tags = {},
            realm = {},
        }
        for _, raw in ipairs(lines) do
            local line = trim(raw)
            local tag, rest = line:match("^@(%w+)%s*(.*)$")
            local field, field_rest = line:match("^%.([%w_]+)%s+(.*)$")
            if not tag and field then
                local lua_type, desc = field_rest:match("^(.-)%s*%-%-%s*(.*)$")
                block.props[#block.props + 1] = {
                    name = field,
                    lua_type = trim(lua_type or field_rest),
                    desc = trim(desc or ""),
                }
            elseif not tag then
                if line ~= "" or #block.desc > 0 then
                    block.desc[#block.desc + 1] = line
                end
            elseif tag == "class" or tag == "within" or tag == "interface" or tag == "function" or tag == "method" then
                block[tag] = trim(rest)
            elseif tag == "location" then
                block.location = trim(rest)
            elseif tag == "param" or tag == "arg" then
                local name, tail = rest:match("^(%S+)%s*(.*)$")
                local lua_type, desc = (tail or ""):match("^(.-)%s*%-%-%s*(.*)$")
                block.params[#block.params + 1] = {
                    name = name,
                    lua_type = trim(lua_type or tail or ""),
                    desc = trim(desc or ""),
                }
            elseif tag == "return" then
                local lua_type, desc = rest:match("^(.-)%s*%-%-%s*(.*)$")
                block.returns[#block.returns + 1] = {
                    lua_type = trim(lua_type or rest),
                    desc = trim(desc or ""),
                }
            elseif tag == "prop" then
                local name, tail = rest:match("^(%S+)%s*(.*)$")
                local lua_type, desc = (tail or ""):match("^(.-)%s*%-%-%s*(.*)$")
                block.props[#block.props + 1] = {
                    name = name,
                    lua_type = trim(lua_type or tail or ""),
                    desc = trim(desc or ""),
                }
            elseif tag == "type" then
                local name, tail = rest:match("^(%S+)%s*(.*)$")
                local lua_type, desc = (tail or ""):match("^(.-)%s*%-%-%s*(.*)$")
                block.types[#block.types + 1] = {
                    name = name,
                    lua_type = trim(lua_type or tail or ""),
                    desc = trim(desc or ""),
                }
            elseif tag == "error" then
                local lua_type, desc = rest:match("^(.-)%s*%-%-%s*(.*)$")
                block.errors[#block.errors + 1] = {
                    lua_type = trim(lua_type or rest),
                    desc = trim(desc or ""),
                }
            elseif tag == "tag" then
                block.tags[#block.tags + 1] = trim(rest)
            elseif tag == "realm" then
                block.realm[#block.realm + 1] = trim(rest)
            elseif tag == "deprecated" then
                block.deprecated = trim(rest) ~= "" and trim(rest) or true
            elseif tag == "since" then
                block.since = trim(rest)
            else
                block[tag] = true
            end
        end
        while #block.desc > 0 and block.desc[#block.desc] == "" do
            block.desc[#block.desc] = nil
        end
        block.desc = table.concat(block.desc, "\n")

        for _, list in ipairs({ block.props, block.types }) do
            if #list == 1 and list[1].desc == "" and block.desc ~= "" and not (block.class or block.interface) then
                list[1].desc = block.desc
            end
        end
        return block
    end

    local function visible(entry)
        if entry.ignore then
            return false
        end
        if entry.private and not show_private then
            return false
        end
        return true
    end

    local function write_table(md, headers, rows)
        if #rows == 0 then
            return
        end
        md[#md + 1] = "| " .. table.concat(headers, " | ") .. " |\n"
        local rule = {}
        for _ = 1, #headers do
            rule[#rule + 1] = "---"
        end
        md[#md + 1] = "|" .. table.concat(rule, "|") .. "|\n"
        for _, row in ipairs(rows) do
            md[#md + 1] = "| " .. table.concat(row, " | ") .. " |\n"
        end
        md[#md + 1] = "\n"
    end

    local function write_item_table(md, items, base_headers, cells, heading)
        local show_desc = false
        for _, item in ipairs(items) do
            if item.desc and trim(item.desc) ~= "" then
                show_desc = true
                break
            end
        end
        local headers = {}
        for _, h in ipairs(base_headers) do
            headers[#headers + 1] = h
        end
        if show_desc then
            headers[#headers + 1] = "Description"
        end
        if heading then
            md[#md + 1] = ("**%s**\n\n"):format(heading)
        end
        local rows = {}
        for _, item in ipairs(items) do
            local row = cells(item)
            if show_desc then
                row[#row + 1] = item.desc or ""
            end
            for i = 1, #row do
                row[i] = escape_cell(row[i])
            end
            rows[#rows + 1] = row
        end
        write_table(md, headers, rows)
    end

    local function write_notices(md, entry)
        local dep = entry.deprecated
        if type(dep) == "string" then
            md[#md + 1] = ('!!! warning "Deprecated"\n    %s\n\n'):format(dep)
        elseif dep then
            md[#md + 1] = '!!! warning "Deprecated"\n\n'
        end
        if entry.unreleased then
            md[#md + 1] = '!!! info "Unreleased"\n    Not yet available in a stable release.\n\n'
        end
        if entry.since and entry.since ~= "" then
            md[#md + 1] = ("*Since %s*\n\n"):format(entry.since)
        end
        if entry.tags and #entry.tags > 0 then
            local quoted = {}
            for _, t in ipairs(entry.tags) do
                quoted[#quoted + 1] = "`" .. t .. "`"
            end
            md[#md + 1] = "**Tags:** " .. table.concat(quoted, ", ") .. "\n\n"
        end
        if entry.realm and #entry.realm > 0 then
            local titled = {}
            for _, r in ipairs(entry.realm) do
                titled[#titled + 1] = r:sub(1, 1):upper() .. r:sub(2)
            end
            md[#md + 1] = "**Realm:** " .. table.concat(titled, ", ") .. "\n\n"
        end
        if entry.private then
            md[#md + 1] = "**Private**\n\n"
        end
    end

    local classes, class_order, class_decl_order, class_paths, class_names = {}, {}, {}, {}, {}

    local function class_for(name, parent, declared)
        local path = parent and (parent.path .. "." .. name) or name
        local existing = class_paths[path]
        if existing then return classes[existing] end
        local id
        if declared and parent then
            local placeholder = classes["\0" .. name]
            if placeholder and placeholder.id ~= parent.id and placeholder.kind == nil and not placeholder.parent then
                id = placeholder.id
                class_paths[placeholder.path] = nil
                placeholder.path = path
                placeholder.parent = parent.id
                class_paths[path] = id
                if not parent.child_seen[id] then
                    parent.child_seen[id] = true
                    parent.children[#parent.children + 1] = id
                end
                return placeholder
            end
        end
        id = parent and (parent.id .. "\0" .. name) or ("\0" .. name)
        if not classes[id] then
            classes[id] = {
                id = id,
                path = path,
                name = name,
                desc = "",
                source = nil,
                location = "",
                properties = {},
                types = {},
                functions = {},
                methods = {},
                children = {},
                child_seen = {},
                parent = parent and parent.id or nil,
                prop_seen = {},
                type_seen = {},
            }
            class_order[#class_order + 1] = id
            class_paths[path] = id
            class_names[name] = class_names[name] or {}
            class_names[name][#class_names[name] + 1] = id
            if parent and not parent.child_seen[id] then
                parent.child_seen[id] = true
                parent.children[#parent.children + 1] = id
            end
        end
        return classes[id]
    end

    local function find_class(name)
        if classes[name] then return classes[name] end
        local id = class_paths[name]
        if id then return classes[id] end
        local matches = class_names[name]
        if matches then
            if #matches == 1 then return classes[matches[1]] end
            return nil
        end
    end

    local function class_target(name)
        local found = find_class(name)
        if found then return found end
        if class_names[name] then return nil end
        local parent_name, child_name = name:match("^(.*)%.([^%.]+)$")
        if parent_name then
            local parent = class_target(parent_name)
            if parent then return class_for(child_name, parent) end
            return nil
        end
        return class_for(name)
    end

    local drifted, skipped = 0, 0

    local function add_once(list, seen, entries)
        for _, entry in ipairs(entries) do
            local key = entry.name or tostring(entry)
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = entry
            end
        end
    end

    local function merge_types(cls, entries)
        for _, entry in ipairs(entries) do
            local existing
            for _, item in ipairs(cls.types) do
                if item.name == entry.name then
                    existing = item
                    break
                end
            end
            if existing then
                if (not existing.lua_type or existing.lua_type == "") and entry.lua_type and entry.lua_type ~= "" then
                    existing.lua_type = entry.lua_type
                end
                if (not existing.desc or existing.desc == "") and entry.desc and entry.desc ~= "" then
                    existing.desc = entry.desc
                end
            else
                cls.type_seen[entry.name] = true
                cls.types[#cls.types + 1] = entry
            end
        end
    end

    local function documented(block)
        return block.desc ~= ""
        or #block.params > 0
        or #block.returns > 0
        or #block.errors > 0
        or #block.types > 0
        or block.deprecated ~= nil
        or block.since ~= nil
    end

    local function declared_type(source, tokens, spans, decl)
        if decl.kind ~= "type" then
            return ""
        end
        for _, span in ipairs(spans) do
            if span.kind == ecl.TYPE_ALIAS_STMT and span.start >= decl.start and span.end_ <= decl.end_ then
                local assignment, first_value, last_value = false, nil, nil
                for _, token in ipairs(tokens) do
                    if token.start >= span.start and token.end_ <= span.end_ and not token.is_trivia then
                        if not assignment and token.text == "=" then
                            assignment = true
                        elseif assignment then
                            first_value = first_value or token
                            last_value = token
                        end
                    end
                end
                if first_value and last_value then
                    return trim(source:sub(first_value.start, last_value.end_))
                end
            end
        end
        return ""
    end

    local function process_file(path)
        local source = read(path)
        local decls, derr = ecl.declarations(source, dialect)
        if not decls then
            diagnostics.error(("could not parse `%s`"):format(path), nil, derr)
            return
        end
        local type_spans = ecl.type_spans(source, dialect) or {}
        local tokens = ecl.tokens(source, dialect) or {}

        local rel = path:gsub("^" .. root:gsub("(%W)", "%%%1") .. "/?", "")

        local scopes = {}
        local floating, matched = {}, {}

        local function scope_at_pending(offset)
            local name
            for _, entry in ipairs(scopes) do
                if entry.at <= offset then
                    name = entry.name
                else
                    break
                end
            end
            return name
        end

        -- Consecutive `---` lines form one block, as above declarations.
        local comments = {}
        for _, comment in ipairs(ecl.comments(source, dialect) or {}) do
            local previous = comments[#comments]
            local joined = previous and previous.dashes and comment.text:sub(1, 3) == "---"
            and source:sub(previous.end_ + 1, comment.start - 1):match("^[ \t]*\r?\n[ \t]*$")
            if joined then
                for _, line in ipairs(comment_body(comment.text)) do
                    table.insert(previous.lines, line)
                end
                previous.end_ = comment.end_
            else
                comments[#comments + 1] = {
                    start = comment.start,
                    end_ = comment.end_,
                    lines = comment_body(comment.text),
                    dashes = comment.text:sub(1, 3) == "---",
                }
            end
        end

        for _, comment in ipairs(comments) do
            local block = parse_block(comment.lines)
            local kind, name = nil, nil
            if block.class then
                kind, name = "class", block.class
            elseif block.interface then
                kind, name = "interface", block.interface
            end

            if kind then
                local parent = block.within and class_target(block.within)
                if block.within and not parent then
                    diagnostics.warn(("`@within %s` is ambiguous"):format(block.within), nil, rel)
                    drifted = drifted + 1
                end
                local cls = class_for(name, parent, true)
                cls.source = cls.source or rel
                if not cls.kind then
                    cls.kind = kind
                    class_decl_order[#class_decl_order + 1] = cls.id
                end
                if block.location and block.location ~= "" then
                    cls.location = block.location
                end
                if cls.desc == "" and block.desc ~= "" then cls.desc = block.desc end
                cls.deprecated = cls.deprecated or block.deprecated
                cls.since = cls.since or block.since
                cls.private = cls.private or block.private
                cls.tags = cls.tags or {}
                cls.tag_seen = cls.tag_seen or {}
                add_once(cls.tags, cls.tag_seen, block.tags)
                cls.realm = cls.realm or block.realm
                cls.ignore = cls.ignore or block.ignore
                add_once(cls.properties, cls.prop_seen, block.props)
                add_once(cls.types, cls.type_seen, block.types)

                if kind == "class" then
                    scopes[#scopes + 1] = { at = comment.start, name = cls.id }
                end
            elseif block["function"] or block.method then
                block.at = comment.start
                floating[(block.within or "") .. "\0" .. (block["function"] or block.method)] = block
            elseif #block.props > 0 or #block.types > 0 then
                local target = block.within or scope_at_pending(comment.start)
                if target then
                    local cls = class_target(target)
                    if cls then
                        add_once(cls.properties, cls.prop_seen, block.props)
                        add_once(cls.types, cls.type_seen, block.types)
                    else
                        diagnostics.warn(("`@within %s` is ambiguous"):format(target), nil, rel)
                        drifted = drifted + 1
                    end
                end
            end
        end

        local function scope_at(offset)
            local name
            for _, entry in ipairs(scopes) do
                if entry.at <= offset then
                    name = entry.name
                else
                    break
                end
            end
            return name or (scopes[1] and scopes[1].name)
        end

        for _, decl in ipairs(decls) do
            -- Consecutive `---` lines form one block; a long comment is its own.
            local groups = {}
            for n, raw in ipairs(decl.doc) do
                local lines = comment_body(raw)
                local previous = decl.doc[n - 1]
                if raw:sub(1, 3) == "---" and previous and previous:sub(1, 3) == "---" then
                    for _, line in ipairs(lines) do
                        table.insert(groups[#groups], line)
                    end
                else
                    groups[#groups + 1] = lines
                end
            end
            local block = parse_block({})
            for _, lines in ipairs(groups) do
                local candidate = parse_block(lines)
                if not (candidate.class or candidate.interface) then
                    block = candidate
                end
            end

            local member = decl.member or decl.name
            local named_key
            for _, key in ipairs({ (decl.owner or "") .. "\0" .. member, "\0" .. decl.name, "\0" .. member }) do
                if not named_key and floating[key] then named_key = key end
            end
            if named_key then
                block = floating[named_key]
                matched[named_key] = true
            end

            local declared_class = decl.owner and find_class(decl.owner)
            local declared_on = declared_class and declared_class.id
            local owner = block.within or declared_on or scope_at(decl.start or 0)
            if owner and documented(block) then
                local cls = class_target(owner)
                if cls then
                if #block.props > 0 then
                    add_once(cls.properties, cls.prop_seen, block.props)
                elseif #block.types > 0 or decl.kind == "type" then
                    if #block.types > 0 then
                        if decl.kind == "type" then
                            local definition = declared_type(source, tokens, type_spans, decl)
                            for _, type_doc in ipairs(block.types) do
                                if type_doc.name == decl.name and type_doc.lua_type == "" then
                                    type_doc.lua_type = definition
                                end
                            end
                        end
                        merge_types(cls, block.types)
                    else
                        add_once(cls.types, cls.type_seen, {
                            {
                                name = decl.name,
                                lua_type = "",
                                desc = block.desc,
                                private = block.private,
                                ignore = block.ignore,
                            },
                        })
                    end
                elseif decl.kind == "function" then
                    local params = block.params
                    if #params == 0 then
                        for _, name in ipairs(decl.params) do
                            params[#params + 1] = { name = name, lua_type = "any", desc = "" }
                        end
                    else
                        local real = {}
                        for _, name in ipairs(decl.params) do
                            real[name] = true
                        end
                        for _, p in ipairs(params) do
                            if p.name and not real[p.name] then
                                diagnostics.warn(
                                    ("`@param %s` matches no parameter of `%s`"):format(p.name, decl.name),
                                    nil,
                                    ("%s declares (%s)"):format(rel, table.concat(decl.params, ", "))
                                )
                                drifted = drifted + 1
                            end
                        end
                    end
                    local is_method = decl.method
                    if block.method then
                        is_method = true
                    end
                    if block["function"] then
                        is_method = false
                    end
                    local into = is_method and cls.methods or cls.functions
                    into[#into + 1] = {
                        name = decl.name,
                        member = decl.member or decl.name,
                        desc = block.desc,
                        params = params,
                        returns = block.returns,
                        errors = block.errors,
                        yields = block.yields,
                        private = block.private,
                        ignore = block.ignore,
                        deprecated = block.deprecated,
                        since = block.since,
                        tags = block.tags,
                        realm = block.realm,
                        unreleased = block.unreleased,
                    }
                end
                else
                    diagnostics.warn(("`@within %s` is ambiguous"):format(owner), nil, rel)
                    drifted = drifted + 1
                end
            elseif owner and decl.kind == "function" then
                skipped = skipped + 1
            end
        end
        for key, block in pairs(floating) do
            if not matched[key] then
                local name = block["function"] or block.method
                local target = block.within or scope_at_pending(block.at or 0)
                if target then
                    local cls = class_target(target)
                    if not cls then
                        diagnostics.warn(("`@within %s` is ambiguous"):format(target), nil, rel)
                        drifted = drifted + 1
                    else
                    local into = block.method and cls.methods or cls.functions
                    into[#into + 1] = {
                        name = name,
                        member = name,
                        desc = block.desc,
                        params = block.params,
                        returns = block.returns,
                        errors = block.errors,
                        yields = block.yields,
                        private = block.private,
                        ignore = block.ignore,
                        deprecated = block.deprecated,
                        since = block.since,
                        tags = block.tags,
                        realm = block.realm,
                        unreleased = block.unreleased,
                    }
                    end
                else
                    diagnostics.warn(
                        ("`@%s %s` has nowhere to go"):format(block.method and "method" or "function", name),
                        nil,
                        ("%s names no class, and the block has no `@within`"):format(rel)
                    )
                    drifted = drifted + 1
                end
            end
        end
    end

    for _, path in ipairs(files(root)) do
        process_file(path)
    end

    for _, name in ipairs(class_order) do
        local cls = classes[name]
        if cls.kind == nil and #cls.children > 0 then
            local children = {}
            for _, id in ipairs(cls.children) do
                children[#children + 1] = classes[id].path
            end
            diagnostics.warn(
                ("`@within %s` names no `@class` or `@interface`"):format(cls.path),
                nil,
                ("declared only as the parent of: %s"):format(table.concat(children, ", "))
            )
            drifted = drifted + 1
        end
    end

    local function heading(depth)
        return ("#"):rep(math.min(math.max(depth, 1), 6))
    end

    local function render_type(md, t, depth)
        md[#md + 1] = ("%s `%s`\n\n"):format(heading(depth), t.name or "Unknown")
        write_notices(md, t)
        if t.desc and t.desc ~= "" then
            md[#md + 1] = t.desc .. "\n\n"
        end
        if t.lua_type and t.lua_type ~= "" then
            md[#md + 1] = ("```lua\ntype %s = %s\n```\n\n"):format(t.name, t.lua_type)
        end
        md[#md + 1] = "---\n\n"
    end

    local function render_callable(md, fn, depth)
        md[#md + 1] = ("%s `%s`\n\n"):format(heading(depth), fn.member or fn.name)
        write_notices(md, fn)
        if fn.yields then
            md[#md + 1] = '!!! note "Yields"\n    This function yields the calling thread.\n\n'
        end
        if fn.desc and fn.desc ~= "" then
            md[#md + 1] = fn.desc .. "\n\n"
        end
        if #fn.params > 0 then
            write_item_table(md, fn.params, { "Name", "Type" }, function(p)
                return { ("`%s`"):format(p.name), fmt_type(p.lua_type or "any") }
            end, "Parameters")
        end
        if #fn.returns > 0 then
            write_item_table(md, fn.returns, { "Type" }, function(r)
                return { fmt_type(r.lua_type or "any") }
            end, "Returns")
        end
        if #fn.errors > 0 then
            write_item_table(md, fn.errors, { "Type" }, function(e)
                return { fmt_type(e.lua_type or "any") }
            end, "Errors")
        end
        md[#md + 1] = "---\n\n"
    end

    local function render_members(md, cls, depth)
        local props = {}
        for _, p in ipairs(cls.properties) do
            if visible(p) then
                props[#props + 1] = p
            end
        end
        if #props > 0 then
            md[#md + 1] = ("%s Properties\n\n"):format(heading(depth))
            write_item_table(md, props, { "Property", "Type" }, function(p)
                local suffix = p.readonly and " *(read-only)*" or ""
                return { ("`%s`%s"):format(p.name, suffix), fmt_type(p.lua_type or "any") }
            end)
        end

        local types = {}
        for _, t in ipairs(cls.types) do
            if visible(t) then
                types[#types + 1] = t
            end
        end
        if #types > 0 then
            md[#md + 1] = ("%s Exported Types\n\n"):format(heading(depth))
            for _, t in ipairs(types) do
                render_type(md, t, depth + 1)
            end
        end

        local methods, functions = {}, {}
        for _, f in ipairs(cls.methods) do
            if visible(f) then
                methods[#methods + 1] = f
            end
        end
        for _, f in ipairs(cls.functions) do
            if visible(f) then
                functions[#functions + 1] = f
            end
        end
        if #methods > 0 then
            md[#md + 1] = ("%s Methods\n\n"):format(heading(depth))
            for _, fn in ipairs(methods) do
                render_callable(md, fn, depth + 1)
            end
        end
        if #functions > 0 then
            md[#md + 1] = ("%s Functions\n\n"):format(heading(depth))
            for _, fn in ipairs(functions) do
                render_callable(md, fn, depth + 1)
            end
        end
    end

    local render_children

    local function render_child(md, cls, depth, seen)
        if seen[cls.id] then
            diagnostics.warn(("`%s` is its own ancestor via `@within`"):format(cls.path), nil, cls.source)
            return
        end
        seen[cls.id] = true
        write_notices(md, cls)
        if cls.desc and cls.desc ~= "" then
            md[#md + 1] = cls.desc .. "\n\n"
        end
        render_members(md, cls, depth)
        render_children(md, cls, depth, seen)
        seen[cls.id] = nil
    end

    function render_children(md, cls, depth, seen)
        local children = {}
        for _, id in ipairs(cls.children) do
            local child = classes[id]
            if visible(child) then
                children[#children + 1] = child
            end
        end
        if #children == 0 then
            return
        end
        md[#md + 1] = ("%s Children\n\n"):format(heading(depth))
        for _, child in ipairs(children) do
            md[#md + 1] = ("%s `%s`\n\n"):format(heading(depth + 1), child.path)
            render_child(md, child, depth + 2, seen)
        end
    end

    os.execute("mkdir -p -- " .. shell.quote(out_dir))
    local written, taken = 0, {}
    --- A page name no other page has, preferring `index` for a package's own
    --- entry point.
    local function page_name(cls)
        local base = (cls.source == "init.lua" or cls.source == "lib.lua") and not taken.index and "index"
        or safe_filename(cls.name)
        local name, suffix = base, 1
        while taken[name] do
            suffix = suffix + 1
            name = ("%s-%d"):format(base, suffix)
        end
        taken[name] = true
        return name
    end

    -- A `@within` cycle has no root, so its first class becomes one.
    for _, name in ipairs(class_decl_order) do
        local seen, at = {}, classes[name]
        while at and at.parent and not seen[at.id] do
            seen[at.id] = true
            at = classes[at.parent]
        end
        if at and at.id == name and at.parent then
            diagnostics.warn(("`%s` is its own ancestor via `@within`"):format(at.path), nil, at.source)
            local former = classes[at.parent]
            for n = #former.children, 1, -1 do
                if former.children[n] == name then
                    table.remove(former.children, n)
                end
            end
            former.child_seen[name] = nil
            at.parent = nil
        end
    end

    for _, name in ipairs(class_order) do
        local cls = classes[name]
        if cls.parent == nil and visible(cls) then
            local md = {}
            md[#md + 1] = ("# %s\n\n%s\n\n"):format(cls.name, cls.desc ~= "" and cls.desc or "No description provided.")
            write_notices(md, cls)
            render_members(md, cls, 2)
            render_children(md, cls, 2, { [cls.id] = true })

            local location = safe_location(cls.location)
            local directory = location ~= "" and (out_dir .. "/" .. location) or out_dir
            if location ~= "" then
                os.execute("mkdir -p -- " .. shell.quote(directory))
            end
            local handle = assert(io.open(("%s/%s.md"):format(directory, page_name(cls)), "w"))
            handle:write(table.concat(md))
            handle:close()
            written = written + 1
        end
    end

    diagnostics.finished("Documented", ("%d page%s -> %s"):format(written, written == 1 and "" or "s", out_dir))
    if skipped > 0 then
        diagnostics.finished("Skipped", ("%d undocumented function%s"):format(skipped, skipped == 1 and "" or "s"))
    end
    if drifted > 0 then
        diagnostics.finished(
            "Drifted",
            ("%d block%s documents something that is not there"):format(drifted, drifted == 1 and "" or "s")
        )
    end
    diagnostics.summary()
    return written, skipped, drifted
end

return documentation
