# sops.nvim

> NOTE: vibe-coded, but checked, reviewed, modified and used by me day-to-day

Transparent editing of [sops](https://github.com/getsops/sops) encrypted files.

Main aim:

- simple, very lightweight and maintainable by me
- nothing decrypted written to disk unless you ask for it

`:SopsToggle` swaps the buffer between ciphertext and plaintext in place. No side
buffers, windows or temp files, so everything else keeps working as usual.

Needs neovim 0.10 or newer and `sops` on `$PATH`.

Many similar plugins exist; none fully satisfied me.

## TL;DR

- open an encrypted file: ciphertext
- `:SopsToggle`: every sops buffer shows plaintext, again: ciphertext
- `:w`: encrypts back into the same file

## Notable features

- detects encrypted files by their content
- one global toggle
- turns off `swapfile` and `undofile` before anything is decrypted
- saves via `sops edit`: same data key, so one changed value is one changed line
- verifies every write is encrypted on disk
- refuses to overwrite a file changed on disk, unless `:w!`
- `:w other`, `:1,2w file`, `:w >> file` write what the buffer shows
- `:saveas` writes an encrypted copy using `.sops.yaml`

For a statusline:

- `b:sops`: set on encrypted buffers
- `b:sops_plaintext`: whether the buffer shows plaintext
- `require("sops").is_plaintext()`: the global toggle

## Limitations

- filetypes: `yaml`, `json`, `env`, `dosini`, `confini`
- `:SopsToggle` skips buffers with unsaved changes
- `BufWritePre` (format on save) only fires for plaintext
- sops is killed after 30s; it may leave a decrypted temp file in `$TMPDIR`
- yanked secrets end up in registers and shada
- LSPs and completion plugins see the plaintext, and may log or send it

## Reference

See [my neovim config](https://github.com/konradmalik/neovim-flake).

## Development

`nix develop` (or direnv) enters the devshell and links `.luarc.json`.

```bash
$ nix fmt
$ nix flake check
```

`nix flake check` runs format, shellcheck, luacheck and tests. In the devshell,
`busted --lua=nlua` runs the tests directly.
