{ local }:

{
  shell.launch_apps_custom_command = "uwsm app -- $CMD";
  wallpaper.directory = "~/Pictures/Wallpapers";
  lockscreen = {
    enabled = local;
    lock_before_suspend = local;
  };
  idle.behavior.lock = {
    enabled = local;
    timeout = 600;
    action = "lock";
  };
}
