{ config, osConfig, pkgs, lib, ... }:

let name = "Michael Russo";
    user = "mjrusso";
    email = "mjr@mjrusso.com"; in
{
  # Shared shell configuration

  # https://github.com/nix-community/nix-direnv
  direnv = {
    enable = true;
    nix-direnv.enable = true;
    stdlib = ''
      # Write cache files to `~/.cache/direnv/layouts/`, instead of creating a
      # `.direnv/` directory directly inside each direnv-enabled directory. See:
      # https://github.com/direnv/direnv/wiki/Customizing-cache-location
      : "''${XDG_CACHE_HOME:="''${HOME}/.cache"}"
      declare -A direnv_layout_dirs
      direnv_layout_dir() {
          local hash path
          echo "''${direnv_layout_dirs[$PWD]:=$(
              hash="$(sha1sum - <<< "$PWD" | head -c40)"
              path="''${PWD//[^a-zA-Z0-9]/-}"
              echo "''${XDG_CACHE_HOME}/direnv/layouts/''${hash}''${path}"
          )}"
      }
    '';
  };

  fish = {
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
      # Connects to an existing Emacs server process (if running), otherwise
      # starts a new one. (In the latter case, use `M-x kill-emacs` to stop the
      # server process.)
      #
      # Note: exits with an error if the user is using vterm[0] from within Emacs,
      # and attempts to run this script.
      #
      # [0]: https://github.com/akermu/emacs-libvterm
      e = ''
        if test "$INSIDE_EMACS" = "vterm"
            echo "Refusing to launch Emacs from inside Emacs: Emacsception denied"
            return 1
        end
        emacsclient -nw -a "" $argv
      '';

      # Same as `e` (quick shortcut to open Emacs in the terminal).
      et = ''
        e $argv
      '';

      # Quick shortcut to open Emacs in a new GUI frame. Like `e`, connects to
      # an existing Emacs server process (if running), otherwise starts a new
      # one.
      eg = ''
        emacsclient --no-wait --create-frame -a "" $argv
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
  };

  git = {
    enable = true;
    ignores = [
      "*.swp"
       "__private/"
       ".DS_Store"
       ".svn"
       ".projectile"
       ".dir-locals.el"
       ".envrc"
       ".direnv/"
       ".nrepl-port"
       "*~"
       "*~.nib"
       "*.pbxuser"
       "*.perspective"
       "*.perspectivev3"
       "*.mode1v3"
       ".aider*"
    ];
    userName = name;
    userEmail = email;
    lfs = {
      enable = true;
    };
    aliases = {
      d   = "diff";
      dc  = "diff --cached";
      f   = "fetch";
      fo  = "fetch origin";
      co  = "checkout";
      com = "checkout main";
      pom = "pull origin main";
      cod = "checkout develop";
      pod = "pull origin develop";
      st  = "status -sb";
      su  = "submodule update";
      g   = "grep --break --heading --line-number";
      up  = "!git pull --rebase --prune $@ && git submodule update --init --recursive";
      save  = "!git add -A && git commit -m 'SAVEPOINT'";
      wip   = "!git add -u && git commit -m 'WIP'";
      undo  = "reset HEAD~1 --mixed";
      amend = "commit -a --amend";
      shortsha = "rev-parse --short HEAD";
      lg  = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative";
      lgp = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative -p";
      wc = "whatchanged --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative";
      refs = "for-each-ref --sort='authordate:iso8601' --format=' %(color:green)%(authordate:relative)%09%(color:white)%(refname:short)' refs/heads";
      count = "!git shortlog -sn";
    };
    extraConfig = {
      init.defaultBranch = "main";
      core = {
        editor = "emacs";
        autocrlf = "input";
      };
      push = {
        default = "current";
      };
      color = {
        ui = "auto";
        diff = "auto";
        status = "auto";
        branch = "auto";
      };
      pull.rebase = true;
      rebase.autoStash = true;
    };
  };

}
