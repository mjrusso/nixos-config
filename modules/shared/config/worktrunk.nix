{ pkgs, lib, ... }:

{
  enable = true;

  settings = {
    # Shell integration is the `wt` function in `fish.nix`. If you remove that
    # function, remove this setting too, so `wt` offers to install shell
    # integration again.
    skip-shell-integration-prompt = true;

    worktree-path = "{{ repo_path }}/../_wt/{{ repo }}.{{ branch | sanitize }}";

    # User `pre-start` hooks run before a project's hooks, so these steps
    # finish before the project's setup command.
    #
    # The `.envrc` link is a separate step that runs before `copy-ignored`. If
    # the two ran at the same time and the project listed `.envrc` in
    # `.worktreeinclude`, `copy-ignored` could create the file first and make
    # `ln` fail. The hook allows `.envrc` only when it created the link. A
    # tracked `.envrc` comes from the branch, and allowing it would trust
    # whatever the branch contains.
    #
    # Don't quote template variables. worktrunk shell-escapes them, and quotes
    # break paths that contain spaces.
    pre-start = [
      {
        envrc = ''
          if [ ! -e .envrc ] && [ -e {{ primary_worktree_path }}/.envrc ]; then
            ln -s {{ primary_worktree_path }}/.envrc .envrc && direnv allow .
          fi
        '';
      }
      {
        copy = "wt step copy-ignored --require-include";
      }
    ];
  };
}
