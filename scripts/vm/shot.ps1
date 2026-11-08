# shot.ps1 <folder> <name>: the whole screen of the signed-in desktop to <folder>\shots\<name>.png. Run it through an
# interactive (/IT) scheduled task: SSH sessions can't see the desktop. Plain CopyFromScreen (CaptureBlt gives a white
# picture on the UTM VM's display driver).
param([string]$Folder, [string]$Name = 'shot')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System.Runtime.InteropServices;
public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[Dpi]::SetProcessDPIAware() | Out-Null
New-Item -ItemType Directory -Force -Path "$Folder\shots" | Out-Null
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bitmap.Save("$Folder\shots\$Name.png", [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
