{
  domain,
  lib,
  tailscale,
  writers,
}:
writers.writePython3Bin "serve-preview" {
  makeWrapperArgs =
    if domain == null || domain == "" then
      [
        "--unset"
        "SERVE_PREVIEW_DOMAIN"
      ]
    else
      [
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath [ tailscale ])
        "--set"
        "SERVE_PREVIEW_DOMAIN"
        domain
      ];
} (builtins.readFile ./serve-preview.py)
