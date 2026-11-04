-- Filetypes sops can parse; `binary` files are not covered.
local filetypes = {
    "confini",
    "dosini",
    "env",
    "json",
    "yaml",
}

local group = vim.api.nvim_create_augroup("Sops", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = filetypes,
    callback = function(args) require("sops").attach(args.buf) end,
})

vim.api.nvim_create_user_command(
    "SopsToggle",
    function() require("sops").toggle() end,
    { desc = "Toggle all sops files between their encrypted and decrypted view" }
)

vim.api.nvim_create_user_command(
    "SopsEncrypt",
    function(args)
        require("sops").encrypt(
            vim.api.nvim_get_current_buf(),
            args.args ~= "" and args.args or nil
        )
    end,
    { nargs = "?", complete = "file", desc = "Encrypt the current buffer into its file, or {file}" }
)
