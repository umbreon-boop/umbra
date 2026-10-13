local scope = require("process.scope")
local diag = require("diag")

local localize_stage = {}

function localize_stage.run(tokens, dialect, library)
    local localised, cached, why = scope.localize(tokens, { dialect = dialect }, library)
    if why then
        diag.warn("no globals were cached", nil, why)
        return tokens
    end
    if #cached == 0 then
        return tokens
    end
    local names = {}
    for _, entry in ipairs(cached) do
        names[#names + 1] = ("%s=%s"):format(entry.fresh, entry.name)
    end
    diag.finished("Cached", ("%d global%s: %s"):format(#cached, #cached == 1 and "" or "s", table.concat(names, ", ")))
    return localised
end

return localize_stage
