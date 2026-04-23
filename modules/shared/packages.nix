{ pkgs }:

with pkgs; [
  # General packages for development and system management
  _1password-cli
  bash-completion
  bat
  btop
  curl
  coreutils
  fish
  killall
  neofetch
  nixfmt-classic
  rsync
  sqlite
  wget
  zip

  # Language servers
  pyright

  # Programming languages
  elixir_1_19
  nodejs_22
  python3
  pipx
  rustc
  cargo
  ruby_3_3

  # Development tools
  just
  git-recent # Run: `git recent` to see a list of recent git branches.

  # AI development tools
  #
  # - Aider: https://github.com/Aider-AI/aider
  #
  #   - Note that Aider is available via Nixpkgs as `aider-chat`, however I'm
  #     currently installing via pipx.
  #
  #   - To upgrade: `pipx uninstall aider-chat; pipx install aider-chat[playwright]`

  # Dictionary
  # https://emacs.stackexchange.com/a/80721
  (aspellWithDicts (dicts: with dicts; [en en-computers en-science]))

  # Media-related packages
  ffmpeg
  portaudio

  # Fonts
  emacs-all-the-icons-fonts
  dejavu_fonts
  font-awesome
  nerd-fonts._0xproto
  nerd-fonts.fira-code
  nerd-fonts.droid-sans-mono
  hack-font
  noto-fonts
  noto-fonts-color-emoji
  meslo-lgs-nf

  # Text and terminal utilities
  fzf
  htop
  hunspell
  iftop
  jetbrains-mono
  jq
  osc
  ripgrep
  fd
  socat
  tree
  tmux
  zellij
  zoxide
  unrar
  unzip
  presenterm # https://github.com/mfontanini/presenterm

  # Document conversion
  pandoc
  typst # Use as a pandoc PDF engine (e.g. `pandoc in.md -o out.pdf --pdf-engine=typst`)
  # mermaid-filter # Pandoc filter for creating diagrams in mermaid syntax blocks
                   # in markdown docs. Source: https://github.com/raghur/mermaid-filter

  # Custom Emacs build
  my-emacs-with-packages

  # Custom emacsclient wrapper
  (pkgs.writeShellScriptBin "ec" ''
    # An `emacsclient` wrapper, intended for use as $EDITOR.
    #
    # Automatically connects to an existing Emacs server process (if running),
    # otherwise starts a new one.
    #
    # Note: exits with an error if the user is using vterm[0] from within Emacs,
    # and attempts to run this script (from within vterm).
    #
    # [0]: https://github.com/akermu/emacs-libvterm

    if [[ "$INSIDE_EMACS" = "vterm" ]]; then
      echo "Refusing to launch Emacs from inside Emacs: Emacsception denied"
      exit 1
    fi

    exec emacsclient -a "" "$@"
  '')

  # Custom Emacs server quit wrapper
  (pkgs.writeShellScriptBin "equit" ''
    # Tells the Emacs server to save all file-visiting buffers and then
    # exit. Mirrors the behaviour of `C-x C-c` (save-buffers-kill-emacs),
    # except that modified buffers are saved silently rather than prompting,
    # and the "active processes exist; kill them?" prompt is suppressed.
    #
    # `kill-emacs-query-functions` are still honoured, so packages like Magit
    # can still block exit (e.g. to warn about unpushed commits).
    #
    # For an immediate exit (no save, no query hooks), use `ekill`. For a
    # SIGKILL when the server is unresponsive, use `ekill9`.

    exec emacsclient -e '(let ((confirm-kill-processes nil)) (save-buffers-kill-emacs t))'
  '')

  # Custom Emacs server kill wrapper
  (pkgs.writeShellScriptBin "ekill" ''
    # Tells the Emacs server to exit immediately via `kill-emacs`. Runs
    # `kill-emacs-hook` but does NOT prompt about (or save) modified
    # buffers, so any unsaved work will be lost.
    #
    # For a save-and-exit, use `equit`. For a SIGKILL when the server is
    # unresponsive, use `ekill9`.

    exec emacsclient -e '(kill-emacs)'
  '')

  # Custom Emacs server force-kill wrapper
  (pkgs.writeShellScriptBin "ekill9" ''
    # SIGKILL the Emacs daemon process. For use when the server is wedged
    # and not responding to `ekill`.
    #
    # On macOS, BSD `killall` matches against the process name (basename of
    # argv[0]), which is just `emacs` — so `killall -9 emacs` targets the
    # daemon without hitting `emacsclient`.
    #
    # On Linux, `killall` (psmisc) matches against `/proc/<pid>/comm`, which
    # for the Nix build is a truncated wrapped-binary name like
    # `.emacs-31.0.50-` — so `killall emacs` finds nothing. We fall back to
    # `pkill -f`, which matches the full argv and is stable across rebuilds.

    ${if pkgs.stdenv.isDarwin
      then "exec killall -9 emacs"
      else "exec pkill -9 -f 'emacs.*daemon'"}
  '')

  # Custom virtual machine management script
  (pkgs.writeShellScriptBin "vm" ''
    ${pkgs.lib.optionalString pkgs.stdenv.isLinux "export VM_QEMU_AARCH64_UEFI=${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd"}
    exec ${pkgs.bash}/bin/bash ${../../scripts/vm} "$@"
  '')

  # Post-install bootstrap script to perform additional imperative setup.
  (pkgs.writeShellScriptBin "home-bootstrap" ''
    exec ${pkgs.bash}/bin/bash ${../../scripts/home-bootstrap} "$@"
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
