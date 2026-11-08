# click.ps1 <folder> <target> <name>: on the signed-in desktop (through an /IT scheduled task), clicks <target> and,
# 2.5 s later, saves the screen to <folder>\shots\<name>.png from this same process (a new process would take the focus
# and close a popover). <target> is "x,y" in physical pixels, or "mochi": the centre of Mochi's visible window, found
# at the moment of the click. The pointer hovers 1.2 s first: the taskbar pet lets clicks through until it's hovered.
param([string]$Folder, [string]$Target = 'mochi', [string]$Name = 'after-click')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Click {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static RECT Find(uint pid) {
    RECT best = new RECT(); long area = 0;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h)) {
        RECT r; GetWindowRect(h, out r);
        long a = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
        if (a > area && a < 400000) { area = a; best = r; }
      }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
'@
[Click]::SetProcessDPIAware() | Out-Null
function Aim {
  if ($Target -eq 'mochi') {
    $proc = Get-Process Mochi | Select-Object -First 1
    $r = [Click]::Find([uint32]$proc.Id)
    return @([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
  }
  $xy = $Target -split '[ ,]'; return @([int]$xy[0], [int]$xy[1])
}
$p = Aim; [Click]::SetCursorPos($p[0], $p[1]) | Out-Null
Start-Sleep -Milliseconds 1200
$p = Aim; [Click]::SetCursorPos($p[0], $p[1]) | Out-Null
Start-Sleep -Milliseconds 400
[Click]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[Click]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Set-Content "$Folder\click-result.txt" "clicked $($p[0]) $($p[1])"
Start-Sleep -Milliseconds 2500
New-Item -ItemType Directory -Force -Path "$Folder\shots" | Out-Null
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bitmap.Save("$Folder\shots\$Name.png", [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
