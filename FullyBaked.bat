<# : batch part; PowerShell reads everything up to the closing mark as a comment
@echo off
title baked. fully baked tool
set "FB_SELF=%~f0"
powershell -NoProfile -Command "iex ([IO.File]::ReadAllText($env:FB_SELF))"
echo.
pause
exit /b
#>

# The list lives in the repo, so a new baked. pack reaches everyone without a new copy of this tool.
$listUrl = 'https://raw.githubusercontent.com/baked-skate/fully-baked-tool/main/modlist.json'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # PowerShell 5's progress bar slows downloads to a crawl
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Ask($question) { "$(Read-Host "$question (Y/N)")" -match '^\s*y' }

function Finish {
    Write-Host ''
    Write-Host 'Thanks for using the baked. fully baked tool!'
    Write-Host 'Join us on Discord: https://discord.bakedskate.org'
    exit
}

Write-Host ''
Write-Host ' baked. fully baked tool'
Write-Host ''
Write-Host ' Installs every baked. mod, and the mods we recommend, into ReSkate.'
Write-Host ' Run it again any time to get new packs and updates.'
Write-Host ''

# Mods can't be replaced while the game or the launcher has them open.
if (Get-Process Skate, ReSkateLauncher -ErrorAction SilentlyContinue) {
    Write-Host 'skate. or the ReSkate launcher is open. Close both, then run this again.'
    Finish
}

# Where ReSkate may be: the launcher path the game saves for Discord's Join button each time it starts,
# the folder this tool is in, then the usual spots.
$places = @()
$join = (Get-ItemProperty 'HKCU:\Software\Classes\discord-1558319241114025986\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
if ($join -match '^"([^"]+)"') { $places += Split-Path $Matches[1] }
$places += Split-Path $env:FB_SELF
foreach ($drive in Get-PSDrive -PSProvider FileSystem) { $places += "$($drive.Root)ReSkate", "$($drive.Root)Games\ReSkate" }

$game = $null
$seen = @()
foreach ($place in $places) {
    $place = $place.TrimEnd('\')
    if ($seen -contains $place -or -not (Test-Path -LiteralPath "$place\ReSkateLauncher.exe")) { continue }
    $seen += $place
    Write-Host 'Found ReSkate at:'
    Write-Host "  $place"
    if (Ask 'Is this the ReSkate you play') { $game = $place; break }
    Write-Host ''
}
while (-not $game) {
    Write-Host 'Drag your ReSkate folder (the one with ReSkateLauncher.exe) onto this window, then press Enter.'
    $typed = "$(Read-Host 'Or press Enter on its own to quit')".Trim().Trim('"')
    if (-not $typed) { Finish }
    if (Test-Path -LiteralPath $typed -PathType Leaf) { $typed = Split-Path $typed }
    if (Test-Path -LiteralPath "$typed\ReSkateLauncher.exe") { $game = $typed.TrimEnd('\') }
    else { Write-Host "There's no ReSkateLauncher.exe in $typed." }
}

# ReSkate loads ModData\Default\Mods instead when the game folder has a ModData folder.
$mods = if (Test-Path -LiteralPath "$game\ModData" -PathType Container) { "$game\ModData\Default\Mods" } else { "$game\Mods" }
Write-Host ''
Write-Host "Installing into $mods"
Write-Host ''

try { $list = (Invoke-WebRequest -UseBasicParsing $listUrl).Content | ConvertFrom-Json }
catch {
    Write-Host "Couldn't download the mod list: $($_.Exception.Message)"
    Write-Host 'Check your internet connection and try again. If it keeps happening, tell us in the Discord.'
    Finish
}

# baked. first, then the recommended ones; dependencies join the end as they turn up.
$queue = [Collections.Generic.List[string]]::new()
foreach ($entry in @($list.baked) + @($list.recommended)) { if ($entry -and -not $queue.Contains($entry)) { $queue.Add($entry) } }

# One line per mod, its name padded into a column; a longer dependency name just pushes its status along.
$width = 4 + ($queue | ForEach-Object { ($_ -replace '^[^-]*-').Length } | Measure-Object -Maximum).Maximum

$work = "$mods\.fully-baked"
$changed = 0; $skipped = 0; $failed = 0
for ($i = 0; $i -lt $queue.Count; $i++) {
    $fullName = $queue[$i]
    Write-Host ('  ' + ($fullName -replace '^[^-]*-').PadRight($width)) -NoNewline
    try {
        # It becomes a folder name and part of a URL, so only a plain Owner-Name gets through.
        if ($fullName -notmatch '^([A-Za-z0-9_]+)-([A-Za-z0-9_]+)$') { throw "that isn't a Thunderstore package name" }
        $owner, $name = $Matches[1], $Matches[2]
        $package = Invoke-RestMethod "https://thunderstore.io/api/experimental/package/$owner/$name/"
        if ($package.is_deprecated) { Write-Host 'skipped (deprecated on Thunderstore)'; $skipped++; continue }
        $version = $package.latest.version_number
        if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Thunderstore gave no version of it" }
        foreach ($dependency in $package.latest.dependencies) {
            $dependency = $dependency -replace '-[^-]*$' # Owner-Name-1.2.3
            if (-not $queue.Contains($dependency)) { $queue.Add($dependency) }
        }

        # The launcher's own folder for a package: its full name, cut to 64 characters.
        $folder = $fullName.Substring(0, [Math]::Min(64, $fullName.Length))
        $target = "$mods\$folder"
        $have = try { (Get-Content -LiteralPath "$target\manifest.json" -Raw -Encoding UTF8 | ConvertFrom-Json).version_number } catch { $null }
        if (($have -as [version]) -ge ($version -as [version])) { Write-Host 'skipped'; $skipped++; continue }

        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        # New-Item gives the long form of the path, as Get-ChildItem does below, so the two compare.
        $unpacked = (New-Item -ItemType Directory -Path "$work\$folder" -Force).FullName
        # Built from the name, not taken from Thunderstore's answer, so downloads only come from thunderstore.io.
        Invoke-WebRequest -UseBasicParsing "https://thunderstore.io/package/download/$owner/$name/$version/" -OutFile "$work\$folder.zip"
        # .NET refuses entries that would land outside the folder.
        [IO.Compression.ZipFile]::ExtractToDirectory("$work\$folder.zip", $unpacked)

        # As the launcher installs: the shallowest folder holding something the game loads is the mod,
        # and the package's own files at the top go in with it.
        $roots = foreach ($file in Get-ChildItem -LiteralPath $unpacked -Recurse -File) {
            if ($file.Name -in 'layout.toc', 'reskate-levels.json', 'reskate-plugin.json') { $file.DirectoryName }
            elseif ($file.Name -like '*.park.json' -and $file.Directory.Name -eq 'parks') { $file.Directory.Parent.FullName }
        }
        $root = $roots | Sort-Object { $_.Split('\').Count } | Select-Object -First 1
        if (-not $root) { $root = $unpacked }
        if ($root -ne $unpacked) {
            Get-ChildItem -LiteralPath $unpacked -File | Where-Object Name -in 'manifest.json', 'icon.png', 'README.md', 'CHANGELOG.md' |
                Copy-Item -Destination $root -Force
        }

        # The launcher writes the team into the manifest too; its Mods page shows it.
        $manifest = "$root\manifest.json"
        $info = try { Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
        if ($info -and -not $info.author) {
            $info | Add-Member author $owner
            [IO.File]::WriteAllText($manifest, ($info | ConvertTo-Json -Depth 20))
        }

        $updating = Test-Path -LiteralPath $target
        if ($updating) { Remove-Item -LiteralPath $target -Recurse -Force }
        Move-Item -LiteralPath $root -Destination $target
        Write-Host $(if ($updating) { 'updated' } else { 'installed' })
        $changed++
    } catch {
        Write-Host "failed: $($_.Exception.Message)"
        $failed++
    }
}
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host "Done: $changed installed or updated, $skipped skipped, $failed failed."
if ($failed) { Write-Host 'Run this again to retry the ones that failed.' }
Write-Host "Start ReSkate as usual. New mods load turned on; any you switched off in the launcher stay off."
Finish
