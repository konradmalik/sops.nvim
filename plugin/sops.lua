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
