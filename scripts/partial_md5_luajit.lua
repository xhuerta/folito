-- KOReader's util.partialMD5 (frontend/util.lua) run on a real LuaJIT, with only the md5 primitive
-- swapped for coreutils `md5sum` (KOReader uses ffi/sha2). The offset loop is copied verbatim, so this
-- reproduces LuaJIT's bit.lshift count masking (1024 << -2 == 0) exactly.
-- Usage: luajit scripts/partial_md5_luajit.lua FILE...
local bit = require("bit")

local function partialMD5(filepath)
    local file = io.open(filepath, "rb")
    if not file then return nil end
    local tmp = os.tmpname()
    local out = io.open(tmp, "wb")
    local step, size = 1024, 1024
    for i = -1, 10 do
        file:seek("set", bit.lshift(step, 2 * i))
        local sample = file:read(size)
        if sample then out:write(sample) else break end
    end
    file:close(); out:close()
    local p = io.popen("md5sum < '" .. tmp .. "'")
    local line = p:read("*l"); p:close(); os.remove(tmp)
    return line:match("^%x+")
end

for _, path in ipairs(arg) do print(partialMD5(path) .. "  " .. path) end
