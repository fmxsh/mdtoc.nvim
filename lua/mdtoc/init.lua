--------------------------------------------------------------------------------
-- mdtoc.lua
-- A minimal “TOC” side-window for markdown or lua files, using `fixedspace` plugin
-- Highlights headings in the TOC, moves the main buffer cursor if you scroll
-- in the TOC, etc.
--------------------------------------------------------------------------------
--
-- ChatGPT o1 fixed my mess when porting this code from using its own float window, to using buffer created by the fixedspace plugin...
-- Ever experienced porting something and its supposed to be simple, but every action creates more bugs? The more you struggle, the more you sink...
--

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
	log("Extracting headings from buffer: " .. last_active_buf .. " (ft: " .. ft .. ")")
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
  (inline) @content) @heading

(setext_heading
  (paragraph (inline) @content)
  (setext_h1_underline)? @level
  (setext_h2_underline)? @level) @heading
]]

		local query = vim.treesitter.query.parse("markdown", query_str)

		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local level
			local content
			local heading_node

			for id, node in pairs(match) do
				local cap = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)
				if cap == "level" and not level then
					level = #text
				elseif cap == "content" then
					content = text
				elseif cap == "heading" then
					heading_node = node
				end
			end

			if level and content and heading_node then
				local start_line = heading_node:start()
				local end_line = heading_node:end_()

				table.insert(toc_headings, {
					text = content,
					level = level,
					line = start_line,
					start_line = start_line,
					end_line = end_line,
				})

				table.insert(headings, string.rep("  ", level - 1) .. "- " .. content)
			end
		end

	--OLD
	--		local query_str = [[
	--(atx_heading
	--  (atx_h1_marker)? @level
	--  (atx_h2_marker)? @level
	--  (atx_h3_marker)? @level
	--  (atx_h4_marker)? @level
	--  (atx_h5_marker)? @level
	--  (atx_h6_marker)? @level
	--  (inline) @content)
	--
	--(setext_heading
	--  (paragraph (inline) @content)
	--  (setext_h1_underline)? @level
	--  (setext_h2_underline)? @level)
	--]]
	--		local query = vim.treesitter.query.parse("markdown", query_str)
	--		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
	--			local level
	--			local content
	--			local heading_node
	--
	--			for id, node in pairs(match) do
	--				local cap = query.captures[id]
	--				local text = vim.treesitter.get_node_text(node, last_active_buf)
	--				if cap == "level" then
	--					level = #text
	--				elseif cap == "content" then
	--					content = text
	--					heading_node = node
	--				end
	--			end
	--
	--			if level and content and heading_node then
	--				local line = heading_node:start() -- 0-based
	--				local start_line = line
	--				local end_line = heading_node:end_()
	--				table.insert(toc_headings, {
	--					text = content,
	--					level = level,
	--					line = line,
	--					start_line = start_line,
	--					end_line = end_line,
	--				})
	--				-- For indentation display in the TOC buffer:
	--				table.insert(headings, string.rep("  ", level - 1) .. "- " .. content)
	--			end
	--		end
	elseif ft == "bash" or ft == "sh" then
		----------------------------------------------------------------------
		-- For Bash, capture function definitions
		----------------------------------------------------------------------

		local query_str = [[
(function_definition
  name: (word) @func_name
) @func
]]

		local query = vim.treesitter.query.parse("bash", query_str)
		local function_map = {} -- start_row → entry (for nesting)
		local seen_functions = {} -- prevent duplicates

		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local func_node, func_name

			for id, node in pairs(match) do
				local cap = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)

				if cap == "func" then
					func_node = node
				elseif cap == "func_name" then
					func_name = text
				end
			end

			if func_node and func_name then
				local start_row, _, end_row, _ = func_node:range()

				-- Skip duplicates
				local unique_key = func_name .. ":" .. start_row
				if not seen_functions[unique_key] then
					seen_functions[unique_key] = true

					-- Detect parent to build nesting level
					local parent_row
					local parent = func_node:parent()
					while parent do
						if parent:type() == "function_definition" then
							parent_row = parent:start()
							break
						end
						parent = parent:parent()
					end

					local level = 1
					if parent_row and function_map[parent_row] then
						level = function_map[parent_row].level + 1
					end

					local func_entry = {
						text = func_name,
						level = level,
						line = start_row,
						start_line = start_row,
						end_line = end_row,
					}

					function_map[start_row] = func_entry
					table.insert(toc_headings, func_entry)
					table.insert(headings, string.rep("  ", level - 1) .. "- " .. func_name)
				end
			end
		end
	elseif ft == "c" then
		----------------------------------------------------------------------
		-- For C, capture function definitions (non-inline, non-macro only)
		----------------------------------------------------------------------
		local query_str = [[
(function_definition
  declarator: [
    (function_declarator
      declarator: (identifier) @func_name)
    (pointer_declarator
      declarator: (function_declarator
        declarator: (identifier) @func_name))
  ]
) @func
]]

		local query = vim.treesitter.query.parse("c", query_str)
		local function_map = {}
		local seen_functions = {}

		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local func_node = nil
			local func_name = nil

			for id, node in pairs(match) do
				local cap = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)

				if cap == "func" then
					func_node = node
				elseif cap == "func_name" then
					func_name = text
				end
			end

			if func_node and func_name then
				local start_row, _, end_row, _ = func_node:range()
				local display_name = func_name

				local unique_key = display_name .. ":" .. start_row
				if not seen_functions[unique_key] then
					seen_functions[unique_key] = true

					-- Determine nesting level by walking up AST
					local level = 1
					local parent_row = nil
					local parent = func_node:parent()
					while parent do
						local t = parent:type()
						if t == "function_definition" then
							parent_row = parent:start()
							break
						end
						parent = parent:parent()
					end
					if parent_row and function_map[parent_row] then
						level = function_map[parent_row].level + 1
					end

					local func_entry = {
						text = display_name,
						level = level,
						line = start_row,
						start_line = start_row,
						end_line = end_row,
					}

					function_map[start_row] = func_entry
					table.insert(toc_headings, func_entry)
					table.insert(headings, string.rep("  ", level - 1) .. "- " .. display_name)
				end
			end
		end
	elseif ft == "lua" then
		----------------------------------------------------------------------
		-- For Lua, capture function definitions
		----------------------------------------------------------------------
		--		local query_str = [[
		--(function_declaration
		--    name: (identifier) @func_name)
		--
		--(function_declaration
		--    name: (dot_index_expression
		--      table: (identifier) @table_name
		--      field: (identifier) @field_name))
		--
		--(field
		--    name: (identifier) @table_field_name
		--    value: (function_definition))
		--]]
		--		local query = vim.treesitter.query.parse("lua", query_str)
		--		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
		--			local func_name = ""
		--			local start_row
		--
		--			for id, node in pairs(match) do
		--				local cap_name = query.captures[id]
		--				local text = vim.treesitter.get_node_text(node, last_active_buf)
		--				if cap_name == "func_name" then
		--					func_name = text
		--					start_row = node:start()
		--				elseif cap_name == "table_name" then
		--					local table_name = text
		--					local field_node = match[id + 1] -- Next capture is field_name
		--					local field_name = vim.treesitter.get_node_text(field_node, last_active_buf)
		--					func_name = table_name .. "." .. field_name
		--					start_row = node:start()
		--				elseif cap_name == "table_field_name" then
		--					func_name = text
		--					start_row = node:start()
		--				end
		--			end
		--
		--			if func_name ~= "" and start_row then
		--				table.insert(toc_headings, {
		--					text = func_name,
		--					level = 1,
		--					line = start_row,
		--				})
		--				table.insert(headings, "- " .. func_name)
		--			end
		--		end
		local query_str = [[
(function_declaration
  name: (identifier) @func_name
) @func

(function_declaration
  name: (dot_index_expression
    table: (identifier) @table_name
    field: (identifier) @field_name
  )
) @func

(field
  name: (identifier) @table_field_name
  value: (function_definition) @func
)

(field
  name: (dot_index_expression
    table: (identifier) @table_name
    field: (identifier) @field_name
  )
  value: (function_definition) @func
)

(function_definition) @func
]]

		local query = vim.treesitter.query.parse("lua", query_str)
		local function_map = {} -- Maps start_row -> function entry (to nest them)
		local seen_functions = {} -- Prevent duplicates

		for _, match, _ in query:iter_matches(root, last_active_buf, 0, -1) do
			local func_node = nil
			local func_name = nil
			local table_name, field_name = nil, nil
			local table_field_name = nil

			for id, node in pairs(match) do
				local cap = query.captures[id]
				local text = vim.treesitter.get_node_text(node, last_active_buf)

				if cap == "func" then
					-- The entire function (function_declaration or function_definition)
					func_node = node
				elseif cap == "func_name" then
					-- A simple function name
					func_name = text
				elseif cap == "table_name" then
					table_name = text
				elseif cap == "field_name" then
					field_name = text
				elseif cap == "table_field_name" then
					-- For `x = function()...end` style
					table_field_name = text
				end
			end

			if func_node then
				-- Full function node range
				local start_row, _, end_row, _ = func_node:range()

				-- Construct a display name
				local display_name = func_name or ""
				if table_name and field_name then
					display_name = table_name .. "." .. field_name
				elseif table_field_name then
					display_name = table_field_name
				end
				if display_name == "" then
					display_name = "anonymous_func"
				end

				-- Skip duplicates
				local unique_key = display_name .. ":" .. start_row
				if not seen_functions[unique_key] then
					seen_functions[unique_key] = true

					-- Determine if this function is nested within another
					local parent_row = nil
					local parent = func_node:parent()
					while parent do
						local t = parent:type()
						if t == "function_declaration" or t == "function_definition" then
							parent_row = parent:start()
							break
						end
						parent = parent:parent()
					end

					-- Default heading level
					local level = 1
					-- If parent is found, bump the nesting level
					if parent_row and function_map[parent_row] then
						level = function_map[parent_row].level + 1
					end

					-- Create your function-entry data
					local func_entry = {
						text = display_name,
						level = level,
						line = start_row, -- This is what you'll jump to
						start_line = start_row,
						end_line = end_row,
					}

					function_map[start_row] = func_entry
					table.insert(toc_headings, func_entry)

					-- For your TOC display
					table.insert(headings, string.rep("  ", level - 1) .. "- " .. display_name)
				end
			end
		end
	end

	return headings
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Update the scratch buffer lines, apply highlight for headings
-- ─────────────────────────────────────────────────────────────────────────────
function M.update_scratch_buffer()
	--The first check because: Error executing vim.schedule lua callback: /usr/share/nvim/runtime/lua/vim/treesitter.lua:97: There is no parser available for buffer 1 and one could not be created because lang could not be determined. Either pass lang or set the buffer filetype
	-- Re-extract headings from the main buffer only if filetype is set and parser exists
	local current_buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[current_buf].filetype
	if not ft or ft == "" or not pcall(vim.treesitter.language.require_language, ft) then
		vim.notify("[mdtoc.nvim] Skipping TOC update: no valid filetype or Tree-sitter parser", vim.log.levels.WARN)
		return
	end
	-------------

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

local previous_breadcrumb_path = nil

--M.update_is_disabled = false
local function update_statusline_text()
	--	if M.update_is_disabled then
	--		return
	--	end
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

	-- If the breadcrumb path has changed, issue an event
	if heading_text ~= previous_breadcrumb_path then
		previous_breadcrumb_path = heading_text -- Update stored value

		-- Trigger event with line number and last heading
		vim.api.nvim_exec_autocmds("User", {
			pattern = "mdtocStatuslineHeaderChanged",
			data = {
				line = current_line + 1, -- Adjust for 1-based line numbers
				header = display_parts[#display_parts] or "No Heading", -- Last heading in breadcrumb
			},
		})
	end

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
	--update_statusline_text()
	--
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
		--if not M.update_is_disabled then
		if not statusline_win or not vim.api.nvim_win_is_valid(statusline_win) then
			-- TODO: Bug, can not run this, we wrong inserts in bubblecol dedicated fixedwin win2, when switching project
			-- Removing this: This makes the bottom status line disapear till switching project
			create_statusline_window()
		end
		--end
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
	last_active_buf = current_buf
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

function M.jump_to(offset)
	if not last_active_win or not vim.api.nvim_win_is_valid(last_active_win) then
		return
	end

	if #toc_headings == 0 then
		vim.notify("No headings found!", vim.log.levels.WARN)
		return
	end

	-- Get current cursor position
	local cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1

	-- Find the index of the current heading
	local current_index = nil
	for i, heading in ipairs(toc_headings) do
		if heading.line <= cursor_line then
			current_index = i
		else
			break
		end
	end

	-- Default to the first heading if no match was found
	if not current_index then
		current_index = 1
	end

	-- Compute the target index based on the offset
	local target_index = current_index + offset

	-- Ensure it stays within bounds
	if target_index < 1 then
		target_index = 1
	elseif target_index > #toc_headings then
		target_index = #toc_headings
	end

	-- Jump to the target heading
	local target_heading = toc_headings[target_index]
	vim.api.nvim_win_set_cursor(last_active_win, { target_heading.line + 1, 0 })
end

function M.preview_outline()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}
	local line_map = {}
	local block_starts = {}
	local highlights = {}

	local all_lines = vim.api.nvim_buf_get_lines(last_active_buf, 0, -1, false)

	local function indent_for_level(level)
		return string.rep("  ", level - 1)
	end

	local function para_indent(level)
		return indent_for_level(level) .. "    "
	end

	for _, heading in ipairs(toc_headings) do
		local heading_indent = indent_for_level(heading.level)
		local title = heading_indent .. heading.text
		local start_line = #lines + 1
		table.insert(block_starts, start_line)

		table.insert(lines, title)
		line_map[#lines] = heading.line + 1
		table.insert(highlights, {
			line = #lines - 1,
			level = heading.level,
			col_start = #heading_indent,
			col_end = #heading_indent + #heading.text,
			is_para = false,
		})

		-- Grab first paragraph
		local para = {}
		for l = heading.line + 1, #all_lines do
			local content = all_lines[l]

			if content:match("^%s*$") then
				if #para > 0 then
					break
				end
			elseif content:match("^%s*[-=]+%s*$") then
				-- skip separators
			elseif content:lower():gsub("%W", "") == heading.text:lower():gsub("%W", "") then
				-- skip repeated heading
			else
				table.insert(para, content)
				if #para >= 3 then
					break
				end
			end
		end

		for _, p in ipairs(para) do
			local heading_indent = indent_for_level(heading.level)
			local body_line = heading_indent .. p
			table.insert(lines, body_line)
			local line_idx = #lines - 1
			table.insert(highlights, {
				line = line_idx,
				level = heading.level,
				col_start = #heading_indent,
				col_end = #body_line,
				is_para = true,
			})
		end

		table.insert(lines, "")
	end

	-- Write lines to buffer
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	-- Floating window
	local width = math.floor(vim.o.columns * 0.6)
	local height = vim.o.lines - 2
	local row = 1
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "none",
	})

	-- Background
	vim.api.nvim_set_hl(0, "PreviewWindowBG", { bg = "#f5f1d4" }) -- soft beige
	vim.api.nvim_set_option_value("winhl", "Normal:PreviewWindowBG", { win = win })

	-- Generate per-level highlights
	local ns = vim.api.nvim_create_namespace("PreviewHeadings")

	local function lighten_hex(hex, percent)
		local r = tonumber(hex:sub(2, 3), 16)
		local g = tonumber(hex:sub(4, 5), 16)
		local b = tonumber(hex:sub(6, 7), 16)
		local function lighten(x)
			return math.floor(x + (255 - x) * percent)
		end
		return string.format("#%02x%02x%02x", lighten(r), lighten(g), lighten(b))
	end

	for level = 1, 6 do
		local hl = opts.hl_groups["h" .. level]
		if hl and hl.fg then
			local base_fg = "#000000"
			local bg = hl.fg
			local washed = lighten_hex(bg, 0.5)

			vim.api.nvim_set_hl(0, "PreviewHeading" .. level, {
				fg = base_fg,
				bg = bg,
				bold = true,
			})

			vim.api.nvim_set_hl(0, "PreviewParagraph" .. level, {
				fg = base_fg,
				bg = washed,
			})
		end
	end

	-- Apply highlights with correct column range
	for _, h in ipairs(highlights) do
		local group = h.is_para and ("PreviewParagraph" .. h.level) or ("PreviewHeading" .. h.level)
		vim.api.nvim_buf_add_highlight(buf, ns, group, h.line, h.col_start or 0, h.col_end or -1)
	end

	-- Navigation
	local current_index = 1
	local function jump_to_block(index)
		current_index = index
		local target = block_starts[index]
		if target then
			vim.api.nvim_win_set_cursor(win, { target, 0 })
		end
	end

	vim.keymap.set("n", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(0)[1]
		local target
		for l = cursor, 1, -1 do
			if line_map[l] then
				target = line_map[l]
				break
			end
		end
		if target and last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
			vim.api.nvim_win_close(win, true)
			vim.api.nvim_set_current_win(last_active_win)
			vim.api.nvim_win_set_cursor(last_active_win, { target, 0 })
		end
	end, { buffer = buf })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "j", function()
		if current_index < #block_starts then
			jump_to_block(current_index + 1)
		end
	end, { buffer = buf })

	vim.keymap.set("n", "k", function()
		if current_index > 1 then
			jump_to_block(current_index - 1)
		end
	end, { buffer = buf })

	jump_to_block(1)
end

local function sha256(str)
	local tempfile = vim.fn.tempname()
	local f = io.open(tempfile, "w")
	f:write(str)
	f:close()
	local handle = io.popen("sha256sum " .. tempfile)
	local result = handle:read("*a")
	handle:close()
	os.remove(tempfile)
	return result:match("^(%w+)")
end

function M.ai_generate_summary_of_headings()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		vim.notify("Invalid buffer", vim.log.levels.WARN)
		return
	end

	if #toc_headings == 0 then
		vim.notify("No headings found", vim.log.levels.WARN)
		return
	end

	local all_lines = vim.api.nvim_buf_get_lines(last_active_buf, 0, -1, false)
	local tmpdir = vim.fn.expand("~/.var/app/nvim-aisum")
	vim.fn.mkdir(tmpdir, "p")

	local queue = {}
	local running = false
	local input_path = tmpdir .. "/input"
	local output_path = tmpdir .. "/output"

	for i, heading in ipairs(toc_headings) do
		local next_line = (#toc_headings > i) and toc_headings[i + 1].line or #all_lines

		local body_lines = {}

		for l = heading.line + 1, next_line - 1 do
			table.insert(body_lines, all_lines[l])
		end
		local body = table.concat(body_lines, "\n")
		if body:match("^%s*$") then
			goto continue
		end

		local prompt = "Summarize this section with a single short sentence. (no intro text or outro, do not print like 'here is a brief summary', only the summary itself). Also suggest an improvement after 'Improvement: ' at the end:\n\n"
			.. "# "
			.. heading.text
			.. "\n\n"
			.. body

		local body_hash = sha256(body)
		local heading_hash = sha256(heading.text)

		local flag_path = tmpdir .. "/" .. body_hash .. ".flag"
		local summary_path = tmpdir .. "/" .. heading_hash .. ".summary"

		if vim.fn.filereadable(flag_path) == 1 then
			goto continue
		end

		table.insert(queue, {
			index = i,
			total = #toc_headings,
			heading = heading.text,
			prompt = prompt,
			summary_path = summary_path,
			flag_path = flag_path,
		})

		::continue::
	end

	if #queue == 0 then
		print("✅ All headings already summarized.")
		return
	end

	local function process_next()
		if #queue == 0 then
			print("🎉 Done summarizing all headings.")
			running = false
			return
		end

		local item = table.remove(queue, 1)
		print(string.format("⚙️  Processing [%d/%d]: %s", item.index, item.total, item.heading))

		local f = io.open(input_path, "w")
		if f then
			f:write(item.prompt)
			f:close()
		else
			print("❌ Failed to write prompt input file.")
			process_next()
			return
		end

		os.remove(output_path)

		vim.fn.jobstart({ "sh", "-c", "ollama run llama3.2 < " .. vim.fn.shellescape(input_path) }, {
			stdout_buffered = true,
			on_stdout = function(_, data)
				if not data or #data == 0 then
					return
				end
				local summary = table.concat(data, "\n")
				if summary:match("%S") then
					local sf = io.open(item.summary_path, "w")
					if sf then
						sf:write(summary)
						sf:close()
					end
					local flag = io.open(item.flag_path, "w")
					if flag then
						flag:write("done\n")
						flag:close()
					end
					print("✅ Finished: " .. item.heading)
				else
					print("⚠️ No meaningful summary for: " .. item.heading)
				end
			end,
			on_exit = function()
				vim.schedule(process_next)
			end,
		})
	end

	if not running then
		running = true
		process_next()
	end
end

function M.preview_outline_summary()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		return
	end

	local source_cursor_line = nil
	if last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
		source_cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}
	local line_map = {}
	local block_starts = {}
	local highlights = {}

	local all_lines = vim.api.nvim_buf_get_lines(last_active_buf, 0, -1, false)
	local tmpdir = vim.fn.expand("~/.var/app/nvim-aisum")

	local function indent_for_level(level)
		return string.rep("  ", level - 1)
	end

	for _, heading in ipairs(toc_headings) do
		local heading_indent = indent_for_level(heading.level)
		local title = heading_indent .. heading.text
		local start_line = #lines + 1
		table.insert(block_starts, start_line)

		table.insert(lines, title)
		line_map[#lines] = heading.line + 1
		table.insert(highlights, {
			line = #lines - 1,
			level = heading.level,
			col_start = #heading_indent + 2,
			col_end = #heading_indent + 2 + #heading.text,
			is_para = false,
		})

		local heading_hash = sha256(heading.text)
		local summary_path = tmpdir .. "/" .. heading_hash .. ".summary"
		local summary_lines = {}

		local f = io.open(summary_path, "r")
		if f then
			for line in f:lines() do
				local trimmed = vim.trim(line)
				local indent = indent_for_level(heading.level)
				table.insert(summary_lines, indent .. trimmed)
				table.insert(highlights, {
					line = #lines + #summary_lines - 1,
					level = heading.level,
					col_start = #indent + 2,
					col_end = #indent + 2 + #trimmed,
					is_para = true,
				})
			end
			f:close()
		else
			local indent = indent_for_level(heading.level)
			local text = "Summary not generated yet."
			table.insert(summary_lines, indent .. text)
			table.insert(highlights, {
				line = #lines,
				level = heading.level,
				col_start = #indent + 2,
				col_end = #indent + 2 + #text,
				is_para = true,
			})
		end

		vim.list_extend(lines, summary_lines)
		table.insert(lines, "")
	end

	local padded = {}
	for _, line in ipairs(lines) do
		table.insert(padded, "  " .. line .. "  ")
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, padded)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	local width = math.floor(vim.o.columns * 0.6)
	local height = vim.o.lines - 2
	local row = 1
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
	})

	vim.api.nvim_set_hl(0, "FloatBorder", { fg = "limegreen", bg = "#0b0b0b" })
	vim.api.nvim_set_hl(0, "PreviewWindowBG", { bg = "#0b0b0b" })
	vim.api.nvim_set_option_value("winhl", "Normal:PreviewWindowBG,FloatBorder:FloatBorder", { win = win })

	local ns = vim.api.nvim_create_namespace("PreviewHeadings")
	local function lighten_hex(hex, percent)
		local r = tonumber(hex:sub(2, 3), 16)
		local g = tonumber(hex:sub(4, 5), 16)
		local b = tonumber(hex:sub(6, 7), 16)
		local function lighten(x)
			return math.floor(x + (255 - x) * percent)
		end
		return string.format("#%02x%02x%02x", lighten(r), lighten(g), lighten(b))
	end

	for level = 1, 6 do
		local hl = opts.hl_groups["h" .. level]
		if hl and hl.fg then
			local fg = hl.fg
			local washed = lighten_hex(fg, 0.5)
			vim.api.nvim_set_hl(0, "PreviewHeading" .. level, { fg = fg, bg = "NONE", bold = true })
			vim.api.nvim_set_hl(0, "PreviewParagraph" .. level, { fg = washed, bg = "NONE" })
		end
	end

	for _, h in ipairs(highlights) do
		local group = h.is_para and ("PreviewParagraph" .. h.level) or ("PreviewHeading" .. h.level)
		vim.api.nvim_buf_add_highlight(buf, ns, group, h.line, h.col_start or 0, h.col_end or -1)
	end

	local marker_ns = vim.api.nvim_create_namespace("FloatCursorMarker")
	vim.api.nvim_set_hl(0, "FloatMarker", { fg = "#ff0000", bold = true })
	local function update_cursor_marker()
		local line = vim.api.nvim_win_get_cursor(win)[1] - 1
		vim.api.nvim_buf_clear_namespace(buf, marker_ns, 0, -1)
		vim.api.nvim_buf_set_extmark(buf, marker_ns, line, 0, {
			virt_text = { { "> ", "FloatMarker" } },
			virt_text_pos = "overlay",
		})
	end
	update_cursor_marker()
	vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = update_cursor_marker })

	local current_line = source_cursor_line or 0
	local current_toc_index = 1
	for i = #toc_headings, 1, -1 do
		if toc_headings[i].line <= current_line then
			current_toc_index = i
			break
		end
	end

	local current_index = current_toc_index
	local function jump_to_block(index)
		current_index = index
		local target = block_starts[index]
		if target then
			vim.api.nvim_win_set_cursor(win, { target, 0 })
		end
	end

	vim.keymap.set("n", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(0)[1]
		local target
		for l = cursor, 1, -1 do
			if line_map[l] then
				target = line_map[l]
				break
			end
		end
		if target and last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
			vim.api.nvim_win_close(win, true)
			vim.api.nvim_set_current_win(last_active_win)
			vim.api.nvim_win_set_cursor(last_active_win, { target, 0 })
		end
	end, { buffer = buf })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "j", function()
		if current_index < #block_starts then
			jump_to_block(current_index + 1)
		end
	end, { buffer = buf })

	vim.keymap.set("n", "k", function()
		if current_index > 1 then
			jump_to_block(current_index - 1)
		end
	end, { buffer = buf })

	jump_to_block(current_toc_index)
	vim.cmd("normal! zz")
end

-- Old one with bright bg and changed colors
--function M.preview_outline_summary()
--	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
--		return
--	end
--
--	-- Save current cursor position BEFORE opening float
--	local source_cursor_line = nil
--	if last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
--		source_cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1
--	end
--
--	local buf = vim.api.nvim_create_buf(false, true)
--	local lines = {}
--	local line_map = {}
--	local block_starts = {}
--	local highlights = {}
--
--	local all_lines = vim.api.nvim_buf_get_lines(last_active_buf, 0, -1, false)
--	local tmpdir = vim.fn.expand("~/.tmp/aisum")
--
--	local function indent_for_level(level)
--		return string.rep("  ", level - 1)
--	end
--
--	for _, heading in ipairs(toc_headings) do
--		local heading_indent = indent_for_level(heading.level)
--		local title = heading_indent .. heading.text
--		local start_line = #lines + 1
--		table.insert(block_starts, start_line)
--
--		table.insert(lines, title)
--		line_map[#lines] = heading.line + 1
--		table.insert(highlights, {
--			line = #lines - 1,
--			level = heading.level,
--			col_start = #heading_indent,
--			col_end = #heading_indent + #heading.text,
--			is_para = false,
--		})
--
--		local heading_hash = sha256(heading.text)
--		local summary_path = tmpdir .. "/" .. heading_hash .. ".summary"
--		local summary_lines = {}
--
--		local f = io.open(summary_path, "r")
--		if f then
--			for line in f:lines() do
--				local trimmed = vim.trim(line)
--				local indent = indent_for_level(heading.level)
--				table.insert(summary_lines, indent .. trimmed)
--
--				table.insert(highlights, {
--					line = #lines + #summary_lines - 1,
--					level = heading.level,
--					col_start = #indent,
--					col_end = #indent + #trimmed,
--					is_para = true,
--				})
--			end
--			f:close()
--		else
--			local indent = indent_for_level(heading.level)
--			local text = "Summary not generated yet."
--			table.insert(summary_lines, indent .. text)
--			table.insert(highlights, {
--				line = #lines,
--				level = heading.level,
--				col_start = #indent,
--				col_end = #indent + #text,
--				is_para = true,
--			})
--		end
--
--		vim.list_extend(lines, summary_lines)
--		table.insert(lines, "")
--	end
--
--	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
--	vim.bo[buf].filetype = "markdown"
--	vim.bo[buf].bufhidden = "wipe"
--	vim.bo[buf].modifiable = false
--
--	local width = math.floor(vim.o.columns * 0.6)
--	local height = vim.o.lines - 2
--	local row = 1
--	local col = math.floor((vim.o.columns - width) / 2)
--
--	local win = vim.api.nvim_open_win(buf, true, {
--		relative = "editor",
--		width = width,
--		height = height,
--		row = row,
--		col = col,
--		style = "minimal",
--		border = "none",
--	})
--
--	-- Define a namespace for the red marker
--	local marker_ns = vim.api.nvim_create_namespace("FloatCursorMarker")
--
--	-- Function to update the virtual marker
--	local function update_cursor_marker()
--		local line = vim.api.nvim_win_get_cursor(win)[1] - 1
--		-- Clear previous marker
--		vim.api.nvim_buf_clear_namespace(buf, marker_ns, 0, -1)
--		-- Add the red ">" marker at the start of the current line
--		vim.api.nvim_buf_set_extmark(buf, marker_ns, line, 0, {
--			virt_text = { { "> ", "FloatMarker" } },
--			virt_text_pos = "overlay",
--		})
--	end
--
--	-- Define highlight for the marker (red color)
--	vim.api.nvim_set_hl(0, "FloatMarker", { fg = "#ff0000", bold = true })
--
--	-- Set the initial marker
--	update_cursor_marker()
--
--	-- Move it as cursor moves
--	vim.api.nvim_create_autocmd("CursorMoved", {
--		buffer = buf,
--		callback = update_cursor_marker,
--	})
--	--	-- Set up cursorline
--	--	vim.api.nvim_set_hl(0, "MyFloatCursorLine", { bg = "#ffffff" })
--	--	vim.wo[win].cursorline = true
--	--	vim.api.nvim_set_option_value("winhl", "CursorLine:MyFloatCursorLine", { win = win })
--
--	vim.api.nvim_set_hl(0, "PreviewWindowBG", { bg = "#f5f1d4" })
--	vim.api.nvim_set_option_value("winhl", "Normal:PreviewWindowBG", { win = win })
--
--	local ns = vim.api.nvim_create_namespace("PreviewHeadings")
--	for level = 1, 6 do
--		local hl = opts.hl_groups["h" .. level]
--		if hl and hl.fg then
--			local fg = "#000000"
--			local bg = hl.fg
--			local function lighten(x)
--				return math.floor(x + (255 - x) * 0.5)
--			end
--			local r = tonumber(bg:sub(2, 3), 16)
--			local g = tonumber(bg:sub(4, 5), 16)
--			local b = tonumber(bg:sub(6, 7), 16)
--			local washed = string.format("#%02x%02x%02x", lighten(r), lighten(g), lighten(b))
--
--			vim.api.nvim_set_hl(0, "PreviewHeading" .. level, { fg = fg, bg = bg, bold = true })
--			vim.api.nvim_set_hl(0, "PreviewParagraph" .. level, { fg = fg, bg = washed })
--		end
--	end
--
--	for _, h in ipairs(highlights) do
--		local group = h.is_para and ("PreviewParagraph" .. h.level) or ("PreviewHeading" .. h.level)
--		vim.api.nvim_buf_add_highlight(buf, ns, group, h.line, h.col_start or 0, h.col_end or -1)
--	end
--
--	-- Get current TOC heading index from cursor position
--	local current_line = source_cursor_line or 0
--	local current_toc_index = 1
--	for i = #toc_headings, 1, -1 do
--		if toc_headings[i].line <= current_line then
--			current_toc_index = i
--			break
--		end
--	end
--
--	-- Navigation
--	local current_index = current_toc_index
--	local function jump_to_block(index)
--		current_index = index
--		local target = block_starts[index]
--		if target then
--			vim.api.nvim_win_set_cursor(win, { target, 0 })
--		end
--	end
--
--	vim.keymap.set("n", "<CR>", function()
--		local cursor = vim.api.nvim_win_get_cursor(0)[1]
--		local target
--		for l = cursor, 1, -1 do
--			if line_map[l] then
--				target = line_map[l]
--				break
--			end
--		end
--		if target and last_active_win and vim.api.nvim_win_is_valid(last_active_win) then
--			vim.api.nvim_win_close(win, true)
--			vim.api.nvim_set_current_win(last_active_win)
--			vim.api.nvim_win_set_cursor(last_active_win, { target, 0 })
--		end
--	end, { buffer = buf })
--
--	vim.keymap.set("n", "q", function()
--		vim.api.nvim_win_close(win, true)
--	end, { buffer = buf })
--
--	vim.keymap.set("n", "<Esc>", function()
--		vim.api.nvim_win_close(win, true)
--	end, { buffer = buf })
--
--	vim.keymap.set("n", "j", function()
--		if current_index < #block_starts then
--			jump_to_block(current_index + 1)
--		end
--	end, { buffer = buf })
--
--	vim.keymap.set("n", "k", function()
--		if current_index > 1 then
--			jump_to_block(current_index - 1)
--		end
--	end, { buffer = buf })
--
--	jump_to_block(current_toc_index)
--	vim.cmd("normal! zz")
--end

function M.ask_ai_about_current_section()
	if not last_active_buf or not vim.api.nvim_buf_is_valid(last_active_buf) then
		vim.notify("Invalid buffer", vim.log.levels.WARN)
		return
	end
	if #toc_headings == 0 then
		vim.notify("No headings found", vim.log.levels.WARN)
		return
	end

	local cursor_line = vim.api.nvim_win_get_cursor(last_active_win)[1] - 1
	local current_index = nil

	for i = #toc_headings, 1, -1 do
		if toc_headings[i].line <= cursor_line then
			current_index = i
			break
		end
	end

	if not current_index then
		vim.notify("Couldn't find current heading", vim.log.levels.WARN)
		return
	end

	local heading = toc_headings[current_index]
	local start_line = heading.line + 1
	local end_line = heading.end_line or start_line

	-- Ensure end_line is at least start_line
	if end_line < start_line then
		end_line = start_line
	end

	local body_lines = vim.api.nvim_buf_get_lines(last_active_buf, start_line, end_line, false)
	local body = table.concat(body_lines, "\n")

	vim.ui.input({ prompt = "Ask AI about this section:" }, function(question)
		if not question or question == "" then
			vim.notify("No question asked.", vim.log.levels.INFO)
			return
		end

		local input =
			string.format("%s\n\n# %s (lines %d–%d)\n\n%s", question, heading.text, start_line + 1, end_line, body)

		--local tmpdir = vim.fn.expand("~/.tmp/aisum")
		local tmpdir = vim.fn.expand("~/.var/app/nvim-aisum")
		vim.fn.mkdir(tmpdir, "p")
		local input_path = tmpdir .. "/ask_input"

		local f = io.open(input_path, "w")
		if not f then
			vim.notify("❌ Failed to write input", vim.log.levels.ERROR)
			return
		end
		f:write(input)
		f:close()

		vim.fn.jobstart({ "sh", "-c", "ollama run llama3.2 < " .. vim.fn.shellescape(input_path) }, {
			stdout_buffered = true,
			on_stdout = function(_, data)
				if not data or #data == 0 then
					vim.notify("⚠️ No answer from AI", vim.log.levels.WARN)
					return
				end

				local response = table.concat(data, "\n")
				if not response:match("%S") then
					vim.notify("⚠️ Empty AI response", vim.log.levels.WARN)
					return
				end

				local combined = {}
				vim.list_extend(combined, vim.split(response, "\n"))
				table.insert(combined, "")
				table.insert(combined, "── INPUT ──")
				vim.list_extend(combined, vim.split(input, "\n"))

				local preview_buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, combined)
				vim.bo[preview_buf].filetype = "markdown"
				vim.bo[preview_buf].bufhidden = "wipe"
				vim.bo[preview_buf].modifiable = false

				local width = math.floor(vim.o.columns * 0.7)
				local height = math.floor(vim.o.lines * 0.8)
				local row = math.floor((vim.o.lines - height) / 2)
				local col = math.floor((vim.o.columns - width) / 2)

				local win = vim.api.nvim_open_win(preview_buf, true, {
					relative = "editor",
					width = width,
					height = height,
					row = row,
					col = col,
					style = "minimal",
					border = "rounded",
				})

				vim.keymap.set("n", "q", function()
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
					end
				end, { buffer = preview_buf })
			end,
		})
	end)
end

function M.ask_ai_about_visual_selection()
	-- If we aren't in visual mode, abort
	local mode = vim.fn.mode()
	local is_selection_mode = true
	if not (mode == "v" or mode == "V" or mode == "\x16") then
		--		vim.notify("Not in visual mode, no text selected.", vim.log.levels.WARN)
		--		return
		is_selection_mode = false
	end

	local selected_text = ""

	if is_selection_mode then
		-- Preserve the user's current " register, register type, and clipboard
		local saved_reg = vim.fn.getreg('"')
		local saved_regtype = vim.fn.getregtype('"')
		local saved_clipboard = vim.opt.clipboard

		-- We'll yank into register z, but to do so, we need to end up in normal mode
		-- without losing the visual selection. We can do this by:
		--  1) "gv" to reselect last visual area, if needed
		--  2) "\"zy" to yank into register z
		--  3) Then read from that register in Lua
		--
		-- The simplest approach is: do a forced normal command that yanks into z:
		--
		vim.cmd([[normal! "zy]])

		-- Now get the text from register z
		selected_text = vim.fn.getreg("z")

		-- Restore original register/clipboard
		vim.fn.setreg('"', saved_reg, saved_regtype)
		vim.opt.clipboard = saved_clipboard

		-- If empty, we can’t proceed
		if not selected_text or selected_text == "" then
			vim.notify("No text was yanked (empty selection?).", vim.log.levels.WARN)
			return
		end
	end
	-- Prompt for question
	vim.ui.input({ prompt = "Ask AI about selected text: " }, function(question)
		if not question or question == "" then
			vim.notify("No question asked.", vim.log.levels.INFO)
			return
		end

		local input = ""
		if is_selection_mode then
			input = string.format("%s\n\n# Selected Text\n\n%s", question, selected_text)
		else
			input = question
		end

		-- Write input to a temp file
		local tmpdir = vim.fn.expand("~/.var/app/nvim-aisum")
		vim.fn.mkdir(tmpdir, "p")
		local input_path = tmpdir .. "/ask_input"

		local f = io.open(input_path, "w")
		if not f then
			vim.notify("❌ Failed to write input", vim.log.levels.ERROR)
			return
		end
		f:write(input)
		f:close()

		-- Spinner
		local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
		local spinner_index = 1
		local timer = vim.loop.new_timer()

		-- Start spinner
		timer:start(
			0,
			100,
			vim.schedule_wrap(function()
				vim.api.nvim_echo({ { "Loading... " .. spinner_frames[spinner_index], "None" } }, false, {})
				spinner_index = (spinner_index % #spinner_frames) + 1
			end)
		)

		-- NOTE: Old local version
		-- Call ollama asynchronously
		--vim.fn.jobstart({ "sh", "-c", "ollama run llama3.2 < " .. vim.fn.shellescape(input_path) }, {
		--		vim.fn.jobstart({ "sh", "-c", "ollama run deepseek-r1:32b < " .. vim.fn.shellescape(input_path) }, {
		--			stdout_buffered = true,
		--			on_stdout = function(_, data)
		--				-- Stop spinner
		--				timer:stop()
		--				timer:close()
		--				vim.api.nvim_echo({ { "", "None" } }, false, {})
		--
		--				if not data or #data == 0 then
		--					vim.notify("⚠️ No response from AI", vim.log.levels.WARN)
		--					return
		--				end
		--
		--				local response = table.concat(data, "\n")
		--				if not response:match("%S") then
		--					vim.notify("⚠️ Empty AI response", vim.log.levels.WARN)
		--					return
		--				end
		--
		--				-- Combine response & input for display
		--				local combined = {}
		--				vim.list_extend(combined, vim.split(response, "\n"))
		--				table.insert(combined, "")
		--				table.insert(combined, "── INPUT ──")
		--				vim.list_extend(combined, vim.split(input, "\n"))
		--
		--				-- Create floating preview buffer
		--				local preview_buf = vim.api.nvim_create_buf(false, true)
		--				vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, combined)
		--				vim.bo[preview_buf].filetype = "markdown"
		--				vim.bo[preview_buf].bufhidden = "wipe"
		--				vim.bo[preview_buf].modifiable = false
		--
		--				-- Define highlight groups with native Lua API
		--				vim.api.nvim_set_hl(0, "AIResponseFloat", {
		--					bg = "#0a0a0a",
		--				})
		--
		--				vim.api.nvim_set_hl(0, "AIResponseBorder", {
		--					fg = "Cyan",
		--					bg = "#0a0a0a",
		--				})
		--
		--				-- Calculate size and position
		--				local width = math.floor(vim.o.columns * 0.7)
		--				local height = vim.o.lines - 2 -- full height with top/bottom padding
		--				local row = 1
		--				local col = math.floor((vim.o.columns - width) / 2)
		--
		--				-- Open floating window with custom highlights
		--				local win = vim.api.nvim_open_win(preview_buf, true, {
		--					relative = "editor",
		--					width = width,
		--					height = height - 4,
		--					row = row,
		--					col = col,
		--					style = "minimal",
		--					border = "rounded",
		--				})
		--
		--				--vim.api.nvim_set_option_value("relativenumber", true, { win = win })
		--				vim.api.nvim_set_option_value(
		--					"winhl",
		--					"Normal:AIResponseFloat,FloatBorder:AIResponseBorder",
		--					{ win = win }
		--				)
		--				local lines = {
		--					"This is the AI response.",
		--					"Here is some more output.",
		--					"Final result below.",
		--				}
		--
		--				-- Press 'q' in this buffer to close it
		--				-- Map 'q' in normal mode to close the window
		--				vim.keymap.set("n", "q", function()
		--					if vim.api.nvim_win_is_valid(win) then
		--						vim.api.nvim_win_close(win, true)
		--					end
		--				end, { buffer = preview_buf, noremap = true, silent = true })
		--				-- Add vertical padding
		--				--table.insert(lines, 1, "") -- top
		--				--table.insert(lines, "") -- bottom
		--
		--				-- Add horizontal padding
		--				--				local padded = {}
		--				--				for _, line in ipairs(lines) do
		--				--					table.insert(padded, "    " .. line .. "    ") -- 4 spaces left/right
		--				--				end
		--
		--				vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, padded)
		--				-- Ensure the float has focus (optional but safe)
		--				vim.api.nvim_set_current_win(win)
		--			end,
		--		})
		--

		local curl = require("plenary.curl")
		local api_key = os.getenv("OPENAI_API_KEY")

		vim.schedule(function()
			local response = curl.post("https://api.openai.com/v1/chat/completions", {
				headers = {
					["Content-Type"] = "application/json",
					["Authorization"] = "Bearer " .. api_key,
				},
				body = vim.fn.json_encode({
					model = "gpt-4.1", -- Change this to gpt-4o, gpt-4o-mini, etc. if needed
					messages = {
						{ role = "system", content = "You are a helpful code assistant." },
						{ role = "user", content = input },
					},
					temperature = 0.3,
				}),
			})
			log("Response: " .. vim.inspect(response))
			timer:stop()
			timer:close()
			vim.api.nvim_echo({ { "", "None" } }, false, {})

			if response.status ~= 200 then
				vim.notify(
					"❌ OpenAI API error: " .. response.status .. "\n" .. (response.body or ""),
					vim.log.levels.ERROR
				)
				return
			end

			local decoded = vim.fn.json_decode(response.body)
			local ai_reply = decoded.choices and decoded.choices[1] and decoded.choices[1].message.content or nil

			if not ai_reply or not ai_reply:match("%S") then
				vim.notify("⚠️ Empty or invalid AI response", vim.log.levels.WARN)
				return
			end

			-- Combine response & input for display
			local combined = {}
			vim.list_extend(combined, vim.split(ai_reply, "\n"))
			table.insert(combined, "")
			table.insert(combined, "── INPUT ──")
			vim.list_extend(combined, vim.split(input, "\n"))

			-- Create floating preview buffer
			local preview_buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, combined)
			vim.bo[preview_buf].filetype = "markdown"
			vim.bo[preview_buf].bufhidden = "wipe"
			vim.bo[preview_buf].modifiable = false

			vim.api.nvim_set_hl(0, "AIResponseFloat", { bg = "#0a0a0a" })
			vim.api.nvim_set_hl(0, "AIResponseBorder", { fg = "Cyan", bg = "#0a0a0a" })

			local width = math.floor(vim.o.columns * 0.7)
			local height = vim.o.lines - 2
			local row = 1
			local col = math.floor((vim.o.columns - width) / 2)

			local win = vim.api.nvim_open_win(preview_buf, true, {
				relative = "editor",
				width = width,
				height = height - 4,
				row = row,
				col = col,
				style = "minimal",
				border = "rounded",
			})

			vim.api.nvim_set_option_value("winhl", "Normal:AIResponseFloat,FloatBorder:AIResponseBorder", { win = win })

			vim.keymap.set("n", "q", function()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
			end, { buffer = preview_buf, noremap = true, silent = true })

			vim.api.nvim_set_current_win(win)
		end)
	end)
end

function M.ask_ai_and_replace_selection()
	local mode = vim.fn.mode()
	local is_selection_mode = (mode == "v" or mode == "V" or mode == "\x16")
	local selected_text = ""

	if not is_selection_mode then
		vim.notify("Not in visual mode, nothing to replace.", vim.log.levels.WARN)
		return
	end

	-- Save current register and yank visual selection into register z
	local saved_reg = vim.fn.getreg('"')
	local saved_regtype = vim.fn.getregtype('"')
	vim.cmd([[normal! "zy]])
	selected_text = vim.fn.getreg("z")
	vim.fn.setreg('"', saved_reg, saved_regtype)

	if not selected_text or selected_text == "" then
		vim.notify("No text selected.", vim.log.levels.WARN)
		return
	end

	-- Get visual selection range so we can replace it later
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local start_line = start_pos[2] - 1
	local start_col = start_pos[3]
	local end_line = end_pos[2] - 1
	local end_col = end_pos[3]

	if start_line > end_line or (start_line == end_line and start_col > end_col) then
		start_line, end_line = end_line, start_line
		start_col, end_col = end_col, start_col
	end

	vim.ui.input({ prompt = "Ask AI to rewrite selection: " }, function(question)
		if not question or question == "" then
			vim.notify("No question asked.", vim.log.levels.INFO)
			return
		end

		-- Construct AI prompt
		local input = string.format("%s\n\nOnly return the code, no explanation:\n\n%s", question, selected_text)

		local tmpdir = vim.fn.expand("~/.var/app/nvim-aisum")
		vim.fn.mkdir(tmpdir, "p")
		local input_path = tmpdir .. "/ask_input"

		local f = io.open(input_path, "w")
		if not f then
			vim.notify("❌ Failed to write input", vim.log.levels.ERROR)
			return
		end
		f:write(input)
		f:close()

		-- Show spinner while waiting
		local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
		local spinner_index = 1
		local timer = vim.loop.new_timer()
		timer:start(
			0,
			100,
			vim.schedule_wrap(function()
				vim.api.nvim_echo({ { "Asking AI... " .. spinner_frames[spinner_index], "None" } }, false, {})
				spinner_index = (spinner_index % #spinner_frames) + 1
			end)
		)

		vim.fn.jobstart({ "sh", "-c", "ollama run llama3.2 < " .. vim.fn.shellescape(input_path) }, {
			stdout_buffered = true,
			on_stdout = function(_, data)
				timer:stop()
				timer:close()
				vim.api.nvim_echo({ { "", "None" } }, false, {})

				if not data or #data == 0 then
					vim.notify("⚠️ No response from AI", vim.log.levels.WARN)
					return
				end

				local response = table.concat(data, "\n")
				if not response:match("%S") then
					vim.notify("⚠️ Empty AI response", vim.log.levels.WARN)
					return
				end

				-- Replace the selected lines with the response
				local bufnr = vim.api.nvim_get_current_buf()
				-- Split into lines
				local response_lines = vim.split(response, "\n")

				-- Trim leading/trailing blank lines
				while response_lines[1] and response_lines[1]:match("^%s*$") do
					table.remove(response_lines, 1)
				end
				while response_lines[#response_lines] and response_lines[#response_lines]:match("^%s*$") do
					table.remove(response_lines, #response_lines)
				end

				-- Strip ```lang and ``` if present
				if response_lines[1] and response_lines[1]:match("^```") then
					-- remove opening ```lang
					table.remove(response_lines, 1)

					-- remove ending ``` (search from bottom)
					for i = #response_lines, 1, -1 do
						if response_lines[i]:match("^```") then
							table.remove(response_lines, i)
							break
						end
					end
				end

				-- Reliable replacement of selection
				bufnr = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_lines(bufnr, start_line, end_line + 1, false, response_lines)
			end,
		})
	end)
end
return M
