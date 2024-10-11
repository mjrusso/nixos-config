{ pkgs }:

with pkgs; [
  # General packages for development and system management
  alacritty
  bash-completion
  bat
  btop
  curl
  coreutils
  docker
  docker-compose
  fish
  killall
  # kitty  # Disabled until https://github.com/NixOS/nixpkgs/issues/337987 is resolved
  neofetch
  nixfmt-classic
  sqlite
  wget
  zip

  # Language servers
  pyright

  # Programming languages
  elixir_1_17
  nodejs_22
  python3
  rustc
  cargo
  ruby_3_3

  # Development tools
  # aider-chat # https://github.com/Aider-AI/aider (Note: currently installing via brew)

  # Dictionary
  # https://emacs.stackexchange.com/a/80721
  (aspellWithDicts (dicts: with dicts; [en en-computers en-science]))

  # Media-related packages
  emacs-all-the-icons-fonts
  dejavu_fonts
  ffmpeg
  fd
  font-awesome
  hack-font
  noto-fonts
  noto-fonts-emoji
  meslo-lgs-nf

  # Text and terminal utilities
  htop
  hunspell
  iftop
  jetbrains-mono
  jq
  ripgrep
  tree
  tmux
  unrar
  unzip

  # Custom Emacs build
  my-emacs-with-packages

  # `e`: shortcut to open Emacs in the current (most recent) frame.
  (pkgs.writeShellScriptBin "e" ''
    # Quick shortcut to Emacs (opens in the current (most recently used) terminal
    # or GUI frame).
    #
    # Note: exits with an error if the user is using vterm[0] from within Emacs,
    # and attempts to run this script.
    #
    # [0]: https://github.com/akermu/emacs-libvterm
    #
    # USAGE:
    #
    #   $ e
    #   # => opens the current directory in your editor
    #
    #   $ e .
    #   $ e /usr/local
    #   # => opens the specified directory in your editor

    if [[ "$INSIDE_EMACS" = "vterm" ]]; then
      echo "Refusing to launch Emacs from inside Emacs: Emacsception denied"
      exit 1
    fi

    if test "$1" == ""
    then
      $($EDITOR --no-wait .)
    else
      $($EDITOR --no-wait $1)
    fi
  '')

  # `et`: shortcut to open Emacs in the terminal.
  (pkgs.writeShellScriptBin "et" ''
    # Quick shortcut to Emacs (opens in the terminal).
    #
    # Note: exits with an error if the user is using vterm[0] from within Emacs,
    # and attempts to run this script.
    #
    # [0]: https://github.com/akermu/emacs-libvterm
    #
    # USAGE:
    #
    #   $ et
    #   # => opens the current directory in your editor
    #
    #   $ et .
    #   $ et /usr/local
    #   # => opens the specified directory in your editor

    if [[ "$INSIDE_EMACS" = "vterm" ]]; then
      echo "Refusing to launch Emacs from inside Emacs: Emacsception denied"
      exit 1
    fi

    if test "$1" == ""
    then
      $EDITOR -nw .
    else
      $EDITOR -nw $1
    fi
  '')

  # `eg`: shortcut to open Emacs in new GUI frame. Unlike the other shortcuts
  # (`e` and `et`), does not require special handling to prevent "Emacsception"
  # when opening from within vterm. [0]
  #
  # [0]: https://github.com/mjrusso/dotfiles/commit/de7d2fbabf0cae25bc977a57ba81e6c93f94f4f2
  (pkgs.writeShellScriptBin "eg" ''
    # Quick shortcut to Emacs (opens in a new GUI frame).
    #
    # USAGE:
    #
    #   $ eg
    #   # => opens the current directory in your editor
    #
    #   $ eg .
    #   $ eg /usr/local
    #   # => opens the specified directory in your editor

    if test "$1" == ""
    then
      $($EDITOR --no-wait --create-frame .)
    else
      $($EDITOR --no-wait --create-frame $1)
    fi
  '')

  # `better-git-branch`: Display git branches ordered by last commit,
  # ahead/behind info, and descriptions. With thanks to [0]. Also see: [1].
  #
  # (Sidenote: Bash variable substitution escaping in Nix string literals is
  # non-obvious. `${}` is escaped as `''${}`, as per [2].)
  #
  # [0]: https://gist.github.com/schacon/e9e743dee2e92db9a464619b99e94eff
  # [1]: https://twitter.com/chacon/status/1746282669342667174
  # [2]: https://discourse.nixos.org/t/how-do-i-use-bash-var-substitution-in-nix/7132/2
  (pkgs.writeShellScriptBin "better-git-branch" ''
    # Display git branches ordered by last commit, ahead/behind info, and
    # descriptions.
    #
    # <https://gist.github.com/schacon/e9e743dee2e92db9a464619b99e94eff>

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NO_COLOR='\033[0m'
    BLUE='\033[0;34m'
    YELLOW='\033[0;33m'
    NO_COLOR='\033[0m'

    width1=5
    width2=6
    width3=30
    width4=20
    width5=40

    count_commits() {
        local branch="$1"
        local base_branch="$2"
        local ahead_behind

        ahead_behind=$(git rev-list --left-right --count "$base_branch"..."$branch")
        echo "$ahead_behind"
    }

    main_branch=$(git rev-parse HEAD)

    if [ $? -ne 0 ]; then
        exit 1
    fi

    printf "''${GREEN}%-''${width1}s ''${RED}%-''${width2}s ''${BLUE}%-''${width3}s ''${YELLOW}%-''${width4}s ''${NO_COLOR}%-''${width5}s\n" "Ahead" "Behind" "Branch" "Last Commit"  " "

    # Separator line for clarity
    printf "''${GREEN}%-''${width1}s ''${RED}%-''${width2}s ''${BLUE}%-''${width3}s ''${YELLOW}%-''${width4}s ''${NO_COLOR}%-''${width5}s\n" "-----" "------" "------------------------------" "-------------------" " "

    format_string="%(objectname:short)@%(refname:short)@%(committerdate:relative)"
    IFS=$'\n'

    for branchdata in $(git for-each-ref --sort=-authordate --format="$format_string" refs/heads/ --no-merged); do
        sha=$(echo "$branchdata" | cut -d '@' -f1)p
        branch=$(echo "$branchdata" | cut -d '@' -f2)
        time=$(echo "$branchdata" | cut -d '@' -f3)
        if [ "$branch" != "$main_branch" ]; then
            # Get branch description
            description=$(git config branch."$branch".description)

            # Count commits ahead and behind
            ahead_behind=$(count_commits "$sha" "$main_branch")
            ahead=$(echo "$ahead_behind" | cut -f2)
            behind=$(echo "$ahead_behind" | cut -f1)

            # Display branch info
            printf "''${GREEN}%-''${width1}s ''${RED}%-''${width2}s ''${BLUE}%-''${width3}s ''${YELLOW}%-''${width4}s ''${NO_COLOR}%-''${width5}s\n" $ahead $behind $branch "$time" "$description"
        fi
    done
  '')
]
