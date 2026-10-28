{
  lib,
  python3,
  stdenvNoCC,
  makeWrapper,
}:
stdenvNoCC.mkDerivation {
  pname = "agent-vault-tunnel";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [ makeWrapper ];
  doCheck = true;
  checkPhase = ''
    ${python3}/bin/python3 -m unittest discover -p 'test_*.py'
  '';
  installPhase = ''
    install -Dm644 agent_vault_tunnel.py "$out/libexec/agent-vault-tunnel.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/agent-vault-tunnel" \
      --add-flags "$out/libexec/agent-vault-tunnel.py"
  '';
  meta.mainProgram = "agent-vault-tunnel";
}
