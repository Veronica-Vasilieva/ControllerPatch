# ControllerPatch - build script
# Builds the x86 injectable DLL (ControllerPatch.dll) and the x86 loader
# (ControllerPatchLoader.exe) using Visual Studio 2022's MSVC toolchain.
#
# Usage:  pwsh ./build.ps1          # or  powershell -File .\build.ps1
# Output: .\build\ControllerPatch.dll  and  .\build\ControllerPatchLoader.exe
#
# The user's PATH contains some quoted segments that confuse vcvarsall.bat's
# inline call to vswhere.exe, so we prepend the VS Installer dir and pass
# everything to a single cmd.exe process whose env we then inspect.

[CmdletBinding()]
param(
    [switch]$LoaderOnly,
    [switch]$DllOnly,
    [switch]$LauncherOnly
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$installerDir = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$vswhere      = Join-Path $installerDir 'vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found at $vswhere - install Visual Studio 2022 (Community or Build Tools) with the C++ workload."
}

$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "No VS install with the x86/x64 MSVC tools was found." }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $vcvars)) { throw "vcvarsall.bat not found under $vs" }

Write-Host "VS install:    $vs"
Write-Host "Installer dir: $installerDir"

$build  = Join-Path $PSScriptRoot 'build'
$objDir = Join-Path $build 'obj'
foreach ($d in @($build, $objDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
}

$dllSrc      = Join-Path $PSScriptRoot 'src\dll\dllmain.cpp'
$loaderSrc   = Join-Path $PSScriptRoot 'src\loader\inject.cpp'
$launcherSrc = Join-Path $PSScriptRoot 'src\launcher\launcher.cpp'
$dllOut      = Join-Path $build 'ControllerPatch.dll'
$loaderOut   = Join-Path $build 'ControllerPatchLoader.exe'
$launcherOut = Join-Path $build 'Launch_WoW.exe'
$dllPdb      = Join-Path $build 'ControllerPatch.pdb'
$loaderPdb   = Join-Path $build 'ControllerPatchLoader.pdb'
$launcherPdb = Join-Path $build 'Launch_WoW.pdb'

$cflags = '/nologo /EHsc /std:c++17 /O2 /GL /W3 /Zi /DNDEBUG /MT'
# Embed an explicit asInvoker manifest from a file (avoids PowerShell/cmd quote
# mangling of /MANIFESTUAC:"level='asInvoker'..."). Prevents Windows' Installer
# Detection heuristic from auto-elevating an executable it mistakes for a setup.
$loaderManifest   = Join-Path $PSScriptRoot 'src\loader\loader.manifest'
$launcherManifest = Join-Path $PSScriptRoot 'src\launcher\launcher.manifest'
$loaderManArgs    = "/MANIFEST:EMBED /MANIFESTINPUT:`"$loaderManifest`""
$launcherManArgs  = "/MANIFEST:EMBED /MANIFESTINPUT:`"$launcherManifest`""
$dllLnk      = "/DLL /MACHINE:X86 /DEBUG /OPT:REF /OPT:ICF /LTCG /OUT:`"$dllOut`" xinput.lib user32.lib kernel32.lib"
$exeLnk      = "/MACHINE:X86 /DEBUG /OPT:REF /OPT:ICF /LTCG $loaderManArgs /OUT:`"$loaderOut`" kernel32.lib user32.lib"
$launcherLnk = "/MACHINE:X86 /SUBSYSTEM:WINDOWS /DEBUG /OPT:REF /OPT:ICF /LTCG $launcherManArgs /OUT:`"$launcherOut`" kernel32.lib user32.lib"

$script = @"
@echo off
rem Make vswhere findable inside vcvarsall.bat (fixes the "not recognized" error
rem on systems with weirdly quoted PATH entries).
set "PATH=$installerDir;%PATH%"

rem The latest-installed Win10 SDK on this box (10.0.26100) is missing x86 libs;
rem pin to 10.0.22621 which has a complete um\x86 directory.
call "$vcvars" x86 10.0.22621.0
if errorlevel 1 (echo vcvarsall.bat failed with %errorlevel% & exit /b 1)

rem Sanity check so a missing LIB fails loud, not with an opaque LNK1181.
if not defined LIB (echo LIB is empty after vcvarsall & exit /b 2)

$(if (-not $LoaderOnly -and -not $LauncherOnly) { @"
echo Compiling ControllerPatch.dll ...
pushd "$objDir"
cl $cflags /Fd"$dllPdb" "$dllSrc" /link $dllLnk
set RC=%errorlevel%
popd
if %RC% neq 0 exit /b %RC%
"@ })

$(if (-not $DllOnly -and -not $LauncherOnly) { @"
echo Compiling ControllerPatchLoader.exe ...
pushd "$objDir"
cl $cflags /Fd"$loaderPdb" "$loaderSrc" /link $exeLnk
set RC=%errorlevel%
popd
if %RC% neq 0 exit /b %RC%
"@ })

$(if (-not $DllOnly -and -not $LoaderOnly) { @"
echo Compiling Launch_WoW.exe ...
pushd "$objDir"
cl $cflags /Fd"$launcherPdb" "$launcherSrc" /link $launcherLnk
set RC=%errorlevel%
popd
if %RC% neq 0 exit /b %RC%
"@ })

exit /b 0
"@

$tmp = Join-Path $env:TEMP ("cp_build_" + [guid]::NewGuid().ToString("N") + ".cmd")
Set-Content -Path $tmp -Value $script -Encoding ascii
try {
    & cmd.exe /c $tmp
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { throw "Build failed with exit code $rc" }
}
finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Build artifacts ==="
Get-ChildItem $build -File | Where-Object { $_.Extension -in '.dll','.exe','.pdb' } |
    Sort-Object Name |
    ForEach-Object { "{0,-40} {1,10:N0} bytes" -f $_.Name, $_.Length }
