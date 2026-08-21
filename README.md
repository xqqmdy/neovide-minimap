# neovide-minimap

VS Code-style minimap for [Neovide](https://github.com/neovide/neovide): a floating
window rendering real code at ~5pt via Neovide's per-window font scaling
(`vim.w.neovide_font_scale`), not Braille glyphs.

## Coupling with the Neovide fork

This plugin depends on one extension that only exists in the [patched
Neovide](https://github.com/xqqmdy/neovide) at `https://github.com/xqqmdy/neovide` (branch `feature/minimap`):

| Extension | Provided by (neovide-src) |
|---|---|
| window-local variable `neovide_font_scale` | `src/bridge/handler.rs` (`sync_window_font_scale`) |

Protocol: set `vim.w[winid].neovide_font_scale = 0.35` on the floating window.
Neovide reads the variable on every `win_pos` / `win_float_pos` UI event and
renders that grid with a scaled font (clamped to `[0.1, 1.0]` on the Rust side).
Plain nvim / upstream Neovide ignore the variable silently.

Auto-opens on VimEnter under Neovide

## Install

lazy.nvim spec:

```lua
return {
  "xqqmdy/neovide-minimap",
  priority = 1000,
  lazy = false,
  config = function()
    if vim.g.neovide then
      require("neovide-minimap")
    end
  end,
}
```

## Usage

- `<leader>mm` — toggle

