# wake.ps1: wakes the display of the signed-in desktop by nudging the pointer one pixel and back (run it through an
# interactive /IT scheduled task).
Add-Type @'
using System.Runtime.InteropServices;
public static class Nudge {
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.UIntPtr extra);
}
'@
[Nudge]::mouse_event(0x0001, 1, 0, 0, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 100
[Nudge]::mouse_event(0x0001, -1, 0, 0, [System.UIntPtr]::Zero)
