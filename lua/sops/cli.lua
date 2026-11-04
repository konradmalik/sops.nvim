-- Feeds stdin on the first run. `sops edit` reruns $EDITOR on a parse error;
-- the second run gets drained stdin, fails, and sops reports the error.
local editor = [[sh -c 'cat > "$0"; [ -s "$0" ]']]

-- `sops edit` exit code for unchanged plaintext.
local unchanged = 200

---@param lines string[]
---@return string
local function to_stdin(lines) return table.concat(lines, "\n") .. "\n" end

---@param out string?
---@return string[]
local function to_lines(out) return vim.split(((out or ""):gsub("\n$", "")), "\n", { plain = true }) end

local M = {}

---sops timeout in ms; keys may be on a token or the network, never hang neovim.
M.timeout = 30000

---@param res vim.SystemCompleted
---@return string
local function failure(res)
    -- vim.system's code for a timeout
    if res.code == 124 then return ("sops did not finish within %gs"):format(M.timeout / 1000) end
    return vim.trim(res.stderr or "")
end

---Start decrypting `path`; the returned function waits for the result.
---Reads the file, not the buffer: a child's stdin is a socket, which linux
---cannot reopen via /dev/stdin. Only unmodified buffers are decrypted anyway.
---@param path string
---@return fun(): string[]?, string? wait lines or an error
function M.decrypt(path)
    local proc = vim.system({ "sops", "decrypt", path }, { text = true, timeout = M.timeout })
    return function()
        local res = proc:wait()
        if res.code ~= 0 then return nil, failure(res) end
        return to_lines(res.stdout), nil
    end
end

---Encrypt `lines` into `path`. `sops edit` keeps the existing data key and
---recipients, so one changed value is one changed line.
---@param path string absolute
---@param lines string[]
---@return boolean ok, string? err
function M.encrypt(path, lines)
    local res = vim.system({ "sops", "edit", path }, {
        -- a new file (:saveas) needs .sops.yaml, sops looks from its cwd up
        cwd = vim.fs.dirname(path),
        env = { EDITOR = editor },
        stdin = to_stdin(lines),
        text = true,
        timeout = M.timeout,
    }):wait()
    if res.code ~= 0 and res.code ~= unchanged then return false, failure(res) end
    return true, nil
end

---Encrypt plaintext `lines` as if they were `path`, which picks the
---`.sops.yaml` rule and format. A fresh data key; `path` is not read.
---@param path string absolute
---@param lines string[]
---@return string[]? lines, string? err
function M.encrypt_new(path, lines)
    local res = vim.system({ "sops", "encrypt", "--filename-override", path }, {
        -- sops looks for .sops.yaml from its cwd up
        cwd = vim.fs.dirname(path),
        stdin = to_stdin(lines),
        text = true,
        timeout = M.timeout,
    }):wait()
    if res.code ~= 0 then return nil, failure(res) end
    return to_lines(res.stdout), nil
end

return M
