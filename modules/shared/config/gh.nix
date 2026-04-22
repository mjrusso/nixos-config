{ ... }:

{
  enable = true;
  settings = {
    # Default protocol for `gh` operations (clone, fork, create, ...).
    git_protocol = "https";
  };
  # `gitCredentialHelper.enable` defaults to true, which injects
  # `credential.https://github.com.helper = "gh auth git-credential"`
  # (and the same for gist.github.com) into the git config. Authenticate
  # once with `gh auth login`; the token is stored in the OS keyring.
}
