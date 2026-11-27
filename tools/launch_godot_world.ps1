param(
    [ValidateSet('wuming', 'youxian')][string]$Map = 'wuming',
    [ValidateSet('vulkan', 'd3d12')][string]$RenderingDriver = '',
    [switch]$Inspect,
    [switch]$LegacyLighting,
    [switch]$ForceImport,
    [switch]$CheckOnly,
    [switch]$NoPause,
    [switch]$VerifyLaunch
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$godotProject = Join-Path $projectRoot 'project'
$godotConsole = Join-Path $PSScriptRoot 'godot\Godot_v4.7.2-stable_win64_console.exe'
$godotWindow = Join-Path $PSScriptRoot 'godot\Godot_v4.7.2-stable_win64.exe'
$logDirectory = Join-Path $projectRoot 'artifacts\wandering-original-worlds-review\launch-logs'
$null = New-Item -ItemType Directory -Path $logDirectory -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$launcherLog = Join-Path $logDirectory ($stamp + '-' + $Map + '-launcher.log')
$runtimeLog = Join-Path $logDirectory ($stamp + '-' + $Map + '-game.log')
$importLog = Join-Path $logDirectory ($stamp + '-' + $Map + '-import.log')

function Write-LaunchStatus([string]$Message) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    Write-Host $line
    [IO.File]::AppendAllText($launcherLog, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($true))
}

function Get-PendingImports {
    $pending = [Collections.Generic.List[string]]::new()
    $cachePath = Join-Path $godotProject '.godot\editor\filesystem_cache10'
    $importSettingHashes = @{}
    if (-not (Test-Path -LiteralPath $cachePath)) {
        $pending.Add('Initial project scan')
    } else {
        $directory = ''
        foreach ($line in [IO.File]::ReadLines($cachePath)) {
            if ($line -match '^::res://(.*?)::') { $directory = $Matches[1]; continue }
            if ($line -match '^([^:]+)::.*<>0<>0<>([a-fA-F0-9]{32})<>res://\.godot/imported/') {
                $importSettingHashes[$directory + $Matches[1]] = $Matches[2]
            }
        }
    }
    $extensions = @('.glb', '.gltf', '.png', '.jpg', '.jpeg', '.webp', '.svg', '.hdr', '.exr', '.wav', '.ogg', '.mp3')
    foreach ($asset in Get-ChildItem -LiteralPath (Join-Path $godotProject 'assets') -File -Recurse) {
        if ($asset.Extension.ToLowerInvariant() -notin $extensions) { continue }
        $importFile = $asset.FullName + '.import'
        if (-not [IO.File]::Exists($importFile)) { $pending.Add($asset.FullName); continue }
        $metadata = [IO.File]::ReadAllText($importFile)
        $relativePath = $asset.FullName.Substring($godotProject.Length + 1).Replace('\', '/')
        $settingsHash = (Get-FileHash -LiteralPath $importFile -Algorithm MD5).Hash
        if (-not $importSettingHashes.ContainsKey($relativePath) -or $settingsHash -ne $importSettingHashes[$relativePath]) {
            $pending.Add($asset.FullName); continue
        }
        $destinations = @([regex]::Matches($metadata, '"res://(\.godot/imported/[^"\r\n]+)"'))
        if (-not $destinations.Count) { $pending.Add($asset.FullName); continue }
        foreach ($match in $destinations) {
            $cachedAsset = Join-Path $godotProject $match.Groups[1].Value
            if (-not [IO.File]::Exists($cachedAsset)) {
                $pending.Add($asset.FullName); break
            }
            if ($asset.LastWriteTimeUtc -gt [IO.File]::GetLastWriteTimeUtc($cachedAsset)) {
                # Godot intentionally keeps the imported result when only the source
                # timestamp changed. Compare its recorded content digest before importing.
                $digestPath = [IO.Path]::ChangeExtension($cachedAsset, '.md5')
                $expected = if ([IO.File]::Exists($digestPath)) { [regex]::Match([IO.File]::ReadAllText($digestPath), 'source_md5="([a-fA-F0-9]{32})"') } else { $null }
                if ($null -eq $expected -or -not $expected.Success -or (Get-FileHash -LiteralPath $asset.FullName -Algorithm MD5).Hash -ne $expected.Groups[1].Value) {
                    $pending.Add($asset.FullName); break
                }
            }
        }
    }
    return $pending.ToArray()
}

function Start-LaunchChild([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [switch]$Hidden, [string]$OutputLog = '', [string]$ErrorLog = '') {
    # Retain the Process object created by .Start(), including its native handle.
    # Windows PowerShell Start-Process -PassThru may otherwise lose fast exit codes.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.Arguments = $Arguments -join ' '
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = [bool]$Hidden
    if ($Hidden) { $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden }
    $info.RedirectStandardOutput = [bool]$OutputLog
    $info.RedirectStandardError = [bool]$ErrorLog
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $info
    if (-not $child.Start()) { throw ('无法启动：' + $FilePath) }
    $streams = [Collections.Generic.List[IO.Stream]]::new()
    $copies = [Collections.Generic.List[Threading.Tasks.Task]]::new()
    if ($OutputLog) {
        $stream = [IO.File]::Open($OutputLog, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $streams.Add($stream)
        $copies.Add($child.StandardOutput.BaseStream.CopyToAsync($stream))
    }
    if ($ErrorLog) {
        $stream = [IO.File]::Open($ErrorLog, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $streams.Add($stream)
        $copies.Add($child.StandardError.BaseStream.CopyToAsync($stream))
    }
    return [PSCustomObject]@{ Process = $child; Streams = $streams; Copies = $copies }
}

function Complete-LaunchChildLogs($Child) {
    if ($Child.Copies.Count) { [Threading.Tasks.Task]::WaitAll($Child.Copies.ToArray()) }
    foreach ($stream in $Child.Streams) { $stream.Dispose() }
}

function Read-SharedLaunchLog([string]$Path) {
    $stream = $null
    $reader = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        return $reader.ReadToEnd()
    } catch [IO.IOException] {
        # Godot may briefly replace or exclusively open its live log. The caller
        # retries within the original deadline; decoded script errors still fail.
        return $null
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

try {
    $title = if ($Map -eq 'wuming') { '无名岛' } else { '游仙村' }
    Write-LaunchStatus ('正在准备 Godot {0}。首次加载可能需要数十秒，请保留此窗口。' -f $title)
    Write-LaunchStatus ('启动记录：' + $launcherLog)
    if ($RenderingDriver) { Write-LaunchStatus ('本次指定渲染后端：{0} / Forward+；未改项目默认设置。' -f $RenderingDriver) }
    foreach ($required in @($godotConsole, $godotWindow, (Join-Path $godotProject 'project.godot'), (Join-Path $godotProject ('assets\' + $Map + '\world.glb')), (Join-Path $godotProject ('assets\' + $Map + '\collision.glb')))) {
        if (-not [IO.File]::Exists($required)) { throw ('找不到必要文件：' + $required) }
    }
    $pending = @(Get-PendingImports)
    Write-LaunchStatus ('待导入项目：{0}；项目路径：{1}' -f $pending.Count, $godotProject)
    if ($CheckOnly) {
        Write-LaunchStatus '检查结束；本次未启动导入器或游戏。'
        exit 0
    }
    $normalizedProject = $godotProject.Replace('/', '\').ToLowerInvariant()
    $existing = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" | Where-Object {
        $_.CommandLine -and $_.CommandLine.Replace('/', '\').ToLowerInvariant().Contains($normalizedProject) -and $_.CommandLine -notmatch '--headless|--editor'
    })
    $sameMap = @($existing | Where-Object { $_.CommandLine.Contains('--map=' + $Map) })
    if ($sameMap.Count -and -not $VerifyLaunch -and -not $RenderingDriver) {
        Write-LaunchStatus ('此地图已经运行，进程 {0}；请从任务栏切回游戏窗口。可在游戏界面切换地图。' -f $sameMap[0].ProcessId)
        exit 0
    }
    if ($ForceImport -or $pending.Count) {
        if ($existing.Count) { throw '检测到此 Godot 工程仍在运行，资源需要重新导入。请先关闭该工程游戏窗口后再双击入口。' }
        Write-LaunchStatus '正在导入原地图、碰撞和贴图资源；导入完成后自动打开游戏。'
        $importError = Join-Path $logDirectory ($stamp + '-' + $Map + '-import-stderr.log')
        $importOut = Join-Path $logDirectory ($stamp + '-' + $Map + '-import-stdout.log')
        $importArguments = @('--headless', '--editor', '--path', ('"' + $godotProject + '"'), '--import', '--log-file', ('"' + $importLog + '"'))
        if ($RenderingDriver) { $importArguments += @('--rendering-driver', $RenderingDriver, '--rendering-method', 'forward_plus') }
        $importChild = Start-LaunchChild -FilePath $godotConsole -Arguments $importArguments -WorkingDirectory $godotProject -Hidden -OutputLog $importOut -ErrorLog $importError
        $importProcess = $importChild.Process
        $deadline = (Get-Date).AddMinutes(10)
        while (-not $importProcess.WaitForExit(1000)) {
            if ((Get-Date) -gt $deadline) { throw ('资源导入超过十分钟，未终止仍在工作的导入器。请查看：' + $importLog) }
        }
        Complete-LaunchChildLogs $importChild
        $importExitCode = $importProcess.ExitCode
        if ($null -eq $importExitCode -or $importExitCode -ne 0) { throw ('资源导入失败，返回码 {0}。请查看 {1} 和 {2}' -f $importExitCode, $importLog, $importError) }
        $importProcess.Dispose()
        $combinedLog = ''
        foreach ($path in @($importLog, $importError)) { if ([IO.File]::Exists($path)) { $combinedLog += [IO.File]::ReadAllText($path) } }
        if ($combinedLog -match 'SCRIPT ERROR:|Parse Error:|Failed loading resource:') { throw ('导入日志包含脚本/资源错误，请查看：' + $importLog) }
        Write-LaunchStatus '资源导入完成。'
    }
    $gameArguments = @('--path', ('"' + $godotProject + '"'), '--log-file', ('"' + $runtimeLog + '"'))
    if ($RenderingDriver) { $gameArguments += @('--rendering-driver', $RenderingDriver, '--rendering-method', 'forward_plus') }
    if ($VerifyLaunch) { $gameArguments += @('--quit-after', '180', '--resolution', '1280x720') }
    $gameArguments += @('--', ('--map=' + $Map))
    if ($VerifyLaunch) {
        $capturePath = Join-Path $logDirectory ($stamp + '-' + $Map + '-verification.png')
        $gameArguments += @(('--capture=' + '"' + $capturePath + '"'), '--capture-after=2')
    }
    if ($Inspect) { $gameArguments += '--inspect' }
    if ($LegacyLighting) { $gameArguments += '--legacy-lighting' }
    Write-LaunchStatus ('正在加载 {0}，游戏日志：{1}' -f $title, $runtimeLog)
    # Shell-launch the long-lived GUI so it does not retain this launcher's tool
    # stdout/stderr pipes. Retain its handle immediately for early-exit diagnostics.
    $game = Start-Process -FilePath $godotWindow -ArgumentList $gameArguments -WorkingDirectory $godotProject -WindowStyle Normal -PassThru
    $null = $game.Handle
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    $actualDriver = ''
    $actualMethod = ''
    while ((Get-Date) -lt $deadline) {
        if ($game.WaitForExit(1000)) {
            throw ('游戏在载入期间退出，返回码 {0}。请查看：{1}' -f $game.ExitCode, $runtimeLog)
        }
        if ([IO.File]::Exists($runtimeLog)) {
            $contents = Read-SharedLaunchLog $runtimeLog
            if ($null -eq $contents) { continue }
            if ($contents -match 'SCRIPT ERROR:|Parse Error:|Failed loading resource:') { throw ('游戏日志包含脚本/资源错误，请查看：' + $runtimeLog) }
            if ($RenderingDriver -and $contents -match '(?m)^(Vulkan|D3D12)\s+[^\r\n]* - (Forward\+|Mobile) -') {
                $actualDriver = $Matches[1].ToLowerInvariant()
                $actualMethod = $Matches[2]
                if ($actualDriver -ne $RenderingDriver -or $actualMethod -ne 'Forward+') {
                    throw ('实际后端 {0}/{1} 与指定 {2}/Forward+ 不符，请查看：{3}' -f $actualDriver, $actualMethod, $RenderingDriver, $runtimeLog)
                }
            }
            if ($contents -match ('ORIGINAL_PLAY_READY[^\r\n]*' + $Map + '[^\r\n]*supported[=: ]+true')) {
                if (-not $RenderingDriver -or $actualDriver) { $ready = $true; break }
            }
        }
    }
    if ($RenderingDriver -and -not $actualDriver) { throw ('未能从引擎日志确认指定渲染后端；请查看：' + $runtimeLog) }
    if ($RenderingDriver) { Write-LaunchStatus ('引擎日志确认后端：{0} / {1}。' -f $actualDriver, $actualMethod) }
    if ($ready) { Write-LaunchStatus ('{0}已载入，进程 {1}。WASD/方向键行走，Tab 隐藏界面。' -f $title, $game.Id) }
    else { Write-LaunchStatus ('游戏仍在运行，进程 {0}，尚未看到载入完成标志；请等待并查看游戏日志。' -f $game.Id) }
    if ($VerifyLaunch) {
        if (-not $ready) { throw '自动验证未取得场景载入完成标志。' }
        $finishDeadline = (Get-Date).AddMinutes(2)
        while (-not $game.WaitForExit(1000)) {
            if ((Get-Date) -gt $finishDeadline) { throw '自动验证窗口未按预期退出，请查看游戏日志。' }
        }
        $finalLog = Read-SharedLaunchLog $runtimeLog
        if ($game.ExitCode -ne 0 -or $finalLog -match 'ERROR:|SCRIPT ERROR:|Parse Error:|Failed loading resource:') {
            throw ('自动验证失败，退出码：' + $game.ExitCode)
        }
        if (-not [IO.File]::Exists($capturePath)) { throw '自动验证未生成截图。' }
        $report = [ordered]@{ map=$Map; project=$godotProject; engine=$godotWindow; ready=$ready; exit_code=$game.ExitCode; log=$runtimeLog; capture=$capturePath; requested_driver=$RenderingDriver; actual_driver=$actualDriver; actual_method=$actualMethod }
        $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logDirectory ($stamp + '-' + $Map + '-verification.json')) -Encoding UTF8
        Write-LaunchStatus '自动验证通过；独立工程已载入、截图并正常退出。'
    } else {
        Write-LaunchStatus '游戏在独立窗口运行。关闭本启动记录窗口不会关闭游戏。'
    }
    exit 0
} catch {
    Write-LaunchStatus ('启动失败：' + $_.Exception.Message)
    Write-LaunchStatus ('完整记录：' + $launcherLog)
    exit 1
}
