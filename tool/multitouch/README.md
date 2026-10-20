# multitouch injector

Real two-finger gestures on an emulator/device through Android's input pipeline (`sendevent` is
blocked by SELinux on Play images). Runs as the shell user via `app_process`, like scrcpy's server,
and calls `InputManager(Global).injectInputEvent`.

```sh
ANDROID_SERIAL=emulator-5554 ./build.sh          # javac + d8, pushes /data/local/tmp/mt.dex
MT="adb shell CLASSPATH=/data/local/tmp/mt.dex app_process / Mt"
$MT swipe2 700 1000 -400 0 250        # x y dx dy ms [gap=300] [holdMs before lifting]
$MT pinch 540 1000 300 700 400        # cx cy spreadFrom spreadTo ms (fingers side by side)
$MT tap2 540 900                      # x y [gap]
$MT dtap2 540 900 300 120             # x y [gap] [pauseMs between taps]
```

Coordinates are physical pixels; moves are sent every ~10 ms.
