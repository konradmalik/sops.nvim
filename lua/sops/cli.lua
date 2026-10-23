-- `sops edit` re-runs $EDITOR in an endless loop when the plaintext it gets
-- back does not parse. This shim feeds the buffer in on the first run and then
-- fails on the second one (stdin is drained by then, so the file comes out
-- empty), which makes sops give up and report the parse error instead.
local editor = [[sh -c 'cat > "$0"; [ -s "$0" ]']]

-- What `sops edit` exits with when the plaintext came back unchanged.
local unchanged = 200

---@param lines string[]
---@return string
local function to_stdin(lines) return table.concat(lines, "\n") .. "\n" end

---@param out string?
---@return string[]
local function to_lines(out) return vim.split(((out or ""):gsub("\n$", "")), "\n", { plain = true }) end

local M = {}

---How long sops may take, in milliseconds. A key can live on a hardware token
---or behind the network, but sops must never be able to hang neovim.
M.timeout = 30000

---@param res vim.SystemCompleted
---@return string
local function failure(res)
    -- what vim.system reports when it had to kill the process
    if res.code == 124 then return ("sops did not finish within %gs"):format(M.timeout / 1000) end
    return vim.trim(res.stderr or "")
end

---Decrypt the file at `path`.
---
---It is read from disk rather than piped in from the buffer on purpose:
---neovim gives a child process a socket for its stdin, and on linux a socket
---cannot be opened again through /dev/stdin. A buffer is only ever decrypted
---while it is unmodified, so the file holds the very same ciphertext anyway.
---
---Only starts sops, so that several files can be decrypted at once; the
---returned function waits for the result.
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
    }):wait(M.timeout)
    if res.code ~= 0 and res.code ~= unchanged then return false, failure(res) end
    return true, nil
end

return M
