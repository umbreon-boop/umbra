local shake = require("process.shake")
local check = require("process.check")
local diagnostics = require("diag")

local shake_stage = {}

function shake_stage.run(tokens, dialect, context, library)
    local ecl = assert(library, "Eclipsed is required")
    local report = shake.analyse(tokens, dialect, ecl)
    for _, warning in ipairs(report.warnings) do
        context.report(warning)
    end
    local shaken, dropped, dropped_list = shake.remove(tokens, report, ecl)
    if dropped == 0 then
        return tokens
    end
    local ok = check.source(shaken, dialect, "shaking produced source that does not parse", ecl)
    if not ok then
        return nil, "shaking failed"
    end
    local names = {}
    for _, entry in ipairs(dropped_list) do
        names[#names + 1] = entry.name
    end
    diagnostics.finished(
        "Shook",
        ("%d unreachable field%s: %s"):format(dropped, dropped == 1 and "" or "s", table.concat(names, ", "))
    )
    return shaken
end

return shake_stage
