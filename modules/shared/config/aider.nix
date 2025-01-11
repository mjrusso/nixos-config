{
  text = ''
    # Docs: https://aider.chat/docs/config/aider_conf.html

    #######
    # Main:

    model: openrouter/deepseek/deepseek-chat
    # model: openrouter/anthropic/claude-3.5-sonnet
    # model: anthropic/claude-3-5-sonnet-20241022

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
