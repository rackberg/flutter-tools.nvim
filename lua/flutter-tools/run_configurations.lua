local Job = require("plenary.job")
local ui = require("flutter-tools.ui")
local utils = require("flutter-tools.utils")
local executable = require("flutter-tools.executable")

local api = vim.api
local fn = vim.fn

local M = {
  ---@type Job
  run_configuration_job = nil,
}

---@param result string[]
local function get_run_configs(result)
  local run_configs = {}
  for _, line in pairs(result) do
    local run_config = M.parse(line)
    if run_config then
      table.insert(run_configs, run_config)
    end
  end
  return run_configs
end

---Highlight each run configuration in the popup window
---@param highlights table
---@param line string
---@param run configurations table<string, string>
local function add_run_config_highlights(highlights, line, run_config)
  return ui.get_line_highlights(line, {
    {
      word = run_config.name,
      highlight = "Type",
    },
    {
      word = run_configuration.args,
      highlight = "Comment",
    },
  }, highlights)
end

---@param line string
function M.parse(line)
  local parts = vim.split(line, "•")
  if #parts == 2 then
    return {
      name = vim.trim(parts[1]),
      args = vim.trim(parts[2]),
    }
  end
end

local function select_run_config()
  if not vim.b.run_configs then
    return utils.echomsg("Sorry there is no run configuration on this line")
  end
  local lnum = fn.line(".")
  local line = api.nvim_buf_get_lines(0, lnum - 1, lnum, false)
  local run_config = vim.b.run_configs[fn.trim(line[1])]
  if run_config then
    require("flutter-tools.commands").run({ run_config = run_config })
  end
  api.nvim_win_close(0, true)
end

---Run commands and setup options after a popup is opened
---@param run configurations table[]
---@param buf number
local function setup_window(run_configs, buf)
  if not vim.tbl_isempty(run_configs) then
    api.nvim_buf_set_var(buf, "run_configs", run_configs)
  end
  utils.map("n", "<CR>", select_run_config, { buffer = buf })
end

---@param job Job
local function show_run_configs(job)
  local result = job:result()
  local lines, run_configs, highlights = M.extract_run_config_props(result)
  if #lines > 0 then
    ui.popup_create({
      title = "Flutter Run Configurations",
      lines = lines,
      highlights = highlights,
      on_create = function(buf, _)
        setup_window(run_configs, buf)
      end,
    })
  end
end

return M
