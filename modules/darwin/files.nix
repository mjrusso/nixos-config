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
      window-width = 110
      window-height = 50
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
      # NOTE: Disabled in favor of using KKP, via kkp.el.
      #   - See: https://github.com/benjaminor/kkp
      #   - Re: Zellij, see: https://github.com/zellij-org/zellij/issues/3789#issuecomment-2567278067
      # keybind = ctrl+0=text:\u001b[27;5;48~
      # keybind = ctrl+shift+0=text:\u001b[27;6;41~
      # keybind = alt+shift+0=text:\u001b[27;4;41~
      # keybind = ctrl+1=text:\u001b[27;5;49~
      # keybind = ctrl+shift+1=text:\u001b[27;6;33~
      # keybind = alt+shift+1=text:\u001b[27;4;33~
      # keybind = ctrl+2=text:\u001b[27;5;50~
      # keybind = ctrl+shift+2=text:\u001b[27;6;64~
      # keybind = alt+shift+2=text:\u001b[27;4;64~
      # keybind = ctrl+3=text:\u001b[27;5;51~
      # keybind = ctrl+shift+3=text:\u001b[27;6;35~
      # keybind = alt+shift+3=text:\u001b[27;4;35~
      # keybind = ctrl+4=text:\u001b[27;5;52~
      # keybind = ctrl+shift+4=text:\u001b[27;6;36~
      # keybind = alt+shift+4=text:\u001b[27;4;36~
      # keybind = ctrl+5=text:\u001b[27;5;53~
      # keybind = ctrl+shift+5=text:\u001b[27;6;37~
      # keybind = alt+shift+5=text:\u001b[27;4;37~
      # keybind = ctrl+6=text:\u001b[27;5;54~
      # keybind = ctrl+shift+6=text:\u001b[27;6;94~
      # keybind = alt+shift+6=text:\u001b[27;4;94~
      # keybind = ctrl+7=text:\u001b[27;5;55~
      # keybind = ctrl+shift+7=text:\u001b[27;6;38~
      # keybind = alt+shift+7=text:\u001b[27;4;38~
      # keybind = ctrl+8=text:\u001b[27;5;56~
      # keybind = ctrl+shift+8=text:\u001b[27;6;42~
      # keybind = alt+shift+8=text:\u001b[27;4;42~
      # keybind = ctrl+9=text:\u001b[27;5;57~
      # keybind = ctrl+shift+9=text:\u001b[27;6;40~
      # keybind = alt+shift+9=text:\u001b[27;4;40~
      # keybind = ctrl+enter=text:\u001b[27;5;13~
      # keybind = ctrl+shift+enter=text:\u001b[27;6;13~
      # keybind = alt+shift+enter=text:\u001b[27;4;13~
      # keybind = ctrl+'=text:\u001b[27;5;39~
      # keybind = ctrl+shift+'=text:\u001b[27;6;34~
      # keybind = alt+shift+'=text:\u001b[27;4;34~
      # keybind = ctrl+equal=text:\u001b[27;5;61~
      # keybind = ctrl+shift+equal=text:\u001b[27;6;43~
      # keybind = alt+shift+equal=text:\u001b[27;4;43~
      # # keybind = ctrl+comma=text:\u001b[27;5;44~
      # keybind = ctrl+shift+comma=text:\u001b[27;5;60~
      # # keybind = alt+shift+comma=text:\u001b[27;4;60~
      # keybind = ctrl+minus=text:\u001b[27;5;45~
      # keybind = ctrl+shift+minus=text:\u001b[27;6;95~
      # keybind = alt+shift+minus=text:\u001b[27;4;95~
      # keybind = ctrl+period=text:\u001b[27;5;46~
      # keybind = ctrl+shift+period=text:\u001b[27;6;62~
      # # keybind = alt+shift+period=text:\u001b[27;4;62~
      # keybind = ctrl+slash=text:\u001b[27;5;47~
      # keybind = ctrl+shift+slash=text:\u001b[27;5;63~
      # keybind = alt+shift+slash=text:\u001b[27;4;63~
      # keybind = ctrl+semicolon=text:\u001b[27;5;59~
      # keybind = ctrl+shift+semicolon=text:\u001b[27;6;58~
      # keybind = alt+shift+semicolon=text:\u001b[27;4;58~
    '';
  };

  "${xdg_configHome}/zellij/config.kdl" = {
    text = ''

      // Re: issues with Emacs, see: https://github.com/zellij-org/zellij/issues/3789
      support_kitty_keyboard_protocol true

      plugins {
          compact-bar location="zellij:compact-bar"
          configuration location="zellij:configuration"
          filepicker location="zellij:strider" {
              cwd "/"
          }
          plugin-manager location="zellij:plugin-manager"
          session-manager location="zellij:session-manager"
          status-bar location="zellij:status-bar"
          strider location="zellij:strider"
          tab-bar location="zellij:tab-bar"
          welcome-screen location="zellij:session-manager" {
              welcome_screen true
          }
      }

      simplified_ui false
      theme "tokyo-night-storm"
      default_mode "locked"
      pane_frames false

      // Provide a command to execute when copying text. The text will be piped to
      // the stdin of the program to perform the copy. This can be used with
      // terminal emulators which do not support the OSC 52 ANSI control sequence
      // that will be used by default if this option is not set.
      // Examples:
      //
      // copy_command "xclip -selection clipboard" // x11
      // copy_command "wl-copy"                    // wayland
      // copy_command "pbcopy"                     // osx
      //
      // copy_command "pbcopy"

      // Choose the destination for copied text
      // Allows using the primary selection buffer (on x11/wayland) instead of the system clipboard.
      // Does not apply when using copy_command.
      // Options:
      //   - system (default)
      //   - primary
      //
      // copy_clipboard "primary"

      // Enable automatic copying (and clearing) of selection when releasing mouse
      // Default: true
      //
      // copy_on_select true

      // A fixed name to always give the Zellij session.
      // Consider also setting `attach_to_session true,`
      // otherwise this will error if such a session exists.
      // Default: <RANDOM>
      //
      // session_name "My singleton session"

      // When `session_name` is provided, attaches to that session
      // if it is already running or creates it otherwise.
      // Default: false
      //
      // attach_to_session true

      keybinds clear-defaults=true {
          locked {
              bind "Ctrl ," { SwitchToMode "normal"; }
          }
          pane {
              bind "left" { MoveFocus "left"; }
              bind "down" { MoveFocus "down"; }
              bind "up" { MoveFocus "up"; }
              bind "right" { MoveFocus "right"; }
              bind "c" { SwitchToMode "renamepane"; PaneNameInput 0; }
              bind "d" { NewPane "down"; SwitchToMode "locked"; }
              bind "e" { TogglePaneEmbedOrFloating; SwitchToMode "locked"; }
              bind "f" { ToggleFocusFullscreen; SwitchToMode "locked"; }
              bind "h" { MoveFocus "left"; }
              bind "j" { MoveFocus "down"; }
              bind "k" { MoveFocus "up"; }
              bind "l" { MoveFocus "right"; }
              bind "n" { NewPane; SwitchToMode "locked"; }
              bind "p" { SwitchToMode "normal"; }
              bind "r" { NewPane "right"; SwitchToMode "locked"; }
              bind "w" { ToggleFloatingPanes; SwitchToMode "locked"; }
              bind "x" { CloseFocus; SwitchToMode "locked"; }
              bind "z" { TogglePaneFrames; SwitchToMode "locked"; }
              bind "tab" { SwitchFocus; }
          }
          tab {
              bind "left" { GoToPreviousTab; }
              bind "down" { GoToNextTab; }
              bind "up" { GoToPreviousTab; }
              bind "right" { GoToNextTab; }
              bind "1" { GoToTab 1; SwitchToMode "locked"; }
              bind "2" { GoToTab 2; SwitchToMode "locked"; }
              bind "3" { GoToTab 3; SwitchToMode "locked"; }
              bind "4" { GoToTab 4; SwitchToMode "locked"; }
              bind "5" { GoToTab 5; SwitchToMode "locked"; }
              bind "6" { GoToTab 6; SwitchToMode "locked"; }
              bind "7" { GoToTab 7; SwitchToMode "locked"; }
              bind "8" { GoToTab 8; SwitchToMode "locked"; }
              bind "9" { GoToTab 9; SwitchToMode "locked"; }
              bind "[" { BreakPaneLeft; SwitchToMode "locked"; }
              bind "]" { BreakPaneRight; SwitchToMode "locked"; }
              bind "b" { BreakPane; SwitchToMode "locked"; }
              bind "h" { GoToPreviousTab; }
              bind "j" { GoToNextTab; }
              bind "k" { GoToPreviousTab; }
              bind "l" { GoToNextTab; }
              bind "n" { NewTab; SwitchToMode "locked"; }
              bind "r" { SwitchToMode "renametab"; TabNameInput 0; }
              bind "s" { ToggleActiveSyncTab; SwitchToMode "locked"; }
              bind "t" { SwitchToMode "normal"; }
              bind "x" { CloseTab; SwitchToMode "locked"; }
              bind "tab" { ToggleTab; }
          }
          resize {
              bind "left" { Resize "Increase left"; }
              bind "down" { Resize "Increase down"; }
              bind "up" { Resize "Increase up"; }
              bind "right" { Resize "Increase right"; }
              bind "+" { Resize "Increase"; }
              bind "-" { Resize "Decrease"; }
              bind "=" { Resize "Increase"; }
              bind "H" { Resize "Decrease left"; }
              bind "J" { Resize "Decrease down"; }
              bind "K" { Resize "Decrease up"; }
              bind "L" { Resize "Decrease right"; }
              bind "h" { Resize "Increase left"; }
              bind "j" { Resize "Increase down"; }
              bind "k" { Resize "Increase up"; }
              bind "l" { Resize "Increase right"; }
              bind "r" { SwitchToMode "normal"; }
          }
          move {
              bind "left" { MovePane "left"; }
              bind "down" { MovePane "down"; }
              bind "up" { MovePane "up"; }
              bind "right" { MovePane "right"; }
              bind "h" { MovePane "left"; }
              bind "j" { MovePane "down"; }
              bind "k" { MovePane "up"; }
              bind "l" { MovePane "right"; }
              bind "m" { SwitchToMode "normal"; }
              bind "n" { MovePane; }
              bind "p" { MovePaneBackwards; }
              bind "tab" { MovePane; }
          }
          scroll {
              bind "Alt left" { MoveFocusOrTab "left"; SwitchToMode "locked"; }
              bind "Alt down" { MoveFocus "down"; SwitchToMode "locked"; }
              bind "Alt up" { MoveFocus "up"; SwitchToMode "locked"; }
              bind "Alt right" { MoveFocusOrTab "right"; SwitchToMode "locked"; }
              bind "e" { EditScrollback; SwitchToMode "locked"; }
              bind "f" { SwitchToMode "entersearch"; SearchInput 0; }
              bind "Alt h" { MoveFocusOrTab "left"; SwitchToMode "locked"; }
              bind "Alt j" { MoveFocus "down"; SwitchToMode "locked"; }
              bind "Alt k" { MoveFocus "up"; SwitchToMode "locked"; }
              bind "Alt l" { MoveFocusOrTab "right"; SwitchToMode "locked"; }
              bind "s" { SwitchToMode "normal"; }
          }
          search {
              bind "c" { SearchToggleOption "CaseSensitivity"; }
              bind "n" { Search "down"; }
              bind "o" { SearchToggleOption "WholeWord"; }
              bind "p" { Search "up"; }
              bind "w" { SearchToggleOption "Wrap"; }
          }
          session {
              bind "c" {
                  LaunchOrFocusPlugin "configuration" {
                      floating true
                      move_to_focused_tab true
                  }
                  SwitchToMode "locked"
              }
              bind "d" { Detach; }
              bind "o" { SwitchToMode "normal"; }
              bind "p" {
                  LaunchOrFocusPlugin "plugin-manager" {
                      floating true
                      move_to_focused_tab true
                  }
                  SwitchToMode "locked"
              }
              bind "w" {
                  LaunchOrFocusPlugin "session-manager" {
                      floating true
                      move_to_focused_tab true
                  }
                  SwitchToMode "locked"
              }
          }
          shared_among "normal" "locked" {
          //     bind "Alt left" { MoveFocusOrTab "left"; }
          //     bind "Alt down" { MoveFocus "down"; }
          //     bind "Alt up" { MoveFocus "up"; }
          //     bind "Alt right" { MoveFocusOrTab "right"; }
          //     bind "Alt +" { Resize "Increase"; }
          //     bind "Alt -" { Resize "Decrease"; }
          //     bind "Alt =" { Resize "Increase"; }
          //     bind "Alt [" { PreviousSwapLayout; }
          //     bind "Alt ]" { NextSwapLayout; }
          //     bind "Alt f" { ToggleFloatingPanes; }
          //     bind "Alt h" { MoveFocusOrTab "left"; }
          //     bind "Alt i" { MoveTab "left"; }
          //     bind "Alt j" { MoveFocus "down"; }
          //     bind "Alt k" { MoveFocus "up"; }
          //     bind "Alt l" { MoveFocusOrTab "right"; }
          //     bind "Alt n" { NewPane; }
          //     bind "Alt o" { MoveTab "right"; }
          }
          shared_except "locked" "renametab" "renamepane" {
              bind "Ctrl ," { SwitchToMode "locked"; }
              bind "Ctrl q" { Quit; }
          }
          shared_except "locked" "entersearch" {
              bind "enter" { SwitchToMode "locked"; }
          }
          shared_except "locked" "entersearch" "renametab" "renamepane" {
              bind "esc" { SwitchToMode "locked"; }
          }
          shared_except "locked" "entersearch" "renametab" "renamepane" "move" {
              bind "m" { SwitchToMode "move"; }
          }
          shared_except "locked" "entersearch" "search" "renametab" "renamepane" "session" {
              bind "o" { SwitchToMode "session"; }
          }
          shared_except "locked" "tab" "entersearch" "renametab" "renamepane" {
              bind "t" { SwitchToMode "tab"; }
          }
          shared_except "locked" "tab" "scroll" "entersearch" "renametab" "renamepane" {
              bind "s" { SwitchToMode "scroll"; }
          }
          shared_among "normal" "resize" "tab" "scroll" "prompt" "tmux" {
              bind "p" { SwitchToMode "pane"; }
          }
          shared_except "locked" "resize" "pane" "tab" "entersearch" "renametab" "renamepane" {
              bind "r" { SwitchToMode "resize"; }
          }
          shared_among "scroll" "search" {
              bind "PageDown" { PageScrollDown; }
              bind "PageUp" { PageScrollUp; }
              bind "left" { PageScrollUp; }
              bind "down" { ScrollDown; }
              bind "up" { ScrollUp; }
              bind "right" { PageScrollDown; }
              bind "Ctrl b" { PageScrollUp; }
              bind "Ctrl c" { ScrollToBottom; SwitchToMode "locked"; }
              bind "d" { HalfPageScrollDown; }
              bind "Ctrl f" { PageScrollDown; }
              bind "h" { PageScrollUp; }
              bind "j" { ScrollDown; }
              bind "k" { ScrollUp; }
              bind "l" { PageScrollDown; }
              bind "u" { HalfPageScrollUp; }
          }
          entersearch {
              bind "Ctrl c" { SwitchToMode "scroll"; }
              bind "esc" { SwitchToMode "scroll"; }
              bind "enter" { SwitchToMode "search"; }
          }
          renametab {
              bind "esc" { UndoRenameTab; SwitchToMode "tab"; }
          }
          shared_among "renametab" "renamepane" {
              bind "Ctrl c" { SwitchToMode "locked"; }
          }
          renamepane {
              bind "esc" { UndoRenamePane; SwitchToMode "pane"; }
          }
      }
    '';
  };


}
