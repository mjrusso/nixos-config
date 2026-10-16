{
  config,
  lib,
  pkgs,
  userInfo,
  ...
}:

let
  local = config.services.localDesktop.enable;
  headless = config.services.headlessDesktop.enable;
  enabled = local || headless;
  nvidia = builtins.elem "nvidia" config.services.xserver.videoDrivers;
  user = userInfo.user;
  output = "HEADLESS-STREAM";
  hyprlandSettings = import ./config/hyprland.nix {
    output = if headless then output else null;
  };
  hyprlandConfig = pkgs.writeText "hyprland.lua" hyprlandSettings.text;
  # Hyprland canonicalizes --config paths; this loader must stay constant across rebuilds.
  hyprlandLoader = pkgs.writeText "hyprland-startup.lua" ''
    require("/etc/xdg/hypr/hyprland.lua")
  '';
  monitorDefaults = pkgs.writeText "hyprland-monitors.lua" hyprlandSettings.monitorDefaults;
  # UWSM rejects execute-only wrapper paths, including those resolved by -F.
  sessionCommand = "${config.programs.uwsm.package}/bin/uwsm start -- Hyprland --config ${hyprlandLoader}";
in
{
  options.services = {
    localDesktop.enable = lib.mkEnableOption "a local Hyprland desktop";
    headlessDesktop.enable = lib.mkEnableOption "an NVIDIA-backed headless Hyprland desktop";
  };

  config = lib.mkMerge [
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = !(local && headless);
          message = "services.localDesktop and services.headlessDesktop cannot both be enabled.";
        }
        {
          assertion = !config.services.xserver.enable;
          message = "The Hyprland desktop requires the local Xorg desktop to be disabled.";
        }
      ];
      programs.hyprland = {
        enable = true;
        withUWSM = true;
      };
      environment.etc."xdg/hypr/hyprland.lua".source = hyprlandConfig;
      systemd.user.services.hyprland-config-reload = {
        description = "Reload the installed Hyprland configuration";
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        restartTriggers = [ hyprlandConfig ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${config.programs.hyprland.package}/bin/hyprctl reload";
        };
      };
      services.greetd = {
        enable = true;
        useTextGreeter = true;
        settings = {
          initial_session = lib.mkIf headless {
            command = sessionCommand;
            inherit user;
          };
          default_session.command = "${config.services.greetd.package}/bin/agreety --cmd ${lib.escapeShellArg sessionCommand}";
        };
      };
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };
      security.rtkit.enable = true;
      environment.systemPackages = [
        pkgs.evince
        pkgs.gedit
        pkgs.ghostty
        pkgs.imv
        pkgs.loupe
        pkgs.mpv
        pkgs.nautilus
        pkgs.nwg-displays
      ];
      services.gvfs.enable = true;
      xdg.mime.defaultApplications = {
        "application/pdf" = "org.gnome.Evince.desktop";
        "text/plain" = "org.gnome.gedit.desktop";
        "inode/directory" = "org.gnome.Nautilus.desktop";
      }
      // lib.genAttrs [
        "image/png"
        "image/jpeg"
        "image/gif"
        "image/webp"
        "image/bmp"
        "image/tiff"
        "image/svg+xml"
        "image/avif"
      ] (_: "org.gnome.Loupe.desktop")
      // lib.genAttrs [
        "video/mp4"
        "video/x-msvideo"
        "video/x-matroska"
        "video/x-flv"
        "video/x-ms-wmv"
        "video/mpeg"
        "video/ogg"
        "video/webm"
        "video/quicktime"
        "video/3gpp"
        "video/3gpp2"
        "video/x-ms-asf"
        "video/x-ogm+ogg"
        "video/x-theora+ogg"
        "application/ogg"
      ] (_: "mpv.desktop");
      users.users.${user}.extraGroups = [
        "video"
        "render"
      ];
      programs.noctalia = {
        enable = true;
        systemd.enable = true;
      };
      home-manager.users.${user} = home: {
        home.activation.startHyprlandConfigReload = home.lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
          if ${pkgs.systemd}/bin/systemctl --user --quiet is-active graphical-session.target; then
            run ${pkgs.systemd}/bin/systemctl --user start hyprland-config-reload.service
          fi
        '';
        home.activation.initializeDisplaySettings = home.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          display_file="${home.config.xdg.configHome}/hypr/monitors.lua"
          # nwg-displays cannot revert Apply when its previous Lua file is empty.
          if [[ ! -s "$display_file" ]]; then
            run install -Dm644 ${monitorDefaults} "$display_file"
          fi
        '';
        home.activation.resetNoctaliaOverrides = home.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${pkgs.python3.withPackages (ps: [ ps.tomli-w ])}/bin/python3 - \
            "${home.config.xdg.stateHome}/noctalia/settings.toml" \
            ${pkgs.writeText "noctalia-settings.json" (builtins.toJSON home.config.programs.noctalia.settings)} <<'PY'
          import copy
          import json
          import os
          from pathlib import Path
          import sys
          import tempfile
          import tomllib
          import tomli_w

          def remove_overrides(saved, managed):
              for key, value in managed.items():
                  if isinstance(value, dict) and isinstance(saved.get(key), dict):
                      remove_overrides(saved[key], value)
                      if not saved[key]:
                          del saved[key]
                  else:
                      saved.pop(key, None)

          path = Path(sys.argv[1]).resolve()
          if path.is_file():
              saved = tomllib.loads(path.read_text())
              original = copy.deepcopy(saved)
              remove_overrides(saved, json.loads(Path(sys.argv[2]).read_text()))
              if saved != original:
                  with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
                      try:
                          tomli_w.dump(saved, temporary)
                          temporary.close()
                          os.replace(temporary.name, path)
                      finally:
                          Path(temporary.name).unlink(missing_ok=True)
          PY
        '';
        programs.noctalia = {
          enable = true;
          package = config.programs.noctalia.package;
          settings = import ./config/noctalia.nix { inherit local; };
        };
        home.file."Pictures/Wallpapers/GNOME".source = "${pkgs.gnome-backgrounds}/share/backgrounds/gnome";
      };
    })
    (lib.mkIf headless {
      assertions = [
        {
          assertion = nvidia;
          message = "services.headlessDesktop requires NVIDIA graphics to be configured separately. In a VM, enable hardware.nvidiaGuest.enable.";
        }
      ];
      systemd.additionalUpstreamSystemUnits = [ "systemd-udev-settle.service" ];
      systemd.services.greetd = {
        wants = [ "systemd-udev-settle.service" ];
        after = [ "systemd-udev-settle.service" ];
        unitConfig.ConditionPathExists = [
          "/dev/nvidia0"
          "/dev/dri/streaming-nvidia"
        ];
      };
      services.udev.extraRules = ''
        SUBSYSTEM=="drm", KERNEL=="card*", ENV{DEVTYPE}=="drm_minor", DRIVERS=="nvidia", SYMLINK+="dri/streaming-nvidia"
      '';
      environment.etc."xdg/uwsm/env-hyprland".text = ''
        export AQ_DRM_DEVICES=/dev/dri/streaming-nvidia
      '';
      services.pipewire.extraConfig.pipewire."90-streaming-audio" = {
        "context.objects" = [
          {
            factory = "adapter";
            args = {
              "factory.name" = "support.null-audio-sink";
              "node.name" = "streaming-audio";
              "node.description" = "Streaming audio";
              "media.class" = "Audio/Sink";
              "audio.position" = [
                "FL"
                "FR"
              ];
              "priority.session" = 2000;
            };
          }
        ];
      };
      systemd.user.services.headless-display = {
        description = "Create the headless Hyprland display";
        wants = lib.optional config.services.sunshine.enable "sunshine.service";
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if ! ${config.programs.hyprland.package}/bin/hyprctl monitors -j \
            | ${pkgs.jq}/bin/jq -e 'any(.[]; .name == "${output}")' >/dev/null; then
            ${config.programs.hyprland.package}/bin/hyprctl output create headless ${output}
          fi
          for attempt in {1..50}; do
            if ${config.programs.hyprland.package}/bin/hyprctl monitors -j \
              | ${pkgs.jq}/bin/jq -e 'any(.[]; .name == "${output}" and .width > 0 and .height > 0)' >/dev/null; then
              ${config.programs.hyprland.package}/bin/hyprctl dispatch 'hl.dsp.focus({ monitor = "${output}" })'
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          echo "Hyprland did not create the ${output} display" >&2
          exit 1
        '';
      };
    })
    (lib.mkIf (enabled && config.services.sunshine.enable) {
      services.sunshine = {
        package = pkgs.sunshine.override { cudaSupport = nvidia; };
        openFirewall = true;
        settings = {
          capture = "wlr";
          encoder = lib.mkIf nvidia "nvenc";
          upnp = "disabled";
          output_name = lib.mkIf headless output;
          audio_sink = lib.mkIf headless "streaming-audio";
        };
        applications.apps = [ { name = "Desktop"; } ];
      };
      systemd.user.services.sunshine = lib.mkIf headless {
        requires = [ "headless-display.service" ];
        after = [ "headless-display.service" ];
      };
      users.groups.sunshine-input = { };
      users.users.${user}.extraGroups = [ "sunshine-input" ];
      # uaccess ACLs follow the active seat; Sunshine must keep input access.
      services.udev.extraRules = ''
        SUBSYSTEM=="misc", KERNEL=="uinput", GROUP="sunshine-input", MODE="0660"
      '';
    })
  ];
}
