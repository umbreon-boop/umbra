local macro = require("process.macro")
local check = require("process.check")
local diag = require("diag")

local macro_stage = {}

function macro_stage.run(tokens, dialect, context, library)
    local ecl = assert(library, "Eclipsed is required")
    local expanded, report = macro.expand(tokens, dialect, ecl)
    for _, warning in ipairs(report.warnings) do
        context.report(warning)
    end
    if report.errors and #report.errors > 0 then
        for _, entry in ipairs(report.errors) do
            if context.report_error then
                context.report_error(entry)
            else
                diag.error(entry.text, nil, entry.note)
            end
        end
        return nil, "macro expansion exceeded the local variable limit"
    end
    if report.expanded == 0 then
        return tokens
    end
    local ok = check.source(expanded, dialect, "expanding macros produced source that does not parse", ecl)
    if not ok then
        return nil, "macro expansion failed"
    end
    diag.finished("Inlined", ("%d macro call%s"):format(report.expanded, report.expanded == 1 and "" or "s"))
    return expanded
end

return macro_stage
