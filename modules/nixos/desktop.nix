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
  hyprlandConfig =
    pkgs.writeText "hyprland.lua"
      (import ./config/hyprland.nix {
        output = if headless then output else null;
      }).text;
  # UWSM rejects execute-only wrapper paths, including those resolved by -F.
  sessionCommand = "${config.programs.uwsm.package}/bin/uwsm start -- Hyprland --config ${hyprlandConfig}";
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
      environment.systemPackages = [ pkgs.ghostty ];
      users.users.${user}.extraGroups = [
        "video"
        "render"
      ];
      programs.hyprlock.enable = local;
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
              | ${pkgs.jq}/bin/jq -e 'any(.[]; .name == "${output}" and .width == 1920 and .height == 1080)' >/dev/null; then
              ${config.programs.hyprland.package}/bin/hyprctl dispatch 'hl.dsp.focus({ monitor = "${output}" })'
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          echo "Hyprland did not create the ${output} display at 1920x1080" >&2
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
