<#
.SYNOPSIS
Packages the TallyIsle Windows x64 Flutter release bundle into:
  - TallyIsle-Windows-x64-portable.zip
  - TallyIsle-Windows-x64-setup.exe (Inno Setup 6)
  - TallyIsle-Windows-x64.msi (WiX Toolset v5 via dotnet global tool)
#>
[CmdletBinding()]
param(
    [string]$ReleaseDir = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..")).Path

if ([string]::IsNullOrWhiteSpace($ReleaseDir)) {
    $ReleaseDir = Join-Path $RepoRoot "build\windows\x64\runner\Release"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = $RepoRoot
}

$ReleaseDir = (Resolve-Path $ReleaseDir).Path
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path $OutDir).Path

$ExePath = Join-Path $ReleaseDir "tallyisle.exe"
if (-not (Test-Path $ExePath)) {
    throw "Expected Windows executable not found: $ExePath"
}

$IconPath = Join-Path $RepoRoot "windows\runner\resources\app_icon.ico"
if (-not (Test-Path $IconPath)) {
    throw "Expected Windows app icon not found: $IconPath"
}

$PubspecPath = Join-Path $RepoRoot "pubspec.yaml"
$VersionMatch = Select-String -Path $PubspecPath -Pattern '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)' | Select-Object -First 1
if (-not $VersionMatch) {
    throw "Failed to parse version: X.Y.Z+BUILD from $PubspecPath"
}
$AppVersion = $VersionMatch.Matches[0].Groups[1].Value
$BuildNumber = $VersionMatch.Matches[0].Groups[2].Value
$MsiVersion = "$AppVersion.$BuildNumber"

Write-Host "Packaging TallyIsle $AppVersion+$BuildNumber (Windows x64)"
Write-Host "  ReleaseDir : $ReleaseDir"
Write-Host "  OutDir     : $OutDir"

# 1. Portable ZIP
$ZipPath = Join-Path $OutDir "TallyIsle-Windows-x64-portable.zip"
if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}
Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $ZipPath -Force

# 2. Inno Setup 6 EXE
function Resolve-IsccPath {
    $candidates = @(
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    return $null
}

$IsccPath = Resolve-IsccPath
if (-not $IsccPath) {
    Write-Host "ISCC.exe not found; installing Inno Setup via Chocolatey..."
    & choco install innosetup -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Inno Setup via choco (exit code $LASTEXITCODE)"
    }
    $IsccPath = Resolve-IsccPath
    if (-not $IsccPath) {
        throw "ISCC.exe still not found after Chocolatey installation"
    }
}

$IssPath = Join-Path $ScriptDir "tallyisle.iss"
$SetupExePath = Join-Path $OutDir "TallyIsle-Windows-x64-setup.exe"
if (Test-Path $SetupExePath) {
    Remove-Item -Force $SetupExePath
}

& $IsccPath `
    "/DMyAppVersion=$AppVersion" `
    "/DMyBuildNumber=$BuildNumber" `
    "/DMySourceDir=$ReleaseDir" `
    "/DMyOutputDir=$OutDir" `
    "/DMyRepoRoot=$RepoRoot" `
    $IssPath
if ($LASTEXITCODE -ne 0) {
    throw "ISCC.exe failed with exit code $LASTEXITCODE"
}

# 3. WiX Toolset v5 MSI (dotnet global tool; works on windows-2025 where WiX v3 is absent)
$DotnetToolsDir = Join-Path $HOME ".dotnet\tools"
if (Test-Path $DotnetToolsDir) {
    if ($env:PATH -notlike "*$DotnetToolsDir*") {
        $env:PATH = "$DotnetToolsDir;$env:PATH"
    }
}

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    Write-Host "Installing WiX CLI 5.0.2 via dotnet global tool..."
    & dotnet tool update --global wix --version 5.0.2
    if ($LASTEXITCODE -ne 0) {
        & dotnet tool install --global wix --version 5.0.2
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install WiX CLI 5.0.2 (exit code $LASTEXITCODE)"
        }
    }
    if ($env:PATH -notlike "*$DotnetToolsDir*") {
        $env:PATH = "$DotnetToolsDir;$env:PATH"
    }
}

function Escape-Xml([string]$Value) {
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-DeterministicGuid([string]$Seed) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("TallyIsle-6D8A4E72:$Seed")
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $guidBytes = New-Object byte[] 16
    [Array]::Copy($hash, 0, $guidBytes, 0, 16)
    # RFC 4122 version 5 & variant bits (Guid constructor uses LE for bytes 6-7)
    $guidBytes[7] = ($guidBytes[7] -band 0x0F) -bor 0x50
    $guidBytes[8] = ($guidBytes[8] -band 0x3F) -bor 0x80
    return (New-Object System.Guid (,$guidBytes)).ToString("D").ToUpperInvariant()
}

$script:DirCounter = 0
$script:SubDirIdCounter = 0
$script:FileCounter = 0
$script:ComponentIds = New-Object System.Collections.Generic.List[string]

function Build-WixDirectoryXml {
    param(
        [string]$Path,
        [string]$RelPath,
        [string]$Indent
    )

    $sb = New-Object System.Text.StringBuilder
    $dirIdx = $script:DirCounter
    $script:DirCounter++
    $dirCompId = "CompDir_$dirIdx"
    $dirGuid = New-DeterministicGuid "dir:$RelPath"
    $script:ComponentIds.Add($dirCompId)

    $files = @(Get-ChildItem -LiteralPath $Path -File | Sort-Object Name)
    $subDirs = @(Get-ChildItem -LiteralPath $Path -Directory | Sort-Object Name)

    [void]$sb.AppendLine("$Indent<Component Id=`"$dirCompId`" Guid=`"$dirGuid`">")
    [void]$sb.AppendLine("$Indent  <CreateFolder />")
    [void]$sb.AppendLine("$Indent  <RemoveFolder Id=`"RemoveDir_$dirIdx`" On=`"uninstall`" />")
    [void]$sb.AppendLine("$Indent  <RegistryValue Root=`"HKCU`" Key=`"Software\TallyIsle\Installer`" Name=`"Dir_$dirIdx`" Type=`"integer`" Value=`"1`" KeyPath=`"yes`" />")
    [void]$sb.AppendLine("$Indent</Component>")

    foreach ($file in $files) {
        $fileIdx = $script:FileCounter
        $script:FileCounter++
        $fileRelPath = if ([string]::IsNullOrEmpty($RelPath)) { $file.Name } else { "$RelPath\$($file.Name)" }
        $fileCompId = "CompFile_$fileIdx"
        $fileGuid = New-DeterministicGuid "file:$fileRelPath"
        $script:ComponentIds.Add($fileCompId)
        $escapedSource = Escape-Xml $file.FullName

        [void]$sb.AppendLine("$Indent<Component Id=`"$fileCompId`" Guid=`"$fileGuid`">")
        [void]$sb.AppendLine("$Indent  <RegistryValue Root=`"HKCU`" Key=`"Software\TallyIsle\Installer`" Name=`"File_$fileIdx`" Type=`"integer`" Value=`"1`" KeyPath=`"yes`" />")
        [void]$sb.AppendLine("$Indent  <File Id=`"File_$fileIdx`" Source=`"$escapedSource`" />")
        [void]$sb.AppendLine("$Indent</Component>")
    }

    foreach ($sub in $subDirs) {
        $subId = $script:SubDirIdCounter
        $script:SubDirIdCounter++
        $subRelPath = if ([string]::IsNullOrEmpty($RelPath)) { $sub.Name } else { "$RelPath\$($sub.Name)" }
        $escapedName = Escape-Xml $sub.Name
        [void]$sb.AppendLine("$Indent<Directory Id=`"Dir_$subId`" Name=`"$escapedName`">")
        $childXml = Build-WixDirectoryXml -Path $sub.FullName -RelPath $subRelPath -Indent "$Indent  "
        [void]$sb.Append($childXml)
        [void]$sb.AppendLine("$Indent</Directory>")
    }

    return $sb.ToString()
}

$AppTreeXml = Build-WixDirectoryXml -Path $ReleaseDir -RelPath "" -Indent "        "
$EscapedIconPath = Escape-Xml $IconPath

$ComponentRefsSb = New-Object System.Text.StringBuilder
foreach ($cid in $script:ComponentIds) {
    [void]$ComponentRefsSb.AppendLine("      <ComponentRef Id=`"$cid`" />")
}
[void]$ComponentRefsSb.AppendLine("      <ComponentRef Id=`"ProtocolAndAssoc`" />")
[void]$ComponentRefsSb.AppendLine("      <ComponentRef Id=`"ApplicationShortcut`" />")

$WxsContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="TallyIsle"
           Manufacturer="TallyIsle"
           Version="$MsiVersion"
           UpgradeCode="6D8A4E72-9F31-4C5B-8A10-2E7B9C4D5F61"
           Scope="perUser">
    <MajorUpgrade AllowSameVersionUpgrades="yes"
                  DowngradeErrorMessage="A newer version of TallyIsle is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Icon Id="AppIcon.ico" SourceFile="$EscapedIconPath" />
    <Property Id="ARPPRODUCTICON" Value="AppIcon.ico" />

    <StandardDirectory Id="LocalAppDataFolder">
      <Directory Id="INSTALLFOLDER" Name="TallyIsle">
$AppTreeXml        <Component Id="ProtocolAndAssoc" Guid="A3B8F2C1-4D5E-4F6A-9B7C-8D9E0F1A2B3C">
          <RegistryValue Root="HKCU" Key="Software\Classes\tallyisle" Type="string" Value="URL:TallyIsle Protocol" KeyPath="yes" />
          <RegistryValue Root="HKCU" Key="Software\Classes\tallyisle" Name="URL Protocol" Type="string" Value="" />
          <RegistryValue Root="HKCU" Key="Software\Classes\tallyisle\DefaultIcon" Type="string" Value="&quot;[INSTALLFOLDER]tallyisle.exe&quot;,0" />
          <RegistryValue Root="HKCU" Key="Software\Classes\tallyisle\shell\open\command" Type="string" Value="&quot;[INSTALLFOLDER]tallyisle.exe&quot; &quot;%1&quot;" />
          <RegistryValue Root="HKCU" Key="Software\Classes\.tally" Type="string" Value="TallyIsle.Backup" />
          <RegistryValue Root="HKCU" Key="Software\Classes\TallyIsle.Backup" Type="string" Value="TallyIsle Backup Archive" />
          <RegistryValue Root="HKCU" Key="Software\Classes\TallyIsle.Backup\DefaultIcon" Type="string" Value="&quot;[INSTALLFOLDER]tallyisle.exe&quot;,0" />
          <RegistryValue Root="HKCU" Key="Software\Classes\TallyIsle.Backup\shell\open\command" Type="string" Value="&quot;[INSTALLFOLDER]tallyisle.exe&quot; &quot;%1&quot;" />
        </Component>
      </Directory>
    </StandardDirectory>

    <StandardDirectory Id="ProgramMenuFolder">
      <Directory Id="ApplicationProgramsFolder" Name="TallyIsle">
        <Component Id="ApplicationShortcut" Guid="B4C9E3D2-5E6F-4A7B-8C9D-0E1F2A3B4C5D">
          <Shortcut Id="ApplicationStartMenuShortcut"
                    Name="TallyIsle"
                    Description="Local-first personal accounting and asset manager"
                    Target="[INSTALLFOLDER]tallyisle.exe"
                    WorkingDirectory="INSTALLFOLDER"
                    Icon="AppIcon.ico" />
          <RemoveFolder Id="RemoveApplicationProgramsFolder" On="uninstall" />
          <RegistryValue Root="HKCU" Key="Software\TallyIsle\Installer" Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>

    <Feature Id="MainFeature" Title="TallyIsle" Level="1">
$($ComponentRefsSb.ToString())    </Feature>
  </Package>
</Wix>
"@

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tallyisle-wix-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
try {
    $WxsPath = Join-Path $TempDir "tallyisle.wxs"
    [System.IO.File]::WriteAllText($WxsPath, $WxsContent, (New-Object System.Text.UTF8Encoding($false)))

    $MsiPath = Join-Path $OutDir "TallyIsle-Windows-x64.msi"
    if (Test-Path $MsiPath) {
        Remove-Item -Force $MsiPath
    }

    & wix build -arch x64 -o $MsiPath $WxsPath
    if ($LASTEXITCODE -ne 0) {
        throw "wix build failed with exit code $LASTEXITCODE"
    }
} finally {
    if (Test-Path $TempDir) {
        Remove-Item -Recurse -Force $TempDir
    }
}

# Verify all 3 installers exist and are non-empty
$Outputs = @(
    $ZipPath,
    $SetupExePath,
    (Join-Path $OutDir "TallyIsle-Windows-x64.msi")
)
foreach ($artifact in $Outputs) {
    if (-not (Test-Path $artifact)) {
        throw "Expected Windows artifact missing: $artifact"
    }
    $len = (Get-Item $artifact).Length
    if ($len -le 0) {
        throw "Expected Windows artifact is empty: $artifact"
    }
    Write-Host ("  OK {0} ({1:N0} bytes)" -f (Split-Path -Leaf $artifact), $len)
}

Write-Host "Windows packaging completed successfully."
