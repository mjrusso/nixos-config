{ ... }:

{
  enable = true;
  settings = {
    # Default protocol for `gh` operations (clone, fork, create, ...).
    git_protocol = "https";
  };
  # Home Manager also configures gh as Git's credential helper for GitHub.
}
