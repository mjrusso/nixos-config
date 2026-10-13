{
  output ? null,
}:

{
  text = ''
    local output = ${if output == null then "nil" else builtins.toJSON output}
    if output then
      hl.monitor({ output = output, mode = "1920x1080@60", position = "0x0", scale = 1 })
    else
      hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
    end
    hl.config({
      input = { kb_layout = "us", kb_options = "ctrl:nocaps" },
      general = { layout = "dwindle" },
      misc = { disable_hyprland_logo = true, force_default_wallpaper = -1 },
    })
    hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("uwsm app -- ghostty"))
    hl.bind("SUPER + Q", hl.dsp.window.close())
    hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
    hl.bind("SUPER + left", hl.dsp.focus({ direction = "left" }))
    hl.bind("SUPER + right", hl.dsp.focus({ direction = "right" }))
    hl.bind("SUPER + up", hl.dsp.focus({ direction = "up" }))
    hl.bind("SUPER + down", hl.dsp.focus({ direction = "down" }))
    hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
    for workspace = 1, 9 do
      if output then
        hl.workspace_rule({ workspace = workspace, monitor = output, default = workspace == 1 })
      end
      hl.bind("SUPER + " .. workspace, hl.dsp.focus({ workspace = workspace }))
      hl.bind("SUPER + SHIFT + " .. workspace, hl.dsp.window.move({ workspace = workspace }))
    end
  '';
}
