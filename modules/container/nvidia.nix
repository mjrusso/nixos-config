{ config, lib, ... }:

{
  options.hardware.nvidiaGuest.enable = lib.mkEnableOption "the NVIDIA driver for a GPU passed through to this guest";

  config = lib.mkIf config.hardware.nvidiaGuest.enable {
    # NixOS requires an explicit choice for driver 560 and later. The open
    # kernel modules support Turing (RTX 20 series) and newer GPUs.
    hardware.nvidia.open = true;
    # CUDA programs load libcuda from /run/opengl-driver, which exists only
    # when this is enabled.
    hardware.graphics.enable = true;
    # Listing the driver here installs it; it does not enable the X server.
    services.xserver.videoDrivers = [ "nvidia" ];
  };
}
