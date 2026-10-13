local directory = arg and arg[0] and arg[0]:match("^(.*)[/\\]")
if directory then
    package.path = directory .. "/?.lua;" .. package.path
end

os.exit(require("cli").run(arg) and 0 or 1)
