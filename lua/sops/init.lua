local cli = require("sops.cli")
local detect = require("sops.detect")

-- the buffer local autocommands, the global ones live in plugin/sops.lua
local group = vim.api.nvim_create_augroup("SopsBuffer", { clear = true })

---global on purpose, the toggle is not per buffer
local plaintext = false

---@param msg string
---@param level integer
local function notify(msg, level) vim.notify("sops: " .. msg, level) end

---Expanded and with symlinks resolved, the way neovim names a buffer.
---@param path string
---@return string
local function full_path(path) return vim.fn.resolve(vim.fn.fnamemodify(path, ":p")) end

---@param bufnr integer
---@return string
local function pretty_name(bufnr)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:~:.")
end

---@param bufnr integer
---@return string[]
local function get_lines(bufnr) return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end

---What the file at `path` looks like on disk, nil when there is none.
---@param path string
---@return string?
local function stamp(path)
    local stat = vim.uv.fs_stat(path)
    return stat and ("%s %d.%d %d"):format(path, stat.mtime.sec, stat.mtime.nsec, stat.size)
end

---Note that the buffer matches its file on disk right now.
---@param bufnr integer
local function remember(bufnr) vim.b[bufnr].sops_stamp = stamp(vim.api.nvim_buf_get_name(bufnr)) end

---@param bufnr integer
---@param lines string[]
local function set_lines(bufnr, lines)
    -- undo must not be able to reach across a ciphertext/plaintext swap
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].undolevels = undolevels
    vim.bo[bufnr].modified = false
end

---Show the buffer the way the global toggle says it should be shown.
---@param bufnr integer
---@param decrypting? fun(): string[]?, string? already started by cli.decrypt
local function render(bufnr, decrypting)
    local path = vim.api.nvim_buf_get_name(bufnr)

    if not plaintext then
        if vim.fn.filereadable(path) == 0 then
            notify(("cannot read %s back"):format(pretty_name(bufnr)), vim.log.levels.ERROR)
            return
        end
        set_lines(bufnr, vim.fn.readfile(path))
        vim.b[bufnr].sops_plaintext = false
        remember(bufnr)
        return
    end

    local lines, err = (decrypting or cli.decrypt(path))()
    if not lines then
        notify(("cannot decrypt %s\n%s"):format(pretty_name(bufnr), err), vim.log.levels.ERROR)
        return
    end

    set_lines(bufnr, lines)
    vim.b[bufnr].sops_plaintext = true
    remember(bufnr)
end

---@param bufnr integer
local function write(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    local plain = vim.b[bufnr].sops_plaintext

    -- writing goes around neovim, so its own check for this never runs; a
    -- file that does not exist yet, after :saveas say, cannot have changed
    local now = stamp(path)
    if vim.v.cmdbang == 0 and now and now ~= vim.b[bufnr].sops_stamp then
        notify(
            ("%s changed on disk, use :w! to overwrite it"):format(pretty_name(bufnr)),
            vim.log.levels.ERROR
        )
        return
    end

    -- formatters hook in here; only for plaintext, reformatted ciphertext
    -- is nobody's business
    if plain then vim.api.nvim_exec_autocmds("BufWritePre", { buffer = bufnr }) end
    local lines = get_lines(bufnr)

    if plain then
        local ok, err = cli.encrypt(path, lines)
        if not ok then
            notify(("cannot encrypt %s\n%s"):format(pretty_name(bufnr), err), vim.log.levels.ERROR)
            return
        end
    elseif detect.is_encrypted(lines) then
        vim.fn.writefile(lines, path)
    else
        -- the buffer claims to hold ciphertext but does not: never write it out
        notify(
            ("refusing to write %s, it does not look encrypted"):format(pretty_name(bufnr)),
            vim.log.levels.ERROR
        )
        return
    end

    -- and confirm what actually ended up in the file
    if not detect.is_encrypted(vim.fn.readfile(path)) then
        notify(
            ("%s ON DISK IS NOT ENCRYPTED, encrypt it by hand now"):format(pretty_name(bufnr)),
            vim.log.levels.ERROR
        )
        return
    end

    -- leaving the buffer modified is what tells neovim a write failed
    vim.bo[bufnr].modified = false
    remember(bufnr)
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
end

local M = {}

---Take over an encrypted buffer, so that it can be toggled and written back.
---Buffers that hold no sops file are left alone.
---@param bufnr integer
function M.attach(bufnr)
    if vim.b[bufnr].sops then
        -- FileType fires again after a reload, but also on a mere :setfiletype,
        -- which must not throw away unsaved changes
        if vim.bo[bufnr].modified then return end
        -- a reload brought the ciphertext back, whatever the flag says
        vim.b[bufnr].sops_plaintext = not detect.is_encrypted(get_lines(bufnr))
        render(bufnr)
        return
    end
    if vim.bo[bufnr].buftype ~= "" or not detect.is_encrypted(get_lines(bufnr)) then return end

    vim.b[bufnr].sops = true
    vim.b[bufnr].sops_plaintext = false
    -- the whole point: nothing decrypted may end up on disk. Both have to be
    -- off before the first decryption, and turning 'swapfile' off deletes the
    -- swap file neovim already made for the ciphertext.
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false

    -- :bdelete forgets b:sops but keeps the buffer's autocommands
    vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
    -- every kind of write: the whole buffer, part of it (:1,2w) or appended
    -- (:w >>), into its own file or elsewhere
    vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }, {
        group = group,
        buffer = bufnr,
        desc = "encrypt the buffer back into its file, write nothing else decrypted",
        callback = function(args)
            local whole = args.event == "BufWriteCmd"
            if whole and full_path(args.file) == full_path(vim.api.nvim_buf_get_name(bufnr)) then
                return write(bufnr)
            end
            -- a copy of the ciphertext is as safe as the original, but
            -- plaintext would have to be encrypted into our own file
            if vim.b[bufnr].sops_plaintext or not detect.is_encrypted(get_lines(bufnr)) then
                return notify(
                    "cannot write a decrypted buffer elsewhere, use :saveas",
                    vim.log.levels.ERROR
                )
            end
            local first = vim.api.nvim_buf_get_mark(bufnr, "[")[1]
            local last = vim.api.nvim_buf_get_mark(bufnr, "]")[1]
            local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
            vim.fn.writefile(lines, args.file, args.event == "FileAppendCmd" and "a" or "")
        end,
    })

    -- neovim has just read the ciphertext, no need to read it again
    if plaintext then
        render(bufnr)
    else
        remember(bufnr)
    end
end

---Switch every sops buffer between its encrypted and decrypted view.
function M.toggle()
    plaintext = not plaintext
    notify(plaintext and "showing plaintext" or "showing ciphertext", vim.log.levels.INFO)

    -- start every sops before waiting on any, each may be waiting on the network
    local pending = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].sops then
            if vim.bo[bufnr].modified then
                notify(
                    ("%s has unsaved changes, left as is"):format(pretty_name(bufnr)),
                    vim.log.levels.WARN
                )
            elseif plaintext then
                table.insert(pending, { bufnr, cli.decrypt(vim.api.nvim_buf_get_name(bufnr)) })
            else
                table.insert(pending, { bufnr })
            end
        end
    end
    for _, p in ipairs(pending) do
        render(p[1], p[2])
    end
end

---Whether sops buffers are currently showing their plaintext.
---@return boolean
function M.is_plaintext() return plaintext end

return M
