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
local function render(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)

    if not plaintext then
        if vim.fn.filereadable(path) == 0 then
            notify(("cannot read %s back"):format(pretty_name(bufnr)), vim.log.levels.ERROR)
            return
        end
        set_lines(bufnr, vim.fn.readfile(path))
        vim.b[bufnr].sops_plaintext = false
        return
    end

    local lines, err = cli.decrypt(path)
    if not lines then
        notify(("cannot decrypt %s\n%s"):format(pretty_name(bufnr), err), vim.log.levels.ERROR)
        return
    end

    set_lines(bufnr, lines)
    vim.b[bufnr].sops_plaintext = true
end

---@param bufnr integer
local function write(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    local lines = get_lines(bufnr)

    if vim.b[bufnr].sops_plaintext then
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
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
end

local M = {}

---Take over an encrypted buffer, so that it can be toggled and written back.
---Buffers that hold no sops file are left alone.
---@param bufnr integer
function M.attach(bufnr)
    if vim.b[bufnr].sops then
        -- already known, it was just reloaded from disk
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

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = bufnr,
        desc = "encrypt the buffer back into the file",
        callback = function(args)
            -- a write to another name would silently encrypt into our own file
            if full_path(args.file) ~= full_path(vim.api.nvim_buf_get_name(bufnr)) then
                return notify("cannot write elsewhere, use :saveas", vim.log.levels.ERROR)
            end
            write(bufnr)
        end,
    })

    -- we write the file behind neovim's back, so its cached timestamp goes
    -- stale right after saving; without this the plaintext view would be
    -- silently reloaded away on the next focus
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = group,
        buffer = bufnr,
        desc = "never reload over a sops buffer we own",
        callback = function()
            local ours = vim.bo[bufnr].modified or vim.b[bufnr].sops_plaintext
            vim.v.fcs_choice = ours and "" or "reload"
        end,
    })

    render(bufnr)
end

---Switch every sops buffer between its encrypted and decrypted view.
function M.toggle()
    plaintext = not plaintext
    notify(plaintext and "showing plaintext" or "showing ciphertext", vim.log.levels.INFO)

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].sops then
            if vim.bo[bufnr].modified then
                notify(
                    ("%s has unsaved changes, left as is"):format(pretty_name(bufnr)),
                    vim.log.levels.WARN
                )
            else
                render(bufnr)
            end
        end
    end
end

---Whether sops buffers are currently showing their plaintext.
---@return boolean
function M.is_plaintext() return plaintext end

return M
