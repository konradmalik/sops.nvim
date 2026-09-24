-- How the sops metadata block starts in each of the formats sops can parse.
local metadata = {
    "^%s*sops:", -- yaml
    '^%s*"sops":', -- json
    "^sops_version=", -- dotenv
    "^%[sops%]", -- ini
}

-- Every encrypted value carries this, whatever the format.
local value = "ENC[AES256_GCM"

local M = {}

---An encrypted file has the metadata block and at least one encrypted value.
---Anything less is a file that merely talks about sops.
---@param lines string[]
---@return boolean
function M.is_encrypted(lines)
    local meta, enc = false, false
    for _, line in ipairs(lines) do
        if not meta then
            meta = vim.iter(metadata):any(function(pattern) return line:find(pattern) ~= nil end)
        end
        if not enc then enc = line:find(value, 1, true) ~= nil end
        if meta and enc then return true end
    end
    return false
end

return M
