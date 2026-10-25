-- Start of the sops metadata block, per format.
local metadata = {
    "^%s*sops:", -- yaml
    '^%s*"sops":', -- json
    "^sops_version=", -- dotenv
    "^%[sops%]", -- ini
}

-- Prefix of every encrypted value.
local value = "ENC[AES256_GCM"

---@param line string
---@return boolean
local function is_metadata(line)
    for _, pattern in ipairs(metadata) do
        if line:find(pattern) then return true end
    end
    return false
end

local M = {}

---Has the metadata block and at least one encrypted value.
---@param lines string[]
---@return boolean
function M.is_encrypted(lines)
    local meta, enc = false, false
    for _, line in ipairs(lines) do
        if not meta then meta = is_metadata(line) end
        if not enc then enc = line:find(value, 1, true) ~= nil end
        if meta and enc then return true end
    end
    return false
end

return M
