# sops.nvim

> NOTE: vibe-coded, but checked and used by me day-to-day

Transparent editing of [sops](https://github.com/getsops/sops) encrypted files.

Main aim:

- simple, very lightweight and maintainable by me
- nothing decrypted ever written to disk

An encrypted file opens like any other file. The buffer stays mapped onto the real
file on disk and `:SopsToggle` swaps what that buffer shows between ciphertext and
plaintext. No side buffers, no side windows, no temporary files, so quickfix,
winbar, statusline and everything else keep behaving as usual.

Needs `sops` on `$PATH`, plus whatever keys it needs to do its job.

There are many similar plugins already. I was not fully satisfied with any of them, so I made my own.

## TL;DR

There is nothing to configure and no `setup` to call.

- open an encrypted file: you see the ciphertext
- `:SopsToggle`: every sops buffer shows its plaintext, again and they all go back
- `:w`: encrypts the buffer back into the same file, whichever view you are in

## Notable features

- detects encrypted files by their content, no file name patterns to maintain
- one global toggle, not one per file
- turns off `swapfile` and `undofile` before anything is decrypted
- saves through `sops edit`, which reuses the file's existing data key and
  recipients, so changing one value changes one line in git
- verifies after every write that what landed on disk is encrypted, and says so
  loudly if it is not
- `:saveas` writes an encrypted copy, keyed by the `.sops.yaml` creation rules

Every buffer it takes over gets two variables, useful for a statusline:

- `b:sops`, set on every encrypted file it has taken over
- `b:sops_plaintext`, whether that buffer currently shows its plaintext

The same state is available as `require("sops").is_plaintext()`.

## Limitations

- only filetypes sops can parse: `yaml`, `json`, `env`, `dosini` and `confini`.
  Files encrypted with sops' `binary` input type keep the name and extension of
  whatever they were, so they are not detected
- `:SopsToggle` skips buffers with unsaved changes, save or undo them first
- format on save does not run on these buffers, `BufWritePre` is not fired
- `:w other-file` is refused, use `:saveas`
- a partial write of a decrypted buffer (`:1,2w file`, `:w >> file`) is not
  guarded, it writes plaintext like it would for any other buffer
- sops is killed after 30s, and a killed sops leaves its own temporary decrypted
  copy behind in `$TMPDIR`
- a yanked secret still ends up in registers and in shada

## Reference

For reference usage see [my neovim config](https://github.com/konradmalik/neovim-flake).
