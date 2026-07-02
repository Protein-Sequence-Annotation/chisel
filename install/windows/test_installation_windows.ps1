param(
  [Parameter(Mandatory = $true)]
  [string]$ChiselDir
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -Path $ChiselDir -PathType Container)) {
  throw "ChiselDir does not exist: $ChiselDir"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw "wsl.exe not found. Install WSL2 and retry."
}

$resolved = (Resolve-Path $ChiselDir).Path
$wslRepo = (wsl.exe wslpath -a "$resolved").Trim()
$wslScript = "$wslRepo/install/test_installation.sh"

Write-Host "[test_installation_windows] Running install test in WSL2:"
Write-Host "  bash $wslScript $wslRepo"

wsl.exe bash -lc "bash '$wslScript' '$wslRepo'"

Write-Host ""
Write-Host "[test_installation_windows] Done."
