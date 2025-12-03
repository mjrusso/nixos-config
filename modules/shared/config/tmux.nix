{ pkgs, lib, ... }:

{
  enable = true;
  plugins = with pkgs.tmuxPlugins; [
    yank
    prefix-highlight
    # {
    # 	plugin = dracula;
    # 	extraConfig = ''
    # 		set -g @dracula-show-battery false
    # 		set -g @dracula-show-powerline true
    # 		set -g @dracula-refresh-rate 10
    #     set -g @dracula-plugins "time"
    # 	'';
    # }
    # {
    #   plugin = power-theme;
    #   extraConfig = ''
    #      set -g @tmux_power_theme 'default'
    #   '';
    # }
    # {
    #   plugin = resurrect; # Used by tmux-continuum
    #
    #   # Use XDG data directory
    #   # https://github.com/tmux-plugins/tmux-resurrect/issues/348
    #   extraConfig = ''
    #     set -g @resurrect-dir '$HOME/.cache/tmux/resurrect'
    #     set -g @resurrect-capture-pane-contents 'on'
    #     set -g @resurrect-pane-contents-area 'visible'
    #   '';
    # }
    # {
    #   plugin = continuum;
    #   extraConfig = ''
    #     # set -g @continuum-restore 'on'
    #     set -g @continuum-save-interval '5' # minutes
    #   '';
    # }
  ];

  terminal = "xterm-ghostty";
  shell = "${pkgs.fish}/bin/fish";
  prefix = "C-,";

  # Count from 1, not 0.
  baseIndex = 1;

  # Automatically spawn a session if trying to attach and none are running.
  newSession = true;

  mouse = true;
  focusEvents = true;
  escapeTime = 0;
  historyLimit = 50000;

  extraConfig = ''

  # M-[ and M-] disable/enable the prefix, to allow for tmux inception.
  #
  # Currently commented out to free M-[ and M-] for emacs.
  #
  # bind -n M-[ set -g prefix None \; set -g status-bg color22 \;
  # bind -n M-] set -g prefix C-, \; set -g status-bg default \;

  # Windows and panes.
  bind c new-window      -c "#{pane_current_path}" \; select-layout -E
  bind | split-window -h -c "#{pane_current_path}" \; select-layout -E
  bind - split-window -v -c "#{pane_current_path}" \; select-layout -E
  bind _ split-window -h -c "#{pane_current_path}" \; select-layout -E
  bind \; last-pane -Z
  bind k kill-pane
  bind K kill-window
  set -g display-panes-time 2500

  bind M-x command-prompt

  # Need to send keys C-k and C-l so Emacs receives them.
  bind -n C-k clear-history\; send-keys C-k
  bind -n C-l send-keys C-l

  # Copy mode bindings.
  bind -T copy-mode M-w send-keys -X copy-pipe
  bind -T copy-mode C-w send-keys -X copy-pipe-and-cancel

  # Like the regular `s`, but sorts by name (rather than session index).
  bind s choose-tree -Z -s -O name
  # Like the regular `w`, but sorts by name (rather than session index).
  bind w choose-tree -Z -w -O name
  # Like the regular `s`, but sorts by recency.
  bind S choose-tree -Z -s -O time
  # Like the regular `w`, but sorts by recency.
  bind W choose-tree -Z -w -O time

  set -as extended-keys on
  set -as extended-keys-format csi-u

  set -ag terminal-features "*:hyperlinks"

  # https://ryantravitz.com/blog/2023-02-18-pull-of-the-undercurl/
  #
  # undercurls can be tested with:
  #
  #  printf '\e[4:3m\e[58:2:206:134:51mUnderlined\n\e[0m'
  #
  set -as terminal-overrides ',alacritty*:RGB' # true-color support
  set -as terminal-overrides ',*:Smulx=\E[4::%p1%dm'  # undercurl support

  set -a terminal-features ",*:sixel"

  set-option -g set-titles on
  set-option -wg automatic-rename on
  set-option -g renumber-windows on

  # Bind Prefix-< to open a window management menu.
  bind-key -T prefix < display-menu -T "#[align=centre]#{window_index}:#{window_name}" -x W -y W "Move Before" b { command-prompt -T window-target "move-window -b -t %%" } "Move After" a { command-prompt -T window-target "move-window -a -t %%" } "#{?#{>:#{session_windows},1},,-}Swap Left" l { swap-window -d -t :-1 } "#{?#{>:#{session_windows},1},,-}Swap Right" r { swap-window -d -t :+1 } "#{?pane_marked_set,,-}Swap Marked" s { swap-window } ${"''"} Kill X { kill-window } Respawn R { respawn-window -k } "#{?pane_marked,Unmark,Mark}" m { select-pane -m } Rename n { command-prompt -F -I "#W" { rename-window -t "#{window_id}" "%%" } } ${"''"} "New After" w { new-window -a } "New At End" W { new-window }

  # Bind Prefix-> to open a pane management menu.
  bind-key -T prefix > display-menu -T "#[align=centre]#{pane_index} (#{pane_id})" -x P -y P "#{?#{m/r:(copy|view)-mode,#{pane_mode}},Go To Top,}" < { send-keys -X history-top } "#{?#{m/r:(copy|view)-mode,#{pane_mode}},Go To Bottom,}" > { send-keys -X history-bottom } ${"''"} "#{?mouse_word,Search For #[underscore]#{=/9/...:mouse_word},}" C-r { if-shell -F "#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}" "copy-mode -t=" ; send-keys -X -t = search-backward "#{q:mouse_word}" } "#{?mouse_word,Type #[underscore]#{=/9/...:mouse_word},}" C-y { copy-mode -q ; send-keys -l "#{q:mouse_word}" } "#{?mouse_word,Copy #[underscore]#{=/9/...:mouse_word},}" c { copy-mode -q ; set-buffer "#{q:mouse_word}" } "#{?mouse_line,Copy Line,}" l { copy-mode -q ; set-buffer "#{q:mouse_line}" } ${"''"} "Horizontal Split" h { split-window -h } "Vertical Split" v { split-window -v } ${"''"} "#{?#{>:#{window_panes},1},,-}Swap Up" u { swap-pane -U } "#{?#{>:#{window_panes},1},,-}Swap Down" d { swap-pane -D } "#{?pane_marked_set,,-}Swap Marked" s { swap-pane } ${"''"} Kill X { kill-pane } Respawn R { respawn-pane -k } "#{?pane_marked,Unmark,Mark}" m { select-pane -m } "#{?#{>:#{window_panes},1},,-}#{?window_zoomed_flag,Unzoom,Zoom}" z { resize-pane -Z }

  # Should be on instead of external for tmux inception to work. Default is
  # external. TODO: Also check if OSC 52 requires the option to be on rather than
  # external.
  set -s set-clipboard on

  set -g status-position bottom
  set -g status-style 'fg=default,bg=default'
  set -g status-left-length 50
  set -g status-left "#{?client_prefix,#[fg=red]  ●  #[default],  ○  } #{p8:[#{session_name}]} "
  set -g status-right-length 100

  # Active/inactive pane colours
  set -g window-style 'fg=default,bg=default'
  set -g window-active-style 'fg=default,bg=default'
  set -g pane-border-indicators off
  set -g pane-border-status top
  set -g pane-border-lines single
  set -g pane-border-format "#{pane_index} #{pane_current_command}"

  # TODO: Broken by tmux 3.5. Need to manually set up CSI u / KKP bindings (they
  # are no longer passed through, instead they are swallowed).
  bind -n C-0 send-keys -l "\u001B[27;5;48~"
  bind -n C-1 send-keys -l "\u001B[27;5;49~"
  bind -n C-2 send-keys -l "\u001B[27;5;50~"
  bind -n C-3 send-keys -l "\u001B[27;5;51~"
  bind -n C-4 send-keys -l "\u001B[27;5;52~"
  bind -n C-5 send-keys -l "\u001B[27;5;53~"
  bind -n C-6 send-keys -l "\u001B[27;5;54~"
  bind -n C-7 send-keys -l "\u001B[27;5;55~"
  bind -n C-8 send-keys -l "\u001B[27;5;56~"
  bind -n C-9 send-keys -l "\u001B[27;5;57~"
  bind -n C-\; send-keys -l "\u001B[27;5;59~"
  bind -n C-\' send-keys -l "\u001B[27;5;39~"
  bind -n C-\- send-keys -l "\u001B[27;5;45~"
  bind -n C-\= send-keys -l "\u001B[27;5;61~"
  bind -n C-\. send-keys -l "\u001B[27;5;46~"
  bind -n C-\| send-keys -l "\u001B[27;5;124~"
  bind -n C-\{ send-keys -l "\u001B[27;5;123~"
  bind -n C-\} send-keys -l "\u001B[27;5;125~"
  bind -n M-S-Enter send-keys -l "\u001B[27;4;13~"
'';

}
