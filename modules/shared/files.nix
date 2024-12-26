{ pkgs, config, ... }: {
  ".aider.conf.yml".text = ''

    # Docs: https://aider.chat/docs/config/aider_conf.html

    #######
    # Main:

    ## Use claude 3.5 sonnet model for the main chat
    sonnet: true

    ###############
    # Git Settings:

    ## Enable/disable adding .aider* to .gitignore (default: True)
    gitignore: false

    ## Enable/disable auto commit of LLM changes (default: True)
    auto-commits: false

    ## Attribute aider code changes in the git author name (default: True)
    attribute-author: false

    ## Attribute aider commits in the git committer name (default: True)
    attribute-committer: false

  '';
}
