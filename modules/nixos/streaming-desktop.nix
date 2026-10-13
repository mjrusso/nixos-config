{
  config,
  lib,
  pkgs,
  userInfo,
  ...
}:

let
  cfg = config.services.streamingDesktop;
  user = userInfo.user;
  output = "HEADLESS-STREAM";
  hyprlandConfig = pkgs.writeText "streaming-hyprland.lua" ''
    hl.monitor({ output = "${output}", mode = "1920x1080@60", position = "0x0", scale = 1 })
    hl.config({
      general = { layout = "dwindle" },
      misc = { disable_hyprland_logo = true, force_default_wallpaper = -1 },
    })
    hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("uwsm app -- ghostty"))
    hl.bind("SUPER + Q", hl.dsp.window.close())
    hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
    hl.bind("SUPER + left", hl.dsp.focus({ direction = "left" }))
    hl.bind("SUPER + right", hl.dsp.focus({ direction = "right" }))
    hl.bind("SUPER + up", hl.dsp.focus({ direction = "up" }))
    hl.bind("SUPER + down", hl.dsp.focus({ direction = "down" }))
    hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
    for workspace = 1, 9 do
      hl.workspace_rule({ workspace = workspace, monitor = "${output}", default = workspace == 1 })
      hl.bind("SUPER + " .. workspace, hl.dsp.focus({ workspace = workspace }))
      hl.bind("SUPER + SHIFT + " .. workspace, hl.dsp.window.move({ workspace = workspace }))
    end
  '';
  sessionCommand = "${config.programs.uwsm.package}/bin/uwsm start -F -- /run/wrappers/bin/Hyprland --config ${hyprlandConfig}";
in
{
  options.services.streamingDesktop.enable = lib.mkEnableOption "an NVIDIA-backed headless Hyprland desktop streamed by Sunshine";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.services.xserver.enable;
        message = "services.streamingDesktop requires the local Xorg desktop to be disabled (set hostInfo.nixosDesktop = false for a physical host).";
      }
      {
        assertion = builtins.elem "nvidia" config.services.xserver.videoDrivers;
        message = "services.streamingDesktop requires NVIDIA graphics to be configured separately. In a VM, enable hardware.nvidiaGuest.enable.";
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
        initial_session = {
          command = sessionCommand;
          inherit user;
        };
        default_session.command = "${pkgs.greetd}/bin/agreety --cmd ${lib.escapeShellArg sessionCommand}";
      };
    };

    systemd.additionalUpstreamSystemUnits = [ "systemd-udev-settle.service" ];
    systemd.services.greetd = {
      wants = [ "systemd-udev-settle.service" ];
      after = [ "systemd-udev-settle.service" ];
      unitConfig.ConditionPathExists = [
        "/dev/nvidia0"
        "/dev/dri/streaming-nvidia"
      ];
    };

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      extraConfig.pipewire."90-streaming-audio" = {
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
    };
    security.rtkit.enable = true;
    services.sunshine = {
      enable = true;
      package = pkgs.sunshine.override { cudaSupport = true; };
      openFirewall = true;
      settings = {
        capture = "wlr";
        output_name = output;
        encoder = "nvenc";
        audio_sink = "streaming-audio";
        upnp = "disabled";
      };
      applications.apps = [ { name = "Desktop"; } ];
    };
    systemd.user.services.sunshine.preStart = ''
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
    users.groups.sunshine-input = { };
    users.users.${user}.extraGroups = [
      "video"
      "render"
      "sunshine-input"
    ];
    # uaccess ACLs follow the active seat; Sunshine must keep input access.
    services.udev.extraRules = ''
      SUBSYSTEM=="drm", KERNEL=="card*", ENV{DEVTYPE}=="drm_minor", DRIVERS=="nvidia", SYMLINK+="dri/streaming-nvidia"
      SUBSYSTEM=="misc", KERNEL=="uinput", GROUP="sunshine-input", MODE="0660"
    '';
    environment.etc."xdg/uwsm/env-hyprland".text = ''
      export AQ_DRM_DEVICES=/dev/dri/streaming-nvidia
    '';
    environment.systemPackages = [ pkgs.ghostty ];
  };
}
