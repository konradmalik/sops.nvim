local cli = require("sops.cli")
local utils = require("test.utils")

---Put a fake `sops` running `script` first on $PATH for the tests in the block.
---@param script string
local function fake_sops(script)
    local dir, path = vim.fn.tempname(), vim.env.PATH

    setup(function()
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "#!/bin/sh", script }, vim.fs.joinpath(dir, "sops"))
        vim.fn.setfperm(vim.fs.joinpath(dir, "sops"), "rwx------")
        vim.env.PATH = dir .. ":" .. path
    end)

    teardown(function()
        vim.env.PATH = path
        vim.fn.delete(dir, "rf")
    end)

    return dir
end

describe("sops that hangs", function()
    local timeout = cli.timeout
    fake_sops("exec sleep 10")

    setup(function() cli.timeout = 100 end)
    teardown(function() cli.timeout = timeout end)

    it("is killed and says so when decrypting", function()
        local lines, err = cli.decrypt("secrets.yaml")()

        assert.is_nil(lines)
        assert.are.equal("sops did not finish within 0.1s", err)
    end)

    it("is killed and says so when encrypting", function()
        local ok, err = cli.encrypt("secrets.yaml", { "foo: bar" })

        assert.is_false(ok)
        assert.are.equal("sops did not finish within 0.1s", err)
    end)
end)

describe("sops that is slow", function()
    -- `sops decrypt <path>` prints the file as it is
    local dir = fake_sops('sleep 0.3; cat "$2"')
    local encrypted =
        { "password: ENC[AES256_GCM,data:Tr7o,type:str]", "sops:", "    version: 3.13.3" }

    local notify = vim.notify

    ---@diagnostic disable-next-line: duplicate-set-field
    setup(function()
        vim.notify = function() end
    end)
    teardown(function() vim.notify = notify end)
    after_each(utils.close_all_buffers)

    it("decrypts every buffer at once on toggle", function()
        local sops = require("sops")
        for i = 1, 3 do
            local path = vim.fs.joinpath(dir, i .. ".yaml")
            vim.fn.writefile(encrypted, path)
            vim.cmd.edit(path)
            sops.attach(vim.api.nvim_get_current_buf())
        end

        local start = vim.uv.hrtime()
        sops.toggle()
        local took = (vim.uv.hrtime() - start) / 1e6
        sops.toggle()

        assert.is_true(took < 600, ("took %dms"):format(took))
    end)
end)
