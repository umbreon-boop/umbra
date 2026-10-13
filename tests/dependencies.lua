return function(h)
    local q = h.quote
    local root = os.tmpname()
    os.remove(root)
    local child, parent, project = root .. "/child", root .. "/parent", root .. "/project"
    assert(os.execute(("mkdir -p %s %s %s"):format(q(child), q(parent), q(project))))

    local function write(path, text)
        local handle = assert(io.open(path, "wb"))
        handle:write(text)
        handle:close()
    end

    -- LuaJIT's `close` does not report a pipe's exit status, so echo it.
    local function command(text)
        local pipe = assert(io.popen("(" .. text .. ") 2>&1; echo \"__exit:$?\""))
        local output = pipe:read("*a")
        pipe:close()
        local status = output:match("__exit:(%d+)%s*$")
        return status == "0", (output:gsub("__exit:%d+%s*$", ""))
    end

    local function git_repo(path, files, message)
        assert(command("git init " .. q(path)))
        for name, text in pairs(files) do write(path .. "/" .. name, text) end
        assert(command(("git -C %s add ."):format(q(path))))
        assert(command(("git -C %s -c user.name=Umbra -c user.email=umbra@example.test commit -m %s"):format(
            q(path), q(message)
        )))
        local ok, rev = command("git -C " .. q(path) .. " rev-parse HEAD")
        assert(ok)
        return rev:match("[0-9a-f]+")
    end

    local child_rev = git_repo(child, {
        ["package.toml"] = '[package]\nname = "child"\n',
        ["lib.lua"] = 'return "transitive value"\n',
    }, "child")
    local parent_rev = git_repo(parent, {
        ["package.toml"] = table.concat({
            '[package]',
            'name = "parent"',
            '',
            '[dependencies]',
            ('child = { git = "%s", rev = "%s" }'):format(child, child_rev),
            '',
        }, "\n"),
        ["init.lua"] = 'return require("@child")\n',
    }, "parent")

    local cwd = os.getenv("PWD") or "."
    local main = cwd .. "/src/main.lua"
    local add_ok, add_output = command(("cd %s && luajit %s add parent %s --rev %s"):format(
        q(project), q(main), q(parent), parent_rev
    ))
    if not add_ok or not add_output:find("Added parent", 1, true) then
        h.fail("umbra add did not install a pinned Git package", add_output)
    else
        local manifest = assert(io.open(project .. "/package.toml", "rb")):read("*a")
        if not manifest:find(parent_rev, 1, true) then
            h.fail("add did not record the requested revision", manifest)
        end
        local lock = assert(io.open(project .. "/package.lock", "rb")):read("*a")
        if not lock:find(parent_rev, 1, true) or not lock:find(child_rev, 1, true) then
            h.fail("dependency lock omitted a transitive commit", lock)
        end
        local owner = root:match("([^/]+)$")
        local snapshots = {
            { path = project .. "/target/" .. owner .. ".parent." .. parent_rev, file = "init.lua" },
            { path = project .. "/target/" .. owner .. ".child." .. child_rev, file = "lib.lua" },
        }
        for _, snapshot in ipairs(snapshots) do
            local handle = io.open(snapshot.path .. "/" .. snapshot.file, "rb")
            if handle then handle:close() else h.fail("dependency snapshot was not exported", snapshot.path) end
            local git_dir = os.execute("test -e " .. q(snapshot.path .. "/.git"))
            if git_dir == true or git_dir == 0 then
                h.fail("snapshot unexpectedly contains Git metadata", snapshot.path)
            end
        end

        local update_ok, update_output = command(("cd %s && luajit %s update"):format(q(project), q(main)))
        if not update_ok or not update_output:find("Updated 2 dependencies", 1, true) then
            h.fail("umbra update did not resolve the full graph", update_output)
        end
    end

    local function read(path)
        local handle = io.open(path, "rb")
        if not handle then return nil end
        local text = handle:read("*a")
        handle:close()
        return text
    end
    local function fresh_project(name, manifest)
        local path = root .. "/" .. name
        assert(os.execute("mkdir -p " .. q(path)))
        if manifest then write(path .. "/package.toml", manifest) end
        return path
    end
    local function umbra(path, arguments)
        return command(("cd %s && luajit %s %s"):format(q(path), q(main), arguments))
    end

    -- A dependency's `rev` must never reach git as an option.
    local marker = root .. "/PWNED"
    local evil = root .. "/evil"
    git_repo(evil, {
        ["package.toml"] = ('[dependencies]\nx = { git = "%s", rev = "--upload-pack=touch %s;git-upload-pack" }\n')
            :format(child, marker),
        ["init.lua"] = "return 1\n",
    }, "evil")
    local evil_project = fresh_project("evil-project")
    local evil_ok = umbra(evil_project, "add e " .. q(evil))
    if evil_ok or read(marker) then
        h.fail("a transitive rev starting with '-' was passed to git", tostring(read(marker) ~= nil))
    end
    local dash_ok, dash_output = umbra(fresh_project("dash-project"), "add n " .. q(child) .. " --rev --upload-pack=x")
    if dash_ok then h.fail("--rev accepted a value starting with '-'", dash_output) end

    local _, bad_name = umbra(fresh_project("name-project"), "add a.b " .. q(child))
    if not bad_name:find("a.b", 1, true) then h.fail("an invalid name is named in its error", bad_name) end

    -- `add` changes only its own line.
    local manifest = table.concat({
        "[package]",
        'name = "keep"',
        "",
        "[dependencies]",
        "# pinned by hand",
        ("lit = '%s'"):format(child),
        ('cmt = "%s" # trailing'):format(child),
        "",
        "[extra]",
        "x = 1",
        "",
    }, "\n")
    local keep = fresh_project("keep-project", manifest)
    local keep_ok, keep_output = umbra(keep, "add added " .. q(child))
    local kept = read(keep .. "/package.toml") or ""
    local expected = manifest:gsub("(\n\n%[extra%])", ('\nadded = "%s"%%1'):format(child))
    if not keep_ok or kept ~= expected then
        h.fail("add rewrote unrelated package.toml content", keep_output .. "\n" .. kept)
    end
    local lock = read(keep .. "/package.lock") or ""
    if not (lock:find("\tlit\t", 1, true) and lock:find("\tcmt\t", 1, true)) then
        h.fail("literal strings and commented values are dependencies too", lock)
    end
    local unknown = fresh_project("unknown-project", ('[dependencies]\nb = { git = "%s", branch = "main" }\n'):format(child))
    local unknown_ok, unknown_output = umbra(unknown, "update")
    if unknown_ok or not unknown_output:find("branch", 1, true) then
        h.fail("an unsupported dependency key is reported", unknown_output)
    end

    local odd = root .. "/odd"
    git_repo(odd, {
        ["package.toml"] = ('[dependencies]\nb = { git = "%s", branch = "main" }\n'):format(child),
        ["init.lua"] = "return 1\n",
    }, "odd")
    local odd_ok, odd_output = umbra(fresh_project("odd-project"), "add o " .. q(odd))
    if odd_ok or not odd_output:find("unsupported key", 1, true) then
        h.fail("a dependency's unreadable manifest is reported", odd_output)
    end

    -- A changed non-commit rev must be noticed by an offline build.
    assert(command(("git -C %s tag v1"):format(q(child))))
    local tagged = fresh_project("tag-project")
    write(tagged .. "/main.lua", 'print(require("@c"))\n')
    local tag_ok, tag_output = umbra(tagged, "add c " .. q(child) .. " --rev v1")
    if not tag_ok then
        h.fail("add with a tag rev", tag_output)
    else
        local declared = read(tagged .. "/package.toml"):gsub('rev = "v1"', 'rev = "v2"')
        write(tagged .. "/package.toml", declared)
        local build_ok, build_output = umbra(tagged, "build main.lua -o -")
        if build_ok or not build_output:find("umbra update", 1, true) then
            h.fail("a changed rev was not detected", build_output)
        end
    end
    local leftover = io.popen("ls -A " .. q(tagged .. "/target")):read("*a")
    if leftover:find(".umbra-stage", 1, true) then h.fail("a staging directory was left behind", leftover) end

    os.execute("rm -rf " .. q(root))
end
