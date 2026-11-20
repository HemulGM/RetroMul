#requires -Version 5.1
<#
.SYNOPSIS
Builds Release binaries and packages them into releases/RetroMul-<platform>.zip.
Each ZIP includes the repository's LICENSE and README.md at its root.
Build logs are written to releases/build-logs.
.EXAMPLE
.\BuildReleases.ps1
.EXAMPLE
.\BuildReleases.ps1 -Platforms win32,win64 -BdsPath 'G:\Program Files (x86)\Embarcadero\Studio\37.0'
.EXAMPLE
.\BuildReleases.ps1 -Platforms macos64,macosarm64
.NOTES
macOS targets are included by default and require the corresponding RAD Studio toolchains
and SDKs. Archives contain a local .app bundle, without Apple signing or
notarization. ARM64 linking may also require a configured Mac/PAServer profile.
#>
[CmdletBinding()]
param(
    [ValidateSet('win32', 'win64', 'linux64', 'android32', 'android64', 'macos64', 'macosarm64')]
    [string[]] $Platforms = @('win32', 'win64', 'linux64', 'android32', 'android64', 'macos64', 'macosarm64'),
    [string] $BdsPath = $env:BDS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectDirectory = Join-Path $PSScriptRoot 'apps/retromul'
$projectFile = Join-Path $projectDirectory 'RetroMul.dproj'
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectFile)
$releaseDirectory = Join-Path $PSScriptRoot 'releases'
$releaseDocuments = @('LICENSE', 'README.md')
foreach ($document in $releaseDocuments) {
    $documentPath = Join-Path $PSScriptRoot $document
    if (-not (Test-Path -LiteralPath $documentPath -PathType Leaf)) { throw "Release document not found: $documentPath" }
}

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
$buildLogDirectory = Join-Path $releaseDirectory 'build-logs'
New-Item -ItemType Directory -Force -Path $buildLogDirectory | Out-Null

function Set-ZipUnixHost([string] $Path) {
    # .NET on Windows writes a DOS host marker even with Unix ExternalAttributes.
    # Mark central-directory entries as Unix so extractors honor their modes.
    # These locally created archives have no ZIP comment.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = $stream.Length - 22
        if ($reader.ReadUInt32() -ne 0x06054b50) { throw 'ZIP end record not found.' }
        $stream.Position = $stream.Length - 12
        $count = $reader.ReadUInt16()
        $stream.Position = $stream.Length - 6
        $offset = $reader.ReadUInt32()
        if ($count -eq 0 -or $offset -eq [uint32]::MaxValue) { throw 'Unexpected macOS ZIP directory format.' }
        for ($index = 0; $index -lt $count; $index++) {
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x02014b50) { throw 'ZIP central-directory entry not found.' }
            $stream.Position = $offset + 5
            $stream.WriteByte(3) # Unix host system.
            $stream.Position = $offset + 28
            $nameLength = $reader.ReadUInt16()
            $extraLength = $reader.ReadUInt16()
            $commentLength = $reader.ReadUInt16()
            $offset += 46 + $nameLength + $extraLength + $commentLength
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

$platformNames = @{ win32 = 'Win32'; win64 = 'Win64'; linux64 = 'Linux64'; android32 = 'Android'; android64 = 'Android64'; macos64 = 'OSX64'; macosarm64 = 'OSXARM64' }
foreach ($prefix in ($Platforms | Select-Object -Unique)) {
    $prefix = $prefix.ToLowerInvariant()
    $platform = $platformNames[$prefix]
    $isAndroid = $prefix -in @('android32', 'android64')
    $isMacTarget = $prefix -in @('macos64', 'macosarm64')
    $outputDirectory = Join-Path $projectDirectory "$platform\Release"
    $binaryName = if ($isAndroid) { 'RetroMul.apk' } elseif ($prefix -eq 'linux64' -or $isMacTarget) { 'RetroMul' } else { 'RetroMul.exe' }
    $binaryPath = if ($isAndroid) {
        Join-Path $outputDirectory "RetroMul\bin\$binaryName"
    } else {
        Join-Path $outputDirectory $binaryName
    }
    $archivePath = Join-Path $releaseDirectory "RetroMul-$prefix.zip"
    $buildLogPath = Join-Path $buildLogDirectory "RetroMul-$prefix.log"
    $temporaryArchive = Join-Path $releaseDirectory (".RetroMul-$prefix-" + [guid]::NewGuid().ToString('N') + '.zip')

    if ($isMacTarget) {
        # Match the project's Release deployment resource, including per-platform
        # overrides, rather than assuming both architectures use the same icon.
        [xml] $projectXml = Get-Content -LiteralPath $projectFile -Raw -Encoding UTF8
        $iconDeployment = @($projectXml.Project.ProjectExtensions.BorlandProject.Deployment.DeployFile |
            Where-Object { $_.Class -eq 'ProjectOSXResource' -and $_.Configuration -eq 'Release' -and
                $_.Platform.Name -eq $platform -and $_.Platform.RemoteName -eq "$projectName.icns" })
        if ($iconDeployment.Count -ne 1) { throw "Expected one Release icon deployment for $platform in $projectFile" }
        $iconPath = $iconDeployment[0].LocalName.Replace('$(BDS)', $BdsPath).Replace('$(ProjectName)', $projectName)
        if (-not [IO.Path]::IsPathRooted($iconPath)) { $iconPath = Join-Path $projectDirectory $iconPath }
        if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw "macOS icon not found: $iconPath" }
        $plistPath = Join-Path $outputDirectory "$projectName.info.plist"
        # A previous metadata file must not survive a build that failed to generate it.
        if (Test-Path -LiteralPath $plistPath) { Remove-Item -LiteralPath $plistPath -Force }
    }

    # Delete only the expected previous binary so it cannot pass as a fresh build.
    if (Test-Path -LiteralPath $binaryPath) { Remove-Item -LiteralPath $binaryPath -Force }
    $target = if ($isAndroid) { '/t:Build;Deploy' } elseif ($isMacTarget) { '/t:Build;BuildInfoPlist' } else { '/t:Build' }
    # Artwork paths in the .dproj use ProjectName before Delphi targets define it.
    # Set it as a global property so it is available during project evaluation.
    $arguments = @($projectFile, '/nologo', '/v:minimal', $target, "/p:ProjectName=$projectName", '/p:Config=Release', "/p:Platform=$platform",
        '/p:DCC_Optimize=true', '/p:DCC_DebugDCUs=false', '/p:DCC_DebugInformation=0', '/p:DCC_LocalDebugSymbols=false',
        '/fl', "/flp:LogFile=$buildLogPath;Verbosity=Normal;Encoding=UTF-8")
    if ($isAndroid) {
        # Debug is RAD Studio's APK packaging mode; Config=Release still controls
        # native compilation. AppStore produces an AAB instead. Use the SDK debug
        # certificate for a sideloadable APK. This packaging mode also enables
        # android:debuggable; native compiler settings remain Release.
        $arguments += @('/p:BT_BuildType=Debug', '/p:DeviceId=')
    }

    Write-Host "Building $platform / Release. Log: $buildLogPath"
    Push-Location $projectDirectory
    try {
        & $msbuild @arguments
        if ($LASTEXITCODE -ne 0) { throw "$platform build failed (MSBuild exit code $LASTEXITCODE). Log: $buildLogPath" }
    } finally { Pop-Location }
    try {
        if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf) -or (Get-Item -LiteralPath $binaryPath).Length -eq 0) {
            throw "Build did not produce a nonempty executable: $binaryPath"
        }
        if ($isMacTarget -and (-not (Test-Path -LiteralPath $plistPath -PathType Leaf) -or (Get-Item -LiteralPath $plistPath).Length -eq 0)) {
            throw "Build did not produce macOS bundle metadata: $plistPath"
        }

        $zip = [IO.Compression.ZipFile]::Open($temporaryArchive, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entryName = if ($isMacTarget) { "$projectName.app/Contents/MacOS/$binaryName" } else { $binaryName }
            $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $binaryPath, $entryName, [IO.Compression.CompressionLevel]::Optimal)
            if ($prefix -eq 'linux64' -or $isMacTarget) {
                # Unix regular file, mode 0755: preserve execute permission on unzip.
                $entry.ExternalAttributes = -2115174400
            }
            if ($isMacTarget) {
                $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $plistPath, "$projectName.app/Contents/Info.plist", [IO.Compression.CompressionLevel]::Optimal)
                $entry.ExternalAttributes = -2119958528 # Unix regular file, mode 0644.
                $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $iconPath, "$projectName.app/Contents/Resources/$projectName.icns", [IO.Compression.CompressionLevel]::Optimal)
                $entry.ExternalAttributes = -2119958528
            }
            foreach ($document in $releaseDocuments) {
                $documentPath = Join-Path $PSScriptRoot $document
                $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $documentPath, $document, [IO.Compression.CompressionLevel]::Optimal)
                if ($isMacTarget) { $entry.ExternalAttributes = -2119958528 } # Unix regular file, mode 0644.
            }
        } finally { $zip.Dispose() }
        if ($isMacTarget) { Set-ZipUnixHost $temporaryArchive }
        Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
    } catch {
        Add-Content -LiteralPath $buildLogPath -Encoding UTF8 -Value ($_ | Out-String) -ErrorAction Continue
        throw
    } finally {
        if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force }
    }
    Write-Host "Created $archivePath"
    if ($isMacTarget) { Write-Host 'The .app bundle has not been signed or notarized by this script.' }
}
