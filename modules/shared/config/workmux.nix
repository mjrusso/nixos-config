# Code: https://github.com/raine/workmux
#
# Docs: https://workmux.raine.dev/guide/configuration
#   - direnv integration: https://workmux.raine.dev/guide/direnv
#   - Port isolation with direnv: https://workmux.raine.dev/guide/monorepos#using-direnv
{
  text = ''
    merge_strategy: rebase
    agent: claude
    panes:
      - command: <agent>
        focus: true
      - split: horizontal
    files:
      symlink:
        - .envrc
    post_create:
      - direnv allow
  '';
}
