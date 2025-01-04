{ ... }:

{
  # https://github.com/nix-community/nix-direnv
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
}
