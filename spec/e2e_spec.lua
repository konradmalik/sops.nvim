local sops = require("sops")
local utils = require("test.utils")

local secret = "s3cr3t"
local fixture = { "foo: bar", "password: " .. secret }

---The plugin talks through `vim.notify`, which would otherwise print all over
---busted's output. Collect the messages instead, they are worth asserting on.
local notifications = {}

---@param pattern string
---@return boolean
local function notified(pattern)
    return vim.iter(notifications):any(function(msg) return msg:find(pattern) ~= nil end)
end

---@param pattern string
---@return string[]
local function notifications_matching(pattern)
    return vim.tbl_filter(function(msg) return msg:find(pattern) ~= nil end, notifications)
end

if not utils.can_run_sops() then
    describe("with a real sops", function()
        pending("needs the sops and age-keygen binaries", function() end)
    end)
    return
end

describe("with a real sops", function()
    local dir, encrypted
    local notify = vim.notify

    setup(function()
        -- the plugin only wires itself up when its plugin/ file is sourced
        dofile("plugin/sops.lua")
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg) table.insert(notifications, msg) end
    end)

    teardown(function() vim.notify = notify end)

    before_each(function()
        notifications = {}
        dir = utils.prepare_dir()
        encrypted = utils.create_encrypted(dir, "secrets.yaml", fixture)

        -- the toggle is global, so make sure every test starts encrypted
        if sops.is_plaintext() then sops.toggle() end
    end)

    after_each(function()
        utils.close_all_buffers()
        utils.clear_dir(dir)
    end)

    it("detects an encrypted file and shows it encrypted", function()
        local bufnr = utils.open(encrypted)

        assert.is_true(vim.b[bufnr].sops)
        assert.is_false(vim.b[bufnr].sops_plaintext)
        assert.matches("ENC%[AES256_GCM", utils.get_buf_lines(bufnr)[1])
    end)

    it("leaves a file that is not encrypted alone", function()
        local plain = vim.fs.joinpath(dir, "plain.yaml")
        vim.fn.writefile({ "foo: bar" }, plain)

        assert.is_nil(vim.b[utils.open(plain)].sops)
    end)

    it("keeps swap and undo files off, so nothing decrypted can reach the disk", function()
        local bufnr = utils.open(encrypted)

        assert.is_false(vim.bo[bufnr].swapfile)
        assert.is_false(vim.bo[bufnr].undofile)
    end)

    it("shows the plaintext in the same buffer and window when toggled", function()
        local bufnr = utils.open(encrypted)
        local windows = #vim.api.nvim_list_wins()

        sops.toggle()

        assert.are.same({}, notifications_matching("cannot"))
        assert.are.same(fixture, utils.get_buf_lines(bufnr))
        assert.is_true(vim.b[bufnr].sops_plaintext)
        assert.is_false(vim.bo[bufnr].modified)
        assert.are.equal(bufnr, vim.api.nvim_get_current_buf())
        assert.are.equal(windows, #vim.api.nvim_list_wins())

        sops.toggle()

        assert.matches("ENC%[AES256_GCM", utils.get_buf_lines(bufnr)[1])
        assert.is_false(vim.b[bufnr].sops_plaintext)
    end)

    it("toggles every open file at once, not just the current one", function()
        local other = utils.create_encrypted(dir, "other.yaml", { "token: abc" })
        local first, second = utils.open(encrypted), utils.open(other)

        sops.toggle()

        assert.are.same(fixture, utils.get_buf_lines(first))
        assert.are.same({ "token: abc" }, utils.get_buf_lines(second))
    end)

    it("encrypts the buffer back into the file on write", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: changed" })

        vim.cmd.write()

        assert.is_false(vim.bo[bufnr].modified)
        assert.is_not.matches(secret, utils.read(encrypted))
        assert.are.same({ "foo: changed", "password: " .. secret }, utils.decrypt(encrypted))
    end)

    it("only rewrites the values that changed", function()
        local bufnr = utils.open(encrypted)
        local untouched = vim.fn.split(utils.read(encrypted), "\n")[2]
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: changed" })

        vim.cmd.write()

        assert.are.equal(untouched, vim.fn.split(utils.read(encrypted), "\n")[2])
    end)

    it("refuses to write a buffer whose contents are not encrypted", function()
        local bufnr = utils.open(encrypted)
        local before = utils.read(encrypted)
        -- pretend the plaintext flag went wrong, the write must still not happen
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fixture)
        vim.b[bufnr].sops_plaintext = false

        pcall(vim.cmd.write)

        assert.are.equal(before, utils.read(encrypted))
        assert.is_true(vim.bo[bufnr].modified)
        assert.is_true(notified("does not look encrypted"))
    end)

    it("refuses to write the buffer to another file", function()
        local elsewhere = vim.fs.joinpath(dir, "elsewhere.yaml")
        local bufnr = utils.open(encrypted)
        sops.toggle()
        local before = utils.read(encrypted)

        pcall(function() vim.cmd("write " .. elsewhere) end)

        assert.are.equal(0, vim.fn.filereadable(elsewhere))
        assert.are.equal(before, utils.read(encrypted))
        assert.is_true(vim.b[bufnr].sops_plaintext)
        assert.is_true(notified("cannot write a decrypted buffer elsewhere"))
    end)

    it("leaves buffers with unsaved changes as they are", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: unsaved" })

        sops.toggle()

        assert.are.same({ "foo: unsaved", "password: " .. secret }, utils.get_buf_lines(bufnr))
        assert.is_true(vim.b[bufnr].sops_plaintext)
        assert.is_true(notified("unsaved changes"))
    end)

    it("keeps showing the plaintext after a write", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: changed" })
        vim.cmd.write()

        vim.wait(1100)
        vim.cmd.checktime()

        assert.are.same({ "foo: changed", "password: " .. secret }, utils.get_buf_lines(bufnr))
        assert.is_true(vim.b[bufnr].sops_plaintext)
    end)

    it("refuses to overwrite a file that changed on disk", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: changed" })
        utils.edit_externally(encrypted, secret, "rotated")

        pcall(vim.cmd.write)

        assert.are.same({ "foo: bar", "password: rotated" }, utils.decrypt(encrypted))
        assert.is_true(vim.bo[bufnr].modified)
        assert.is_true(notified("changed on disk"))

        vim.cmd("write!")

        assert.are.same({ "foo: changed", "password: " .. secret }, utils.decrypt(encrypted))
        assert.is_false(vim.bo[bufnr].modified)
    end)

    it("writes once after the buffer was deleted and opened again", function()
        utils.open(encrypted)
        vim.cmd.bdelete()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: changed" })

        vim.cmd.write()

        assert.are.same({}, notifications_matching("cannot"))
        assert.are.same({ "foo: changed", "password: " .. secret }, utils.decrypt(encrypted))
    end)

    it("keeps unsaved changes when the filetype is set again", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "foo: unsaved" })

        vim.bo[bufnr].filetype = "json"

        assert.are.same({ "foo: unsaved", "password: " .. secret }, utils.get_buf_lines(bufnr))
        assert.is_true(vim.bo[bufnr].modified)
    end)

    it("knows the buffer holds ciphertext when a reload cannot be decrypted", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()
        local key = vim.env.SOPS_AGE_KEY_FILE
        vim.env.SOPS_AGE_KEY_FILE = nil

        vim.cmd("edit!")
        vim.bo[bufnr].filetype = "json"
        vim.env.SOPS_AGE_KEY_FILE = key

        assert.matches("ENC%[AES256_GCM", utils.get_buf_lines(bufnr)[1])
        assert.is_false(vim.b[bufnr].sops_plaintext)
        assert.is_true(notified("cannot decrypt"))
    end)

    it("writes a buffer without changes without complaining", function()
        local bufnr = utils.open(encrypted)
        sops.toggle()

        vim.cmd.write()

        assert.are.same({}, notifications_matching("cannot"))
        assert.is_false(vim.bo[bufnr].modified)
        assert.are.same(fixture, utils.decrypt(encrypted))
    end)

    it("refuses to write part of the plaintext elsewhere", function()
        local part, appended =
            vim.fs.joinpath(dir, "part.yaml"), vim.fs.joinpath(dir, "appended.yaml")
        vim.fn.writefile({ "existing: line" }, appended)
        utils.open(encrypted)
        sops.toggle()

        pcall(vim.cmd, "1,1write " .. part)
        pcall(vim.cmd, "write >> " .. appended)

        assert.are.equal(0, vim.fn.filereadable(part))
        assert.are.same({ "existing: line" }, vim.fn.readfile(appended))
        assert.is_true(notified("cannot write a decrypted buffer elsewhere"))
    end)

    it("still writes part of the ciphertext elsewhere", function()
        local part = vim.fs.joinpath(dir, "part.yaml")
        local bufnr = utils.open(encrypted)

        vim.cmd("1,2write " .. part)
        vim.cmd("1write >> " .. part)

        local lines = utils.get_buf_lines(bufnr)
        assert.are.same({ lines[1], lines[2], lines[1] }, vim.fn.readfile(part))
    end)

    it("lets formatters run before encrypting, but not on ciphertext", function()
        local formatted = 0
        local id = vim.api.nvim_create_autocmd("BufWritePre", {
            pattern = "*",
            callback = function(args)
                formatted = formatted + 1
                vim.api.nvim_buf_set_lines(args.buf, 0, 1, false, { "foo: formatted" })
            end,
        })
        local bufnr = utils.open(encrypted)
        vim.bo[bufnr].modified = true

        vim.cmd.write()
        sops.toggle()
        vim.cmd.write()
        vim.api.nvim_del_autocmd(id)

        assert.are.equal(1, formatted)
        assert.are.same({ "foo: formatted", "password: " .. secret }, utils.decrypt(encrypted))
        assert.is_false(vim.bo[bufnr].modified)
    end)

    it("saves an encrypted copy with :saveas", function()
        local copy = vim.fs.joinpath(dir, "copy.yaml")
        local bufnr = utils.open(encrypted)
        sops.toggle()
        -- a new file takes its creation rules from the .sops.yaml sops finds
        -- from the working directory
        local cwd = vim.fn.chdir(dir)

        vim.cmd.saveas(copy)
        vim.fn.chdir(cwd)

        assert.are.same({}, notifications_matching("cannot"))
        assert.are.equal(copy, vim.api.nvim_buf_get_name(bufnr))
        assert.is_not.matches(secret, utils.read(copy))
        assert.are.same(fixture, utils.decrypt(copy))
    end)

    it("refuses to copy a buffer that does not look encrypted", function()
        local elsewhere = vim.fs.joinpath(dir, "elsewhere.yaml")
        local bufnr = utils.open(encrypted)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fixture)

        pcall(function() vim.cmd("write " .. elsewhere) end)

        assert.are.equal(0, vim.fn.filereadable(elsewhere))
        assert.is_true(notified("cannot write a decrypted buffer elsewhere"))
    end)

    it("writes a copy of the ciphertext to another file", function()
        local elsewhere = vim.fs.joinpath(dir, "elsewhere.yaml")
        local bufnr = utils.open(encrypted)

        vim.cmd("write " .. elsewhere)

        assert.are.equal(utils.read(encrypted), utils.read(elsewhere))
        assert.are.same(fixture, utils.decrypt(elsewhere))
        assert.are.equal(encrypted, vim.api.nvim_buf_get_name(bufnr))
    end)
end)
