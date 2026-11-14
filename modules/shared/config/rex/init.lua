-- https://www.superlogical.com/rex/docs/customize/config
--
-- The Rex server reads this file, so these bindings apply to the sessions of
-- the server on this machine.
--
-- - Check:  rex config check
-- - Reload: rex config reload

-- Rex splits the pane on cmd+enter by default; send it to the program instead.
rex.unbind("cmd+enter")

local function bind(key, action, args)
  rex.bind("ctrl+,>" .. key, action, args)
end

bind("ctrl+,", "pane.send_key", { key = "ctrl+," })

-- Sessions
bind("shift+c", "session.new")
bind("shift+w", "session.rename")
bind("shift+4", "session.rename")
bind("shift+9", "session.previous")
bind("shift+0", "session.next")
bind("g", "session.switch")
bind("s", "session.switch")

-- Tabs
bind("c", "client.tab.new")
bind("n", "client.tab.next")
bind("p", "client.tab.previous")
bind("shift+k", "client.tab.close")
bind("shift+t", "client.tab.rename")
bind(",", "client.tab.rename")
bind("shift+,", "client.tab.move", { direction = "backward" })
bind("shift+.", "client.tab.move", { direction = "forward" })
for index = 1, 9 do
  bind(tostring(index), "client.tab.goto", { index = index })
end

-- Panes
bind("shift+\\", "pane.split", { direction = "right" })
bind("shift+-", "pane.split", { direction = "right" })
bind("-", "pane.split", { direction = "down" })
bind("k", "pane.close")
bind("z", "pane.zoom")
bind("a", "pane.view_activity")
bind("shift+a", "pane.go_to")

for _, direction in ipairs({ "left", "down", "up", "right" }) do
  bind(direction, "pane.focus", { direction = direction })
  bind("shift+" .. direction, "pane.move", { direction = direction })
end

-- Popups start in the directory of the program running in the pane, which
-- for an agent pane is where the agent was launched, rather than where the
-- pane's shell last reported being.
local function program_cwd(block_id)
  local process = rex.block.call("com.superlogical.terminal", "process", { block_id = block_id })
  return process and process.foreground and process.foreground.cwd
end

local function open_popup(ctx, command, w, h)
  local layer, err = rex.session.new_layer{
    bounds = { (1 - w) / 2, (1 - h) / 2, w, h },
    focus = true,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      options = { command = command, cwd = program_cwd(ctx.block_id) },
    },
  }
  if err ~= nil then error(err, 0) end
  return layer
end

rex.action{
  name = "popup",
  title = "Open Popup",
  args = { command = "array", w = "number", h = "number" },
  run = function(ctx, args)
    return open_popup(ctx, args.command, args.w, args.h)
  end,
}

-- `rex capture` without -b would capture the popup, through its REX_BLOCK.
rex.action{
  name = "edit_scrollback",
  title = "Edit Scrollback",
  run = function(ctx)
    return open_popup(ctx, {
      "fish", "-c",
      "set f (mktemp); $REX_BIN_DIR/rex capture -b $argv[1] --unwrap --trim >$f; et $f; rm -f $f",
      ctx.block_id,
    }, 0.9, 0.9)
  end,
}

-- `e` and `et` are fish functions.
bind("e", "popup", { command = { "fish", "-c", "e" }, w = 0.9, h = 0.9 })
bind("t", "popup", { command = { "fish" }, w = 0.85, h = 0.75 })
bind("x", "edit_scrollback")
