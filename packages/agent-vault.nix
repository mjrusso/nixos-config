{
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  version = "0.39.3";
  sources = {
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-7ay92wPG9CIVFdmHXDp7CUPHFDRwjn/RO+D3Y1p7rsw=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-Uv5wYmKM8kSaOlAhxDlzo/eIm06baADu27KM7KGFGPY=";
    };
  };
  source = sources.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "agent-vault";
  inherit version;

  src = fetchurl {
    url = "https://github.com/Infisical/agent-vault/releases/download/v${version}/agent-vault_${version}_linux_${source.arch}.tar.gz";
    inherit (source) hash;
  };

  sourceRoot = ".";
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 agent-vault "$out/bin/agent-vault"
    install -Dm644 LICENSE "$out/share/licenses/agent-vault/LICENSE"
    install -Dm644 README.md "$out/share/doc/agent-vault/README.md"
    runHook postInstall
  '';

  meta = {
    description = "HTTP credential proxy and vault for software agents";
    homepage = "https://github.com/Infisical/agent-vault";
    license = lib.licenses.mit;
    mainProgram = "agent-vault";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
