local vim = vim
local installer = require 'codex.installer'
local state = require 'codex.state'

local M = {}

local config = {
  keymaps = {
    toggle = nil,
    quit = '<C-q>', -- Default: Ctrl+q to quit
    send_selection = nil,
  },
  border = 'single',
  width = 0.8,
  height = 0.8,
  cmd = 'codex',
  model = nil, -- Default to the latest model
  sandbox = nil, -- Optional default sandbox mode for Codex CLI
  approval = nil, -- Optional default approval policy for Codex CLI
  autoinstall = true,
  panel     = false,   -- if true, open Codex in a side-panel instead of floating window
  use_buffer = false,  -- if true, capture Codex stdout into a normal buffer instead of a terminal
}

local valid_sandbox_modes = {
  ['read-only'] = true,
  ['workspace-write'] = true,
  ['danger-full-access'] = true,
}

local valid_approval_policies = {
  untrusted = true,
  ['on-failure'] = true,
  ['on-request'] = true,
  never = true,
}

local function launch_option_completion()
  return {
    'read-only',
    'workspace-write',
    'danger-full-access',
    'untrusted',
    'on-failure',
    'on-request',
    'never',
  }
end

local function parse_command_opts(args)
  local launch_opts = {}

  if not args or args == '' then
    return launch_opts
  end

  for token in string.gmatch(args, '%S+') do
    if valid_sandbox_modes[token] then
      if launch_opts.sandbox and launch_opts.sandbox ~= token then
        vim.notify('[codex.nvim] Multiple sandbox modes provided', vim.log.levels.ERROR)
        return nil
      end
      launch_opts.sandbox = token
    elseif valid_approval_policies[token] then
      if launch_opts.approval and launch_opts.approval ~= token then
        vim.notify('[codex.nvim] Multiple approval policies provided', vim.log.levels.ERROR)
        return nil
      end
      launch_opts.approval = token
    else
      vim.notify('[codex.nvim] Invalid launch option: ' .. tostring(token), vim.log.levels.ERROR)
      return nil
    end
  end

  return launch_opts
end

local function resolve_launch_opts(opts)
  local launch_opts = opts or {}
  local sandbox = launch_opts.sandbox
  local approval = launch_opts.approval
  local prompt = launch_opts.prompt

  if sandbox == nil then
    sandbox = config.sandbox
  end

  if approval == nil then
    approval = config.approval
  end

  if sandbox ~= nil and not valid_sandbox_modes[sandbox] then
    vim.notify(
      '[codex.nvim] Invalid sandbox mode: ' .. tostring(sandbox),
      vim.log.levels.ERROR
    )
    return nil
  end

  if approval ~= nil and not valid_approval_policies[approval] then
    vim.notify(
      '[codex.nvim] Invalid approval policy: ' .. tostring(approval),
      vim.log.levels.ERROR
    )
    return nil
  end

  return {
    sandbox = sandbox,
    approval = approval,
    prompt = prompt,
  }
end

local function build_cmd_args(launch_opts)
  local cmd_args = type(config.cmd) == 'string' and { config.cmd } or vim.deepcopy(config.cmd)

  if config.model then
    table.insert(cmd_args, '-m')
    table.insert(cmd_args, config.model)
  end

  if launch_opts.sandbox then
    table.insert(cmd_args, '--sandbox')
    table.insert(cmd_args, launch_opts.sandbox)
  end

  if launch_opts.approval then
    table.insert(cmd_args, '--ask-for-approval')
    table.insert(cmd_args, launch_opts.approval)
  end

  if launch_opts.prompt and launch_opts.prompt ~= '' then
    table.insert(cmd_args, launch_opts.prompt)
  end

  return cmd_args
end

local function get_visual_selection()
  local start_pos = vim.fn.getpos "'<"
  local end_pos = vim.fn.getpos "'>"
  local start_row = start_pos[2]
  local start_col = start_pos[3]
  local end_row = end_pos[2]
  local end_col = end_pos[3]

  if start_row == 0 or end_row == 0 then
    return nil
  end

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)

  if vim.tbl_isempty(lines) then
    return nil
  end

  lines[1] = string.sub(lines[1], start_col, #lines[1])
  lines[#lines] = string.sub(lines[#lines], 1, end_col)

  return table.concat(lines, '\n')
end

local function is_job_active(job)
  return type(job) == 'number' and job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1
end

local function reset_session()
  if state.job then
    vim.fn.jobstop(state.job)
    state.job = nil
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
end

function M.setup(user_config)
  config = vim.tbl_deep_extend('force', config, user_config or {})

  vim.api.nvim_create_user_command('Codex', function(opts)
    local launch_opts = parse_command_opts(opts.args)
    if not launch_opts then
      return
    end
    M.toggle(launch_opts)
  end, {
    desc = 'Toggle Codex popup',
    nargs = '*',
    complete = launch_option_completion,
  })

  vim.api.nvim_create_user_command('CodexToggle', function(opts)
    local launch_opts = parse_command_opts(opts.args)
    if not launch_opts then
      return
    end
    M.toggle(launch_opts)
  end, {
    desc = 'Toggle Codex popup (alias)',
    nargs = '*',
    complete = launch_option_completion,
  })

  vim.api.nvim_create_user_command('CodexSendSelection', function()
    M.send_selection()
  end, {
    desc = 'Send the current visual selection to Codex',
    range = true,
  })

  if config.keymaps.toggle then
    vim.api.nvim_set_keymap('n', config.keymaps.toggle, '<cmd>CodexToggle<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.send_selection then
    vim.keymap.set('x', config.keymaps.send_selection, function()
      M.send_selection()
    end, { noremap = true, silent = true, desc = 'Send selection to Codex' })
  end
end

local function open_window()
  local width = math.floor(vim.o.columns * config.width)
  local height = math.floor(vim.o.lines * config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local styles = {
    single = {
      { '┌', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '┐', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '┘', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '└', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    double = {
      { '╔', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╗', 'FloatBorder' },
      { '║', 'FloatBorder' },
      { '╝', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╚', 'FloatBorder' },
      { '║', 'FloatBorder' },
    },
    rounded = {
      { '╭', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╮', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '╯', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╰', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    none = nil,
  }

  local border = type(config.border) == 'string' and styles[config.border] or config.border

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = border,
  })
end

--- Open Codex in a side-panel (vertical split) instead of floating window
local function open_panel()
  -- Create a vertical split on the right and show the buffer
  vim.cmd('vertical rightbelow vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  -- Adjust width according to config (percentage of total columns)
  local width = math.floor(vim.o.columns * config.width)
  vim.api.nvim_win_set_width(win, width)
  state.win = win
end

function M.open(opts)
  local launch_opts = resolve_launch_opts(opts)

  if not launch_opts then
    return
  end

  if launch_opts.prompt then
    reset_session()
  end

  local function create_clean_buf()
    local buf = vim.api.nvim_create_buf(false, false)

    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'codex')

    -- Apply configured quit keybinding

    if config.keymaps.quit then
      local quit_cmd = [[<cmd>lua require('codex').close()<CR>]]
      vim.api.nvim_buf_set_keymap(buf, 't', config.keymaps.quit, [[<C-\><C-n>]] .. quit_cmd, { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.quit, quit_cmd, { noremap = true, silent = true })
    end

    return buf
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  local check_cmd = type(config.cmd) == 'string' and not config.cmd:find '%s' and config.cmd or (type(config.cmd) == 'table' and config.cmd[1]) or nil

  if check_cmd and vim.fn.executable(check_cmd) == 0 then
    if config.autoinstall then
      installer.prompt_autoinstall(function(success)
        if success then
          M.open(launch_opts) -- Try again after installing
        else
          -- Show failure message *after* buffer is created
          if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
            state.buf = create_clean_buf()
          end
          vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
            'Autoinstall cancelled or failed.',
            '',
            'You can install manually with:',
            '  npm install -g @openai/codex',
          })
          if config.panel then open_panel() else open_window() end
        end
      end)
      return
    else
      -- Show fallback message
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        state.buf = vim.api.nvim_create_buf(false, false)
      end
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
        'Codex CLI not found, autoinstall disabled.',
        '',
        'Install with:',
        '  npm install -g @openai/codex',
        '',
        'Or enable autoinstall in setup: require("codex").setup{ autoinstall = true }',
      })
      if config.panel then open_panel() else open_window() end
      return
    end
  end

  local function is_buf_reusable(buf)
    return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
  end

  if not is_buf_reusable(state.buf) then
    state.buf = create_clean_buf()
  end

  if config.panel then open_panel() else open_window() end

  if not state.job then
    local cmd_args = build_cmd_args(launch_opts)

    if config.use_buffer then
      -- capture stdout/stderr into normal buffer
      state.job = vim.fn.jobstart(cmd_args, {
        cwd = vim.loop.cwd(),
        stdout_buffered = true,
        on_stdout = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { line })
            end
          end
        end,
        on_stderr = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { '[ERR] ' .. line })
            end
          end
        end,
        on_exit = function(_, code)
          state.job = nil
          vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, {
            ('[Codex exit: %d]'):format(code),
          })
        end,
      })
    else
      -- use a terminal buffer
      state.job = vim.fn.termopen(cmd_args, {
        cwd = vim.loop.cwd(),
        on_exit = function()
          state.job = nil
        end,
      })
    end
  end
end

function M.send_selection(opts)
  local selection = get_visual_selection()

  if not selection or selection == '' then
    vim.notify('[codex.nvim] No visual selection available to send', vim.log.levels.WARN)
    return
  end

  if is_job_active(state.job) and not config.use_buffer then
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
    else
      if config.panel then
        open_panel()
      else
        open_window()
      end
    end

    vim.fn.chansend(state.job, selection .. '\n')
    return
  end

  local launch_opts = vim.tbl_extend('force', opts or {}, {
    prompt = selection,
  })

  M.open(launch_opts)
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle(opts)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open(opts)
  end
end

function M.statusline()
  if state.job and not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return '[Codex]'
  end
  return ''
end

function M.status()
  return {
    function()
      return M.statusline()
    end,
    cond = function()
      return M.statusline() ~= ''
    end,
    icon = '',
    color = { fg = '#51afef' },
  }
end

return setmetatable(M, {
  __call = function(_, opts)
    M.setup(opts)
    return M
  end,
})
