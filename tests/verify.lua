package.path = (arg[0]:match("^(.*)[/\\]") or ".") .. "/../src/?.lua;" .. package.path

local diag = require("diag")
local q = require("shell").quote

local dialect, runtime, entry, exercise = "luau", "luajit", nil, nil
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--dialect" or a == "-d" then
        i = i + 1
        dialect = arg[i]
    elseif a == "--runtime" then
        i = i + 1
        runtime = arg[i]
    elseif not entry then
        entry = a
    else
        exercise = a
    end
    i = i + 1
end
if not entry or not exercise then
    io.stderr:write("usage: verify.lua [--dialect <name>] [--runtime <cmd>] " .. "<entry.lua> <exercise-script>\n")
    os.exit(2)
end

local here = (arg[0]:match("^(.*)[/\\]") or ".") .. "/../src"

local exercise_dir = exercise:match("^(.*)[/\\]") or "."
local tag = ("umbra-verify-%d"):format(os.time())
local stem = ("%s/%s"):format(exercise_dir, tag)

local function run(command)
    local pipe = io.popen(command .. ' 2>&1; echo "__exit:$?"')
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__exit:(%d+)%s*$")) or 1
    output = output:gsub("__exit:%d+%s*$", "")
    return status == 0, output
end

local function build(flags, out)
    local ok, output = run(("luajit %s build --dialect %s %s -o %s %s"):format(
            q(here .. "/main.lua"), q(dialect), flags, q(out), q(entry)
        ))
    if not ok then
        diag.fail(("could not build %s"):format(out), output:gsub("%s+$", ""))
    end
end

build("--plain", stem .. "-plain.lua")
build("", stem .. "-opt.lua")

local function transcript(bundle, out)
    local ok, output = run(("%s %s %s %s"):format(q(runtime), q(exercise), q(bundle), q(out)))
    if not ok then
        diag.fail(("the exercise failed against %s"):format(bundle), output:gsub("%s+$", ""))
    end
    local handle = io.open(out, "rb")
    if not handle then
        diag.fail(
            ("the exercise wrote no transcript for %s"):format(bundle),
            (output:gsub("%s+$", "")) ~= "" and output:gsub("%s+$", "")
            or "it should write to the file named by its second argument"
        )
    end
    local text = handle:read("*a")
    handle:close()
    return text
end

local before = transcript(stem .. "-plain.lua", stem .. "-plain.txt")
local after = transcript(stem .. "-opt.lua", stem .. "-opt.txt")

os.remove(stem .. "-plain.lua")
os.remove(stem .. "-opt.lua")
os.remove(stem .. "-plain.txt")
os.remove(stem .. "-opt.txt")

if before == after then
    local lines = select(2, before:gsub("\n", "\n"))
    diag.finished(
        "Verified",
        ("%d transcript line%s identical under %s"):format(lines, lines == 1 and "" or "s", runtime)
    )
    diag.summary()
    os.exit(0)
end

local want, got = {}, {}
for line in before:gmatch("([^\n]*)\n?") do
    want[#want + 1] = line
end
for line in after:gmatch("([^\n]*)\n?") do
    got[#got + 1] = line
end
for n = 1, math.max(#want, #got) do
    if want[n] ~= got[n] then
        diag.error("optimising changed what the code does", nil, ("transcript line %d"):format(n))
        io.stderr:write(("       unoptimised | %s\n"):format(tostring(want[n])))
        io.stderr:write(("         optimised | %s\n"):format(tostring(got[n])))
        break
    end
end
diag.summary()
os.exit(1)
