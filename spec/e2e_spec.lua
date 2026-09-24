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

        assert.are.same(
            {},
            vim.tbl_filter(function(m) return m:find("cannot") ~= nil end, notifications)
        )
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
        assert.is_true(notified("cannot write elsewhere"))
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
end)
