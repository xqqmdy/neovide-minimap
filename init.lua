local M = {}
local minimap_win = nil
local minimap_buf = nil
local source_win = nil
local source_buf = nil
local sync_timer = nil
local is_syncing = false

local FONT_SCALE = 0.35
local MINIMAP_WIDTH = 60 -- logical columns; scaled to ~21 cell widths on screen

local function grid_win_handle(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local prev = vim.api.nvim_get_current_win()
  local ok = pcall(vim.api.nvim_set_current_win, win)
  if not ok then
    return nil
  end
  local handle = vim.fn.win_getid()
  pcall(vim.api.nvim_set_current_win, prev)
  return handle
end

local function send_font_scale(window_handle)
  local channel_id = vim.g.neovide_channel_id
  if not channel_id then
    return
  end
  if not window_handle then
    return
  end
  vim.fn.rpcnotify(channel_id, "neovide.set_grid_font_scale", window_handle, FONT_SCALE)
end

-- Create minimap window
function M.create_minimap()
  if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
    return
  end

  source_win = vim.api.nvim_get_current_win()
  source_buf = vim.api.nvim_get_current_buf()
  local source_ft = vim.bo[source_buf].ft

  -- Create a new buffer for minimap
  minimap_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[minimap_buf].buftype = "nofile"
  vim.bo[minimap_buf].bufhidden = "wipe"
  vim.bo[minimap_buf].swapfile = false
  -- modifiable=true is REQUIRED: Neovim's built-in mouse drag (which enters
  -- visual mode + text selection) only works on modifiable buffers. Content is
  -- still fully managed by sync_content; the user never types here.
  vim.bo[minimap_buf].modifiable = true
  vim.bo[minimap_buf].ft = source_ft ~= "" and source_ft or "text"

  -- Floating window: logical height must cover the whole screen after the
  -- font_scale shrink, so it can show far more lines than a vsplit.
  --   screen_height_px = grid_rows * H
  --   minimap_rows     = grid_rows / font_scale
  local screen_rows = vim.api.nvim_win_get_height(source_win)
  local minimap_rows = math.ceil(screen_rows / FONT_SCALE)

  -- Anchor at the right edge. Neovim positions the float by logical cells
  -- (full scale), but Neovide renders its size at font_scale, so the visual
  -- width is MINIMAP_WIDTH * FONT_SCALE cells. Place the window's left edge so
  -- its rendered (shrunk) right edge lands exactly on the editor's right edge.
  -- The editor width is the full terminal width (no splits), so this hugs the
  -- window's right edge.
  local screen_cols = vim.api.nvim_win_get_width(source_win)
  local visual_width = math.ceil(MINIMAP_WIDTH * FONT_SCALE)
  local col = math.max(screen_cols - visual_width, 0)

  minimap_win = vim.api.nvim_open_win(minimap_buf, false, {
    relative = "editor",
    row = 0,
    col = col,
    width = MINIMAP_WIDTH,
    height = minimap_rows,
    style = "minimal",
    border = "none",
    zindex = 50,
    focusable = true,
    mouse = true,
  })

  -- Window options
  vim.wo[minimap_win].number = false
  vim.wo[minimap_win].relativenumber = false
  vim.wo[minimap_win].cursorline = false
  vim.wo[minimap_win].wrap = false
  vim.wo[minimap_win].signcolumn = "no"
  vim.wo[minimap_win].foldcolumn = "0"
  vim.wo[minimap_win].list = false
  vim.wo[minimap_win].spell = false
  vim.wo[minimap_win].winhighlight = "Normal:NormalFloat"

  -- Send font scale; retry a few times so it lands after the grid is registered.
  local window_handle = grid_win_handle(minimap_win)
  send_font_scale(window_handle)
  for _, delay in ipairs({ 50, 100, 200, 500, 1000 }) do
    vim.defer_fn(function()
      if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
        send_font_scale(window_handle)
      end
    end, delay)
  end

  -- Syntax highlighting: attach treesitter if a parser exists for the filetype.
  local ok_ts = pcall(vim.treesitter.start, minimap_buf, source_ft)
  if not ok_ts and source_ft ~= "" then
    vim.bo[minimap_buf].syntax = source_ft
  end

  -- Initial sync
  M.sync_content()

  -- Set up autocmds for sync
  local group = vim.api.nvim_create_augroup("NeovideMinimap", { clear = true })

  -- Sync on text change (dynamic buffer check so it keeps working after
  -- switching files in the source window)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_buf() == source_buf then
        M.schedule_sync()
      end
    end,
  })

  -- Sync on scroll: WinScrolled fires with the scrolled window as current.
  -- args.win may be nil/odd for some window types, so fall back to the
  -- current window and verify it shows the source buffer.
  vim.api.nvim_create_autocmd({ "WinScrolled" }, {
    group = group,
    callback = function()
      local ok, scrolled_buf = pcall(vim.api.nvim_win_get_buf, vim.api.nvim_get_current_win())
      if ok and scrolled_buf == source_buf then
        M.sync_scroll()
      end
    end,
  })

  -- Sync on cursor move in the source buffer (CursorMoved has no args.win)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      local cur_win = vim.api.nvim_get_current_win()
      if cur_win == minimap_win then
        -- Click or drag on the minimap: Neovim's mouse handling moves the
        -- minimap cursor to the target cell (visual selection while dragging).
        -- Read the minimap's own cursor line (reliable — getmousepos().winid
        -- can be stale by release time) and map it to the source line.
        local cursor = vim.api.nvim_win_get_cursor(minimap_win)
        local line = cursor and cursor[1]
        if line and line > 0 then
          vim.schedule(function()
            if source_win and vim.api.nvim_win_is_valid(source_win) then
              pcall(vim.api.nvim_win_set_cursor, source_win, { line, 0 })
              -- Scroll the minimap's OWN view so the clicked line becomes the
              -- viewport CENTER (not the top — putting it at the top leaves
              -- almost no scroll room when clicking near the top of the file).
              -- set_cursor won't do this: the float's LOGICAL height
              -- (~screen_rows/0.35) exceeds mid-file lines, so Neovim thinks
              -- they're visible.
              if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
                local dbg = io.open("C:/Users/xqqmdy/AppData/Local/Temp/minimap_dbg.log", "a")
                local before = vim.api.nvim_win_call(minimap_win, function()
                  return vim.fn.winsaveview().topline
                end)
                pcall(vim.api.nvim_win_call, minimap_win, function()
                  -- Center the clicked line in the VISIBLE area. The float's
                  -- logical height is screen_rows/0.35 (~112) but only
                  -- screen_rows (~39) rows are on screen; Neovim's topline is
                  -- in logical rows. topline = line - vis_half places the
                  -- clicked line exactly in the middle of the visible band.
                  -- scrolloff=0 prevents Neovim from re-scrolling the cursor
                  -- to satisfy a nonzero scrolloff, which would override the
                  -- topline we just set.
                  local screen_rows = vim.api.nvim_win_get_height(source_win)
                  local vis_half = math.floor(screen_rows / 2) + 30
                  local top = math.max(1, line - vis_half)
                  local prev_so = vim.wo[minimap_win].scrolloff
                  vim.wo[minimap_win].scrolloff = 0
                  pcall(vim.fn.winrestview, { topline = top, lnum = line, col = 0 })
                  vim.wo[minimap_win].scrolloff = prev_so
                end)
                local after = vim.api.nvim_win_call(minimap_win, function()
                  return vim.fn.winsaveview().topline
                end)
                if dbg then
                  dbg:write(string.format("click line=%d mm_top before=%d after=%d\n", line, before, after))
                  dbg:close()
                end
              end
              -- Refresh the minimap viewport highlight while clicking/dragging
              -- (do NOT call sync_scroll: it moves the minimap cursor and
              -- would disturb the in-progress visual selection).
              M.update_viewport_highlight(line)
            end
          end)
        end
      elseif vim.api.nvim_win_get_buf(cur_win) == source_buf then
        -- Skip while a minimap click-jump is in progress (it sets the source
        -- cursor itself and would otherwise scroll the minimap right back).
        if not M._suppress_sync then
          M.sync_scroll()
        end
      end
    end,
  })

  -- Reposition on editor resize (F11 fullscreen, maximize, window drag-resize)
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
          M.reposition()
        end
      end)
    end,
  })

  -- Follow buffer switches: rebind to the new buffer and resync the minimap
  -- content. BufEnter fires when the buffer changes (or when entering a window).
  -- We follow ANY normal window switch, not just source_win, because switching
  -- files can open a new window (telescope, neo-tree, etc.).
  --
  -- Tab switches: a floating window is anchored to ONE tab's editor grid.
  -- Switching tabs hides the float (it belongs to the old tab), so on
  -- TabEnter we tear down and rebuild the minimap in the new tab.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        M.close_minimap()
        if vim.g.neovide then
          M.create_minimap()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      -- Click on the minimap float: scroll the source to the clicked line.
      -- getmousepos() returns line = on-screen row (1-based within window) and
      -- lnum = the actual buffer line under the mouse. The minimap buffer is a
      -- 1:1 copy of the source buffer, so lnum IS the source line number.
      -- Click/drag on the minimap is handled in the CursorMoved autocmd
      -- (Neovim moves the minimap cursor on click; CursorMoved fires reliably
      -- even when getmousepos/BufEnter timing is off). Here we only handle
      -- buffer switches in normal windows.
      if win == minimap_win then
        return
      end
      local new_buf = vim.api.nvim_get_current_buf()
      if new_buf == source_buf then
        return
      end

      -- Switch to the new source buffer/window
      source_win = win
      source_buf = new_buf
      -- minimap_buf may have been wiped by :q closing the tab (BufWipeout →
      -- close_minimap sets it to nil). Guard before touching it.
      if not minimap_buf or not vim.api.nvim_buf_is_valid(minimap_buf) then
        return
      end
      local source_ft = vim.bo[source_buf].ft
      vim.bo[minimap_buf].ft = source_ft ~= "" and source_ft or "text"
      pcall(vim.treesitter.start, minimap_buf, source_ft)

      -- Re-sync content and scroll immediately
      vim.schedule(function()
        if minimap_buf and vim.api.nvim_buf_is_valid(minimap_buf) then
          M.sync_content()
          M.sync_scroll()
        end
      end)
    end,
  })

  -- Clean up on buffer delete (dynamic: source_buf may change after switches)
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      if args.buf == source_buf then
        M.close_minimap()
      end
    end,
  })

  -- Clean up on window close
  vim.api.nvim_create_autocmd({ "WinClosed" }, {
    group = group,
    pattern = tostring(minimap_win),
    callback = function()
      minimap_win = nil
      minimap_buf = nil
    end,
  })

  -- Return to source window
  vim.api.nvim_set_current_win(source_win)
end

-- Reposition the minimap float after the editor grid resized (e.g. F11
-- fullscreen / window maximize). The float is anchored to the editor, so its
-- row/col/width/height must be recomputed from the new editor size.
function M.reposition()
  if not minimap_win or not vim.api.nvim_win_is_valid(minimap_win) then
    return
  end
  if not source_win or not vim.api.nvim_win_is_valid(source_win) then
    return
  end

  local screen_rows = vim.api.nvim_win_get_height(source_win)
  local minimap_rows = math.ceil(screen_rows / FONT_SCALE)
  local screen_cols = vim.api.nvim_win_get_width(source_win)
  local visual_width = math.ceil(MINIMAP_WIDTH * FONT_SCALE)
  local col = math.max(screen_cols - visual_width, 0)

  pcall(vim.api.nvim_win_set_config, minimap_win, {
    relative = "editor",
    row = 0,
    col = col,
    width = MINIMAP_WIDTH,
    height = minimap_rows,
    focusable = true,
    mouse = true,
  })

  -- Re-assert the font scale in case the grid was recreated on resize.
  -- The window may have been closed/rebuild by another WinResized handler
  -- between the check above and here, so re-validate before touching it.
  if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
    local window_handle = grid_win_handle(minimap_win)
    send_font_scale(window_handle)
    M.sync_scroll()
  end
end

-- Close minimap
function M.close_minimap()
  if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
    pcall(vim.api.nvim_win_close, minimap_win, true)
  end
  minimap_win = nil
  minimap_buf = nil
  if sync_timer then
    sync_timer:stop()
    sync_timer = nil
  end
end

-- Toggle minimap
function M.toggle()
  if minimap_win and vim.api.nvim_win_is_valid(minimap_win) then
    M.close_minimap()
  else
    M.create_minimap()
  end
end

-- Schedule content sync (debounced)
function M.schedule_sync()
  if sync_timer then
    sync_timer:stop()
  end
  sync_timer = vim.defer_fn(function()
    M.sync_content()
  end, 50)
end

-- Sync buffer content. Every line is right-padded to MINIMAP_WIDTH so the
-- screen grid actually has cells across the full float width — Neovim only
-- renders background highlight over real cells, so short lines would otherwise
-- stop the viewport band at their content end.
function M.sync_content()
  if not minimap_buf or not vim.api.nvim_buf_is_valid(minimap_buf) then
    return
  end
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    return
  end

  is_syncing = true
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if #line < MINIMAP_WIDTH then
      lines[i] = line .. string.rep(" ", MINIMAP_WIDTH - #line)
    end
  end
  vim.bo[minimap_buf].modifiable = true
  vim.api.nvim_buf_set_lines(minimap_buf, 0, -1, false, lines)
  vim.bo[minimap_buf].modifiable = false
  is_syncing = false

  M.sync_scroll()
end

-- Draw the semi-transparent viewport band on the minimap for the given
-- cursor line. Does NOT touch the minimap cursor/scroll, so it is safe to
-- call right after a click-to-jump (which must not disturb the minimap's
-- own view state).
function M.update_viewport_highlight(cursor_line)
  if not minimap_buf or not vim.api.nvim_buf_is_valid(minimap_buf) then
    return
  end
  cursor_line = cursor_line or 1

  if vim.fn.hlexists("MinimapViewport") == 0 then
    vim.api.nvim_set_hl(0, "MinimapViewport", { bg = "#ffffff", blend = 85 })
  end
  if vim.fn.hlexists("MinimapViewportCursor") == 0 then
    vim.api.nvim_set_hl(0, "MinimapViewportCursor", { bg = "#ffffff", blend = 70 })
  end

  local ns = vim.api.nvim_create_namespace("minimap_viewport")
  vim.api.nvim_buf_clear_namespace(minimap_buf, ns, 0, -1)

  local height = vim.api.nvim_win_get_height(source_win)
  local radius = math.max(1, math.floor(height / 2) - 8)
  local first = math.max(1, cursor_line - radius)
  local last = math.min(vim.api.nvim_buf_line_count(source_buf), cursor_line + radius)

  for l = first, last do
    pcall(vim.api.nvim_buf_set_extmark, minimap_buf, ns, l - 1, 0, {
      end_row = l - 1,
      end_col = MINIMAP_WIDTH,
      hl_group = "MinimapViewport",
      priority = 200,
      strict = false,
    })
  end

  pcall(vim.api.nvim_buf_set_extmark, minimap_buf, ns, cursor_line - 1, 0, {
    end_row = cursor_line - 1,
    end_col = MINIMAP_WIDTH,
    hl_group = "MinimapViewportCursor",
    priority = 200,
    strict = false,
  })
end

-- Sync scroll + viewport indicator:
-- 1. minimap scrolls to follow the source window's viewport (cursor set)
-- 2. cursor-nearby lines get a semi-transparent overlay, full minimap width
--    (VS Code style viewport highlight), driven by Neovide's blend attr.
function M.sync_scroll()
  if not minimap_win or not vim.api.nvim_win_is_valid(minimap_win) then
    return
  end
  if not minimap_buf or not vim.api.nvim_buf_is_valid(minimap_buf) then
    return
  end
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    return
  end

  local current = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current)
  if current_buf ~= source_buf then
    if source_win and vim.api.nvim_win_is_valid(source_win)
      and vim.api.nvim_win_get_buf(source_win) == source_buf then
      current = source_win
    else
      return
    end
  end

  local src_view = vim.api.nvim_win_call(current, vim.fn.winsaveview)

  -- 1) Scroll the minimap so the source cursor line sits centered (with the
  -- same bottom-biased offset as click-to-jump: floor(h/2)+30). This keeps
  -- keyboard navigation (j/k/ctrl-d…) visually consistent with clicking the
  -- minimap.
  pcall(vim.api.nvim_win_call, minimap_win, function()
    local max_line = vim.api.nvim_buf_line_count(minimap_buf)
    local screen_rows = vim.api.nvim_win_get_height(source_win)
    local offset = math.floor(screen_rows / 2) + 30
    local target = math.min(math.max(src_view.lnum - offset, 1), max_line)
    local prev_so = vim.wo[minimap_win].scrolloff
    vim.wo[minimap_win].scrolloff = 0
    pcall(vim.fn.winrestview, { topline = target, lnum = src_view.lnum, col = 0 })
    vim.wo[minimap_win].scrolloff = prev_so
  end)

  -- 2) Viewport highlight
  M.update_viewport_highlight(src_view.lnum)
end

-- Keybindings
vim.keymap.set("n", "<leader>mm", M.toggle, { desc = "Toggle Minimap" })
vim.keymap.set("n", "<leader>mc", M.close_minimap, { desc = "Close Minimap" })

-- Auto-open the minimap as soon as Neovide starts. No deferred delay: by
-- VimEnter all lazy=false plugins have loaded, and the font-scale race
-- (notification arriving before the float's grid is registered in Neovide)
-- is absorbed by the retry defers inside create_minimap.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    if vim.g.neovide then
      M.create_minimap()
    end
  end,
})

-- Export for manual use
_G.NeovideMinimap = M

return M