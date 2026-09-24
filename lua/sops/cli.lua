-- `sops edit` re-runs $EDITOR in an endless loop when the plaintext it gets
-- back does not parse. This shim feeds the buffer in on the first run and then
-- fails on the second one (stdin is drained by then, so the file comes out
-- empty), which makes sops give up and report the parse error instead.
local editor = [[sh -c 'cat > "$0"; [ -s "$0" ]']]

-- A key can live on a hardware token or behind the network, but sops must
-- never be able to hang neovim.
local timeout = 30000

---@param lines string[]
---@return string
local function to_stdin(lines) return table.concat(lines, "\n") .. "\n" end

---@param out string?
---@return string[]
local function to_lines(out) return vim.split(((out or ""):gsub("\n$", "")), "\n", { plain = true }) end

local M = {}

---Decrypt the contents of the file at `path`. The lines are passed in rather
---than read from disk so that an unsaved buffer decrypts too, `path` only
---tells sops which format to expect.
---@param path string
---@param lines string[]
---@return string[]? lines, string? err
function M.decrypt(path, lines)
    local res = vim.system({ "sops", "decrypt", "--filename-override", path, "/dev/stdin" }, {
        stdin = to_stdin(lines),
        text = true,
    }):wait(timeout)
    if res.code ~= 0 then return nil, vim.trim(res.stderr or "") end
    return to_lines(res.stdout), nil
end

---Encrypt `lines` into the sops file at `path`. Going through `sops edit`
---keeps the data key and the recipients that are already in the file, so
---changing one value changes one line.
---@param path string
---@param lines string[]
---@return boolean ok, string? err
function M.encrypt(path, lines)
    local res = vim.system({ "sops", "edit", path }, {
        env = { EDITOR = editor },
        stdin = to_stdin(lines),
        text = true,
    }):wait(timeout)
    if res.code ~= 0 then return false, vim.trim(res.stderr or "") end
    return true, nil
end

return M
