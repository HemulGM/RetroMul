#requires -Version 5.1
<#
.SYNOPSIS
Builds Release binaries and packages them into releases/RetroMul-<platform>.zip.
.EXAMPLE
.\BuildReleases.ps1
.EXAMPLE
.\BuildReleases.ps1 -Platforms win32,win64 -BdsPath 'G:\Program Files (x86)\Embarcadero\Studio\37.0'
#>
[CmdletBinding()]
param(
    [ValidateSet('win32', 'win64', 'linux64', 'android32', 'android64')]
    [string[]] $Platforms = @('win32', 'win64', 'linux64', 'android32', 'android64'),
    [string] $BdsPath = $env:BDS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectDirectory = Join-Path $PSScriptRoot 'fmx'
$projectFile = Join-Path $projectDirectory 'RetroMul.dproj'
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectFile)
$releaseDirectory = Join-Path $PSScriptRoot 'releases'

# Prefer the active installation; otherwise discover Delphi on PATH or in the registry.
if (-not $BdsPath) {
    $compiler = Get-Command dcc32.exe -ErrorAction SilentlyContinue
    if ($compiler) {
        $BdsPath = Split-Path -Parent (Split-Path -Parent $compiler.Source)
    } else {
        $installations = @(Get-ChildItem 'HKCU:\Software\Embarcadero\BDS' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d+\.\d+$' } |
            Sort-Object { [version]$_.PSChildName } -Descending)
        foreach ($installation in $installations) {
            $candidate = (Get-ItemProperty -LiteralPath $installation.PSPath).RootDir
            if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\rsvars.bat'))) {
                $BdsPath = $candidate
                break
            }
        }
    }
}
if (-not $BdsPath) { throw 'RAD Studio was not found. Specify -BdsPath or run from the RAD Studio command prompt.' }
$rsvars = Join-Path $BdsPath 'bin\rsvars.bat'
if (-not (Test-Path -LiteralPath $rsvars -PathType Leaf)) { throw "RAD Studio environment script not found: $rsvars" }

# rsvars.bat configures SDK/compiler/MSBuild paths. Import into this process only.
$environmentLines = & $env:ComSpec /d /c "call `"$rsvars`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw "Could not initialize RAD Studio from $rsvars" }
foreach ($line in $environmentLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
$msbuild = Join-Path $env:FrameworkDir 'MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) { throw "MSBuild not found: $msbuild" }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force -Path $releaseDirectory | Out-Null

$platformNames = @{ win32 = 'Win32'; win64 = 'Win64'; linux64 = 'Linux64'; android32 = 'Android'; android64 = 'Android64' }
foreach ($prefix in ($Platforms | Select-Object -Unique)) {
    $prefix = $prefix.ToLowerInvariant()
    $platform = $platformNames[$prefix]
    $isAndroid = $prefix -in @('android32', 'android64')
    $outputDirectory = Join-Path $projectDirectory "$platform\Release"
    $binaryName = if ($isAndroid) { 'RetroMul.apk' } elseif ($prefix -eq 'linux64') { 'RetroMul' } else { 'RetroMul.exe' }
    $binaryPath = if ($isAndroid) {
        Join-Path $outputDirectory "RetroMul\bin\$binaryName"
    } else {
        Join-Path $outputDirectory $binaryName
    }
    $archivePath = Join-Path $releaseDirectory "RetroMul-$prefix.zip"
    $temporaryArchive = Join-Path $releaseDirectory (".RetroMul-$prefix-" + [guid]::NewGuid().ToString('N') + '.zip')

    # Delete only the expected previous binary so it cannot pass as a fresh build.
    if (Test-Path -LiteralPath $binaryPath) { Remove-Item -LiteralPath $binaryPath -Force }
    $target = if ($isAndroid) { '/t:Build;Deploy' } else { '/t:Build' }
    # Artwork paths in the .dproj use ProjectName before Delphi targets define it.
    # Set it as a global property so it is available during project evaluation.
    $arguments = @($projectFile, '/nologo', '/v:minimal', $target, "/p:ProjectName=$projectName", '/p:Config=Release', "/p:Platform=$platform",
        '/p:DCC_Optimize=true', '/p:DCC_DebugDCUs=false', '/p:DCC_DebugInformation=0', '/p:DCC_LocalDebugSymbols=false')
    if ($isAndroid) {
        # Debug is RAD Studio's APK packaging mode; Config=Release still controls
        # native compilation. AppStore produces an AAB instead. Use the SDK debug
        # certificate for a sideloadable APK. This packaging mode also enables
        # android:debuggable; native compiler settings remain Release.
        $arguments += @('/p:BT_BuildType=Debug', '/p:DeviceId=')
    }

    Write-Host "Building $platform / Release..."
    Push-Location $projectDirectory
    try {
        & $msbuild @arguments
        if ($LASTEXITCODE -ne 0) { throw "$platform build failed (MSBuild exit code $LASTEXITCODE)." }
    } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf) -or (Get-Item -LiteralPath $binaryPath).Length -eq 0) {
        throw "Build did not produce a nonempty executable: $binaryPath"
    }

    try {
        $zip = [IO.Compression.ZipFile]::Open($temporaryArchive, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $binaryPath, $binaryName, [IO.Compression.CompressionLevel]::Optimal)
            if ($prefix -eq 'linux64') {
                # Unix regular file, mode 0755: preserve execute permission on unzip.
                $entry.ExternalAttributes = -2115174400
            }
        } finally { $zip.Dispose() }
        Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force }
    }
    Write-Host "Created $archivePath"
}
