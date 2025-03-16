-- 1) In open_scratch_window() – Around the WinClosed autocommand

-- Why defer the check?
-- Question:
-- so it runs it sequentially if short timespann, otherwise assync
-- ChatGPT (4o) said:
-- Neovim’s Event Handling: Sequential for Short Tasks, Async for Long Tasks
--Yes, exactly! Neovim runs tasks sequentially if they are short but switches to async if they take too long.
-- Question: so when i close window, its not truly sequential, but behind scene goes into event queue
-- Yes, closing a window (nvim_win_close) is not purely sequential. Instead, it triggers updates that go into the event queue, meaning the full effect is not applied immediately.
-- (marking it for closing is sequential, but layout changes,  buffer detachment, and othe
--
--
-- 2) Defer wrapper / Highlight logic explanations

-- Defer wrapper
-- Wrapper because else it's not working
-- I figured this out more or less by intuition, the chat explains its reflection on it:
-- Put simply, deferring the highlight function gives everything time to update in the background, so you end up with one correct highlight event, not two or three partially correct ones that overwrite each other.
-- Brief Explanation:
-- 1) Highlighting immediately on window/cursor changes often grabbed partial state, causing a flash of row 0 or flicker loops.
-- 2) By deferring the highlight call (e.g., 200ms), Neovim’s cursor/buffer state stabilizes first, ensuring a single correct highlight
--    without re-triggering loops or “reset to top” behavior.

-- And slightly further down near highlight_active_toc_entry():

-- TODO: Should be renamed, this call means it is not being deferred. Naming-logic messes it up.
-- We try to remove the deferring here, and it should work, otherwise revert.
-- The defer solution was for switching back from TOC view.

local M = {}

local default_opts = {
	-- Fraction of the Neovim editor width and height to use for the floating window
	-- NOTE: disabled for now
	--float_width_ratio = 0.2, -- 20% of editor width
	--float_height_ratio = 0.8, -- 80% of editor height
	-- NOTE: hardcoded settings further down for now
	float_width = 25,

	-- If you want to anchor the window to the right, left, or center, tweak float_col_offset.
	-- E.g. for the right side, a typical approach might be:
	--   col = vim.o.columns - float_width - float_col_offset
	float_col_offset = 0,

	-- Or if you want it more central, set float_col_offset differently:
	--   col = math.floor((vim.o.columns - float_width) / 2)
	--
	-- Similarly, you can adjust row positioning with float_row_offset.
	float_row_offset = 0,

	border = "rounded", -- style: 'none', 'single', 'double', 'rounded', 'solid', 'shadow'
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

function M.setup(user_opts)
	opts = vim.tbl_deep_extend("force", default_opts, user_opts or {})
	vim.api.nvim_set_hl(0, "MDTocHeading1", opts.hl_groups.h1)
	vim.api.nvim_set_hl(0, "MDTocHeading2", opts.hl_groups.h2)
	vim.api.nvim_set_hl(0, "MDTocHeading3", opts.hl_groups.h3)
	vim.api.nvim_set_hl(0, "MDTocHeading4", opts.hl_groups.h4)
	vim.api.nvim_set_hl(0, "MDTocHeading5", opts.hl_groups.h5)
	vim.api.nvim_set_hl(0, "MDTocHeading6", opts.hl_groups.h6)
	vim.api.nvim_set_hl(0, "MDTocCurrent", { bg = "#44475a", bold = true })
end

local scratch_buf = nil
local scratch_win = nil
local is_active = false

local last_active_buf = nil -- The markdown (or lua) buffer
local last_active_win = nil -- The markdown (or lua) window
local toc_headings = {}

--local function find_buffer_by_name(target_name)
--	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
--		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(target_name, 1, true) then
--			return buf -- ✅ Found buffer, return its ID
--		end
--	end
--	return nil -- ❌ Not found
--end

-- Create or get the scratch buffer
local function get_scratch_buffer()
	--	local existing_buf = find_buffer_by_name("xmdtocx")
	--	if existing_buf then
	--		return existing_buf -- ✅ Return existing buffer ID
	--	end

	if scratch_buf and vim.api.nvim_buf_is_valid(scratch_buf) then
		return scratch_buf
	end

	scratch_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(scratch_buf, "xmdtocx")
	vim.bo[scratch_buf].buftype = "nofile"
	vim.bo[scratch_buf].bufhidden = "wipe"
	vim.bo[scratch_buf].swapfile = false
	vim.bo[scratch_buf].filetype = "mdtoc"
	vim.bo[scratch_buf].modifiable = false
	vim.bo[scratch_buf].undolevels = -1

	return scratch_buf
end

local function close_scratch_window()
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		vim.api.nvim_win_close(scratch_win, true)
	end
	scratch_win = nil
	is_active = false
end

-- NOTE: Create or re-open the floating window
local function open_scratch_window()
	-- Introducing the fixedspace.nvim solution, this isn't used anymore
	--	-- Do not show TOC if more than 1 normal window is open
	--	-- 1) Count how many normal (non-floating) windows are currently open
	--	local normal_wins = {}
	--	for _, w in ipairs(vim.api.nvim_list_wins()) do
	--		local cfg = vim.api.nvim_win_get_config(w)
	--		if cfg.relative == "" then
	--			table.insert(normal_wins, w)
	--		end
	--	end
	--
	--	-- 2) If more than 1 normal window is open, refuse to open the TOC
	--	if #normal_wins > 1 then
	--		print("[mdtoc] Refusing to display TOC because more than 1 normal window is open.")
	--		return
	--	end
	--
	--
	--
	--

	local current_buf = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()

	-- Only track if it's markdown or lua
	local ft = vim.bo[current_buf].filetype
	if ft == "markdown" or ft == "lua" then
		last_active_buf = current_buf
		last_active_win = current_win
	end

	local buf = get_scratch_buffer()
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		return buf
	end

	-- Calculate floating window size
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines

	-- NOTE: disabled for now
	--local float_width = math.floor(editor_width * opts.float_width_ratio)
	--local float_height = math.floor(editor_height * opts.float_height_ratio)
	local float_width = opts.float_width
	local float_height = editor_height - 3

	-- Positioning; tweak as desired:
	local row = 0
	--local row = math.floor((editor_height - float_height) / 2) + opts.float_row_offset
	local col = editor_width - float_width - opts.float_col_offset

	local float_opts = {
		relative = "editor",
		width = float_width,
		height = float_height,
		row = row,
		col = col,
		style = "minimal",
		--border = opts.border or "rounded",
		--border = "none",
		-- Put space as border to create padding effetc
		border = { "", "", "", "", "", "", "", " " }, -- Right-only border
	}

	scratch_win = vim.api.nvim_open_win(buf, false, float_opts)
	-- For no background color
	--vim.api.nvim_win_set_option(scratch_win, "winhl", "NormalFloat:")

	vim.api.nvim_set_hl(0, "MyFloatBG", { bg = "#010101" })
	vim.api.nvim_set_hl(0, "MyFloatBorder", { fg = "#ffcc00", bg = "NONE" })
	--	vim.api.nvim_win_set_option(scratch_win, "winhl", "NormalFloat:MyFloatBG")
	-- Apply window highlight settings
	vim.api.nvim_set_option_value("winhl", "NormalFloat:MyFloatBG,FloatBorder:MyFloatBorder", { win = scratch_win })
	vim.api.nvim_set_option_value("winblend", 20, { win = scratch_win })

	-- Set other window options correctly
	vim.wo[scratch_win].wrap = false
	vim.wo[scratch_win].number = false
	vim.wo[scratch_win].relativenumber = false
	vim.wo[scratch_win].scrolloff = 0

	-- Autocmd to handle the floating window’s lifecycle
	vim.api.nvim_create_autocmd("WinClosed", {
		callback = function()
			vim.defer_fn(function()
				local normal_wins = {}
				for _, win in ipairs(vim.api.nvim_list_wins()) do
					local config = vim.api.nvim_win_get_config(win)
					local is_floating = config.relative ~= ""
					local buf_id = vim.api.nvim_win_get_buf(win)
					local buf_name = vim.api.nvim_buf_get_name(buf_id)
					if not is_floating then
						table.insert(normal_wins, { win = win, buf = buf_id, name = buf_name })
					end
				end

				-- Check if any non-TOC buffers exist
				local non_toc_buffers_exist = false
				for _, b in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_valid(b) then
						local name = vim.api.nvim_buf_get_name(b)
						if not name:match("xmdtocx") then
							non_toc_buffers_exist = true
							break
						end
					end
				end

				-- Quit Neovim if the only remaining normal window is our TOC and no other buffers exist
				if #normal_wins == 1 and normal_wins[1].name:match("xmdtocx") and not non_toc_buffers_exist then
					vim.cmd("q!")
				end
			end, 1)
		end,
	})

	-- Jumping logic: when user scrolls/clicks in the TOC, mirror in the Markdown window
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			if last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
				local row = vim.api.nvim_win_get_cursor(scratch_win)[1] -- 1-based row
				local heading_entry = toc_headings[row]
				if heading_entry then
					vim.api.nvim_win_set_cursor(last_active_win, { heading_entry.line + 1, 0 })
				end
			end
		end,
		desc = "Jump to selected heading in the markdown window",
	})

	-- Press <CR> in TOC => re-focus the markdown (lua) window
	vim.keymap.set("n", "<CR>", function()
		if last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
			vim.api.nvim_set_current_win(last_active_win)
		end
	end, { buffer = buf, noremap = true, silent = true })

	return buf
end

-- Treesitter: parse the markdown/lua to get headings + line numbers
local function extract_headings()
	if not is_active or not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
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

	toc_headings = {}
	local headings = {}

	if ft == "markdown" then
		-- 1) Markdown query for headings
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
				local heading_entry = {
					text = content,
					level = level,
					line = line,
				}
				table.insert(headings, string.rep("  ", level - 1) .. "- " .. content)
				table.insert(toc_headings, heading_entry)
			end
		end
	elseif ft == "lua" then
		-- 2) Lua query capturing functions
		local query_str = [[
      ; Match standalone function declarations
      (function_declaration
          name: (identifier) @func_name)

      ; Match function declarations in tables (dot-indexed)
      (function_declaration
          name: (dot_index_expression
              table: (identifier) @table_name
              field: (identifier) @field_name))

      ; Match function definitions in table constructors
      (field
        name: (identifier) @table_field_name
        value: (function_definition))
    ]]
		local query = vim.treesitter.query.parse("lua", query_str)

		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local func_name = ""
			local start_row = nil

			for id, node in pairs(match) do
				local cap_name = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)

				if cap_name == "func_name" then
					func_name = text
					start_row = node:start()
				elseif cap_name == "table_name" then
					local table_name = text
					local field_node = match[id + 1]
					local field_name = vim.treesitter.get_node_text(field_node, last_active_buf)
					func_name = table_name .. "." .. field_name
					start_row = node:start()
				elseif cap_name == "table_field_name" then
					func_name = text
					start_row = node:start()
				end
			end

			if func_name ~= "" and start_row then
				local line = start_row
				table.insert(headings, "- " .. func_name)
				table.insert(toc_headings, {
					text = func_name,
					level = 1,
					line = line,
				})
			end
		end
	else
		-- Other filetypes: do nothing
		return {}
	end

	return headings
end

-- Update the TOC buffer lines, apply highlights
function M.update_scratch_buffer()
	if not is_active then
		return
	end

	local buf = get_scratch_buffer()
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

	vim.o.termguicolors = true
	vim.treesitter.stop(buf) -- disable TS in the scratch buffer
	vim.bo[buf].filetype = "plaintext"
	vim.bo[buf].buftype = ""

	local hl_groups = opts.hl_groups or {}
	local hl_map = {
		[1] = "MDTocHeading1",
		[2] = "MDTocHeading2",
		[3] = "MDTocHeading3",
		[4] = "MDTocHeading4",
		[5] = "MDTocHeading5",
		[6] = "MDTocHeading6",
	}

	for level, hl_name in pairs(hl_map) do
		local color = hl_groups["h" .. level]
		if color then
			vim.api.nvim_set_hl(0, hl_name, color)
		end
	end

	local headings = extract_headings()
	local lines = {}
	for _, heading in ipairs(headings) do
		table.insert(lines, heading)
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Highlight them
	vim.defer_fn(function()
		for i, heading in ipairs(headings) do
			local spaces = heading:match("^%s*") or ""
			local level = math.floor((#spaces / 2) + 1)
			level = math.max(1, math.min(level, 6))
			local hl_group = hl_map[level] or "MDTocHeading1"

			-- check if buf is valid if not, run get scratch
			if not vim.api.nvim_buf_is_valid(buf) then
				buf = get_scratch_buffer()
			end

			vim.api.nvim_buf_add_highlight(buf, -1, hl_group, i - 1, 0, -1)
		end
	end, 10)
	vim.bo[buf].modifiable = false
end

-- Figure out which heading the user is currently in
local function get_current_section()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		return nil
	end
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(last_active_win)
	local cursor_line = cursor[1] - 1

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

local function deferred_highlight_active_toc_entry()
	if not is_active then
		return
	end

	local buf = get_scratch_buffer()
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local current_line = get_current_section()
	if not current_line then
		return
	end

	local ns_id = vim.api.nvim_create_namespace("MDTocCurrent")
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

	local target_line = nil
	for i, heading in ipairs(toc_headings) do
		if heading.line == current_line then
			target_line = i - 1
			break
		end
	end

	if target_line then
		-- Fix... for cursor out of bounds§
		local line_count = vim.api.nvim_buf_line_count(buf) -- Get total number of lines in the scratch buffer

		-- Clamp target_line to be within the buffer range
		if target_line >= line_count then
			target_line = line_count - 1 -- Ensure we don't exceed the last valid line
		end
		if target_line < 0 then
			target_line = 0 -- Ensure we don't go below the first line
		end
		-- Added fix above

		-- Only apply cursor change if the target line is valid
		vim.api.nvim_buf_add_highlight(buf, ns_id, "MDTocCurrent", target_line, 0, -1)
		if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
			vim.api.nvim_win_call(scratch_win, function()
				vim.api.nvim_win_set_cursor(scratch_win, { target_line + 1, 0 })
			end)
		end
	end
end

local function highlight_active_toc_entry()
	vim.defer_fn(function()
		deferred_highlight_active_toc_entry()
	end, 110)
end

local function attach_autocmd()
	-- Update TOC when we enter or write to a markdown/lua buffer
	vim.api.nvim_create_autocmd({ "WinClosed", "WinEnter", "BufEnter", "BufWinEnter", "BufWritePost", "InsertLeave" }, {
		callback = function()
			log("WinClosed, WinEnter, BufEnter, BufWinEnter, BufWritePost, InsertLeave")
			-- log what event it was triggered
			if not is_active then
				return
			end
			log("is_active")
			local current_buf = vim.api.nvim_get_current_buf()
			local ft = vim.bo[current_buf].filetype
			if ft == "markdown" or ft == "lua" then
				log("ft == markdown or lua")
				last_active_buf = current_buf
				last_active_win = vim.api.nvim_get_current_win()
				vim.defer_fn(M.update_scratch_buffer, 100)
			end
		end,
	})
end

local function attach_cursor_autocmd()
	-- Highlight active heading in TOC as the user moves in their main buffer
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		callback = function()
			if not is_active then
				return
			end
			if vim.api.nvim_get_current_buf() == scratch_buf then
				return
			end

			-- Preserve highlighting logic
			deferred_highlight_active_toc_entry()
		end,
	})

	-- When user focuses back into markdown/lua window, re-highlight
	vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			if not is_active then
				return
			end
			local current_buf = vim.api.nvim_get_current_buf()
			if current_buf == last_active_buf then
				highlight_active_toc_entry()
			end
		end,
	})
end

function M.toggle()
	if is_active then
		close_scratch_window()
		-- TODO:: This flag is set in above func too...
		is_active = false
	else
		local old_win = vim.api.nvim_get_current_win()
		open_scratch_window()
		is_active = true
		M.update_scratch_buffer()
		-- Return focus to the user’s previous window
		if vim.api.nvim_win_is_valid(old_win) then
			vim.api.nvim_set_current_win(old_win)
		end
	end
end

-- Store the last known TOC position before closing

local function maybe_hide_float()
	--------------------------------------------------------------------------------
	-- 1) Basic Guards
	--------------------------------------------------------------------------------
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end

	-- Get window's top-left position (absolute screen coordinates)
	local win_pos = vim.api.nvim_win_get_position(last_active_win) -- { row, col }
	local win_row = win_pos[1]
	local win_col = win_pos[2] -- Window's left-most column (including line numbers)

	-- Get cursor's absolute **row** in the window
	local cursor_line_in_win = vim.fn.winline() - 1
	local cursor_win_row = win_row + cursor_line_in_win

	-- **NEW: Use `wincol()` to get the real visual column**
	local cursor_screen_col = vim.fn.wincol()
	local cursor_win_col = win_col + cursor_screen_col

	--------------------------------------------------------------------------------
	-- 2) If TOC is Open, Check If Cursor Is Inside It
	--------------------------------------------------------------------------------
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		local float_config = vim.api.nvim_win_get_config(scratch_win)

		-- Adjusted hitbox (wider and offset)
		local float_row = float_config.row
		local float_col = float_config.col - 32 -- Expanding hitbox to the left
		local float_height = float_config.height
		local float_width = float_config.width + 32 -- Expanding hitbox width

		-- Convert row/col from tables to numbers if needed
		if type(float_row) == "table" then
			float_row = float_row[false]
		end
		if type(float_col) == "table" then
			float_col = float_col[false]
		end

		-- Define TOC rectangle (expanded hitbox)
		local float_row_end = float_row + float_height
		local float_col_end = float_col + float_width

		-- **Save adjusted hitbox globally** so all functions use the correct size
		_G.adjusted_float_rect = {
			row = float_row,
			col = float_col,
			row_end = float_row_end,
			col_end = float_col_end,
		}

		-- If cursor is inside the adjusted TOC area, close it (but defer slightly)
		if
			(cursor_win_row >= float_row)
			and (cursor_win_row < float_row_end)
			and (cursor_win_col >= float_col)
			and (cursor_win_col <= float_col_end)
		then
			--vim.defer_fn(function()
			-- Recheck after delay to avoid flickering
			--local new_cursor_col = vim.fn.wincol() + win_col
			--if new_cursor_col >= float_col and new_cursor_col <= float_col_end then
			close_scratch_window()
			--end
			--end, 100) -- 100ms delay prevents flicker
		end

		return -- TOC is still open, no need to check further
	end

	--------------------------------------------------------------------------------
	-- 3) If TOC Is Closed, Check If Cursor Is Still Inside Its Last Known Position
	--------------------------------------------------------------------------------
	if _G.adjusted_float_rect then
		local rect = _G.adjusted_float_rect
		-- Use adjusted values for checking last known TOC area
		if
			cursor_win_row >= rect.row
			and cursor_win_row < rect.row_end
			and cursor_win_col >= rect.col
			and cursor_win_col < rect.col_end
		then
			-- Cursor is still inside the last known TOC area, do nothing
			return
		end
	end

	--------------------------------------------------------------------------------
	-- 4) If Cursor Has Moved Outside the TOC's Last Position, Re-open It
	--------------------------------------------------------------------------------
	--vim.defer_fn(function()
	M.enable()
	--end, 50) -- Small delay to avoid fast close/reopen flicker
end

function M.enable()
	if not is_active then
		M.toggle()
		-- TODO: we could make more elegant solution by having toggle check the cords etc and not open if it should not
		vim.defer_fn(function()
			maybe_hide_float()
		end, 10)
	end
end

local function detach_lsp_from_buffer(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
			vim.lsp.buf_detach_client(buf, client.id)
		end
	end
end

function M.disable()
	-- 1) Close the floating TOC window
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		detach_lsp_from_buffer(scratch_buf)
		vim.api.nvim_win_close(scratch_win, true)
	end
	scratch_win = nil
	is_active = false

	-- 2) Delete the scratch_buf
	if scratch_buf and vim.api.nvim_buf_is_valid(scratch_buf) then
		vim.api.nvim_buf_delete(scratch_buf, { force = true })
	end
	scratch_buf = nil

	-- 3) Clean up any leftover xmdtocx buffers
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) then
			local name = vim.api.nvim_buf_get_name(b)
			if name:match("xmdtocx") then
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == b then
						vim.api.nvim_win_close(w, true)
					end
				end
				vim.api.nvim_buf_delete(b, { force = true })
			end
		end
	end
end

close_scratch_window = function()
	if scratch_win and vim.api.nvim_win_is_valid(scratch_win) then
		local float_config = vim.api.nvim_win_get_config(scratch_win)
		local float_row = float_config.row
		local float_col = float_config.col
		local float_height = float_config.height
		local float_width = float_config.width

		-- Ensure absolute values
		if type(float_row) == "table" then
			float_row = float_row[false]
		end
		if type(float_col) == "table" then
			float_col = float_col[false]
		end

		-- Store TOC's last known rectangle before closing
		last_toc_rect = {
			row = float_row,
			col = float_col,
			row_end = float_row + float_height,
			col_end = float_col + float_width,
		}
	end

	M.disable()
end

-- 1) Create a shared function to count normal windows and disable TOC if needed
local function disable_toc_if_multiple_normal_wins()
	local normal_wins = {}
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(w)
		-- cfg.relative == "" => normal window (not floating)
		if cfg.relative == "" then
			table.insert(normal_wins, w)
		end
	end

	if #normal_wins > 1 then
		-- More than 1 normal window => disable the TOC
		require("mdtoc").disable() -- or M.disable() if you’re in the same file
	else
		require("mdtoc").enable() -- or M.enable() if you’re in the same file
	end
end

-- 2) Autocmd for both events: WinEnter *and* WinClosed
--vim.api.nvim_create_autocmd({ "WinEnter", "WinClosed" }, {
--	desc = "Disable TOC if more than one normal window is open",
--	callback = function()
-- NOTE:disabled for now
--
--disable_toc_if_multiple_normal_wins()
--	end,
--})

-- Global CursorMoved autocmd
--vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
--group = vim.api.nvim_create_augroup("TocCursorCheckGroup", { clear = true }),
--callback = maybe_hide_float,
--})
--
--

-- Move cursor to the next heading in the source buffer
function M.next_heading()
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(last_active_win)
	local cursor_line = cursor[1] - 1

	for _, heading in ipairs(toc_headings) do
		if heading.line > cursor_line then
			vim.api.nvim_win_set_cursor(last_active_win, { heading.line + 1, 0 })
			return
		end
	end
end

-- Move cursor to the previous heading in the source buffer
function M.prev_heading()
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(last_active_win)
	local cursor_line = cursor[1] - 1
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

	-- Convert `toc_headings` to Telescope format
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

-- Auto update on cursor move
vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
	callback = function()
		create_statusline_window()
		update_statusline_text()
	end,
})

function M.fix_statusline()
	create_statusline_window()
	update_statusline_text()
end

function M.start()
	attach_autocmd()
	attach_cursor_autocmd()

	-- some more autocmds
	vim.api.nvim_create_autocmd({ "BufDelete", "WinClosed" }, {
		callback = function(args)
			local buf_name = vim.api.nvim_buf_get_name(args.buf)
			if not buf_name:match("xmdtocx") then
			--log("A non-TOC buffer was deleted or window closed => disabling TOC")
			-- TODO: Not needed... we reuse the exisitng float.. this one line is executed after a few sec after windows open close, and it closes toc
			--M.disable()
			else
				log("TOC buffer was deleted, ignoring...")
			end
		end,
	})

	-- create same but for entering buffer
	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		callback = function(args)
			log("Buffer entered")
			M.enable()
			vim.defer_fn(function()
				log("deferred highlight active toc entry")
				highlight_active_toc_entry()
				create_statusline_window()
				update_statusline_text()
			end, 1)
		end,
	})
	-- To run first time after startup
	vim.defer_fn(function()
		highlight_active_toc_entry()
		create_statusline_window()
		update_statusline_text()
	end, 1)
	-- Clear any previous TOC usage
	-- TODO: is this needed by now?
	M.disable()
	-- The user can now run :lua require('your_module_name').toggle() or :MDtoc, etc.
end

return M
