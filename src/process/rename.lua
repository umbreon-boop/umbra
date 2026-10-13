local scope = require("process.scope")

local rename_stage = {}

function rename_stage.run(tokens, dialect, library)
    return scope.rename(tokens, { dialect = dialect }, library)
end

return rename_stage
