{ userInfo, ... }:
{
  environment.etc."mjr-vm-guest".text = "1\n";
  security.sudo.extraConfig = ''
    ${userInfo.user} ALL=(ALL) NOPASSWD: ALL
  '';
  power.sleep.computer = "never";
}
