{
  haproxy,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "voom-agent-vault";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ haproxy ];

  doCheck = true;
  checkPhase = ''
    HAPROXY=${lib.getExe haproxy} ${python3}/bin/python3 -m unittest test_voom_agent_vault.py
  '';

  installPhase = ''
    install -Dm755 voom_agent_vault.py "$out/libexec/voom-agent-vault/voom_agent_vault.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/voom-agent-vault" \
      --add-flags "$out/libexec/voom-agent-vault/voom_agent_vault.py"
  '';

  meta.mainProgram = "voom-agent-vault";
}
