# mdtoc.nvim - Table of contents for markdown files and anything else

_mdtoc_ stands for "Make Dynamic Table Of Contents".

Why? I need visible overview of toc of large markdown files.

Creates a floating window. Uses Treesitter to parse the markdown file and generate a table of contents. The table of contents (toc) is updated as the markdown file is edited. Moving around in the file moves the highlight in the toc-display. Moving in the toc display moves the cursor document in paralell.

Not only markdown: Because of treesitter, it can parse anything. Works the same for code, showing functions in the toc.

> [!Caution]
> Bug Alert: This is a buggy plugin not intended for public usability, but will probably be improved over time, and maybe made into a proper plugin.

About the code: This code was boilerplate genrated by ChatGPT, 4o and o1 in iterations alongside fixing bugs and adding features by hand.

Requirements:

[fixedspace.nvim](https://github.com/fmxsh/fixedspace.nvim)

Use the plugin _fixedspace_. The floating window is floating, meaning text goes under it. I want word-break at the edge of the toc-window. _Fixedspace_ creates a real non-enterable, non-editable window underneaht the floating window. This sounds like a bad solution, but my first attempt to create real-window-only solutoin messed things up. Later the float solution had its own design issues (text going under). I experimented with hiding the toc window when cursor was X number of characters close to it, but it amounted to an unintuitive clumsy ui anyway. A quick hack was to create a real window underneath, by the way of a separate plugin. I just need this to work, rather than how.

## Installation

Integrated into my own project manager, to close and open on project switching.

This goes into `.config/nvim/lua/custom/plugins/mdtoc.lua`, which is loaded by my highly modified kickstart.lua running Lazy plugin manager.

> [!Note]
> This is not provided in a user friendly way and not expected to be used as it is.

```lua
return {
  'fmxsh/mdtoc.nvim',
  dependencies = {},
  config = function()
    local colors = require 'nvim-color-theme.themes.pastel1_own'
    require('mdtoc').setup {
      window_size = 40,
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
      pattern = 'preSwitchToProject',
      callback = function()
        require('mdtoc').disable()
      end,
    })

    vim.api.nvim_create_autocmd('User', {
      pattern = 'postSwitchToProject',
      callback = function()
        require('mdtoc').enable()
      end,
    })

    -- When the plugin is loaded first time, start the plugin
    require('mdtoc').start()

    -- why this defer is the case I do not know,
    -- but intuition tells me...
    -- If Treesitter hasn't fully parsed the Markdown/Lua buffer yet, ...?
    -- Chat 4o's answer:
    -- Why Even 1ms Delay Works
    --    1ms delay doesn’t mean "1ms after now"
    --    It means "run this after all other queued startup events finish."
    -- This seem to apply only when nvim is starting up, but after that, it works as a normal timer. Chat 4o's answer:
    -- 	Before Neovim is fully started → The function waits until startup is done.
    --	After startup → The function behaves like a normal timer (runs in ~1ms).
    vim.defer_fn(function()
      require('mdtoc').enable()
    end, 1)
  end,
}
```
