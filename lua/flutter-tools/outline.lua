local ui = require("flutter-tools.ui")
local utils = require("flutter-tools.utils")
local config = require("flutter-tools.config")
local code_actions = require("flutter-tools.lsp.code_actions")

local api = vim.api
local fn = vim.fn
local lsp = vim.lsp
local fmt = string.format
local outline_filename = "Flutter Outline"
local outline_filetype = "flutterToolsOutline"

local M = {}

-----------------------------------------------------------------------------//
-- Namespaces
-----------------------------------------------------------------------------//
local outline_ns_id = api.nvim_create_namespace("flutter_tools_outline_selected_item")

-----------------------------------------------------------------------------//
-- Icons
-----------------------------------------------------------------------------//

local markers = {
  bottom = "└",
  middle = "├",
  vertical = "│",
  horizontal = "─",
}

local icons = setmetatable({
  TOP_LEVEL_VARIABLE = "",
  CLASS = "",
  FIELD = "綠",
  CONSTRUCTOR = "",
  CONSTRUCTOR_INVOCATION = "ﰪ",
  FUNCTION = "ƒ",
  METHOD = "",
  GETTER = "ྟ",
  ENUM = "",
  ENUM_CONSTANT = "",
  DEFAULT = "",
}, {
  __index = function(t, _)
    return t.DEFAULT
  end,
})

local hl_prefix = "FlutterToolsOutline"

local icon_highlights = {
  [icons.TOP_LEVEL_VARIABLE] = { name = "TopLevelVar", link = "Identifier" },
  [icons.CLASS] = { name = "Class", link = "Type" },
  [icons.FIELD] = { name = "Field", link = "Identifier" },
  [icons.CONSTRUCTOR] = { name = "Constructor", link = "Identifier" },
  [icons.CONSTRUCTOR_INVOCATION] = { name = "ConstructorInvocation", link = "Special" },
  [icons.FUNCTION] = { name = "Function", link = "Function" },
  [icons.METHOD] = { name = "Method", link = "Function" },
  [icons.GETTER] = { name = "Getter", link = "Function" },
  [icons.ENUM] = { name = "Enum", link = "Type" },
  [icons.ENUM_CONSTANT] = { name = "EnumConstant", link = "Type" },
  [icons.DEFAULT] = { name = "Default", link = "Comment" },
}

-----------------------------------------------------------------------------//
-- State
-----------------------------------------------------------------------------//
local state = setmetatable({
  outline_buf = nil,
  outline_win = nil,
}, {
  __index = function(_, k)
    --- if the buffer of the outline file is nil but it *might* exist
    --- we default to also checking if any file with a similar name exists
    -- if so we return it's buffer number
    if k == "outline_buf" then
      local buf = fn.bufnr(outline_filename)
      return buf >= 0 and buf or nil
    end
    return nil
  end,
})

M.outlines = setmetatable({}, {
  __index = function()
    return {}
  end,
})
-----------------------------------------------------------------------------//
---@param name string
---@param group string
local function hl_link(name, group)
  vim.cmd(fmt("highlight default link %s%s %s", hl_prefix, name, group))
end

---@param name string
---@param value string
---@param group string
local function highlight_item(name, value, group)
  vim.cmd(fmt("syntax match %s%s /%s/", hl_prefix, name, value))
  hl_link(name, group)
end

local function set_outline_highlights()
  hl_link("SelectedOutlineItem", "Search")
  highlight_item("String", [[\v(''|""|(['"]).{-}[^\\]\2)]], "String")

  for key, value in pairs(markers) do
    highlight_item(key, value, "Whitespace")
  end
  for icon, hl in pairs(icon_highlights) do
    highlight_item(hl.name, icon, hl.link)
  end
end

---@param list table
---@param highlights table
---@param item string
---@param hl string
---@param length number
---@param position number
local function add_segment(list, highlights, item, hl, length, position)
  if item and item ~= "" then
    --- NOTE highlights are byte indexed
    --- so use "#" operator to get the byte count
    local item_length = #item
    local new_length = item_length + length
    table.insert(highlights, {
      value = item,
      highlight = hl,
      column_start = length + 1,
      column_end = new_length + 1,
    })
    list[position or #list + 1] = item
    length = new_length
  end
  return length
end

---@param result table
---@param node table
---@param indent string
---@param marker string
local function parse_outline(result, node, indent, marker)
  indent = indent or ""
  marker = marker or ""
  if not node then
    return
  end
  local range = node.codeRange
  local element = node.element or {}
  local text = {}
  local icon = icons[element.kind]
  local display_str = { indent, marker, icon }

  local hl = {}
  local length = #table.concat(display_str, " ")

  local return_type = element.returnType and element.returnType .. " "
  length = add_segment(text, hl, return_type, "Comment", length)
  length = add_segment(text, hl, element.name, "None", length)
  length = add_segment(text, hl, element.typeParameters, "Type", length)
  length = add_segment(text, hl, element.parameters, "Bold", length)

  table.insert(display_str, table.concat(text, ""))
  local content = table.concat(display_str, " ")

  table.insert(result, {
    hl = hl,
    -- this number might be required to be 1 or 0 based
    -- based on the api call using it as row, col api functions
    -- can be (1, 0) based. It is stored as 0 based as this is the
    -- most common requirement but must be one based when manipulating
    -- the cursor
    lnum = #result,
    buf_start = #indent,
    buf_end = #content,
    start_line = range.start.line,
    start_col = range.start.character - 1,
    end_line = range["end"].line,
    end_col = range["end"].character - 1,
    name = element.name,
    text = content,
  })

  local children = node.children
  if not children or vim.tbl_isempty(children) then
    return
  end

  local parent_marker = marker == markers.middle and markers.vertical or " "
  indent = indent .. " " .. parent_marker
  for index, child in ipairs(children) do
    local new_marker = index == #children and markers.bottom or markers.middle
    parse_outline(result, child, indent, new_marker)
  end
end

---@return boolean, table?, table?, table?
local function get_outline_content()
  local buf = api.nvim_get_current_buf()
  local outline = M.outlines[vim.uri_from_bufnr(buf)]
  if not outline or vim.tbl_isempty(outline) then
    return false
  end
  local lines = {}
  local highlights = {}
  for _, item in ipairs(outline) do
    if item.hl then
      for _, hl in ipairs(item.hl) do
        hl.line_number = item.lnum
        table.insert(highlights, hl)
      end
    end
    table.insert(lines, item.text)
  end
  return true, lines, highlights, outline
end

---@param buf integer the buf number
---@param lines table the lines to append
---@param highlights table the highlights to apply
local function refresh_outline(buf, lines, highlights)
  vim.bo[buf].modifiable = true
  local ok = pcall(api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  if not ok then
    return
  end
  vim.bo[buf].modifiable = false
  if highlights then
    ui.add_highlights(state.outline_buf, highlights)
  end
end

local function is_outline_open()
  local wins = fn.win_findbuf(state.outline_buf)
  return wins and #wins > 0
end

local function highlight_current_item(item)
  if not utils.buf_valid(state.outline_buf) then
    return
  end
  ui.clear_highlights(state.outline_buf, outline_ns_id)
  ui.add_highlights(state.outline_buf, {
    {
      highlight = "SelectedOutlineItem",
      line_number = item.lnum,
      column_start = item.buf_start,
      column_end = item.buf_end + 1, -- add one for padding
    },
  }, outline_ns_id)
end

local function set_current_item()
  local curbuf = api.nvim_get_current_buf()
  if
    not utils.buf_valid(state.outline_buf)
    or not is_outline_open()
    or curbuf == state.outline_buf
  then
    return
  end
  local uri = vim.uri_from_bufnr(curbuf)
  local outline = M.outlines[uri]
  if vim.tbl_isempty(outline) then
    return
  end
  local cursor = api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1
  local column = cursor[2] - 1
  local current_item
  if not lnum or not column then
    return
  end
  for _, item in ipairs(outline) do
    if
      item
      and not vim.tbl_isempty(item)
      and (lnum > item.start_line or (lnum == item.start_line and column >= item.start_col))
      and (lnum < item.end_line or (lnum == item.end_line and column < item.end_col))
    then
      current_item = item
    end
  end
  if current_item then
    local item_buf = vim.uri_to_bufnr(outline.uri)
    if item_buf ~= curbuf then
      return
    end
    highlight_current_item(current_item)
    local win = fn.bufwinid(state.outline_buf)
    -- nvim_win_set_cursor is a 1,0 based method i.e.
    -- the row should be one based and the column 0 based
    if api.nvim_win_is_valid(win) then
      api.nvim_win_set_cursor(win, { current_item.lnum + 1, current_item.buf_start })
    end
  end
end

local function setup_autocommands()
  utils.augroup("FlutterToolsOutline", {
    {
      events = { "User FlutterOutlineChanged" },
      command = function()
        if not utils.buf_valid(state.outline_buf) then
          return
        end
        local ok, lines, highlights = get_outline_content()
        if not ok then
          return
        end
        refresh_outline(state.outline_buf, lines, highlights)
      end,
    },
    {
      events = { "CursorHold" },
      targets = { "*.dart" },
      command = set_current_item,
    },
    {
      events = { "BufEnter" },
      targets = { "*.dart" },
      command = "doautocmd User FlutterOutlineChanged",
    },
  })
end

---Execute the currently selected code action in the code action popup
---@param actions table[]
---@param action_win number
---@param code_buf number
---@param code_win number
---@param outline_win number
---@return function
local function select_code_action(actions, action_win, code_buf, code_win, outline_win)
  return function()
    local ln = api.nvim_get_current_line()
    --- TODO: improve this once popup create returns a mapping of data to lines
    local action = utils.find(actions, function(ca)
      return ln:match(ca.title)
    end)
    if action then
      code_actions.execute(action, code_buf, function()
        -- HACK: figure out how to automatically refresh the code window so the new widget appears
        -- in the outline window
        api.nvim_set_current_win(code_win)
        vim.defer_fn(function()
          api.nvim_set_current_win(outline_win)
        end, 500)
      end)
    end
    if api.nvim_win_is_valid(action_win) then
      vim.api.nvim_win_close(action_win, true)
    end
  end
end

---Find the window the outline relates to
---@param uri string
---@return number, number[]
local function find_code_window(uri)
  local code_buf = vim.uri_to_bufnr(uri)
  local code_wins = fn.win_findbuf(code_buf)
  if not code_wins or #code_wins == 0 then
    return
  end
  return code_wins[1], code_wins
end

local function request_code_actions()
  local line = fn.line(".")
  local uri = vim.b.outline_uri
  if not uri then
    return utils.echomsg("Sorry! code actions not available")
  end
  local outline = M.outlines[uri]
  local item = outline[line]
  local params = code_actions.get_action_params(item, uri)
  if not params then
    return
  end

  local code_buf = vim.uri_to_bufnr(uri)
  local code_win = find_code_window(uri)
  local outline_win = api.nvim_get_current_win()

  lsp.buf_request(params.bufnr, "textDocument/codeAction", params, function(_, _, actions)
    code_actions.create_popup(actions, function(buf, win)
      utils.map(
        "n",
        "<CR>",
        select_code_action(actions, win, code_buf, code_win, outline_win),
        { buffer = buf }
      )
    end)
    vim.api.nvim_win_set_cursor(code_win, { item.start_line + 1, item.start_col + 1 })
  end)
end

local function select_outline_item()
  local line = fn.line(".")
  local uri = vim.b.outline_uri
  if not uri then
    return utils.echomsg([[Sorry! this item can't be opened]])
  end
  local outline = M.outlines[uri]
  local item = outline[line]
  if not item then
    return utils.echomsg([[Sorry! this item can't be opened]])
  end
  vim.cmd("drop " .. vim.uri_to_fname(uri))
  api.nvim_win_set_cursor(0, { item.start_line + 1, item.start_col + 1 })
end

---@param buf number
---@param win number
---@param lines table
---@param highlights table
---@param go_back boolean
local function setup_outline_window(buf, win, lines, highlights, go_back)
  state.outline_buf = buf
  state.outline_win = win
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.wo[win].winfixwidth = true

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  set_outline_highlights()

  if highlights and not vim.tbl_isempty(highlights) then
    ui.add_highlights(state.outline_buf, highlights)
  end

  utils.map("n", "q", "<Cmd>bw!<CR>", { nowait = true, buffer = buf })
  utils.map("n", "<CR>", select_outline_item, { buffer = buf, nowait = true })
  utils.map("n", "a", request_code_actions, { buffer = buf, nowait = true })

  setup_autocommands()
end

function M.close()
  if api.nvim_win_is_valid(state.outline_win) then
    api.nvim_win_close(state.outline_win, true)
  end
end

function M.toggle()
  if is_outline_open() then
    M.close()
  else
    M.open()
  end
end

---Open the outline window
---@param opts table
function M.open(opts)
  opts = opts or {}
  local ok, lines, highlights, outline = get_outline_content()
  if not ok then
    utils.echomsg([[Sorry! There is no outline for this file]])
    return
  end
  local parent_win = api.nvim_get_current_win()
  local options = config.get("outline")
  if not utils.buf_valid(state.outline_buf) and not vim.tbl_isempty(lines) then
    ui.open_split({
      open_cmd = options.open_cmd,
      filetype = outline_filetype,
      filename = outline_filename,
    }, function(buf, win)
      setup_outline_window(buf, win, lines, highlights, opts.go_back)
    end)
  else
    refresh_outline(state.outline_buf, lines, highlights)
  end
  vim.b.outline_uri = outline.uri
  if opts.go_back and api.nvim_win_is_valid(parent_win) then
    api.nvim_set_current_win(parent_win)
  end
end

function M.document_outline(_, _, data, _)
  local outline = data.outline or {}
  local result = {}
  if not outline.children or #outline.children == 0 then
    return
  end
  for _, item in ipairs(outline.children) do
    parse_outline(result, item)
  end
  result.uri = data.uri
  M.outlines[data.uri] = result
  vim.cmd("doautocmd User FlutterOutlineChanged")
  local conf = config.get("outline")
  if conf.auto_open and not state.outline_buf then
    M.open({ go_back = true })
  end
end

return M
