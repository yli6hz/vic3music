#requires -Version 5.1
<#
    Victoria 3 自定义音乐 Mod 一键部署脚本
    ----------------------------------------
    功能（全部自动，无需改任何路径）：
      1. 自动定位 Victoria 3 安装目录（本目录在游戏目录内 / Steam 注册表 + libraryfolders.vdf）
      2. 自动读取游戏版本（launcher-settings.json 的 rawVersion），并写入
         descriptor.mod 的 supported_version 和 .metadata/metadata.json 的
         supported_game_version（格式如 1.14.*）
      3. 自动把本文件夹安装到文档目录的 Paradox Interactive\Victoria 3\mod\
         （创建目录联接，本文件夹仍是唯一数据源）
      4. 自动查找 ffmpeg：系统 PATH -> 本文件夹 tools\ -> 常见安装位置；
         找不到时可自动下载到 tools\（依赖随本文件夹保存）
      5. 扫描 original\ 里的音频，非 ogg 自动转码，并生成
         曲目定义 / 播放器分类 / 中英文曲名本地化
    用法：双击 一键部署.bat（内部调用本脚本）
#>
param(
    [switch]$NonInteractive   # 自动化/无人值守模式：不询问，跳过下载
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ModDir     = $PSScriptRoot
$ModId      = 'my_custom_music'
$CatId      = 'my_custom_music_category'
$SteamAppId = 529340   # Victoria 3
$AudioExts  = @('.m4a', '.mp3', '.flac', '.wav', '.aac', '.m4b', '.wma', '.ogg')
$SkipSuffix = '.corrupt'
$TitleCN    = '我的自定义音乐'
$TitleEN    = 'My Custom Music'

function Info([string]$m) { Write-Host $m }
function Ok([string]$m)   { Write-Host $m -ForegroundColor Green }
function Warn([string]$m) { Write-Host $m -ForegroundColor Yellow }

function Write-ModText([string]$Path, [string]$Text) {
    # 统一以 UTF-8 BOM 写出（Paradox 解析器要求）
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

Info ''
Info '==================== Victoria 3 自定义音乐 Mod 一键部署 ===================='
Info ('Mod 目录: ' + $ModDir)

# ---------- 1. 自动定位 Victoria 3 安装目录 ----------
$gameRoot = $null

# 1a. 本文件夹若放在游戏目录里（或其子目录），逐层向上找 launcher-settings.json
$d = $ModDir
while ($d) {
    $cand = Join-Path $d 'launcher\launcher-settings.json'
    if (Test-Path -LiteralPath $cand) {
        try { $ls = Get-Content -LiteralPath $cand -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $ls = $null }
        if ($ls -and $ls.gameId -eq 'victoria3') { $gameRoot = $d; break }
    }
    $p = Split-Path -Parent $d
    if ($p -eq $d) { break }
    $d = $p
}

# 1b. Steam 注册表 + libraryfolders.vdf 兜底（mod 文件夹放在任意位置均可）
if (-not $gameRoot) {
    $steamPath = $null
    try { $steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if ($steamPath) {
        $libs = New-Object System.Collections.Generic.List[string]
        $libs.Add($steamPath)
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs.Add($m.Groups[1].Value)
            }
        }
        foreach ($lib in $libs) {
            $acf = Join-Path $lib ('steamapps\appmanifest_{0}.acf' -f $SteamAppId)
            if (-not (Test-Path -LiteralPath $acf)) { continue }
            $m2 = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
            if (-not $m2.Success) { continue }
            $cand = Join-Path $lib ('steamapps\common\' + $m2.Groups[1].Value)
            if (Test-Path -LiteralPath (Join-Path $cand 'launcher\launcher-settings.json')) { $gameRoot = $cand; break }
        }
    }
}

# ---------- 2. 自动读取游戏版本 + 文档目录位置 ----------
$gameDataPath = $null
$gameVersion  = $null
if ($gameRoot) {
    $ls = Get-Content -LiteralPath (Join-Path $gameRoot 'launcher\launcher-settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $gameDataPath = $ls.gameDataPath
    if ($ls.rawVersion -match '^(\d+\.\d+)') { $gameVersion = '{0}.*' -f $Matches[1] }
    Ok ('检测到 Victoria 3 安装目录: ' + $gameRoot)
    if ($gameVersion) { Ok ('检测到游戏版本: ' + $gameVersion) }
} else {
    Warn '未检测到 Victoria 3 安装目录，游戏版本将保持现状（不影响其他功能）。'
}

$docs = [Environment]::GetFolderPath('MyDocuments')   # 兼容 OneDrive 重定向的文档目录
if (-not $gameDataPath) { $gameDataPath = '%USER_DOCUMENTS%/Paradox Interactive/Victoria 3' }
$gameDataRoot = $gameDataPath -replace '%USER_DOCUMENTS%', $docs
$gameDataRoot = $gameDataRoot -replace '%USER_PROFILE%', $env:USERPROFILE
$gameDataRoot = $gameDataRoot -replace '/', '\'
$installDir = Join-Path $gameDataRoot ('mod\' + $ModId)
Info ('Mod 部署位置: ' + $installDir)

# ---------- 3. 安装：创建目录联接（本文件夹仍是唯一数据源） ----------
$parent = Split-Path -Parent $installDir
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

if ($ModDir.TrimEnd('\') -ieq $installDir.TrimEnd('\')) {
    Ok 'Mod 已直接位于游戏 mod 目录，无需安装。'
} elseif (Test-Path -LiteralPath $installDir) {
    $item = Get-Item -LiteralPath $installDir -Force
    $isJunction = ($item.LinkType -eq 'Junction')
    $pointsHere = $false
    if ($isJunction -and $item.Target) {
        try { $pointsHere = ((Get-Item -LiteralPath $item.Target -Force).FullName.TrimEnd('\') -ieq $ModDir.TrimEnd('\')) } catch {}
    }
    if ($pointsHere) {
        Ok 'Mod 已安装（联接指向本目录）。'
    } elseif ($isJunction) {
        Warn ('部署位置已有联接，原目标: ' + $item.Target + ' ，将重建为本目录。')
        & cmd.exe /c rmdir "$installDir" | Out-Null
        New-Item -ItemType Junction -Path $installDir -Value $ModDir | Out-Null
        Ok 'Mod 联接已重建，安装完成。'
    } else {
        Warn '部署位置已存在同名普通文件夹，为避免覆盖数据已跳过安装。'
        Warn ('如需重新部署，请手动删除或改名: ' + $installDir)
    }
} else {
    New-Item -ItemType Junction -Path $installDir -Value $ModDir | Out-Null
    Ok '已创建目录联接，Mod 安装完成。'
}

# ---------- 4. 把游戏版本写进 descriptor.mod / metadata.json ----------
if ($gameVersion) {
    $descPath = Join-Path $ModDir 'descriptor.mod'
    if (Test-Path -LiteralPath $descPath) {
        $t = Get-Content -LiteralPath $descPath -Raw
        $t = [regex]::Replace($t, 'supported_version\s*=\s*"[^"]*"', ('supported_version="{0}"' -f $gameVersion))
        [System.IO.File]::WriteAllText($descPath, $t, (New-Object System.Text.UTF8Encoding($false)))
        Ok ('descriptor.mod supported_version -> ' + $gameVersion)
    }
    $metaPath = Join-Path $ModDir '.metadata\metadata.json'
    if (Test-Path -LiteralPath $metaPath) {
        $t = Get-Content -LiteralPath $metaPath -Raw
        $t = [regex]::Replace($t, '"supported_game_version"\s*:\s*"[^"]*"', ('"supported_game_version": "{0}"' -f $gameVersion))
        [System.IO.File]::WriteAllText($metaPath, $t, (New-Object System.Text.UTF8Encoding($false)))
        Ok ('metadata.json supported_game_version -> ' + $gameVersion)
    }
}

# ---------- 5. 查找 / 自动下载 ffmpeg ----------
function Find-Ffmpeg {
    $c = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }
    $toolsDir = Join-Path $ModDir 'tools'
    if (Test-Path -LiteralPath $toolsDir) {
        $hit = Get-ChildItem -LiteralPath $toolsDir -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $pf86 = ${env:ProgramFiles(x86)}
    $cands = @(
        'C:\ffmpeg\bin\ffmpeg.exe',
        (Join-Path $env:ProgramFiles 'ffmpeg\bin\ffmpeg.exe'),
        ($(if ($pf86) { Join-Path $pf86 'ffmpeg\bin\ffmpeg.exe' } else { $null })),
        (Join-Path $env:LOCALAPPDATA 'ffmpeg\bin\ffmpeg.exe')
    )
    foreach ($c2 in $cands) { if ($c2 -and (Test-Path -LiteralPath $c2)) { return $c2 } }
    $hits = Get-ChildItem 'C:\ffmpeg' -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hits) { return $hits.FullName }
    return $null
}

$ffmpeg = Find-Ffmpeg
if (-not $ffmpeg) {
    Warn '未找到 ffmpeg（用于把 mp3/m4a/flac 等转成游戏需要的 ogg）。'
    $answer = 'n'
    if ($NonInteractive) {
        Warn '无人值守模式：跳过自动下载。'
    } else {
        try { $answer = (Read-Host '是否现在自动下载 ffmpeg 到本文件夹 tools\ 内？(y/n，约 90MB，仅首次需要)').Trim().ToLower() } catch { $answer = 'n' }
    }
    if ($answer -eq 'y' -or $answer -eq 'yes') {
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
            $zip = Join-Path $env:TEMP 'ffmpeg-essentials.zip'
            $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
            Info ('正在下载 ffmpeg（首次约 90MB，请耐心等待）...')
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            $tools = Join-Path $ModDir 'tools'
            New-Item -ItemType Directory -Path $tools -Force | Out-Null
            Info '正在解压到 tools\ ...'
            Expand-Archive -LiteralPath $zip -DestinationPath $tools -Force
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            $ffmpeg = Find-Ffmpeg
        } catch {
            Warn ('自动下载失败: ' + $_.Exception.Message)
            Warn '可手动下载 ffmpeg，把 ffmpeg.exe 所在 bin 目录整体放到本文件夹 tools\ 下。'
        }
    }
}
if ($ffmpeg) { Ok ('使用 ffmpeg: ' + $ffmpeg) }
else { Warn '没有 ffmpeg：只有 .ogg 文件可以直接使用，其他格式将无法转码。' }

# ---------- 6. 扫描 original\ 并转码 ----------
$srcDir = Join-Path $ModDir 'original'
New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
$catDir    = Join-Path $ModDir 'music\music_player_categories'
$locEnDir  = Join-Path $ModDir 'localization\english'
$locCnDir  = Join-Path $ModDir 'localization\simp_chinese'
foreach ($dd in @($catDir, $locEnDir, $locCnDir)) {
    if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
}

Info ''
Info ('正在扫描音乐文件: ' + $srcDir)
$sources = @(Get-ChildItem -LiteralPath $srcDir -File -ErrorAction SilentlyContinue | Where-Object {
    $lower = $_.Name.ToLower()
    ($AudioExts -contains $_.Extension.ToLower()) -and
    (-not $lower.StartsWith('.')) -and
    (-not $lower.EndsWith($SkipSuffix))
} | Sort-Object Name)

$converted = @(); $copied = @(); $existed = @(); $failed = @()
foreach ($s in $sources) {
    $stem = [regex]::Replace([System.IO.Path]::GetFileNameWithoutExtension($s.Name), '[ \t]+', '_')
    $dst  = Join-Path $ModDir ($stem + '.ogg')
    if (Test-Path -LiteralPath $dst) { $existed += $s.Name; continue }
    if ($s.Extension.ToLower() -eq '.ogg') {
        Copy-Item -LiteralPath $s.FullName -Destination $dst -Force
        $copied += $s.Name
        continue
    }
    if (-not $ffmpeg) { $failed += ,@($s.Name, '未找到 ffmpeg，无法转码'); continue }
    $tmp = Join-Path $ModDir ($stem + '.part.ogg')
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    & $ffmpeg -y -loglevel error -err_detect ignore_err -i $s.FullName -vn -c:a libvorbis -q:a 6 $tmp 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 100000)
    if ($ok) {
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
        Move-Item -LiteralPath $tmp -Destination $dst -Force
        $converted += $s.Name
    } else {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $failed += ,@($s.Name, '转码失败（文件可能损坏）')
    }
}

# ---------- 7. 生成曲目定义 / 分类 / 本地化 ----------
$oggFiles = @(Get-ChildItem -LiteralPath $ModDir -File -Filter '*.ogg' -ErrorAction SilentlyContinue | Where-Object {
    (-not $_.Name.StartsWith('.')) -and (-not $_.Name.ToLower().EndsWith('.part.ogg'))
} | Sort-Object Name)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('##### 自动生成 by 一键部署脚本，向 original\ 添加歌曲后重新运行即可 #####')
$lines.Add('')
$trackIds = New-Object System.Collections.Generic.List[string]
$i = 1
foreach ($f in $oggFiles) {
    $tid = 'custom_track_{0:d3}' -f $i
    $trackIds.Add($tid)
    $lines.Add('{0} = {{' -f $tid)
    $lines.Add(("`tname = `"{0}_name`"" -f $tid))
    $lines.Add("`tmusic = `"file:/{0}`"" -f $f.Name)
    $lines.Add("`tpause_factor = 50")
    $lines.Add("`tmood = yes")
    $lines.Add("`tcan_be_interrupted = yes")
    $lines.Add('')
    $i++
}
if ($oggFiles.Count -eq 0) {
    $lines.Add('# 还没有歌曲，请把 .m4a/.mp3/.flac 等音频放进 original\ 子文件夹后重新运行 一键部署.bat')
    $lines.Add('')
}
Write-ModText (Join-Path $ModDir ('music\' + $ModId + '.txt')) ([string]::Join("`n", $lines))

$cat = New-Object System.Collections.Generic.List[string]
$cat.Add('category = {')
$cat.Add("`tid = `"$CatId`"")
$cat.Add("`tname = `"$($CatId)_name`"")
$cat.Add("`ttracks = {")
foreach ($tid in $trackIds) { $cat.Add("`t`t`"$tid`"") }
$cat.Add("`t}")
$cat.Add('}')
Write-ModText (Join-Path $catDir ('zzz_' + $ModId + '.txt')) ([string]::Join("`n", $cat) + "`n")

function Write-Loc([string]$DirPath, [string]$Lang, [string]$Title) {
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('l_{0}:' -f $Lang))
    $out.Add((' {0}_name:0 "{1}"' -f $CatId, $Title))
    $j = 1
    foreach ($f in $oggFiles) {
        $t = ([System.IO.Path]::GetFileNameWithoutExtension($f.Name)) -replace '_', ' '
        $out.Add((' custom_track_{0:d3}_name:0 "{1}"' -f $j, $t))
        $j++
    }
    if ($oggFiles.Count -eq 0) {
        $out.Add(' custom_music_empty:0 "(还没有歌曲，请往 original\ 放入音频后重新运行 一键部署.bat)"')
    }
    Write-ModText (Join-Path $DirPath ('{0}_l_{1}.yml' -f $ModId, $Lang)) ([string]::Join("`n", $out) + "`n")
}
Write-Loc $locCnDir 'simp_chinese' $TitleCN
Write-Loc $locEnDir 'english' $TitleEN

# ---------- 8. 汇总报告 ----------
Info ''
Info ('============================================================')
Ok ('完成！游戏内曲目共 ' + $oggFiles.Count + ' 首。')
if ($converted.Count -gt 0) {
    Info ('本次新转码 ' + $converted.Count + ' 首：')
    foreach ($n in $converted) { Info ('   [+] ' + $n) }
}
if ($copied.Count -gt 0) {
    Info ('本次直接复制 .ogg ' + $copied.Count + ' 首：')
    foreach ($n in $copied) { Info ('   [c] ' + $n) }
}
if ($existed.Count -gt 0) { Info ('已存在、跳过 ' + $existed.Count + ' 首。') }
if ($failed.Count -gt 0) {
    Warn ('!! 以下 ' + $failed.Count + ' 个文件转码失败，请重新下载或改名为 .corrupt 跳过：')
    foreach ($pair in $failed) { Warn ('   [x] ' + $pair[0] + ' —— ' + $pair[1]) }
}
Info ''
Info '下一步：'
Info '  1. 把音乐文件放进 original\ 文件夹，再双击一次 一键部署.bat（有 ffmpeg 时自动转码）'
Info ('  2. 打开游戏启动器 -> 播放集(Playset)，勾选 "' + $TitleEN + '"')
Info ('  3. 进入游戏后点右下角音乐播放器，切换到 "' + $TitleCN + '" 分类')
Info '============================================================'
