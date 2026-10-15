{
  output ? null,
}:

let
  monitorDefaults =
    if output == null then
      ''hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })''
    else
      ''hl.monitor({ output = ${builtins.toJSON output}, mode = "3840x2160@60", position = "0x0", scale = 1.5 })'';
in
{
  inherit monitorDefaults;
  text = ''
    local output = ${if output == null then "nil" else builtins.toJSON output}
    ${monitorDefaults}
    local config_home = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
    local monitors = package.searchpath("monitors", config_home .. "/hypr/?.lua")
    if monitors then
      require(monitors)
    end
    hl.config({
      input = { kb_layout = "us", kb_options = "ctrl:nocaps" },
      general = { layout = "dwindle" },
      misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = -1,
      },
    })
    hl.animation({ leaf = "global", enabled = true, speed = 2, bezier = "default" })
    hl.layer_rule({
      name = "noctalia",
      match = { namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$" },
      no_anim = true,
    })
    hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("uwsm app -- ghostty"))
    hl.bind("SUPER + SHIFT + F", hl.dsp.exec_cmd("uwsm app -- nautilus --new-window"))
    hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("noctalia msg panel-toggle launcher"))
    hl.bind("ALT + TAB", hl.dsp.exec_cmd("noctalia msg window-switcher hold"))
    hl.bind("SUPER + S", hl.dsp.exec_cmd("noctalia msg panel-toggle control-center"))
    hl.bind("SUPER + comma", hl.dsp.exec_cmd("noctalia msg settings-toggle"))
    hl.bind("SUPER + CTRL + V", hl.dsp.exec_cmd("noctalia msg panel-toggle clipboard"))
    hl.bind("PRINT", hl.dsp.exec_cmd("noctalia msg screenshot-region"))
    hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("noctalia msg volume-up"))
    hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("noctalia msg volume-down"))
    hl.bind("XF86AudioMute", hl.dsp.exec_cmd("noctalia msg volume-mute"))
    if not output then
      hl.bind("SUPER + L", hl.dsp.exec_cmd("noctalia msg session lock"))
    end
    hl.window_rule({ match = { class = "dev.noctalia.Noctalia" }, float = true })
    hl.bind("SUPER + Q", hl.dsp.window.close())
    hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
    hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
    hl.bind("SUPER + left", hl.dsp.focus({ direction = "left" }))
    hl.bind("SUPER + right", hl.dsp.focus({ direction = "right" }))
    hl.bind("SUPER + up", hl.dsp.focus({ direction = "up" }))
    hl.bind("SUPER + down", hl.dsp.focus({ direction = "down" }))
    hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
    for workspace = 1, 9 do
      hl.workspace_rule({
        workspace = workspace,
        monitor = output,
        persistent = true,
        default = output and workspace == 1,
      })
      hl.bind("SUPER + " .. workspace, hl.dsp.focus({ workspace = workspace }))
      hl.bind("SUPER + SHIFT + " .. workspace, hl.dsp.window.move({ workspace = workspace }))
    end
  '';
}
