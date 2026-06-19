# https://herdr.dev
#
# Docs: https://herdr.dev/docs/configuration/
#
# - View defaults:    herdr --default-config
# - Reload config:    herdr server reload-config
{
  text = ''
    [terminal]
    default_shell = "fish"
    shell_mode = "auto"
    new_cwd = "follow"

    [keys]
    prefix = "ctrl+comma"

    # --- Sessions (tmux session = herdr workspace) ---
    new_workspace = "prefix+shift+c"           # tmux: prefix C (new-session)
    workspace_picker = "prefix+s"              # tmux: prefix s (choose-tree -s)
    detach = "prefix+d"                        # tmux: prefix d (detach)

    # --- Windows (tmux window = herdr tab) ---
    new_tab = "prefix+c"                       # tmux: prefix c (new-window)
    next_tab = "prefix+n"                      # tmux default n
    previous_tab = "prefix+p"                  # tmux default p
    close_tab = "prefix+shift+k"               # tmux: prefix K (kill-window)

    # Note: switch_tab is prefix+1..9; tabs are 1-indexed, matching tmux base-index 1

    # --- Panes ---
    split_vertical = ["prefix+|", "prefix+_"]  # tmux: prefix | and _ (split -h, side by side)
    split_horizontal = "prefix+minus"          # tmux: prefix - (split -v, stacked)
    close_pane = "prefix+k"                    # tmux: prefix k (kill-pane)
    last_pane = "prefix+;"                     # tmux: prefix ; (last-pane -Z)
    zoom = "prefix+z"
    copy_mode = "prefix+["                     # tmux default [

    focus_pane_left = "prefix+left"
    focus_pane_down = "prefix+down"
    focus_pane_up = "prefix+up"
    focus_pane_right = "prefix+right"

    swap_pane_up = "prefix+shift+up"
    swap_pane_down = "prefix+shift+down"

    [ui]
    mouse_capture = true
    confirm_close = true
    prompt_new_tab_name = true
    show_agent_labels_on_pane_borders = true
    agent_panel_scope = "all"

    [theme]
    name = "terminal"

    [advanced]
    scrollback_limit_bytes = 52428800
  '';
}
