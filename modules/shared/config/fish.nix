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
    # If we're on Apple Silicon and Homebrew is installed, ensure that Homebrew
    # is in the PATH. We insert `/opt/homebrew/bin` after Nix-managed paths but
    # before the system paths; this way, binaries that ship with MacOS don't
    # take priority over Homebrew (and Nix always has priority).
    if test -d /opt/homebrew/bin
        # Remove /opt/homebrew/bin if present to avoid duplicates and to ensure
        # that our index calculation is stable.
        set -l p (string match -v /opt/homebrew/bin $PATH)

        # Look for where the system paths begin in the cleaned list.
        set -l idx (contains -i /usr/local/bin $p)
        if test -z "$idx"
           set idx (contains -i /usr/bin $p)
        end

        # Splice /opt/homebrew/bin in before the anchor.
        if test -n "$idx"
            if test $idx -eq 1
                # If anchor is at the beginning, put /opt/homebrew/bin first.
                set -gx PATH /opt/homebrew/bin $p
            else
                # Anchor is not first: [Start...Before] + [Homebrew] + [Anchor...End]
                set -gx PATH $p[1..(math $idx - 1)] /opt/homebrew/bin $p[$idx..-1]
            end
        else
            # Fallback: append (no system paths found).
            set -gx PATH $p /opt/homebrew/bin
        end
    end

    # Store private environment variables (which aren't committed to this
    # repository) in ~/.localrc.fish.
    if test -f ~/.localrc.fish
        source ~/.localrc.fish
    end
  '';

  interactiveShellInit = ''
    # Enable Ghostty shell integration. (Because we're using nix-shell, this
    # needs to be sourced manually.)
    # https://ghostty.org/docs/features/shell-integration
    if test -n "$GHOSTTY_RESOURCES_DIR" && test -z "$INSIDE_EMACS"
        source "$GHOSTTY_RESOURCES_DIR/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
    end

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

  shellAliases = {
    g = "git";
    "..." = "cd ../..";
    "...." = "cd ../../..";
  };

  functions = {
    # Quick shortcut to open Emacs in the terminal.
    #
    # If called without arguments, automatically opens the project associated
    # with the current directory. If called with arguments, these arguments are
    # passed through unmodified.
    #
    # As per the `ec` shell script (custom `emacsclient` wrapper), this will
    # connect to an existing Emacs server process (if running), or start a new
    # one. (At any point, the server process can be stopped by running the
    # command `M-x kill-emacs`.)
    e = ''
      if test (count $argv) -eq 0
        ec -nw -e "(my/maybe-open-project \"$PWD\")"
      else
        ec -nw $argv
      end
    '';

    # Quick shortcut to open Emacs in the terminal. Like `e`, connects to
    # an existing Emacs server process (if running), otherwise starts a new
    # one. Unlike `e`, this command does not attempt to switch to a project.
    et = "ec -nw $argv";

    # Quick shortcut to open Emacs in a new GUI frame. Like `e`, connects to
    # an existing Emacs server process (if running), otherwise starts a new
    # one.
    eg = "ec --no-wait --create-frame $argv";

    # Quick shortcut to open Emacs in the terminal, specifically to today's
    # daily "scratch file" (for making quick notes). Like `e`, connects to an
    # existing Emacs server process (if running), otherwise starts a new one.
    enote = ''
      ec -nw -e "(progn (my/maybe-open-project my/persistent-scratch-files-dir) (my/daily-scratch-file))"
    '';

    # Quick shortcut to open Emacs in the terminal, specifically viewing my
    # "dashboard" org file. Like `e`, connects to an existing Emacs server
    # process (if running), otherwise starts a new one.
    edash = ''
      ec -nw -e "(progn (my/maybe-open-project my/primary-org-directory) (my/workspace:dashboard))"
    '';

    # Launch tmux, first checking if there are any existing sessions. If
    # there are existing sessions, opens an interactive session selection
    # tree; otherwise, starts a new tmux session.
    t = ''
      if test (tmux list-sessions | count) -gt 0
        tmux attach\; choose-tree -Zw;
      else
        tmux
      end
    '';

    # tat: tmux attach
    #
    # With thanks to: https://juliu.is/a-simple-tmux/
    tat = ''
      set name (basename (pwd) | sed -e 's/\.//g')

      if tmux ls 2>&1 | grep "$name" >/dev/null
        tmux attach -t "$name"
      else if test -f .envrc
        direnv exec / tmux new-session -s "$name"
      else
        tmux new-session -s "$name"
      end
    '';

    # md2pdf: render a markdown file to PDF via pandoc + typst.
    #
    # Usage: md2pdf <input.md> [output.pdf]
    #
    # If the output path is omitted, it's derived from the input (foo.md →
    # foo.pdf). Explicit fonts are passed because pandoc's typst template
    # errors out with "font fallback list must not be empty" when the font
    # variables are unset.
    md2pdf = ''
      if test (count $argv) -lt 1
          echo "usage: md2pdf <input.md> [output.pdf]"
          return 1
      end
      set -l input $argv[1]
      set -l output
      if test (count $argv) -ge 2
          set output $argv[2]
      else
          set output (string replace -r '\.(md|markdown)$' '.pdf' $input)
          if test "$output" = "$input"
              set output "$input.pdf"
          end
      end
      pandoc $input -o $output --pdf-engine=typst \
          -V mainfont="DejaVu Sans" -V monofont="JetBrains Mono" \
          -V fontsize=10pt
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

      # Add a newline to separate previous command output from this prompt.
      echo

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
          if string match -q "lima-*" (hostname)
              set_color green --bold
          else
              set_color blue --bold
          end
          echo -n ssh→
          set_color normal
      end

      set_color blue --bold
      echo -n @(prompt_hostname)

      set_color normal
      echo -n " "
      echo -n (prompt_pwd)
      echo -n (fish_git_prompt)
      echo

      if test $_display_status -eq 0
          set_color green --bold
          echo -n '$'
      else
          set_color red --bold
          echo -n [$_display_status]
          echo -n ">"
      end

      set_color normal
      echo -n " "
    '';
  };
}
