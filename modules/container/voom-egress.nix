{
  lib,
  pkgs,
  userInfo,
  ...
}:

let
  user = userInfo.user;
  voomEgressPrepare = pkgs.callPackage ../../packages/voom-egress-prepare.nix { };
  voomEgressRun = pkgs.callPackage ../../packages/voom-egress-run.nix { };
  voomEgressSkip = pkgs.callPackage ../../packages/voom-egress-skip.nix { };
  voomEgressEnvironment = "/run/voom-egress/environment";
  voomEgressEnvironmentGenerator = pkgs.writeShellScript "90-voom-egress" ''
    if [[ -r ${voomEgressEnvironment} ]]; then
      ${pkgs.coreutils}/bin/cat ${voomEgressEnvironment}
    fi
  '';
  # Chromium reads the per-user NSS database instead of the CA environment.
  # The runtime egress CA cannot be installed through build-time pki options.
  voomEgressSetup = pkgs.writeShellScript "voom-egress-setup" ''
    set -euo pipefail

    db="$HOME/.pki/nssdb"
    ca=/run/voom/egress-ca.pem
    manifest=/run/voom/egress.json

    remove_trust() {
      [ -f "$db/cert9.db" ] || return 0
      ${pkgs.nss.tools}/bin/certutil -d "sql:$db" -L >/dev/null
      if ${pkgs.nss.tools}/bin/certutil -d "sql:$db" -L \
        -n voom-egress >/dev/null 2>&1; then
        ${pkgs.nss.tools}/bin/certutil -d "sql:$db" -D -n voom-egress
      fi
    }

    ${lib.getExe voomEgressPrepare} --allow-missing /run/voom-egress

    if [ ! -r "$manifest" ]; then
      remove_trust
      exit 0
    fi

    ca_path="$(${pkgs.jq}/bin/jq -er '.caCertificate // "" | strings' "$manifest")"
    if [ -z "$ca_path" ]; then
      remove_trust
      exit 0
    fi

    ${pkgs.coreutils}/bin/install -d -m 0700 "$db"
    # certutil -A rejects an existing nickname, so remove the previous CA first.
    remove_trust
    ${pkgs.nss.tools}/bin/certutil -d "sql:$db" -A -t "C,," \
      -n voom-egress -i "$ca"
  '';
in
{
  # nofail mounts are not ordered before local-fs.target. A path unit cannot
  # detect host-side changes because virtiofs does not report them through
  # inotify, so live manifest changes require a service or VM restart.
  systemd.services.voom-egress-trust = {
    description = "Prepare the Voom egress environment and browser trust";
    wantedBy = [ "multi-user.target" ];
    requiredBy = [ "systemd-user-sessions.service" ];
    wants = [ "run-voom.mount" ];
    after = [ "run-voom.mount" ];
    before = [ "systemd-user-sessions.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Environment = "HOME=/home/${user}";
      RuntimeDirectory = "voom-egress";
      RuntimeDirectoryMode = "0755";
      ExecStart = voomEgressSetup;
      RemainAfterExit = true;
    };
  };

  environment.systemPackages = [
    voomEgressRun
    voomEgressSkip
  ];

  environment.etc."systemd/user-environment-generators/90-voom-egress".source =
    voomEgressEnvironmentGenerator;
}
