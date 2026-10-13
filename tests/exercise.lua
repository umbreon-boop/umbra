package.path = "./src/?.lua;" .. package.path
local shell = require("shell")
local bundle, transcript = assert(arg[1]), assert(arg[2])
local command = ("luajit %s --help > %s 2>&1"):format(shell.quote(bundle), shell.quote(transcript))
local ok, status = os.execute(command)
if ok ~= true and ok ~= 0 then
    error("could not run the built CLI")
end
