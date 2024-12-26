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

    # Includes a fix for broken $PATH when using Fish shell. With thanks to:
    # https://github.com/LnL7/nix-darwin/issues/122#issuecomment-1659465635
    loginShellInit =
      let
        dquote = str: "\"" + str + "\"";

        makeBinPathList = map (path: path + "/bin");
      in ''


      fish_add_path --move --prepend --path ${lib.concatMapStringsSep " " dquote (makeBinPathList (
        osConfig.environment.profiles ++

        # Ensure that Homebrew is in the PATH on Macs. (Technically we should
        # only be adding this specific directory if we're on an Apple
        # Silicon-based Mac.) Note that we set this here, instead of using
        # `home.sessionPath`, because we want Homebrew-installed software to
        # take precedence over software that ships with MacOS.
        lib.optionals pkgs.stdenv.isDarwin ["/opt/homebrew"]
      ))}

      set fish_user_paths $fish_user_paths
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
    };
  };

  tmux = {
    enable = true;
    plugins = with pkgs.tmuxPlugins; [
      sensible
      yank
      prefix-highlight
      {
        plugin = power-theme;
        extraConfig = ''
           set -g @tmux_power_theme 'gold'
        '';
      }
      {
        plugin = resurrect; # Used by tmux-continuum

        # Use XDG data directory
        # https://github.com/tmux-plugins/tmux-resurrect/issues/348
        extraConfig = ''
          set -g @resurrect-dir '$HOME/.cache/tmux/resurrect'
          set -g @resurrect-capture-pane-contents 'on'
          set -g @resurrect-pane-contents-area 'visible'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '5' # minutes
        '';
      }
    ];
    terminal = "screen-256color";
    prefix = "C-x";
    escapeTime = 10;
    historyLimit = 50000;
    extraConfig = ''
      # Remove Vim mode delays
      set -g focus-events on

      # Enable full mouse support
      set -g mouse on

      # -----------------------------------------------------------------------------
      # Key bindings
      # -----------------------------------------------------------------------------

      # Unbind default keys
      unbind C-b
      unbind '"'
      unbind %

      # Split panes, vertical or horizontal
      bind-key x split-window -v
      bind-key v split-window -h

      # Move around panes with vim-like bindings (h,j,k,l)
      bind-key -n M-k select-pane -U
      bind-key -n M-h select-pane -L
      bind-key -n M-j select-pane -D
      bind-key -n M-l select-pane -R

      # Smart pane switching with awareness of Vim splits.
      # This is copy paste from https://github.com/christoomey/vim-tmux-navigator
      is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
        | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"
      bind-key -n 'C-h' if-shell "$is_vim" 'send-keys C-h'  'select-pane -L'
      bind-key -n 'C-j' if-shell "$is_vim" 'send-keys C-j'  'select-pane -D'
      bind-key -n 'C-k' if-shell "$is_vim" 'send-keys C-k'  'select-pane -U'
      bind-key -n 'C-l' if-shell "$is_vim" 'send-keys C-l'  'select-pane -R'
      tmux_version='$(tmux -V | sed -En "s/^tmux ([0-9]+(.[0-9]+)?).*/\1/p")'
      if-shell -b '[ "$(echo "$tmux_version < 3.0" | bc)" = 1 ]' \
        "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\'  'select-pane -l'"
      if-shell -b '[ "$(echo "$tmux_version >= 3.0" | bc)" = 1 ]' \
        "bind-key -n 'C-\\' if-shell \"$is_vim\" 'send-keys C-\\\\'  'select-pane -l'"

      bind-key -T copy-mode-vi 'C-h' select-pane -L
      bind-key -T copy-mode-vi 'C-j' select-pane -D
      bind-key -T copy-mode-vi 'C-k' select-pane -U
      bind-key -T copy-mode-vi 'C-l' select-pane -R
      bind-key -T copy-mode-vi 'C-\' select-pane -l
      '';
    };
}
