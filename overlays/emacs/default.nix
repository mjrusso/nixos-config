# Emacs from nixpkgs, with a few packages that need native modules or grammars.
#
# Uses stock Emacs so the build is substituted from cache.nixos.org instead of
# compiled locally.
self: super:
let
  base = if super.stdenv.isDarwin then super.emacs else super.emacs-gtk;

  withPackages = base.pkgs.withPackages (epkgs: [
    epkgs.vterm
    epkgs.treesit-grammars.with-all-grammars
    epkgs.jinx
  ]);
in
{
  my-emacs-with-packages =
    if super.stdenv.isDarwin then
      # The wrapper copies Resources/ into its own output, so the icon can be
      # replaced here without rebuilding Emacs.
      withPackages.overrideAttrs (old: {
        buildCommand = old.buildCommand + ''
          chmod -R u+w $out/Applications/Emacs.app/Contents/Resources
          cp ${./emacs-icon-1.0-dh.icns} $out/Applications/Emacs.app/Contents/Resources/Emacs.icns
        '';
      })
    else
      withPackages;
}
