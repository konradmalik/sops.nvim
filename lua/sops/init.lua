local cli = require("sops.cli")
local detect = require("sops.detect")

-- buffer local autocommands; global ones are in plugin/sops.lua
local group = vim.api.nvim_create_augroup("SopsBuffer", { clear = true })

---global, the toggle is not per buffer
local plaintext = false

---@param msg string
---@param level integer
local function notify(msg, level) vim.notify("sops: " .. msg, level) end

---Absolute, symlinks resolved, like buffer names.
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

---Identifies the file's current state on disk, nil if missing.
---@param path string
---@return string?
local function stamp(path)
    local stat = vim.uv.fs_stat(path)
    return stat and ("%s %d.%d %d"):format(path, stat.mtime.sec, stat.mtime.nsec, stat.size)
end

---Mark the buffer as in sync with its file.
---@param bufnr integer
local function remember(bufnr) vim.b[bufnr].sops_stamp = stamp(vim.api.nvim_buf_get_name(bufnr)) end

---@param bufnr integer
---@param lines string[]
local function set_lines(bufnr, lines)
    -- no undo across a ciphertext/plaintext swap
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].undolevels = undolevels
    vim.bo[bufnr].modified = false
end

---Show the buffer as the global toggle says.
---@param bufnr integer
---@param decrypting? fun(): string[]?, string? started cli.decrypt
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

    -- we bypass neovim's own check; a new file (:saveas) cannot have changed
    local now = stamp(path)
    if vim.v.cmdbang == 0 and now and now ~= vim.b[bufnr].sops_stamp then
        notify(
            ("%s changed on disk, use :w! to overwrite it"):format(pretty_name(bufnr)),
            vim.log.levels.ERROR
        )
        return
    end

    -- formatters, plaintext only
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
        -- claims ciphertext but is not
        notify(
            ("refusing to write %s, it does not look encrypted"):format(pretty_name(bufnr)),
            vim.log.levels.ERROR
        )
        return
    end

    -- verify what landed on disk
    if not detect.is_encrypted(vim.fn.readfile(path)) then
        notify(
            ("%s ON DISK IS NOT ENCRYPTED, encrypt it by hand now"):format(pretty_name(bufnr)),
            vim.log.levels.ERROR
        )
        return
    end

    -- staying modified is how neovim learns a write failed
    vim.bo[bufnr].modified = false
    remember(bufnr)
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
end

local M = {}

---Take over an encrypted buffer; others are left alone.
---@param bufnr integer
function M.attach(bufnr)
    if vim.b[bufnr].sops then
        -- FileType also fires on :setfiletype, keep unsaved changes
        if vim.bo[bufnr].modified then return end
        -- a reload brings back ciphertext
        vim.b[bufnr].sops_plaintext = not detect.is_encrypted(get_lines(bufnr))
        render(bufnr)
        return
    end
    if vim.bo[bufnr].buftype ~= "" or not detect.is_encrypted(get_lines(bufnr)) then return end

    vim.b[bufnr].sops = true
    vim.b[bufnr].sops_plaintext = false
    -- off before the first decryption; this also deletes the existing swap file
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false

    -- :bdelete forgets b:sops but keeps the buffer's autocommands
    vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
    -- partial writes (:1,2w, :w >>) are left to neovim
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = bufnr,
        desc = "encrypt the buffer back into its file",
        callback = function(args)
            if full_path(args.file) == full_path(vim.api.nvim_buf_get_name(bufnr)) then
                return write(bufnr)
            end
            -- elsewhere: as shown; neovim already refused an existing file without !
            vim.fn.writefile(get_lines(bufnr), args.file)
        end,
    })

    -- neovim just read the ciphertext
    if plaintext then
        render(bufnr)
    else
        remember(bufnr)
    end
end

---Switch every sops buffer between ciphertext and plaintext.
function M.toggle()
    plaintext = not plaintext
    notify(plaintext and "showing plaintext" or "showing ciphertext", vim.log.levels.INFO)

    -- start all before waiting on any, each may wait on the network
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

---Whether sops buffers show plaintext.
---@return boolean
function M.is_plaintext() return plaintext end

return M
