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
  kitty
  neofetch
  nixfmt
  sqlite
  wget
  zip

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


]
