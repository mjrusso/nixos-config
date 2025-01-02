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

  alacritty = {
    enable = true;
    settings = {

      shell = {
        program = "/run/current-system/sw/bin/fish";
      };

      window = {
        opacity = 1.0;
        option_as_alt = "Both";
        padding = {
          x = 5;
          y = 5;
        };
      };

      font = {
        # Run the following to improve font rendering on MacOS:
        #
        #   defaults write org.alacritty AppleFontSmoothing -int 0
        #
        normal = {
          family = "Berkeley Mono";
        };
        size = lib.mkMerge [
          (lib.mkIf pkgs.stdenv.hostPlatform.isLinux 10)
          (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin 14)
        ];
        offset = {
          x = 2;
          y = 2;
        };
      };

      cursor = {
        style = {
          shape = "Block";
          blinking = "on";
        };
      };

      colors = {
        primary = {
          background = "0x1f2528";
          foreground = "0xc0c5ce";
        };

        normal = {
          black = "0x1f2528";
          red = "0xec5f67";
          green = "0x99c794";
          yellow = "0xfac863";
          blue = "0x6699cc";
          magenta = "0xc594c5";
          cyan = "0x5fb3b3";
          white = "0xc0c5ce";
        };

        bright = {
          black = "0x65737e";
          red = "0xec5f67";
          green = "0x99c794";
          yellow = "0xfac863";
          blue = "0x6699cc";
          magenta = "0xc594c5";
          cyan = "0x5fb3b3";
          white = "0xd8dee9";
        };
      };

      keyboard = {
        bindings = [

          # Modifier Codes:
          #
          #  Shift      1
          #  Alt (Meta) 2
          #  Ctrl       4
          #

          { key = "Key0"; mods = "Control"; chars = "\\u001b[27;5;48~"; }
          { key = "Key0"; mods = "Control|Shift"; chars = "\\u001b[27;6;41~"; }
          { key = "Key0"; mods = "Alt|Shift"; chars = "\\u001b[27;4;41~"; }

          { key = "Key1"; mods = "Control"; chars = "\\u001b[27;5;49~"; }
          { key = "Key1"; mods = "Control|Shift"; chars = "\\u001b[27;6;33~"; }
          { key = "Key1"; mods = "Alt|Shift"; chars = "\\u001b[27;4;33~"; }

          { key = "Key2"; mods = "Control"; chars = "\\u001b[27;5;50~"; }
          { key = "Key2"; mods = "Control|Shift"; chars = "\\u001b[27;6;64~"; }
          { key = "Key2"; mods = "Alt|Shift"; chars = "\\u001b[27;4;64~"; }

          { key = "Key3"; mods = "Control"; chars = "\\u001b[27;5;51~"; }
          { key = "Key3"; mods = "Control|Shift"; chars = "\\u001b[27;6;35~"; }
          { key = "Key3"; mods = "Alt|Shift"; chars = "\\u001b[27;4;35~"; }

          { key = "Key4"; mods = "Control"; chars = "\\u001b[27;5;52~"; }
          { key = "Key4"; mods = "Control|Shift"; chars = "\\u001b[27;6;36~"; }
          { key = "Key4"; mods = "Alt|Shift"; chars = "\\u001b[27;4;36~"; }

          { key = "Key5"; mods = "Control"; chars = "\\u001b[27;5;53~"; }
          { key = "Key5"; mods = "Control|Shift"; chars = "\\u001b[27;6;37~"; }
          { key = "Key5"; mods = "Alt|Shift"; chars = "\\u001b[27;4;37~"; }

          { key = "Key6"; mods = "Control"; chars = "\\u001b[27;5;54~"; }
          { key = "Key6"; mods = "Control|Shift"; chars = "\\u001b[27;6;94~"; }
          { key = "Key6"; mods = "Alt|Shift"; chars = "\\u001b[27;4;94~"; }

          { key = "Key7"; mods = "Control"; chars = "\\u001b[27;5;55~"; }
          { key = "Key7"; mods = "Control|Shift"; chars = "\\u001b[27;6;38~"; }
          { key = "Key7"; mods = "Alt|Shift"; chars = "\\u001b[27;4;38~"; }

          { key = "Key8"; mods = "Control"; chars = "\\u001b[27;5;56~"; }
          { key = "Key8"; mods = "Control|Shift"; chars = "\\u001b[27;6;42~"; }
          { key = "Key8"; mods = "Alt|Shift"; chars = "\\u001b[27;4;42~"; }

          { key = "Key9"; mods = "Control"; chars = "\\u001b[27;5;57~"; }
          { key = "Key9"; mods = "Control|Shift"; chars = "\\u001b[27;6;40~"; }
          { key = "Key9"; mods = "Alt|Shift"; chars = "\\u001b[27;4;40~"; }

          { key = "Return"; mods = "Control"; chars = "\\u001b[27;5;13~"; }
          { key = "Return"; mods = "Control|Shift"; chars = "\\u001b[27;6;13~"; }
          { key = "Return"; mods = "Alt|Shift"; chars = "\\u001b[27;4;13~"; }

          { key = "'"; mods = "Control"; chars = "\\u001b[27;5;39~"; }
          { key = "'"; mods = "Control|Shift"; chars = "\\u001b[27;6;34~"; }
          { key = "'"; mods = "Alt|Shift"; chars = "\\u001b[27;4;34~"; }

          { key = "Equals"; mods = "Control"; chars = "\\u001b[27;5;61~"; }
          { key = "Equals"; mods = "Control|Shift"; chars = "\\u001b[27;6;43~"; }
          { key = "Equals"; mods = "Alt|Shift"; chars = "\\u001b[27;4;43~"; }

          { key = "Comma"; mods = "Control"; chars = "\\u001b[27;5;44~"; }
          { key = "Comma"; mods = "Control|Shift"; chars = "\\u001b[27;5;60~"; }
          { key = "Comma"; mods = "Alt|Shift"; chars = "\\u001b[27;4;60~"; }

          { key = "Minus"; mods = "Control"; chars = "\\u001b[27;5;45~"; }
          { key = "Minus"; mods = "Control|Shift"; chars = "\\u001b[27;6;95~"; }
          { key = "Minus"; mods = "Alt|Shift"; chars = "\\u001b[27;4;95~"; }

          { key = "Period"; mods = "Control"; chars = "\\u001b[27;5;46~"; }
          { key = "Period"; mods = "Control|Shift"; chars = "\\u001b[27;6;62~"; }
          { key = "Period"; mods = "Alt|Shift"; chars = "\\u001b[27;4;62~"; }

          { key = "Slash"; mods = "Control"; chars = "\\u001b[27;5;47~"; }
          { key = "Slash"; mods = "Control|Shift"; chars = "\\u001b[27;5;63~"; }
          { key = "Slash"; mods = "Alt|Shift"; chars = "\\u001b[27;4;63~"; }

          { key = "Semicolon"; mods = "Control"; chars = "\\u001b[27;5;59~"; }
          { key = "Semicolon"; mods = "Control|Shift"; chars = "\\u001b[27;6;58~"; }
          { key = "Semicolon"; mods = "Alt|Shift"; chars = "\\u001b[27;4;58~"; }
        ];
      };
    };
  };

}
