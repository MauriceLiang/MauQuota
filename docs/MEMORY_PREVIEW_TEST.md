# MauQuota v2.0.1 Memory Stability Preview

This preview is isolated from `main` and does not change the stable v2.0.0 release.

## Changes

- Construct the AppKit menu and its submenus once per app launch, then update existing menu items and informational views.
- Re-render the two quota rings only when quota values or ring visibility actually change.
- Skip rebuilding the attributed menu-bar title when the displayed value and color options are unchanged.
- Keep OAuth, refresh timers, reset credits and the existing Keychain behavior intact.

## Manual memory comparison (macOS)

1. Quit MauQuota v2.0.0 and record its idle RSS for 30–60 minutes with a normal 1–2 minute refresh interval.
2. Install this preview over the existing app and run with the same refresh interval and account.
3. Record RSS after launch, after 30 minutes, after 2 hours, and after 6–12 hours.
4. Open and close the menu 30 times, then open and close the reset-credit window 20 times.
5. Confirm login, manual refresh, automatic refresh, language change, ring toggles, and reset-card browsing still work.
6. Compare trends rather than a single Activity Monitor value. RSS can remain elevated due to allocator and system caching; use Xcode Instruments (Allocations/Leaks) if memory continues increasing.

Example periodic RSS log:
```sh
PID="$(pgrep -x MauQuota | head -n 1)"
while kill -0 "$PID" 2>/dev/null; do
  ps -p "$PID" -o rss= | awk -v t="$(date '+%F %T')" '{printf "%s %.2f MiB\n", t, $1/1024}'
  sleep 60
done
```

## Scope and limitations

This is a targeted lifecycle/allocation reduction, not a proven fix for a memory leak. There is no on-device long-duration memory profile in CI. Do not consume a real reset card solely for this test.
