# mdtoc.nvim - Table of contents for markdown files and anything else

_mdtoc_ stands for "Make Dynamic Table Of Contents".

Why? I need visible overview of toc of large markdown files.

Creates a table of contents (toc) for markdown content **or any other format supported by Treesitter** (but you have to write the parser directives for it).

The content is sent to a buf_id, which you create yourself (thus I made a plugin for it, [fixedspace.nvim](https://github.com/fmxsh/fixedspace.nvim)).

The table of contents (toc) is updated as the markdown file is edited. Moving around in the file moves the highlight in the toc-display. Moving in the toc display moves the cursor document in paralell.

Not only markdown: Because of treesitter, it can parse anything. Works the same for code, showing functions in the toc.

> [!Caution]
> Bug Alert: This is a buggy plugin not intended for public usability, but will probably be improved over time, and maybe made into a proper plugin.

> [!Note]
> Mostly made to integrate with a personal project manager that is not published anywhere yet.

About the code: This code was boilerplate genrated by ChatGPT, 4o and o1 in iterations alongside fixing bugs and adding features by hand.

Requirements:

- [fixedspace.nvim](https://github.com/fmxsh/fixedspace.nvim)

- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)

## Installation

Two code examples are provided.

Integrated into my own project manager, to close and open on project switching.

This goes into `.config/nvim/lua/custom/plugins/mdtoc.lua`, which is loaded by my highly modified kickstart.lua running Lazy plugin manager.

> [!Note]
> This is not provided in a user friendly way and not expected to be used as it is. Its my highly specific setup. The plugin is not made addapted for public use.

### Lazy initialization

```lua
return {
  'fmxsh/mdtoc.nvim',
  dependencies = {},
  config = function()
    local colors = require 'nvim-color-theme.themes.pastel1_own'
    require('mdtoc').setup {
      float_window = 20,
      -- Define highlight options for each heading level
      hl_groups = {
        h1 = { fg = colors.markup_heading_1 },
        h2 = { fg = colors.markup_heading_2 },
        h3 = { fg = colors.markup_heading_3 },
        h4 = { fg = colors.markup_heading_4 },
        h5 = { fg = colors.markup_heading_5 },
        h6 = { fg = colors.markup_heading_6 },
      },
    }
    vim.api.nvim_create_autocmd('User', {
      pattern = 'phxmanPostLoaded',
      callback = function()
        -- Only create user commands if phxman is loaded
        vim.api.nvim_create_autocmd('User', {
          pattern = 'postSwitchToProject',
          callback = function()
            require('mdtoc').update_scratch_buffer()
            require('mdtoc').highlight_active_toc_entry()
            require('mdtoc').attach_main_buf_autocmds()
            require('mdtoc').attach_toc_buf_autocmds()
            require('mdtoc').fix_statusline()
          end,
        })

        -- First time start it up
        vim.defer_fn(function()
          require('mdtoc').start()
          require('mdtoc').update_scratch_buffer()
        end, 1)
      end,
    })

  end,
}
```

### Key bindings for header navigation

Also now supports keybindings, to do like <num>j in normal mode to jump down x, and in context of toc, jump down x headings. <num>p for up.

```lua
    vim.keymap.set({ 'n', 'v' }, '<C-n>', function()
      local count = vim.v.count -- Get the count if provided
      if count > 0 then
        require('mdtoc').jump_to(count)
      else
        require('mdtoc').next_heading()
      end
    end, { noremap = true, silent = true })

    vim.keymap.set({ 'n', 'v' }, '<C-p>', function()
      local count = vim.v.count -- Get the count if provided
      if count > 0 then
        require('mdtoc').jump_to(-count)
      else
        require('mdtoc').prev_heading()
      end
    end, { noremap = true, silent = true })

    --    vim.keymap.set({ 'n', 'v' }, '<C-n>', '<CMD>lua require("mdtoc").next_heading()<CR>', { noremap = true, silent = true })
    --    vim.keymap.set({ 'n', 'v' }, '<C-p>', '<CMD>lua require("mdtoc").prev_heading()<CR>', { noremap = true, silent = true })
    vim.keymap.set({ 'n', 'v' }, '<C-h>', '<CMD>lua require("mdtoc").telescope_headings()<CR>', { noremap = true, silent = true })
```
