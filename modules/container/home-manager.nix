{ config, osConfig, pkgs, lib, userInfo, ... }:

let
  user = userInfo.user;
  homeDir = "/home/${user}";
  sharedFiles = import ../shared/files.nix { inherit user config pkgs homeDir; };
  additionalFiles = import ./files.nix { inherit user config pkgs homeDir; };
  sharedPrograms = import ../shared/home-manager.nix {
    inherit config osConfig pkgs lib userInfo;
  };
  voomEgressEnvironment = "/run/voom-egress/environment";
  voomEgressFishInit = ''
    if test -r ${voomEgressEnvironment}
        set -l voom_no_proxy
        if set -q NO_PROXY
            set voom_no_proxy $NO_PROXY
        else if set -q no_proxy
            set voom_no_proxy $no_proxy
        end

        while read -l assignment
            set -l pair (string split -m 1 = -- "$assignment")
            if test (count $pair) -ne 2
                continue
            end
            switch $pair[1]
                case GH_TOKEN
                    if not set -q GH_TOKEN; or test -z "$GH_TOKEN"
                        set -gx GH_TOKEN $pair[2]
                    end
                case NO_PROXY no_proxy
                case '*'
                    set -gx $pair[1] $pair[2]
            end
        end < ${voomEgressEnvironment}

        for entry in localhost 127.0.0.1 ::1
            if not contains -- $entry (string split , -- "$voom_no_proxy")
                set voom_no_proxy (string join , $voom_no_proxy $entry)
            end
        end
        set -gx NO_PROXY $voom_no_proxy
        set -gx no_proxy $voom_no_proxy
    end
  '';
in {
  home = {
    username = user;
    homeDirectory = homeDir;
    enableNixpkgsReleaseCheck = false;
    packages = pkgs.callPackage ./packages.nix { };
    sessionPath = [
      "$HOME/.local/bin"
    ];
    sessionVariables = {
      PATH = "$PATH:$HOME/.npm/bin";
      EDITOR = "ec";
    };
    file = lib.mkMerge [ sharedFiles additionalFiles ];
    stateVersion = "24.11";
  };

  news.display = "silent";

  programs = lib.recursiveUpdate sharedPrograms {
    fish.shellInitLast = sharedPrograms.fish.shellInitLast + voomEgressFishInit;
  };
}
