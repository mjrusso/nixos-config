{
  text = ''
    // Enable KKP (Kitty Keyboard Protocol).
    // For additional context on Zellij's KKP support, see:
    // https://github.com/zellij-org/zellij/issues/3789
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
}
