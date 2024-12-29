{ user, config, pkgs, ... }:

let
  xdg_configHome = "${config.users.users.${user}.home}/.config";
  xdg_dataHome   = "${config.users.users.${user}.home}/.local/share";
  xdg_stateHome  = "${config.users.users.${user}.home}/.local/state"; in
{

  "${xdg_configHome}/ghostty/config" = {
    text = ''
      # Presentation
      theme = dark:Raycast_Dark,light:Raycast_Light
      font-family = "Berkeley Mono"
      font-size = 16
      cursor-style = block
      mouse-hide-while-typing = true
      window-padding-balance = true
      window-colorspace = "display-p3"
      macos-non-native-fullscreen = "visible-menu"

      # Shell
      shell-integration = fish

      # Behaviour
      window-save-state = always
      confirm-close-surface = false

      # Keyboard
      macos-option-as-alt = true

      # Keybindings (Emacs)
      keybind = ctrl+0=text:\u001b[27;5;48~
      keybind = ctrl+shift+0=text:\u001b[27;6;41~
      keybind = alt+shift+0=text:\u001b[27;4;41~
      keybind = ctrl+1=text:\u001b[27;5;49~
      keybind = ctrl+shift+1=text:\u001b[27;6;33~
      keybind = alt+shift+1=text:\u001b[27;4;33~
      keybind = ctrl+2=text:\u001b[27;5;50~
      keybind = ctrl+shift+2=text:\u001b[27;6;64~
      keybind = alt+shift+2=text:\u001b[27;4;64~
      keybind = ctrl+3=text:\u001b[27;5;51~
      keybind = ctrl+shift+3=text:\u001b[27;6;35~
      keybind = alt+shift+3=text:\u001b[27;4;35~
      keybind = ctrl+4=text:\u001b[27;5;52~
      keybind = ctrl+shift+4=text:\u001b[27;6;36~
      keybind = alt+shift+4=text:\u001b[27;4;36~
      keybind = ctrl+5=text:\u001b[27;5;53~
      keybind = ctrl+shift+5=text:\u001b[27;6;37~
      keybind = alt+shift+5=text:\u001b[27;4;37~
      keybind = ctrl+6=text:\u001b[27;5;54~
      keybind = ctrl+shift+6=text:\u001b[27;6;94~
      keybind = alt+shift+6=text:\u001b[27;4;94~
      keybind = ctrl+7=text:\u001b[27;5;55~
      keybind = ctrl+shift+7=text:\u001b[27;6;38~
      keybind = alt+shift+7=text:\u001b[27;4;38~
      keybind = ctrl+8=text:\u001b[27;5;56~
      keybind = ctrl+shift+8=text:\u001b[27;6;42~
      keybind = alt+shift+8=text:\u001b[27;4;42~
      keybind = ctrl+9=text:\u001b[27;5;57~
      keybind = ctrl+shift+9=text:\u001b[27;6;40~
      keybind = alt+shift+9=text:\u001b[27;4;40~
      keybind = ctrl+enter=text:\u001b[27;5;13~
      keybind = ctrl+shift+enter=text:\u001b[27;6;13~
      keybind = alt+shift+enter=text:\u001b[27;4;13~
      keybind = ctrl+'=text:\u001b[27;5;39~
      keybind = ctrl+shift+'=text:\u001b[27;6;34~
      keybind = alt+shift+'=text:\u001b[27;4;34~
      keybind = ctrl+equal=text:\u001b[27;5;61~
      keybind = ctrl+shift+equal=text:\u001b[27;6;43~
      keybind = alt+shift+equal=text:\u001b[27;4;43~
      keybind = ctrl+comma=text:\u001b[27;5;44~
      keybind = ctrl+shift+comma=text:\u001b[27;5;60~
      keybind = alt+shift+comma=text:\u001b[27;4;60~
      keybind = ctrl+minus=text:\u001b[27;5;45~
      keybind = ctrl+shift+minus=text:\u001b[27;6;95~
      keybind = alt+shift+minus=text:\u001b[27;4;95~
      keybind = ctrl+period=text:\u001b[27;5;46~
      keybind = ctrl+shift+period=text:\u001b[27;6;62~
      keybind = alt+shift+period=text:\u001b[27;4;62~
      keybind = ctrl+slash=text:\u001b[27;5;47~
      keybind = ctrl+shift+slash=text:\u001b[27;5;63~
      keybind = alt+shift+slash=text:\u001b[27;4;63~
      keybind = ctrl+semicolon=text:\u001b[27;5;59~
      keybind = ctrl+shift+semicolon=text:\u001b[27;6;58~
      keybind = alt+shift+semicolon=text:\u001b[27;4;58~
    '';
  };

}
