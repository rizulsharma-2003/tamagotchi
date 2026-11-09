# drive.ps1 <folder> <steps file>: plays a list of pointer and keyboard steps on the signed-in desktop (through an /IT
# /RL LIMITED scheduled task), all from this one process so nothing new takes the focus between steps. For checking
# Mochi's drop target, Ask box and cards on the VM without a person at the keyboard. One step per line, fields split by |:
#   drag-file|C:\a.txt[,C:\b.pdf]|<target>   a real OLE drag (CF_HDROP) from a small non-activating source window
#   drag-text|some text|<target>             CF_UNICODETEXT
#   drag-link|https://...|<target>           UniformResourceLocatorW + the URL as text
#   click|<target>        hover 1.2 s (the taskbar pet lets clicks through until it's hovered), then a left click
#   type|text             Unicode keys, only while Mochi's own window has the focus (never into another window)
#   key|{ENTER}           SendKeys syntax as is, only while Mochi's own window has the focus
#   hotkey|^%( )          a global shortcut in SendKeys syntax, skipped while a terminal has the focus
#   scroll|<target>|n     n wheel notches down (negative: up) with the pointer at <target>
#   fg                    the program that has the focus     down-up|<target>   a click, noting the focus around the press
#   wait|ms     shot|name     run|program|arguments
# <target> is "x,y" in physical pixels, "last+dx,y" (x from the last click), or "mochi": the centre of the test build's taskbar pet, aimed again on every
# step of the drag, because Mochi walks. Each step's outcome goes to <folder>\drive-result.txt; shots to <folder>\shots.
param([string]$Folder, [string]$Steps)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class SourceForm : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000008 | 0x00000080; return cp; } // NOACTIVATE TOPMOST TOOLWINDOW
  }
}
public static class Drive {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static uint MochiPid;
  // Typing goes only to Mochi: never into another window (the user's own Claude sessions are open on this desktop).
  public static uint ForegroundPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
  public static bool MochiFocused() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return MochiPid != 0 && p == MochiPid; }
  public static Point Pet() {
    RECT best = new RECT(); long area = 0;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == MochiPid && IsWindowVisible(h)) {
        RECT r; GetWindowRect(h, out r);
        long a = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
        if (a > area && a < 400000) { area = a; best = r; }
      }
      return true;
    }, IntPtr.Zero);
    return new Point((best.Left + best.Right) / 2, (best.Top + best.Bottom) / 2);
  }
  public static void MoveTo(int x, int y) {
    int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
    mouse_event(0x8001, (int)((long)x * 65535 / (w - 1)), (int)((long)y * 65535 / (h - 1)), 0, UIntPtr.Zero);
  }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT m; [FieldOffset(0)] public KEYBDINPUT k; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  // Each character as a Unicode key (VK_PACKET): SendKeys' synthetic Shift loses capitals and "?" in Flutter's field.
  public static void TypeText(string s) {
    foreach (char c in s) {
      var down = new INPUT { type = 1 }; down.u.k.wScan = c; down.u.k.dwFlags = 0x0004;
      var up = new INPUT { type = 1 }; up.u.k.wScan = c; up.u.k.dwFlags = 0x0004 | 0x0002;
      SendInput(2, new[] { down, up }, Marshal.SizeOf(typeof(INPUT)));
      Thread.Sleep(15);
    }
  }
  public static void Wheel(int delta) { mouse_event(0x0800, 0, 0, unchecked((uint)delta), UIntPtr.Zero); }
  public static void Down() { mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); }
  public static void Up() { mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
  static Point Aim(int tx, int ty) { return tx < 0 ? Pet() : new Point(tx, ty); }
  // Presses on a small source window, starts an OLE drag of `data` from it, walks the pointer to the target in 40
  // steps, lingers there (re-aiming), and lets go. Returns the effect the drop target chose ("None": refused or missed).
  public static string Drag(IDataObject data, int tx, int ty, int lingerMs) {
    Application.OleRequired();
    int sx = 150, sy = 160; // away from Mochi's window and the taskbar, so the source never sits on the drop point
    string result = "no drag";
    var f = new SourceForm { FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual,
      Location = new Point(sx - 30, sy - 30), Size = new Size(60, 60), BackColor = Color.HotPink, ShowInTaskbar = false };
    f.MouseDown += (o, e) => {
      result = f.DoDragDrop(data, DragDropEffects.Copy | DragDropEffects.Link | DragDropEffects.Move).ToString();
      f.BeginInvoke(new Action(f.Close));
    };
    f.Shown += (o, e) => {
      var t = new Thread(() => {
        Thread.Sleep(400);
        MoveTo(sx, sy); Thread.Sleep(200);
        Down(); Thread.Sleep(300);
        for (int i = 1; i <= 40; i++) {
          var p = Aim(tx, ty);
          MoveTo(sx + (p.X - sx) * i / 40, sy + (p.Y - sy) * i / 40); Thread.Sleep(35);
        }
        var end = DateTime.Now.AddMilliseconds(lingerMs); int k = 0;
        while (DateTime.Now < end) { var p = Aim(tx, ty); MoveTo(p.X + (k++ % 2), p.Y); Thread.Sleep(100); }
        Up();
        Thread.Sleep(3000);
        try { f.BeginInvoke(new Action(f.Close)); } catch { }
      });
      t.IsBackground = true; t.Start();
    };
    Application.Run(f);
    return result;
  }
}
'@
[Drive]::SetProcessDPIAware() | Out-Null
$proc = Get-Process Mochi -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\src\mochi-check*' } | Select-Object -First 1
if (-not $proc) { $proc = Get-Process Mochi -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($proc) { [Drive]::MochiPid = [uint32]$proc.Id }
$log = "$Folder\drive-result.txt"
Set-Content $log "mochi pid $([Drive]::MochiPid); screen $([Drive]::GetSystemMetrics(0))x$([Drive]::GetSystemMetrics(1))"
New-Item -ItemType Directory -Force -Path "$Folder\shots" | Out-Null

$script:lastX = 0
function Target([string]$t) {
  if ($t -eq 'mochi') { return @(-1, -1) }
  $xy = $t -split '[ ,]'
  if ($xy[0] -like 'last*') { return @(($script:lastX + [int]($xy[0].Substring(4))), [int]$xy[1]) } # x from the last click
  return @([int]$xy[0], [int]$xy[1])
}
function Shot([string]$name) {
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bitmap.Save("$Folder\shots\$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose(); $bitmap.Dispose()
}

foreach ($line in Get-Content $Steps) {
  if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
  $f = $line -split '\|'
  $out = ''
  try {
    switch ($f[0]) {
      'drag-file' {
        $d = New-Object System.Windows.Forms.DataObject
        $d.SetData([System.Windows.Forms.DataFormats]::FileDrop, [string[]]($f[1] -split ','))
        $t = Target $f[2]; $out = [Drive]::Drag($d, $t[0], $t[1], 1800)
      }
      'drag-text' {
        $d = New-Object System.Windows.Forms.DataObject
        $d.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $f[1])
        $t = Target $f[2]; $out = [Drive]::Drag($d, $t[0], $t[1], 1800)
      }
      'drag-link' {
        $d = New-Object System.Windows.Forms.DataObject
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($f[1] + [char]0)
        $d.SetData('UniformResourceLocatorW', (New-Object System.IO.MemoryStream (, $bytes)))
        $d.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $f[1])
        $t = Target $f[2]; $out = [Drive]::Drag($d, $t[0], $t[1], 1800)
      }
      'click' {
        $t = Target $f[1]
        for ($i = 0; $i -lt 2; $i++) {
          $p = if ($t[0] -lt 0) { [Drive]::Pet() } else { New-Object System.Drawing.Point $t[0], $t[1] }
          [Drive]::MoveTo($p.X, $p.Y); Start-Sleep -Milliseconds 700
        }
        [Drive]::Down(); Start-Sleep -Milliseconds 60; [Drive]::Up()
        $script:lastX = $p.X; $out = "at $($p.X),$($p.Y)"
      }
      'scroll' {
        $t = Target $f[1]; [Drive]::MoveTo($t[0], $t[1]); Start-Sleep -Milliseconds 300
        for ($i = 0; $i -lt [Math]::Abs([int]$f[2]); $i++) {
          [Drive]::Wheel([Math]::Sign([int]$f[2]) * -120); Start-Sleep -Milliseconds 120
        }
        $out = "$($f[2]) notches"
      }
      'type' { if ([Drive]::MochiFocused()) { [Drive]::TypeText($f[1]); $out = 'typed' } else { $out = 'skipped: Mochi is not focused' } }
      'key' { if ([Drive]::MochiFocused()) { [System.Windows.Forms.SendKeys]::SendWait($f[1]); $out = 'sent' } else { $out = 'skipped: Mochi is not focused' } }
      'hotkey' {
        # A global shortcut (SendKeys syntax), never while a terminal has the focus: it must not land in a Claude session.
        $fg = (Get-Process -Id ([Drive]::ForegroundPid()) -ErrorAction SilentlyContinue).ProcessName
        if ($fg -match '^(WindowsTerminal|OpenConsole|conhost|cmd|powershell|pwsh|claude)$') { $out = "skipped: $fg has the focus" }
        else { [System.Windows.Forms.SendKeys]::SendWait($f[1]); $out = "sent over $fg" }
      }
      'fg' { $out = (Get-Process -Id ([Drive]::ForegroundPid()) -ErrorAction SilentlyContinue).ProcessName }
      'down-up' {
        # A click on <target> with the foreground's owner noted between the press and the release.
        $t = Target $f[1]; $p = if ($t[0] -lt 0) { [Drive]::Pet() } else { New-Object System.Drawing.Point $t[0], $t[1] }
        [Drive]::MoveTo($p.X, $p.Y); Start-Sleep -Milliseconds 1200
        $p = if ($t[0] -lt 0) { [Drive]::Pet() } else { $p }; [Drive]::MoveTo($p.X, $p.Y); Start-Sleep -Milliseconds 300
        $before = (Get-Process -Id ([Drive]::ForegroundPid())).ProcessName
        [Drive]::Down(); Start-Sleep -Milliseconds 80
        $between = (Get-Process -Id ([Drive]::ForegroundPid())).ProcessName
        [Drive]::Up(); Start-Sleep -Milliseconds 300
        $script:lastX = $p.X; $out = "before $before, pressed $between, after $((Get-Process -Id ([Drive]::ForegroundPid())).ProcessName)"
      }
      'wait' { Start-Sleep -Milliseconds ([int]$f[1]) }
      'shot' { Shot $f[1]; $out = "$($f[1]).png" }
      'run' { Start-Process -FilePath $f[1] -ArgumentList $f[2]; $out = 'started' }
      default { $out = 'unknown step' }
    }
  } catch { $out = "error: $($_.Exception.Message)" }
  Add-Content $log "$($f[0]): $out"
}
Add-Content $log 'done'
