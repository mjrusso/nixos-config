{ lib, ... }:

{
  options.programs.servePreview.domain = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "voom.example.org";
    description = ''
      Domain under which the tailnet Caddy host publishes this machine's
      loopback ports, as `<hostname>-<port>.<domain>`. When null,
      serve-preview reports plain `http://localhost` URLs.
    '';
  };
}
