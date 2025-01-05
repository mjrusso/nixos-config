{ pkgs, lib, ... }:

{
  enable = true;

  plugins =
    if pkgs.stdenv.isLinux
    then
      [
        # Set up the Nix environment for a non-NixOS Fish shell. See:
        # https://github.com/lilyball/nix-env.fish and
        # https://www.reddit.com/r/Nix/comments/zyqv7z/fish_shell_not_setting_nix_paths/
        # for more context.
        {
          name = "nix-env";
          src = pkgs.fetchFromGitHub {
            owner = "lilyball";
            repo = "nix-env.fish";
            rev = "7b65bd228429e852c8fdfa07601159130a818cfa";
            sha256 = "sha256-RG/0rfhgq6aEKNZ0XwIqOaZ6K5S4+/Y5EEMnIdtfPhk=";
          };
        }
      ]
    else
      [];

  shellInit = ''
    set -g fish_color_autosuggestion gray --dim
  '';

  shellInitLast = ''
    # Store private environment variables (which aren't committed to this
    # repository) in ~/.localrc.fish.
    if test -f ~/.localrc.fish
        source ~/.localrc.fish
    end
  '';

  interactiveShellInit = ''
    # Shell-side configuration for vterm.
    # https://github.com/akermu/emacs-libvterm#shell-side-configuration
    # https://github.com/akermu/emacs-libvterm#shell-side-configuration-files
    if [ "$INSIDE_EMACS" = 'vterm' ]
       set -gx PAGER "less -R"
       if test -n "$EMACS_VTERM_PATH"
           if test -f "$EMACS_VTERM_PATH/etc/emacs-vterm.fish"
              source "$EMACS_VTERM_PATH/etc/emacs-vterm.fish"
           end
       end

       # https://github.com/akermu/emacs-libvterm#vterm-clear-scrollback
       function clear
           vterm_printf "51;Evterm-clear-scrollback";
           tput clear;
       end
    end
  '';

  functions = {
    # Quick shortcut to open Emacs in the terminal.
    #
    # As per the `ec` shell script (custom `emacsclient` wrapper), this will
    # connect to an existing Emacs server process (if running), or start a new
    # one. (At any point, the server process can be stopped by running the
    # command `M-x kill-emacs`.)
    e = "ec -nw $argv";

    # Same as `e`.
    et = "e $argv";

    # Quick shortcut to open Emacs in a new GUI frame. Like `e`, connects to
    # an existing Emacs server process (if running), otherwise starts a new
    # one.
    eg = "ec --no-wait --create-frame $argv";

    z = "zellij $argv";

    # zat: zellij attach
    #
    # Adapted from this tmux version: https://juliu.is/a-simple-tmux/
    zat = ''
        set name (basename (pwd))

        if zellij list-sessions 2>&1 | grep "$name" >/dev/null
            zellij attach "$name"
        else if test -f .envrc
            direnv exec / zellij --session "$name"
        else
            zellij --session "$name"
        end
    '';

    # https://fishshell.com/docs/current/cmds/fish_git_prompt.html
    # https://mariuszs.github.io/blog/2013/informative_git_prompt.html
    fish_prompt = ''
      # The exit status of the most-recently-run command. This must be the
      # first line, because because any function or command called from within
      # this prompt function will reset the value. <https://superuser.com/a/893187>
      set -l _display_status $status

      # Disable fancy formatting when using Tramp:
      # https://www.gnu.org/software/tramp/#index-FAQ
      if test $TERM = "dumb"
          echo "\$ "
          return
      end

      set -g __fish_git_prompt_show_informative_status 1
      set -g __fish_git_prompt_hide_untrackedfiles 1

      set -g __fish_git_prompt_color_branch magenta
      set -g __fish_git_prompt_showupstream "informative"
      set -g __fish_git_prompt_char_upstream_ahead "↑"
      set -g __fish_git_prompt_char_upstream_behind "↓"
      set -g __fish_git_prompt_char_upstream_prefix ""

      set -g __fish_git_prompt_char_stagedstate "●"
      set -g __fish_git_prompt_char_dirtystate "✚"
      set -g __fish_git_prompt_char_untrackedfiles "…"
      set -g __fish_git_prompt_char_conflictedstate "✖"
      set -g __fish_git_prompt_char_cleanstate "✔"

      set -g __fish_git_prompt_color_dirtystate blue
      set -g __fish_git_prompt_color_stagedstate yellow
      set -g __fish_git_prompt_color_invalidstate red
      set -g __fish_git_prompt_color_untrackedfiles $fish_color_normal
      set -g __fish_git_prompt_color_cleanstate green

      if test -n "$SSH_CLIENT"
          set_color purple
          echo -n @(prompt_hostname)# ""
      else
          set_color blue
          echo -n @(prompt_hostname) ""
      end

      set_color normal
      echo -n (prompt_pwd)
      echo -n (fish_git_prompt)

      if test $_display_status -eq 0
          set_color green
          echo -n ' $'
      else
          set_color red
          echo -n " "
          echo -n [$_display_status]
          echo -n " >"
      end

      set_color normal
      echo -n " "
    '';
  };
}
