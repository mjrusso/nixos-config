{ name, email, ... }:

{
  enable = true;
  settings = {
    user = {
      name = name;
      email = email;
    };
    ui = {
      default-command = "log";
      diff-editor = ":builtin";
      merge-editor = ":builtin";
    };
    remotes.origin.auto-track-bookmarks = "glob:*";
    aliases = {
      d  = ["diff"];
      dc = ["diff" "--from" "@-" "--to" "@"];
      st = ["status"];
      l  = ["log"];
      lg = ["log" "-r" "::@"];
    };
  };
}
