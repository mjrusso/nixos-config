# https://herdr.dev
#
# Docs: https://herdr.dev/docs/configuration/
#
# - View defaults:    herdr --default-config
# - Reload config:    herdr server reload-config
{
  text = ''
    onboarding = false

    [terminal]
    default_shell = "fish"
    shell_mode = "auto"
    new_cwd = "follow"

    [keys]
    prefix = "ctrl+comma"

    # --- Sessions (tmux session = herdr workspace) ---
    new_workspace = "prefix+shift+c"           # tmux: prefix C (new-session)
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
    edit_scrollback = "prefix+x"

    focus_pane_left = "prefix+left"
    focus_pane_down = "prefix+down"
    focus_pane_up = "prefix+up"
    focus_pane_right = "prefix+right"

    swap_pane_up = "prefix+shift+up"
    swap_pane_down = "prefix+shift+down"

    # --- Remote (`herdr --remote`) ---
    # Under --remote, herdr grabs the raw ctrl+v keystroke whenever the local
    # clipboard holds an image, stealing C-v (scroll-up) from Emacs and
    # block-visual from vim. Ghostty's own paste (ctrl+shift+v, cmd+v on MacOS)
    # still bridges clipboard images over SSH.
    remote_image_paste = ""

    # --- Custom commands ---
    # Popups capture all input and herdr has no dismiss key, so only bind
    # commands that can exit themselves: Emacs with `C-x C-c`, a shell with
    # `exit` or `C-d`, etc.

    [[keys.command]]
    key = "prefix+e"
    type = "popup"
    command = "fish -c e" # `e` is a fish function; popup commands run via `sh`.
    description = "emacs (current project)"
    width = "90%"
    height = "90%"

    [[keys.command]]
    key = "prefix+t"
    type = "popup"
    command = "fish"
    description = "terminal (fish shell)"
    width = "60%"
    height = "70%"

    [update]
    # herdr is managed by Nix; `herdr update` can't write to the store.
    version_check = false

    [worktrees]
    directory = "~/git/worktrees"

    [ui]
    mouse_capture = true
    pane_scrollbars = false                    # reclaim the column; keeps it out of Ghostty selections
    confirm_close = true
    prompt_new_tab_name = true
    show_agent_labels_on_pane_borders = true
    hide_tab_bar_when_single_tab = true
    tab_bar_position = "bottom"

    [theme]
    name = "terminal"

    [experimental]
    # Restore recent pane contents after a full server restart (Nix installs
    # can't do herdr's live handoff, so every version bump stops the server).
    # Writes pane output to ~/.config/herdr/session-history.json; treat that
    # directory like shell history.
    pane_history = true

    [advanced]
    scrollback_limit_bytes = 52428800
  '';
}
