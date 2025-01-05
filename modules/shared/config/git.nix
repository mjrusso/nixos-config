{ name, user, email, ... }:

{
  enable = true;
  ignores = [
    "*.swp"
     "__private/"
     ".DS_Store"
     ".svn"
     ".projectile"
     ".dir-locals.el"
     ".envrc"
     ".direnv/"
     ".nrepl-port"
     "*~"
     "*~.nib"
     "*.pbxuser"
     "*.perspective"
     "*.perspectivev3"
     "*.mode1v3"
     ".aider*"
  ];
  userName = name;
  userEmail = email;
  lfs = {
    enable = true;
  };
  aliases = {
    d   = "diff";
    dc  = "diff --cached";
    f   = "fetch";
    fo  = "fetch origin";
    co  = "checkout";
    com = "checkout main";
    pom = "pull origin main";
    cod = "checkout develop";
    pod = "pull origin develop";
    st  = "status -sb";
    su  = "submodule update";
    g   = "grep --break --heading --line-number";
    up  = "!git pull --rebase --prune $@ && git submodule update --init --recursive";
    save  = "!git add -A && git commit -m 'SAVEPOINT'";
    wip   = "!git add -u && git commit -m 'WIP'";
    undo  = "reset HEAD~1 --mixed";
    amend = "commit -a --amend";
    shortsha = "rev-parse --short HEAD";
    lg  = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative";
    lgp = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative -p";
    wc = "whatchanged --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative";
    refs = "for-each-ref --sort='authordate:iso8601' --format=' %(color:green)%(authordate:relative)%09%(color:white)%(refname:short)' refs/heads";
    count = "!git shortlog -sn";
  };
  extraConfig = {
    init.defaultBranch = "main";
    core = {
      autocrlf = "input";
    };
    push = {
      default = "current";
    };
    color = {
      ui = "auto";
      diff = "auto";
      status = "auto";
      branch = "auto";
    };
    pull.rebase = true;
    rebase.autoStash = true;
  };
}
