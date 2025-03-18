--------------------------------------------------------------------------------
-- mdtoc.lua
-- A minimal “TOC” side-window for markdown or lua files, using `fixedspace` plugin
-- Highlights headings in the TOC, moves the main buffer cursor if you scroll
-- in the TOC, etc.
--------------------------------------------------------------------------------
--
-- ChatGPT o1 fixed my mess when porting this code from using its own float window, to using buffer created by the fixedspace plugin...
-- Ever experienced porting something and its supposed to be simple, but every action creates more bugs? The more you struggle, the more you sink...

local M = {}

-- Default highlight groups
local default_opts = {
	float_width = 25,
	float_col_offset = 0,
	float_row_offset = 0,
	border = "rounded",
	hl_groups = {
		h1 = { fg = "#e9ff00" },
		h2 = { fg = "#00e9ff" },
		h3 = { fg = "#00ff15" },
		h4 = { fg = "#919ae2" },
		h5 = { fg = "#ff55aa" },
		h6 = { fg = "#ff9933" },
	},
}

local opts = {}
-- Will hold the TOC buffer and other data
local scratch_buf = nil
local is_active = false

-- Will keep track of your “source” (markdown/lua) buffer & window
local last_active_buf = nil
local last_active_win = nil

-- A table of headings => each entry { text, level, line }
local toc_headings = {}

-- We'll store our autocmd group ID so we can clear it on disable():
local autocmd_group = nil

-- ─────────────────────────────────────────────────────────────────────────────
-- Setup
-- ─────────────────────────────────────────────────────────────────────────────
function M.setup(user_opts)
	opts = vim.tbl_deep_extend("force", default_opts, user_opts or {})
	-- Define highlight groups for headings 1..6
	vim.api.nvim_set_hl(0, "MDTocHeading1", opts.hl_groups.h1)
	vim.api.nvim_set_hl(0, "MDTocHeading2", opts.hl_groups.h2)
	vim.api.nvim_set_hl(0, "MDTocHeading3", opts.hl_groups.h3)
	vim.api.nvim_set_hl(0, "MDTocHeading4", opts.hl_groups.h4)
	vim.api.nvim_set_hl(0, "MDTocHeading5", opts.hl_groups.h5)
	vim.api.nvim_set_hl(0, "MDTocHeading6", opts.hl_groups.h6)
	vim.api.nvim_set_hl(0, "MDTocCurrent", { bg = "#44475a", bold = true })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Utility: get (or create) the scratch buffer from 'fixedspace'
-- ─────────────────────────────────────────────────────────────────────────────
local function get_scratch_buffer()
	-- We rely on the `fixedspace` plugin to have a .buf_id
	local fixedspace = require("fixedspace")
	if not fixedspace.buf_id or not vim.api.nvim_buf_is_valid(fixedspace.buf_id) then
		return nil
	end
	return fixedspace.buf_id
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Treesitter: parse the main buffer (markdown/lua) to find headings
-- ─────────────────────────────────────────────────────────────────────────────
local function extract_headings()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		return {}
	end

	local ft = vim.bo[last_active_buf].filetype
	local parser = vim.treesitter.get_parser(last_active_buf, ft)
	if not parser then
		return {}
	end
	local tree = parser:parse()[1]
	if not tree then
		return {}
	end

	local root = tree:root()
	toc_headings = {} -- global table

	local headings = {}
	if ft == "markdown" then
		----------------------------------------------------------------------
		-- For Markdown, capture atx/setext headings
		----------------------------------------------------------------------
		local query_str = [[
(atx_heading
  (atx_h1_marker)? @level
  (atx_h2_marker)? @level
  (atx_h3_marker)? @level
  (atx_h4_marker)? @level
  (atx_h5_marker)? @level
  (atx_h6_marker)? @level
  (inline) @content)

(setext_heading
  (paragraph (inline) @content)
  (setext_h1_underline)? @level
  (setext_h2_underline)? @level)
]]
		local query = vim.treesitter.query.parse("markdown", query_str)
		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local level
			local content
			local heading_node

			for id, node in pairs(match) do
				local cap = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)
				if cap == "level" then
					level = #text
				elseif cap == "content" then
					content = text
					heading_node = node
				end
			end

			if level and content and heading_node then
				local line = heading_node:start() -- 0-based
				table.insert(toc_headings, {
					text = content,
					level = level,
					line = line,
				})
				-- For indentation display in the TOC buffer:
				table.insert(headings, string.rep("  ", level - 1) .. "- " .. content)
			end
		end
	elseif ft == "lua" then
		----------------------------------------------------------------------
		-- For Lua, capture function definitions
		----------------------------------------------------------------------
		local query_str = [[
(function_declaration
    name: (identifier) @func_name)

(function_declaration
    name: (dot_index_expression
      table: (identifier) @table_name
      field: (identifier) @field_name))

(field
    name: (identifier) @table_field_name
    value: (function_definition))
]]
		local query = vim.treesitter.query.parse("lua", query_str)
		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local func_name = ""
			local start_row

			for id, node in pairs(match) do
				local cap_name = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)
				if cap_name == "func_name" then
					func_name = text
					start_row = node:start()
				elseif cap_name == "table_name" then
					local table_name = text
					local field_node = match[id + 1] -- Next capture is field_name
					local field_name = vim.treesitter.get_node_text(field_node, last_active_buf)
					func_name = table_name .. "." .. field_name
					start_row = node:start()
				elseif cap_name == "table_field_name" then
					func_name = text
					start_row = node:start()
				end
			end

			if func_name ~= "" and start_row then
				table.insert(toc_headings, {
					text = func_name,
					level = 1,
					line = start_row,
				})
				table.insert(headings, "- " .. func_name)
			end
		end
	end

	return headings
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Update the scratch buffer lines, apply highlight for headings
-- ─────────────────────────────────────────────────────────────────────────────
function M.update_scratch_buffer()
	local buf = get_scratch_buffer()
	if not buf then
		return
	end

	-- Clear old lines
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

	-- We'll turn off treesitter highlights in the “TOC” buffer
	vim.treesitter.stop(buf)
	vim.bo[buf].filetype = "plaintext"

	local hl_groups = opts.hl_groups or {}
	local hl_map = {
		[1] = "MDTocHeading1",
		[2] = "MDTocHeading2",
		[3] = "MDTocHeading3",
		[4] = "MDTocHeading4",
		[5] = "MDTocHeading5",
		[6] = "MDTocHeading6",
	}

	-- Re-set highlight definitions (in case your config changes them)
	for level, hl_name in pairs(hl_map) do
		local color = hl_groups["h" .. level]
		if color then
			vim.api.nvim_set_hl(0, hl_name, color)
		end
	end

	-- Re-extract headings from the main buffer
	local headings = extract_headings()

	-- Place them in the TOC buffer
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, headings)

	-- Defer highlight (tiny delay) to avoid flicker if state changes quickly
	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		for i, heading in ipairs(headings) do
			local spaces = heading:match("^%s*") or ""
			local level = math.floor(#spaces / 2) + 1
			level = math.max(1, math.min(level, 6))
			local hl_group = hl_map[level] or "MDTocHeading1"
			vim.api.nvim_buf_add_highlight(buf, -1, hl_group, i - 1, 0, -1)
		end
	end, 10)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Identify which heading we are “in” based on the main-buffer cursor
-- ─────────────────────────────────────────────────────────────────────────────
local function get_current_section()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		return nil
	end
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1
	local current_section = nil
	local last_section_line = 0

	for _, heading in ipairs(toc_headings) do
		if heading.line <= cursor_line and heading.line >= last_section_line then
			current_section = heading.line
			last_section_line = heading.line
		end
	end
	return current_section
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Defer highlight of the “active heading” in the TOC
-- ─────────────────────────────────────────────────────────────────────────────
local function deferred_highlight_active_toc_entry()
	if not is_active then
		return
	end

	local buf = get_scratch_buffer()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local current_line = get_current_section()
	if not current_line then
		return
	end

	-- Find which index in toc_headings matches that line
	local target_line
	for i, heading in ipairs(toc_headings) do
		if heading.line == current_line then
			target_line = i - 1
			break
		end
	end
	if not target_line then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	if target_line >= line_count then
		target_line = line_count - 1
	end
	if target_line < 0 then
		target_line = 0
	end

	-- Clear old highlight
	local ns_id = vim.api.nvim_create_namespace("MDTocCurrent")
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	-- Highlight
	vim.api.nvim_buf_add_highlight(buf, ns_id, "MDTocCurrent", target_line, 0, -1)

	-- Optionally move the scratch buffer’s cursor
	local fixedspace = require("fixedspace")
	local scratch_win = fixedspace.win_id
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		vim.api.nvim_win_call(scratch_win, function()
			vim.api.nvim_win_set_cursor(scratch_win, { target_line + 1, 0 })
		end)
	end
	local scratch_win = fixedspace.win_id
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		vim.api.nvim_win_call(scratch_win, function()
			vim.api.nvim_win_set_cursor(scratch_win, { target_line + 1, 0 })
		end)
	end
end

-- Slight wrapper so we only schedule once
function M.highlight_active_toc_entry()
	vim.defer_fn(function()
		deferred_highlight_active_toc_entry()
		--end, 110)
	end, 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Autocmds that watch the *main buffer* and update the TOC
-- ─────────────────────────────────────────────────────────────────────────────
function M.attach_main_buf_autocmds()
	-- On entering or writing (etc.) a markdown/lua buffer, re-extract headings
	vim.api.nvim_create_autocmd({ "WinClosed", "WinEnter", "BufEnter", "BufWinEnter", "BufWritePost", "InsertLeave" }, {
		group = autocmd_group,
		callback = function()
			if not is_active then
				return
			end
			local current_buf = vim.api.nvim_get_current_buf()
			local ft = vim.bo[current_buf].filetype
			if ft == "markdown" or ft == "lua" then
				last_active_buf = current_buf
				last_active_win = vim.api.nvim_get_current_win()
				-- Defer to let Neovim finalize window layout if needed

				vim.defer_fn(function()
					M.update_scratch_buffer()
					M.highlight_active_toc_entry()
				end, 1)
			end
		end,
	})

	-- Also track cursor movement in the main buffer, to highlight in the TOC
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = autocmd_group,
		callback = function()
			-- If we’re in the scratch_buf, skip
			if vim.api.nvim_get_current_buf() == scratch_buf then
				return
			end
			deferred_highlight_active_toc_entry()
		end,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Autocmds that watch the *TOC buffer* and jump in the main buffer
-- ─────────────────────────────────────────────────────────────────────────────
function M.attach_toc_buf_autocmds()
	local buf = get_scratch_buffer()
	if not buf then
		return
	end

	-- When you move in the scratch buffer, jump the cursor in the main window
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = autocmd_group,
		buffer = buf,
		callback = function()
			log("CursorMoved in TOC buffer")
			if last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
				local row = vim.api.nvim_win_get_cursor(0)[1]
				local heading_entry = toc_headings[row]
				if heading_entry then
					vim.api.nvim_win_set_cursor(last_active_win, { heading_entry.line + 1, 0 })
				end
			end
		end,
		desc = "Jump to selected heading in the main buffer when you move in the TOC",
	})

	-- Hitting <CR> in the TOC buffer refocuses the main buffer
	vim.keymap.set("n", "<CR>", function()
		if last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
			vim.api.nvim_set_current_win(last_active_win)
			M.highlight_active_toc_entry()
		end
	end, { buffer = buf, noremap = true, silent = true })
end

------------ Bottom status line showing what header you are in
local statusline_buf = nil
local statusline_win = nil

local function update_statusline_text()
	if not statusline_win or not vim.api.nvim_win_is_valid(statusline_win) then
		return
	end

	local current_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	local breadcrumbs = {}

	-- Get the full file path
	local file_path = vim.api.nvim_buf_get_name(0)
	if file_path == "" then
		file_path = "[No Name]" -- Handle unnamed buffers
	end

	-- Track last valid parents at each level
	local last_valid_parents = {}

	-- Define highlight groups mapping
	local hl_groups = opts.hl_groups or {}
	local hl_map = {
		[1] = "MDTocHeading1",
		[2] = "MDTocHeading2",
		[3] = "MDTocHeading3",
		[4] = "MDTocHeading4",
		[5] = "MDTocHeading5",
		[6] = "MDTocHeading6",
	}

	-- Iterate through headings in order
	for _, heading in ipairs(toc_headings) do
		if heading.line <= current_line then
			-- Store valid parent heading for its level
			-- Clear deeper levels when moving up
			for lvl = heading.level + 1, 6 do
				last_valid_parents[lvl] = nil
			end
			last_valid_parents[heading.level] = heading.text
		else
			break -- Stop checking when passing the current cursor position
		end
	end

	-- Assemble correct hierarchical structure
	local display_parts = {}
	local highlight_info = {}

	-- Traverse from level 1 up to find non-nil parents
	for level = 1, 6 do
		local heading_text = last_valid_parents[level]
		if heading_text then
			local hl_group = hl_map[level] or "MDTocHeading1"

			-- Ensure highlight exists
			if hl_groups["h" .. level] then
				vim.api.nvim_set_hl(0, hl_group, hl_groups["h" .. level])
			end

			-- Store breadcrumb with highlight info
			table.insert(display_parts, heading_text)
			table.insert(highlight_info, { text = heading_text, hl = hl_group })
		end
	end

	-- Ensure fallback text if no headings found
	if #display_parts == 0 then
		display_parts = { "No Heading" }
		highlight_info = { { text = "No Heading", hl = "Normal" } }
	end

	-- Construct the final display text for headings
	local heading_text = table.concat(display_parts, " > ")

	-- Temporarily enable modifications
	vim.bo[statusline_buf].modifiable = true
	vim.api.nvim_buf_set_lines(statusline_buf, 0, -1, false, { file_path, "  " .. heading_text })
	vim.bo[statusline_buf].modifiable = false -- Lock buffer again

	-- Apply highlights correctly
	vim.api.nvim_buf_clear_namespace(statusline_buf, -1, 0, -1) -- Clear previous highlights

	-- Apply highlights for headings
	local pos = 2 -- Account for leading space
	for _, item in ipairs(highlight_info) do
		local hl_group = item.hl
		local text_length = #item.text
		vim.api.nvim_buf_add_highlight(statusline_buf, -1, hl_group, 1, pos, pos + text_length) -- Apply to second line
		pos = pos + text_length + 3 -- Move past " > "
	end
end

local function create_statusline_window()
	if statusline_win and vim.api.nvim_win_is_valid(statusline_win) then
		return
	end

	-- Create a scratch buffer if it doesn't exist
	if not statusline_buf or not vim.api.nvim_buf_is_valid(statusline_buf) then
		statusline_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(statusline_buf, "current_heading_status")
		vim.bo[statusline_buf].buftype = "nofile"
		vim.bo[statusline_buf].bufhidden = "wipe"
		vim.bo[statusline_buf].modifiable = true -- Allow modifications temporarily
		vim.bo[statusline_buf].swapfile = false
	end

	-- Get editor dimensions
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines

	-- Floating window options
	local float_opts = {
		relative = "editor",
		width = editor_width,
		height = 2,
		row = editor_height - 4,
		col = 0,
		style = "minimal",
		border = "none",
	}

	-- Open the floating window
	statusline_win = vim.api.nvim_open_win(statusline_buf, false, float_opts)

	-- Set highlight for transparency and visibility
	vim.api.nvim_set_hl(0, "StatuslineFloatBG", { bg = "NONE", fg = "#ffffff", bold = false })
	vim.api.nvim_set_option_value("winhl", "NormalFloat:StatuslineFloatBG", { win = statusline_win })
	vim.api.nvim_set_option_value("winblend", 20, { win = statusline_win })
	vim.wo[statusline_win].winblend = 20
	vim.wo[statusline_win].number = false
	vim.wo[statusline_win].relativenumber = false
	vim.wo[statusline_win].wrap = false
	vim.wo[statusline_win].scrolloff = 0

	-- Call the update function after creation
	update_statusline_text()
end

-- Hide the floating window if it exists
local function hide_statusline_window()
	if statusline_win and vim.api.nvim_win_is_valid(statusline_win) then
		vim.api.nvim_win_hide(statusline_win)
		statusline_win = nil
	end
end

-- Decide whether to hide or show the statusline based on cursor position
local function maybe_hide_or_show_statusline()
	-- How many lines are in this window?
	local total_lines_in_window = vim.api.nvim_win_get_height(0)
	-- The cursor's row in the *window*, 1-based
	local row_in_window = vim.fn.winline()
	-- Lines remaining below the cursor
	local lines_below_cursor = total_lines_in_window - row_in_window

	-- If we are in the last 2 lines => hide
	if lines_below_cursor < 2 then
		hide_statusline_window()
	else
		-- Otherwise, show or update
		if not statusline_win or not vim.api.nvim_win_is_valid(statusline_win) then
			create_statusline_window()
		end
		update_statusline_text()
	end
end

-- Set up an autocmd to run on cursor move or buffer enter
vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
	group = autocmd_group,
	callback = maybe_hide_or_show_statusline,
})

function M.fix_statusline()
	create_statusline_window()
	update_statusline_text()
end
-- ─────────────────────────────────────────────────────────────────────────────
-- The “start” entrypoint that sets everything up
-- ─────────────────────────────────────────────────────────────────────────────
function M.start()
	-- Mark plugin as active
	is_active = true

	-- Clear old autocmds in case we previously disabled
	if autocmd_group then
		vim.api.nvim_clear_autocmds({ group = autocmd_group })
	end
	autocmd_group = vim.api.nvim_create_augroup("MDTocAUGroup", { clear = true })

	-- If we’re currently in a markdown/lua buffer, remember it
	local current_buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[current_buf].filetype
	if ft == "markdown" or ft == "lua" then
		last_active_buf = current_buf
		last_active_win = vim.api.nvim_get_current_win()
	end

	scratch_buf = get_scratch_buffer()
	if not scratch_buf then
		vim.notify("fixedspace buf_id not valid yet; TOC won't show until that is available.")
		return
	end

	-- Attach autocmds for the *main buffer* => update TOC
	M.attach_main_buf_autocmds()

	-- Attach autocmds for the *TOC buffer* => jump main buffer
	M.attach_toc_buf_autocmds()

	-- Update the TOC once on startup
	vim.defer_fn(function()
		M.update_scratch_buffer()
		M.highlight_active_toc_entry()
		M.fix_statusline()
		--end, 150)
	end, 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Disabling logic (if you ever want to “turn off” everything)
-- ─────────────────────────────────────────────────────────────────────────────
function M.disable()
	is_active = false
	if autocmd_group then
		vim.api.nvim_clear_autocmds({ group = autocmd_group })
		autocmd_group = nil
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Simple motions: jump to next/prev heading
-- ─────────────────────────────────────────────────────────────────────────────
function M.next_heading()
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1
	for _, heading in ipairs(toc_headings) do
		if heading.line > cursor_line then
			vim.api.nvim_win_set_cursor(last_active_win, { heading.line + 1, 0 })
			return
		end
	end
end

function M.prev_heading()
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1
	local last_heading = nil
	for _, heading in ipairs(toc_headings) do
		if heading.line < cursor_line then
			last_heading = heading
		else
			break
		end
	end
	if last_heading then
		vim.api.nvim_win_set_cursor(last_active_win, { last_heading.line + 1, 0 })
	end
end

--------------------------------------------------------------------------------
-- Optional: a telescope-based heading picker
--------------------------------------------------------------------------------
function M.telescope_headings()
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")

	-- Ensure TOC exists
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end

	-- Define highlight groups mapping
	local hl_groups = opts.hl_groups or {}
	local hl_map = {
		[1] = "MDTocHeading1",
		[2] = "MDTocHeading2",
		[3] = "MDTocHeading3",
		[4] = "MDTocHeading4",
		[5] = "MDTocHeading5",
		[6] = "MDTocHeading6",
	}

	-- Convert toc_headings to Telescope format
	local heading_entries = {}

	-- Track last seen parents for multi-column view
	local last_parents = { [1] = nil, [2] = nil }

	for _, heading in ipairs(toc_headings) do
		local level = math.max(1, math.min(heading.level, 6)) -- Ensure valid level
		local hl_group = hl_map[level] or "MDTocHeading1"

		-- Store parents for display
		if level > 1 then
			last_parents[level] = heading.text
		end

		-- Find closest parent and grandparent
		local parent = nil
		local grandparent = nil

		for i = level - 1, 1, -1 do
			if last_parents[i] then
				if not parent then
					parent = last_parents[i]
				else
					grandparent = last_parents[i]
					break
				end
			end
		end

		table.insert(heading_entries, {
			display = heading.text,
			value = heading.line + 1,
			level = level,
			parent = parent,
			grandparent = grandparent,
		})
	end

	-- If no headings found, exit
	if #heading_entries == 0 then
		vim.notify("No headings found!", vim.log.levels.WARN)
		return
	end

	-- Custom entry maker for 3-column display
	local function entry_maker(entry)
		local hl_level = entry.level
		local hl_group = hl_map[hl_level] or "MDTocHeading1"

		-- Ensure highlight group exists
		if hl_groups["h" .. hl_level] then
			vim.api.nvim_set_hl(0, hl_group, hl_groups["h" .. hl_level])
		end

		local displayer = entry_display.create({
			separator = " | ",
			items = {
				{ width = 40, hl = hl_map[hl_level - 2] or "" }, -- Grandparent (if exists)
				{ width = 45, hl = hl_map[hl_level - 1] or "" }, -- Parent (if exists)
				{ remaining = true, hl = hl_group }, -- Current heading
			},
		})

		return {
			value = entry.value,
			ordinal = (entry.grandparent or "") .. " " .. (entry.parent or "") .. " " .. entry.display,
			display = function()
				return displayer({
					{ entry.grandparent or "", hl_map[hl_level - 2] or "" },
					{ entry.parent or "", hl_map[hl_level - 1] or "" },
					{ entry.display, hl_group },
				})
			end,
		}
	end

	-- Telescope Picker
	pickers
		.new({}, {
			prompt_title = "Jump to Heading",
			finder = finders.new_table({
				results = heading_entries,
				entry_maker = entry_maker,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(_, map)
				actions.select_default:replace(function(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection and selection.value then
						vim.api.nvim_win_set_cursor(last_active_win, { selection.value, 0 })
					end
				end)
				return true
			end,
		})
		:find()
end

return M
