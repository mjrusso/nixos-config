# Custom Emacs build. Uses emacs-plus [0] patches on MacOS.
#
# Adapted from [1]. (Specifically, this version: [2])
#
# Also see: [3]
#
# [0]: https://github.com/d12frosted/homebrew-emacs-plus/tree/master/patches/emacs-30
# [1]: https://github.com/noctuid/dotfiles/blob/master/nix/overlays/emacs.nix
# [2]: https://github.com/noctuid/dotfiles/blob/1a013bf10cf06ab122caba211e614bad48f43d2b/nix/overlays/emacs.nix)
# [3]: https://www.reddit.com/r/emacs/comments/15opqdy/comment/jvuyqps/

self: super: rec {
  my-emacs-base = super.emacs-git.override {
    withSQLite3 = true;
    withWebP = true;
    withImageMagick = true;
    withTreeSitter = true;
  };

  # https://darrinhenein.com/blog/emacs-icon/
  custom-mac-emacs-icon = ./emacs-icon-1.0-dh.icns;

  my-emacs =
    if super.stdenv.isDarwin
    then
      my-emacs-base.overrideAttrs (old: {
        patches =
          (old.patches or [])
          ++ [
            (super.fetchpatch {
              url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-28/fix-window-role.patch";
              sha256 = "+z/KfsBm1lvZTZNiMbxzXQGRTjkCFO4QPlEK35upjsE=";
            })
            (super.fetchpatch {
              url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-31/round-undecorated-frame.patch";
              sha256 = "WWLg7xUqSa656JnzyUJTfxqyYB/4MCAiiiZUjMOqjuY=";
            })
            (super.fetchpatch {
              url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-31/system-appearance.patch";
              sha256 = "4+2U+4+2tpuaThNJfZOjy1JPnneGcsoge9r+WpgNDko=";
            })
          ];
        postFixup = old.postFixup + ''
          rm $out/Applications/Emacs.app/Contents/Resources/Emacs.icns
          cp ${custom-mac-emacs-icon} $out/Applications/Emacs.app/Contents/Resources/Emacs.icns
        '';
      })
    else
      (my-emacs-base.override {
        withX = true;
        withGTK3 = true;
        withXinput2 = true;
      }).overrideAttrs(_: {
        configureFlags = [
          "--disable-build-details"
          "--with-modules"
          "--with-x-toolkit=gtk3"
          "--with-xft"
          "--with-cairo"
          "--with-xaw3d"
          "--with-native-compilation"
          "--with-imagemagick"
          "--with-xinput2"
        ];
      });

  my-emacs-with-packages =
    ((super.emacsPackagesFor my-emacs).emacsWithPackages (epkgs: [
      epkgs.vterm
      epkgs.treesit-grammars.with-all-grammars
      epkgs.jinx # necessary to install through nix to get libenchant integration working
    ]));
}
