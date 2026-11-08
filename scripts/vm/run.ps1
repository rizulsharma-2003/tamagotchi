# run.ps1 <exe> <envfile>: starts Mochi on the signed-in desktop (through an /IT scheduled task) with the KEY=VALUE
# lines of <envfile> set. Start-Process, not a .cmd file: Flutter's runner attaches to a parent console and would keep a
# console window open for as long as it runs.
param([string]$Exe, [string]$EnvFile)
if ($EnvFile -and (Test-Path $EnvFile)) {
  foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*([^=#\s]+)\s*=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
  }
}
Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe)
