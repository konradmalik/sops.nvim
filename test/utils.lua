---@param cmd string[]
---@param opts vim.SystemOpts?
---@return vim.SystemCompleted
local function run(cmd, opts)
    local res = vim.system(cmd, opts or {}):wait()
    if res.code ~= 0 then error(table.concat(cmd, " ") .. " failed: " .. tostring(res.stderr)) end
    return res
end

---@param path string
---@return string
local function read(path) return table.concat(vim.fn.readfile(path), "\n") end

return {
    read = read,

    ---Whether real sops tests can run.
    ---@return boolean
    can_run_sops = function()
        return vim.fn.executable("sops") == 1 and vim.fn.executable("age-keygen") == 1
    end,

    ---Temp dir with an age key and a matching .sops.yaml.
    ---@return string
    prepare_dir = function()
        local res = run({ "mktemp", "-d", "-t", "sops-nvim-XXXXXX" }, { text = true })
        local dir = vim.fn.split(res.stdout, "\n")[1]

        local key = vim.fs.joinpath(dir, "key.txt")
        run({ "age-keygen", "-o", key })
        vim.fn.writefile({
            "creation_rules:",
            "  - path_regex: .*",
            "    age: " .. read(key):match("public key: (age%w+)"),
        }, vim.fs.joinpath(dir, ".sops.yaml"))
        vim.env.SOPS_AGE_KEY_FILE = key

        return dir
    end,

    ---@param dir string
    clear_dir = function(dir)
        vim.fn.delete(dir, "rf")
        vim.env.SOPS_AGE_KEY_FILE = nil
    end,

    ---Write `lines` to `dir/name` and encrypt in place. --config because sops
    ---looks for .sops.yaml from the working directory.
    ---@param dir string
    ---@param name string
    ---@param lines string[]
    ---@return string path
    create_encrypted = function(dir, name, lines)
        local path = vim.fs.joinpath(dir, name)
        vim.fn.writefile(lines, path)
        local config = vim.fs.joinpath(dir, ".sops.yaml")
        run({ "sops", "--config", config, "encrypt", "--in-place", path })
        return path
    end,

    ---@param path string
    ---@return string[]
    decrypt = function(path)
        return vim.fn.split(run({ "sops", "decrypt", path }, { text = true }).stdout, "\n")
    end,

    ---Change the file outside of neovim.
    ---@param path string
    ---@param from string
    ---@param to string
    edit_externally = function(path, from, to)
        -- no `sed -i`, differs on darwin
        local editor = ([[sh -c 'sed s/%s/%s/ "$0" > "$0.new" && mv "$0.new" "$0"']]):format(
            from,
            to
        )
        run({ "sops", "edit", path }, { env = { EDITOR = editor } })
    end,

    ---Open a file and set its filetype by hand, `-u NONE` has no detection.
    ---@param path string
    ---@return integer
    open = function(path)
        vim.cmd.edit(path)
        local bufnr = vim.api.nvim_get_current_buf()
        vim.bo[bufnr].filetype = "yaml"
        return bufnr
    end,

    ---@param bufnr integer
    ---@return string[]
    get_buf_lines = function(bufnr) return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true) end,

    ---Wipe all, including the initial buffer `:edit` reused.
    close_all_buffers = function() vim.cmd("silent! %bwipeout!") end,
}
