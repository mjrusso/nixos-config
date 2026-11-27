local function start_preview(ctx, args, viewer)
  if not ctx.block_id then error("Start the preview from a terminal pane", 0) end
  local cwd = program_cwd(ctx.block_id)
  local path = args.path or rex.ui.input{
    title = "Directory to serve",
    value = cwd or "",
    confirm = viewer and "View" or "Serve",
  }
  if path == nil or path:match("^%s*$") then return end

  local command = { serve_preview_command }
  if args.port then
    table.insert(command, "--port")
    table.insert(command, tostring(args.port))
  end
  if viewer == "ladybird" then
    table.insert(command, "--view-from")
    table.insert(command, ctx.block_id)
  elseif viewer == "browser" then
    table.insert(command, "--open-in-client")
    table.insert(command, ctx.client_id or "")
  end
  table.insert(command, "--")
  table.insert(command, path)

  local split, err = rex.session.new_split{
    anchor_id = ctx.block_id,
    direction = "vertical",
    side = "after",
    focus = viewer ~= "ladybird",
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      label = "Serve Preview",
      options = { command = command, cwd = cwd, exit = { on_completion = false } },
    },
  }
  if err ~= nil then error(err, 0) end
  return split
end

local preview_args = { path = "string?", port = "integer?" }

rex.action{
  name = "serve_preview",
  title = "Serve Preview…",
  args = preview_args,
  run = function(ctx, args) return start_preview(ctx, args) end,
}

rex.action{
  name = "view_preview",
  title = "View Preview…",
  args = preview_args,
  run = function(ctx, args) return start_preview(ctx, args, "ladybird") end,
}

rex.action{
  name = "open_preview",
  title = "Open Preview in Default Browser…",
  args = preview_args,
  run = function(ctx, args) return start_preview(ctx, args, "browser") end,
}

bind("v", "serve_preview")
bind("shift+v", "view_preview")
