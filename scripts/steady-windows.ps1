#requires -Version 5.1
<#
.SYNOPSIS
    Windows 10/11 的稳质、低噪声个性化脚本。

.DESCRIPTION
    以“核心稳定、结构清晰、行动有余量”为原则调整当前用户的 Windows：
    - 深色、克制的外观；
    - 精简任务栏、开始菜单和系统建议；
    - 更透明可靠的资源管理器；
    - 保留通知、安全、更新、UAC 和系统服务；
    - 每次应用前精确记录注册表值，可预览、可恢复；
    - 可选创建独立电源计划，不修改原电源计划。

    默认 Action 为 Preview，不会修改系统。大部分设置无需管理员权限。

.EXAMPLE
    .\steady-windows.ps1
    预览将要进行的调整。

.EXAMPLE
    .\steady-windows.ps1 -Action Apply
    交互确认后应用，并自动备份。

.EXAMPLE
    .\steady-windows.ps1 -Action Apply -Wallpaper "D:\Pictures\calm.jpg" -IncludePowerPlan
    应用设置、使用指定壁纸，并创建独立的“Steady Balanced”电源计划。

.EXAMPLE
    .\steady-windows.ps1 -Action ListBackups
    列出可恢复的备份。

.EXAMPLE
    .\steady-windows.ps1 -Action Restore
    恢复最近一次备份。

.EXAMPLE
    .\steady-windows.ps1 -Action Restore -Backup "20260728-213000"
    恢复指定备份。
#>

[CmdletBinding()]
param(
    [ValidateSet("Preview", "Apply", "Restore", "ListBackups")]
    [string]$Action = "Preview",

    [string]$Wallpaper,

    [string]$Backup,

    [switch]$IncludePowerPlan,

    [switch]$SkipExplorerRestart,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProductName = "SteadyWindows"
$script:DataRoot = Join-Path $env:LOCALAPPDATA $script:ProductName
$script:BackupRoot = Join-Path $script:DataRoot "Backups"
$script:LogRoot = Join-Path $script:DataRoot "Logs"
$script:CurrentLog = $null

function Write-SteadyLog {
    param(
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "CHANGE")]
        [string]$Level,
        [string]$Message
    )

    $colors = @{
        INFO   = "Gray"
        OK     = "Green"
        WARN   = "Yellow"
        ERROR  = "Red"
        CHANGE = "Cyan"
    }
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line -ForegroundColor $colors[$Level]

    if ($script:CurrentLog) {
        $timestamped = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $line
        Add-Content -LiteralPath $script:CurrentLog -Value $timestamped -Encoding UTF8
    }
}

function Assert-Windows {
    $isWindowsPlatform = $env:OS -eq "Windows_NT"
    if (-not $isWindowsPlatform) {
        throw "此脚本只能在 Windows 10/11 上运行。"
    }

    $versionKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $buildText = (Get-ItemProperty -LiteralPath $versionKey -Name CurrentBuildNumber).CurrentBuildNumber
    $build = [int]$buildText
    if ($build -lt 10240) {
        throw "仅支持 Windows 10/11；当前系统 Build 为 $build。"
    }
    return $build
}

function Initialize-DataFolders {
    foreach ($folder in @($script:DataRoot, $script:BackupRoot, $script:LogRoot)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }
}

function New-RegSetting {
    param(
        [string]$Category,
        [string]$Path,
        [string]$Name,
        [ValidateSet("String", "ExpandString", "Binary", "DWord", "MultiString", "QWord")]
        [string]$Type,
        [AllowNull()]
        [object]$Value,
        [string]$Description,
        [int]$MinBuild = 10240,
        [int]$MaxBuild = [int]::MaxValue
    )

    [pscustomobject]@{
        Category    = $Category
        Path        = $Path
        Name        = $Name
        Type        = $Type
        Value       = $Value
        Description = $Description
        MinBuild    = $MinBuild
        MaxBuild    = $MaxBuild
    }
}

function Get-SteadySettings {
    param(
        [int]$Build,
        [string]$WallpaperPath
    )

    $settings = @(
        # 外观：深色、稳定、低视觉噪声。
        (New-RegSetting "外观" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" "DWord" 0 "应用使用深色模式"),
        (New-RegSetting "外观" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme" "DWord" 0 "系统界面使用深色模式"),
        (New-RegSetting "外观" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" "DWord" 0 "关闭透明效果，减少干扰与 GPU 开销"),
        (New-RegSetting "外观" "HKCU:\Software\Microsoft\Windows\DWM" "ColorPrevalence" "DWord" 0 "标题栏保持克制，不铺满强调色"),
        (New-RegSetting "外观" "HKCU:\Control Panel\Desktop" "DragFullWindows" "String" "1" "拖动窗口时显示完整内容"),
        (New-RegSetting "外观" "HKCU:\Control Panel\Desktop" "MenuShowDelay" "String" "180" "缩短菜单响应延迟但保留从容感"),

        # 资源管理器：信息透明、核心路径清楚，同时保护系统文件。
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" "DWord" 0 "显示文件扩展名"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Hidden" "DWord" 1 "显示隐藏文件"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSuperHidden" "DWord" 0 "继续隐藏受保护的系统文件"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "LaunchTo" "DWord" 1 "资源管理器默认打开“此电脑”"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowStatusBar" "DWord" 1 "显示状态栏"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState" "FullPath" "DWord" 1 "标题栏显示完整路径"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SeparateProcess" "DWord" 1 "文件夹窗口使用独立进程，提高故障隔离"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "UseCompactMode" "DWord" 1 "使用紧凑布局" 22000),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" "ShowRecent" "DWord" 0 "主页不堆积最近文件"),
        (New-RegSetting "资源管理器" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" "ShowFrequent" "DWord" 0 "主页不堆积常用文件夹"),

        # 多任务：保留好用的系统能力，把界面入口收静。
        (New-RegSetting "多任务" "HKCU:\Control Panel\Desktop" "WindowArrangementActive" "String" "1" "启用窗口贴靠"),
        (New-RegSetting "多任务" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssist" "DWord" 1 "启用贴靠建议"),
        (New-RegSetting "多任务" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapAssistFlyout" "DWord" 1 "启用贴靠布局"),
        (New-RegSetting "多任务" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "SnapBar" "DWord" 1 "启用屏幕顶部贴靠栏" 22000),
        (New-RegSetting "多任务" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "VirtualDesktopAltTabFilter" "DWord" 1 "Alt+Tab 仅显示当前虚拟桌面窗口"),
        (New-RegSetting "多任务" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "VirtualDesktopTaskbarFilter" "DWord" 1 "任务栏仅显示当前虚拟桌面窗口"),

        # 任务栏：只保留稳定入口，不用策略锁死用户选择。
        (New-RegSetting "任务栏" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" "DWord" 1 "搜索收为图标"),
        (New-RegSetting "任务栏" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" "DWord" 0 "隐藏任务视图按钮，快捷键仍可用"),
        (New-RegSetting "任务栏" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarAl" "DWord" 0 "Windows 11 任务栏左对齐" 22000),
        (New-RegSetting "任务栏" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" "DWord" 0 "隐藏 Windows 11 小组件按钮" 22000),
        (New-RegSetting "任务栏" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarMn" "DWord" 0 "隐藏 Windows 11 聊天按钮" 22000),

        # 开始菜单与通知：关闭系统自我推广，保留真正的通知能力。
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" "DWord" 0 "关闭开始菜单在线推荐"),
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_AccountNotifications" "DWord" 0 "关闭开始菜单账户推广通知"),
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SoftLandingEnabled" "DWord" 0 "关闭 Windows 使用技巧弹窗"),
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" "DWord" 0 "关闭系统面板建议"),
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-310093Enabled" "DWord" 0 "关闭设置应用中的推荐内容"),
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338389Enabled" "DWord" 0 "关闭 Windows 提示与建议"),
        (New-RegSetting "低噪声" "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" "DWord" 0 "关闭登录后的设备完成设置提示"),

        # 隐私：减少个性化广告，但不破坏应用权限和云同步。
        (New-RegSetting "隐私" "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" "DWord" 0 "关闭当前用户广告 ID"),
        (New-RegSetting "隐私" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" "DWord" 0 "关闭基于诊断数据的定制体验")
    )

    if ($WallpaperPath) {
        $settings += @(
            (New-RegSetting "壁纸" "HKCU:\Control Panel\Desktop" "Wallpaper" "String" $WallpaperPath "设置桌面壁纸"),
            (New-RegSetting "壁纸" "HKCU:\Control Panel\Desktop" "WallpaperStyle" "String" "10" "壁纸使用填充方式"),
            (New-RegSetting "壁纸" "HKCU:\Control Panel\Desktop" "TileWallpaper" "String" "0" "关闭壁纸平铺")
        )
    }

    return @($settings | Where-Object { $Build -ge $_.MinBuild -and $Build -le $_.MaxBuild })
}

function Get-RegistryValueSnapshot {
    param(
        [string]$Path,
        [string]$Name
    )

    $snapshot = [ordered]@{
        Path      = $Path
        Name      = $Name
        Exists    = $false
        Kind      = $null
        Format    = $null
        Value     = $null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$snapshot
    }

    $key = Get-Item -LiteralPath $Path
    if ($key.GetValueNames() -notcontains $Name) {
        return [pscustomobject]$snapshot
    }

    $kind = $key.GetValueKind($Name).ToString()
    $value = $key.GetValue(
        $Name,
        $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    )

    $snapshot.Exists = $true
    $snapshot.Kind = $kind
    switch ($kind) {
        "Binary" {
            $snapshot.Format = "Base64"
            $snapshot.Value = [Convert]::ToBase64String([byte[]]$value)
        }
        "MultiString" {
            $snapshot.Format = "StringArray"
            $snapshot.Value = @([string[]]$value)
        }
        default {
            $snapshot.Format = "Scalar"
            $snapshot.Value = $value
        }
    }

    return [pscustomobject]$snapshot
}

function Convert-SnapshotValue {
    param([object]$Snapshot)

    if ($Snapshot.Format -eq "Base64") {
        return [Convert]::FromBase64String([string]$Snapshot.Value)
    }
    if ($Snapshot.Format -eq "StringArray") {
        return [string[]]@($Snapshot.Value)
    }
    return $Snapshot.Value
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Type,
        [AllowNull()]
        [object]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Restore-RegistrySnapshot {
    param([object[]]$Snapshots)

    foreach ($snapshot in $Snapshots) {
        if ([bool]$snapshot.Exists) {
            $value = Convert-SnapshotValue -Snapshot $snapshot
            Set-RegistryValue -Path $snapshot.Path -Name $snapshot.Name -Type $snapshot.Kind -Value $value
        }
        elseif (Test-Path -LiteralPath $snapshot.Path) {
            $key = Get-Item -LiteralPath $snapshot.Path
            if ($key.GetValueNames() -contains $snapshot.Name) {
                Remove-ItemProperty -LiteralPath $snapshot.Path -Name $snapshot.Name -Force
            }
        }
    }
}

function Save-BackupDocument {
    param(
        [object]$Document,
        [string]$Path
    )

    $Document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-BackupDirectories {
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Sort-Object Name -Descending)
}

function Resolve-BackupDirectory {
    param([string]$BackupName)

    $directories = Get-BackupDirectories
    if ($directories.Count -eq 0) {
        throw "没有找到可恢复的备份。"
    }

    if (-not $BackupName) {
        return $directories[0]
    }

    $candidate = Join-Path $script:BackupRoot $BackupName
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "备份不存在：$BackupName"
    }
    return Get-Item -LiteralPath $candidate
}

function Show-SettingsPreview {
    param([object[]]$Settings)

    Write-Host ""
    Write-Host "Steady Windows 配置预览" -ForegroundColor White
    Write-Host ("Windows Build: {0}" -f $script:WindowsBuild) -ForegroundColor DarkGray
    Write-Host ""

    foreach ($group in ($Settings | Group-Object Category)) {
        Write-Host ("[{0}]" -f $group.Name) -ForegroundColor Cyan
        foreach ($setting in $group.Group) {
            $current = Get-RegistryValueSnapshot -Path $setting.Path -Name $setting.Name
            $state = if ($current.Exists) {
                $existing = Convert-SnapshotValue -Snapshot $current
                "当前: {0}" -f ($existing -join ",")
            }
            else {
                "当前: <未设置>"
            }
            Write-Host ("  - {0}" -f $setting.Description)
            Write-Host ("    {0} -> 目标: {1}" -f $state, ($setting.Value -join ",")) -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($IncludePowerPlan) {
        Write-Host "[电源]" -ForegroundColor Cyan
        Write-Host "  - 复制当前电源计划为 Steady Balanced：插电 15/45 分钟关闭屏幕/睡眠，电池 7/20 分钟"
        Write-Host ""
    }

    Write-Host "不会改动：Defender、Windows Update、UAC、防火墙、系统服务、应用权限。" -ForegroundColor Green
}

function Confirm-SteadyAction {
    param(
        [string]$Prompt,
        [string]$ExpectedText
    )

    if ($Force) {
        return
    }

    $answer = Read-Host "$Prompt；输入 $ExpectedText 继续"
    if ($answer -cne $ExpectedText) {
        throw "操作已取消，未修改系统。"
    }
}

function Invoke-PowerCfg {
    param([string[]]$Arguments)

    $output = & powercfg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') 失败：$($output -join ' ')"
    }
    return ($output -join [Environment]::NewLine)
}

function Get-GuidFromText {
    param([string]$Text)

    $match = [regex]::Match($Text, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    if (-not $match.Success) {
        throw "无法从 powercfg 输出中识别电源计划 GUID：$Text"
    }
    return $match.Value
}

function New-SteadyPowerPlan {
    $activeOutput = Invoke-PowerCfg -Arguments @("/getactivescheme")
    $originalGuid = Get-GuidFromText -Text $activeOutput

    $duplicateOutput = Invoke-PowerCfg -Arguments @("/duplicatescheme", $originalGuid)
    $createdGuid = Get-GuidFromText -Text $duplicateOutput

    try {
        Invoke-PowerCfg -Arguments @("/changename", $createdGuid, "Steady Balanced", "清晰响应与合理续航之间保留余量") | Out-Null
        Invoke-PowerCfg -Arguments @("/setactive", $createdGuid) | Out-Null
        Invoke-PowerCfg -Arguments @("/change", "monitor-timeout-ac", "15") | Out-Null
        Invoke-PowerCfg -Arguments @("/change", "monitor-timeout-dc", "7") | Out-Null
        Invoke-PowerCfg -Arguments @("/change", "standby-timeout-ac", "45") | Out-Null
        Invoke-PowerCfg -Arguments @("/change", "standby-timeout-dc", "20") | Out-Null
    }
    catch {
        Invoke-PowerCfg -Arguments @("/setactive", $originalGuid) | Out-Null
        Invoke-PowerCfg -Arguments @("/delete", $createdGuid) | Out-Null
        throw
    }

    return [pscustomobject]@{
        OriginalActiveGuid = $originalGuid
        CreatedGuid        = $createdGuid
    }
}

function Restore-PowerPlan {
    param([object]$PowerPlan)

    if (-not $PowerPlan -or -not $PowerPlan.OriginalActiveGuid) {
        return
    }

    Invoke-PowerCfg -Arguments @("/setactive", [string]$PowerPlan.OriginalActiveGuid) | Out-Null
    if ($PowerPlan.CreatedGuid) {
        try {
            Invoke-PowerCfg -Arguments @("/delete", [string]$PowerPlan.CreatedGuid) | Out-Null
        }
        catch {
            Write-SteadyLog "WARN" "原电源计划已恢复，但未能删除脚本创建的电源计划：$($_.Exception.Message)"
        }
    }
}

function Set-DesktopWallpaper {
    param([string]$Path)

    if (-not $Path) {
        return
    }

    if (-not ("SteadyWindows.NativeMethods" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace SteadyWindows {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SystemParametersInfo(
            uint uiAction,
            uint uiParam,
            string pvParam,
            uint fWinIni
        );
    }
}
"@
    }

    $SPI_SETDESKWALLPAPER = 0x0014
    $SPIF_UPDATEINIFILE = 0x0001
    $SPIF_SENDWININICHANGE = 0x0002
    $ok = [SteadyWindows.NativeMethods]::SystemParametersInfo(
        $SPI_SETDESKWALLPAPER,
        0,
        $Path,
        ($SPIF_UPDATEINIFILE -bor $SPIF_SENDWININICHANGE)
    )
    if (-not $ok) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "壁纸设置失败，Win32 错误码：$code"
    }
}

function Update-WindowsShell {
    if ($SkipExplorerRestart) {
        Write-SteadyLog "INFO" "已跳过 Explorer 重启；部分界面将在下次登录后完全生效。"
        return
    }

    Write-SteadyLog "INFO" "正在重启 Explorer，使任务栏与资源管理器设置生效……"
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 700
    Start-Process explorer.exe
}

function Invoke-Apply {
    param([object[]]$Settings)

    Show-SettingsPreview -Settings $Settings
    Confirm-SteadyAction -Prompt "将修改当前用户设置并自动创建备份" -ExpectedText "APPLY"

    $backupId = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDirectory = Join-Path $script:BackupRoot $backupId
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupFile = Join-Path $backupDirectory "state.json"

    $snapshots = @(
        foreach ($setting in $Settings) {
            Get-RegistryValueSnapshot -Path $setting.Path -Name $setting.Name
        }
    )

    $backupDocument = [ordered]@{
        SchemaVersion = 1
        Product       = $script:ProductName
        BackupId      = $backupId
        CreatedAt     = (Get-Date).ToString("o")
        WindowsBuild  = $script:WindowsBuild
        ComputerName  = $env:COMPUTERNAME
        UserName      = $env:USERNAME
        Registry      = $snapshots
        PowerPlan     = $null
    }
    Save-BackupDocument -Document $backupDocument -Path $backupFile

    try {
        foreach ($setting in $Settings) {
            Set-RegistryValue -Path $setting.Path -Name $setting.Name -Type $setting.Type -Value $setting.Value
            Write-SteadyLog "CHANGE" $setting.Description
        }

        Set-DesktopWallpaper -Path $Wallpaper

        if ($IncludePowerPlan) {
            $backupDocument.PowerPlan = New-SteadyPowerPlan
            Save-BackupDocument -Document $backupDocument -Path $backupFile
            Write-SteadyLog "CHANGE" "已创建并启用独立电源计划 Steady Balanced"
        }

        Update-WindowsShell
        Write-SteadyLog "OK" "配置完成。备份编号：$backupId"
        Write-SteadyLog "INFO" "恢复命令：.\steady-windows.ps1 -Action Restore -Backup `"$backupId`""
    }
    catch {
        Write-SteadyLog "ERROR" "应用过程中发生错误，正在回滚：$($_.Exception.Message)"
        Restore-RegistrySnapshot -Snapshots $snapshots
        if ($backupDocument.PowerPlan) {
            Restore-PowerPlan -PowerPlan $backupDocument.PowerPlan
        }
        try {
            $oldWallpaper = $snapshots | Where-Object {
                $_.Path -eq "HKCU:\Control Panel\Desktop" -and $_.Name -eq "Wallpaper" -and $_.Exists
            } | Select-Object -First 1
            if ($oldWallpaper) {
                Set-DesktopWallpaper -Path ([string](Convert-SnapshotValue -Snapshot $oldWallpaper))
            }
        }
        catch {
            Write-SteadyLog "WARN" "注册表已回滚，但壁纸刷新失败；重新登录后会恢复。"
        }
        throw
    }
}

function Invoke-Restore {
    $backupDirectory = Resolve-BackupDirectory -BackupName $Backup
    $backupFile = Join-Path $backupDirectory.FullName "state.json"
    if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
        throw "备份文件损坏或不完整：$backupFile"
    }

    $document = Get-Content -LiteralPath $backupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($document.Product -ne $script:ProductName -or [int]$document.SchemaVersion -ne 1) {
        throw "不支持的备份格式。"
    }

    Write-Host ""
    Write-Host ("将恢复备份 {0}（创建于 {1}）" -f $document.BackupId, $document.CreatedAt) -ForegroundColor Yellow
    Confirm-SteadyAction -Prompt "当前脚本设置将被恢复为备份前状态" -ExpectedText "RESTORE"

    Restore-RegistrySnapshot -Snapshots @($document.Registry)
    Restore-PowerPlan -PowerPlan $document.PowerPlan

    $wallpaperSnapshot = @($document.Registry) | Where-Object {
        $_.Path -eq "HKCU:\Control Panel\Desktop" -and $_.Name -eq "Wallpaper" -and $_.Exists
    } | Select-Object -First 1
    if ($wallpaperSnapshot) {
        Set-DesktopWallpaper -Path ([string](Convert-SnapshotValue -Snapshot $wallpaperSnapshot))
    }

    Update-WindowsShell
    Write-SteadyLog "OK" "已恢复备份：$($document.BackupId)"
}

function Show-Backups {
    $directories = Get-BackupDirectories
    if ($directories.Count -eq 0) {
        Write-Host "暂无备份。"
        return
    }

    $items = foreach ($directory in $directories) {
        $file = Join-Path $directory.FullName "state.json"
        if (Test-Path -LiteralPath $file) {
            try {
                $document = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                [pscustomobject]@{
                    BackupId     = $document.BackupId
                    CreatedAt    = $document.CreatedAt
                    WindowsBuild = $document.WindowsBuild
                    HasPowerPlan = [bool]$document.PowerPlan
                }
            }
            catch {
                [pscustomobject]@{
                    BackupId     = $directory.Name
                    CreatedAt    = "<损坏>"
                    WindowsBuild = ""
                    HasPowerPlan = $false
                }
            }
        }
    }

    $items | Format-Table -AutoSize
}

try {
    $script:WindowsBuild = Assert-Windows
    Initialize-DataFolders
    $script:CurrentLog = Join-Path $script:LogRoot ("{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Action)

    if ($Wallpaper) {
        if (-not (Test-Path -LiteralPath $Wallpaper -PathType Leaf)) {
            throw "壁纸文件不存在：$Wallpaper"
        }
        $Wallpaper = (Resolve-Path -LiteralPath $Wallpaper).Path
        $supportedExtensions = @(".bmp", ".jpg", ".jpeg", ".png")
        if ([IO.Path]::GetExtension($Wallpaper).ToLowerInvariant() -notin $supportedExtensions) {
            throw "壁纸仅支持 BMP、JPG、JPEG 或 PNG：$Wallpaper"
        }
    }

    switch ($Action) {
        "Preview" {
            $settings = Get-SteadySettings -Build $script:WindowsBuild -WallpaperPath $Wallpaper
            Show-SettingsPreview -Settings $settings
            Write-Host "应用命令：.\steady-windows.ps1 -Action Apply" -ForegroundColor White
        }
        "Apply" {
            $settings = Get-SteadySettings -Build $script:WindowsBuild -WallpaperPath $Wallpaper
            Invoke-Apply -Settings $settings
        }
        "Restore" {
            Invoke-Restore
        }
        "ListBackups" {
            Show-Backups
        }
    }
}
catch {
    Write-SteadyLog "ERROR" $_.Exception.Message
    exit 1
}
