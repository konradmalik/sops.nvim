local cli = require("sops.cli")

describe("sops that hangs", function()
    local dir, path, timeout = vim.fn.tempname(), vim.env.PATH, cli.timeout

    setup(function()
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "#!/bin/sh", "exec sleep 10" }, vim.fs.joinpath(dir, "sops"))
        vim.fn.setfperm(vim.fs.joinpath(dir, "sops"), "rwx------")
        vim.env.PATH = dir .. ":" .. path
        cli.timeout = 100
    end)

    teardown(function()
        vim.env.PATH = path
        cli.timeout = timeout
        vim.fn.delete(dir, "rf")
    end)

    it("is killed and says so when decrypting", function()
        local lines, err = cli.decrypt("secrets.yaml")

        assert.is_nil(lines)
        assert.are.equal("sops did not finish within 0.1s", err)
    end)

    it("is killed and says so when encrypting", function()
        local ok, err = cli.encrypt("secrets.yaml", { "foo: bar" })

        assert.is_false(ok)
        assert.are.equal("sops did not finish within 0.1s", err)
    end)
end)
