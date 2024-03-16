{ config, pkgs, lib, ... }:

let name = "%NAME%";
    user = "%USER%";
    email = "%EMAIL%"; in
{
  # Shared shell configuration

  # https://github.com/nix-community/nix-direnv
  direnv = {
    enable = true;
    enableFishIntegration = true;
    nix-direnv.enable = true;
  };

  fish = {
    enable = true;

    interactiveShellInit = ''
      # Store private environment variables (which aren't committed to this
      # repository) in ~/.localrc.fish.
      if test -f ~/.localrc.fish
          source ~/.localrc.fish
      end

      set -x EDITOR (which emacsclient)

      # https://fishshell.com/docs/current/cmds/fish_git_prompt.html
      # https://mariuszs.github.io/blog/2013/informative_git_prompt.html
      function fish_prompt
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

          # The exit status of the most recently-run command.
          # See: https://superuser.com/a/893187
          set -l _display_status $status

          set_color blue
          echo -n @(prompt_hostname) ""

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
      end

      # Shell-side configuration for vterm.
      # https://github.com/akermu/emacs-libvterm#shell-side-configuration
      # https://github.com/akermu/emacs-libvterm#shell-side-configuration-files
      if [ "$INSIDE_EMACS" = 'vterm' ]
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

         # Force direnv to load the .envrc file (if one exists). This automatically
         # happens when changing directories from within vterm, but not when opening
         # a new vterm instance. (Unclear why this is the case.)
         if test -f ".envrc"
             direnv reload
         end
      end
    ''

  };

  zsh = {
    enable = true;
    autocd = false;
    plugins = [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
      {
        name = "powerlevel10k-config";
        src = lib.cleanSource ./config;
        file = "p10k.zsh";
      }
    ];

    initExtraFirst = ''
      if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
      fi

      # Define variables for directories
      export PATH=$HOME/.pnpm-packages/bin:$HOME/.pnpm-packages:$PATH
      export PATH=$HOME/.npm-packages/bin:$HOME/bin:$PATH
      export PATH=$HOME/.local/share/bin:$PATH

      # Remove history data we don't want to see
      export HISTIGNORE="pwd:ls:cd"

      # Emacs is my editor
      export ALTERNATE_EDITOR=""
      export EDITOR="emacsclient -t"
      export VISUAL="emacsclient -c -a emacs"

      e() {
          emacsclient -t "$@"
      }

      # nix shortcuts
      shell() {
          nix-shell '<nixpkgs>' -A "$1"
      }

      # Use difftastic, syntax-aware diffing
      alias diff=difft

      # Always color ls and group directories
      alias ls='ls --color=auto'
    '';
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
       "*~"
       "*.swp"
       "*~.nib"
       "*.pbxuser"
       "*.perspective"
       "*.perspectivev3"
       "*.mode1v3"
       "*.tm_build_errors"
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
      wip   = "!git add -u && git commit -m "WIP"";
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
	    editor = "vim";
        autocrlf = "input";
      };
      pull.rebase = true;
      rebase.autoStash = true;
    };
  };

  vim = {
    enable = true;
    plugins = with pkgs.vimPlugins; [ vim-airline vim-airline-themes vim-startify vim-tmux-navigator ];
    settings = { ignorecase = true; };
    extraConfig = ''
      "" General
      set number
      set history=1000
      set nocompatible
      set modelines=0
      set encoding=utf-8
      set scrolloff=3
      set showmode
      set showcmd
      set hidden
      set wildmenu
      set wildmode=list:longest
      set cursorline
      set ttyfast
      set nowrap
      set ruler
      set backspace=indent,eol,start
      set laststatus=2
      set clipboard=autoselect

      " Dir stuff
      set nobackup
      set nowritebackup
      set noswapfile
      set backupdir=~/.config/vim/backups
      set directory=~/.config/vim/swap

      " Relative line numbers for easy movement
      set relativenumber
      set rnu

      "" Whitespace rules
      set tabstop=8
      set shiftwidth=2
      set softtabstop=2
      set expandtab

      "" Searching
      set incsearch
      set gdefault

      "" Statusbar
      set nocompatible " Disable vi-compatibility
      set laststatus=2 " Always show the statusline
      let g:airline_theme='bubblegum'
      let g:airline_powerline_fonts = 1

      "" Local keys and such
      let mapleader=","
      let maplocalleader=" "

      "" Change cursor on mode
      :autocmd InsertEnter * set cul
      :autocmd InsertLeave * set nocul

      "" File-type highlighting and configuration
      syntax on
      filetype on
      filetype plugin on
      filetype indent on

      "" Paste from clipboard
      nnoremap <Leader>, "+gP

      "" Copy from clipboard
      xnoremap <Leader>. "+y

      "" Move cursor by display lines when wrapping
      nnoremap j gj
      nnoremap k gk

      "" Map leader-q to quit out of window
      nnoremap <leader>q :q<cr>

      "" Move around split
      nnoremap <C-h> <C-w>h
      nnoremap <C-j> <C-w>j
      nnoremap <C-k> <C-w>k
      nnoremap <C-l> <C-w>l

      "" Easier to yank entire line
      nnoremap Y y$

      "" Move buffers
      nnoremap <tab> :bnext<cr>
      nnoremap <S-tab> :bprev<cr>

      "" Like a boss, sudo AFTER opening the file to write
      cmap w!! w !sudo tee % >/dev/null

      let g:startify_lists = [
        \ { 'type': 'dir',       'header': ['   Current Directory '. getcwd()] },
        \ { 'type': 'sessions',  'header': ['   Sessions']       },
        \ { 'type': 'bookmarks', 'header': ['   Bookmarks']      }
        \ ]

      let g:startify_bookmarks = [
        \ '~/.local/share/src',
        \ ]

      let g:airline_theme='bubblegum'
      let g:airline_powerline_fonts = 1
      '';
     };

  alacritty = {
    enable = true;
    settings = {
      cursor = {
        style = "Block";
      };

      window = {
        opacity = 1.0;
        padding = {
          x = 24;
          y = 24;
        };
      };

      font = {
        normal = {
          family = "MesloLGS NF";
          style = "Regular";
        };
        size = lib.mkMerge [
          (lib.mkIf pkgs.stdenv.hostPlatform.isLinux 10)
          (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin 14)
        ];
      };

      dynamic_padding = true;
      decorations = "full";
      title = "Terminal";
      class = {
        instance = "Alacritty";
        general = "Alacritty";
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

  ssh = {
    enable = true;

    extraConfig = lib.mkMerge [
      ''
        Host github.com
          Hostname github.com
          IdentitiesOnly yes
      ''
      (lib.mkIf pkgs.stdenv.hostPlatform.isLinux
        ''
          IdentityFile /home/${user}/.ssh/id_github
        '')
      (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin
        ''
          IdentityFile /Users/${user}/.ssh/id_github
        '')
    ];
  };

  tmux = {
    enable = true;
    plugins = with pkgs.tmuxPlugins; [
      vim-tmux-navigator
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
