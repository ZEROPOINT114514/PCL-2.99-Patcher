# ===========================================================================
# PCL 2.99.0 下载功能解锁补丁 - 主控脚本
#
# 用法：
#   1) 双击同目录下的「一键解锁.bat」（推荐）
#   2) 或把 "Plain Craft Launcher 2.exe" 拖到「一键解锁.bat」上
#   3) 或在 PowerShell 里： .\unlock.ps1 -ExePath "D:\PCL2\Plain Craft Launcher 2.exe"
#
# 它做什么：
#   把 PCL.PageDownloadInstall::LoaderInit() 里那个"立即抛异常"的假 LoaderTask
#   换成真实的 PCL.ModDownload::DlClientListLoader，从而恢复「下载 -> 原版游戏」。
#   只改这一个方法，其余 IL 逐方法不变（可用 apply_patch.ps1 -NoPatch 复核）。
# ===========================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$ExePath = ''
)

$ErrorActionPreference = 'Stop'
$root    = $PSScriptRoot
$cecil   = Join-Path $root 'Mono.Cecil.dll'
$patcher = Join-Path $root 'apply_patch.ps1'

function Say-Step { param([string]$t) Write-Host ('  > ' + $t) -ForegroundColor Cyan }
function Say-Ok   { param([string]$t) Write-Host ('  [OK] ' + $t) -ForegroundColor Green }
function Say-Warn { param([string]$t) Write-Host ('  [!!] ' + $t) -ForegroundColor Yellow }
function Say-Err  { param([string]$t) Write-Host ('  [XX] ' + $t) -ForegroundColor Red }

Write-Host ''
Write-Host '=========================================' -ForegroundColor White
Write-Host '  PCL 2.99.0  原版下载功能 解锁补丁' -ForegroundColor White
Write-Host '=========================================' -ForegroundColor White
Write-Host ''

# --- 0. 依赖自检 ---------------------------------------------------------
foreach ($dep in @($cecil, $patcher)) {
    if (-not (Test-Path -LiteralPath $dep)) {
        Say-Err ('缺少必要文件：' + (Split-Path $dep -Leaf))
        Say-Err '请确保补丁包完整（unlock.ps1 / apply_patch.ps1 / Mono.Cecil.dll 在同一目录）。'
        exit 1
    }
}

# --- 1. 定位 PCL 主程序 --------------------------------------------------
$exeName = 'Plain Craft Launcher 2.exe'
if (-not $ExePath) {
    $candidates = @(
        (Join-Path $root $exeName),
        (Join-Path (Split-Path $root -Parent) $exeName),
        (Join-Path (Get-Location).Path $exeName)
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $ExePath = $c; break }
    }
}

if (-not $ExePath) {
    Say-Warn '补丁包所在目录没找到 PCL 主程序，请手动选择。'
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = '请选择 PCL 主程序（Plain Craft Launcher 2.exe）'
    $dlg.Filter = 'PCL 主程序|Plain Craft Launcher 2.exe|可执行文件|*.exe'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Say-Err '已取消。'
        exit 1
    }
    $ExePath = $dlg.FileName
}

if (-not (Test-Path -LiteralPath $ExePath)) {
    Say-Err ('找不到文件：' + $ExePath)
    exit 1
}
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
Say-Ok ('目标程序：' + $ExePath)

# --- 2. 版本校验 --------------------------------------------------------
try {
    $asmName = [System.Reflection.AssemblyName]::GetAssemblyName($ExePath)
    $ver = $asmName.Version.ToString()
}
catch {
    Say-Err '无法读取该文件的程序集信息，确认它是 PCL 主程序而不是快捷方式。'
    exit 1
}

if ($ver -ne '2.99.0.0') {
    Say-Err ('当前 PCL 版本为 ' + $ver + '，本补丁只适用于 2.99.0.0。')
    Say-Warn '其他版本 IL 结构不同，强行补丁会失败。请先从官方发布页下载 2.99.0.0。'
    exit 1
}
Say-Ok ('版本校验通过：' + $ver)

# --- 3. 检查是否已经解锁过（幂等） --------------------------------------
Say-Step '检查当前状态…'
Add-Type -Path $cecil
$already = $false
$chkAsm  = $null
try {
    $chkAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($ExePath)
    $chkType = $null
    foreach ($t in $chkAsm.MainModule.GetTypes()) {
        if ($t.FullName -eq 'PCL.PageDownloadInstall') { $chkType = $t; break }
    }
    if ($null -eq $chkType) { throw '未找到 PCL.PageDownloadInstall，程序可能不是 PCL 2.99。' }

    $chkMethod = $null
    foreach ($m in $chkType.Methods) { if ($m.Name -eq 'LoaderInit') { $chkMethod = $m; break } }
    if ($null -eq $chkMethod) { throw '未找到 LoaderInit 方法，版本可能不匹配。' }

    # 判据 A：原版方法里有 ldstr "关闭下载"（假 LoaderTask 的名字），补丁后该指令消失
    $dummyName = [string][char]0x5173 + [string][char]0x95ED + [string][char]0x4E0B + [string][char]0x8F7D
    $hasDummyName  = $false
    # 判据 B：补丁后会引用真实的静态字段 DlClientListLoader
    $hasRealLoader = $false
    foreach ($i in $chkMethod.Body.Instructions) {
        $op = "$($i.Operand)"
        if ($i.OpCode.Name -eq 'ldstr'  -and $op -eq $dummyName) { $hasDummyName = $true }
        if ($i.OpCode.Name -eq 'ldsfld' -and $op.Contains('DlClientListLoader')) { $hasRealLoader = $true }
    }
    if ($hasRealLoader -and (-not $hasDummyName)) { $already = $true }
}
catch {
    Say-Err ('状态检查失败：' + $_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne $chkAsm) { $chkAsm.Dispose() }
}

if ($already) {
    Say-Ok '这个 PCL 已经是解锁版了，无需重复打补丁。'
    Write-Host ''
    Write-Host '  直接启动 PCL，进入「下载 -> 原版游戏」即可。' -ForegroundColor Gray
    Write-Host ''
    exit 0
}
Say-Ok '当前为官方原版，可以打补丁。'

# --- 4. 占用检查 --------------------------------------------------------
$running = Get-Process -Name 'Plain Craft Launcher 2' -ErrorAction SilentlyContinue
if ($running) {
    Say-Warn '检测到 PCL 正在运行，必须先关闭它才能替换程序文件。'
    $answer = Read-Host '  要现在自动关闭 PCL 吗？(Y/N)'
    if ($answer -match '^[Yy]') {
        $running | Stop-Process -Force
        Start-Sleep -Seconds 2
        Say-Ok '已关闭 PCL。'
    }
    else {
        Say-Err '请手动关闭 PCL 后重新运行本补丁。'
        exit 1
    }
}

# --- 5. 备份 ------------------------------------------------------------
$bak = $ExePath + '.bak'
if (Test-Path -LiteralPath $bak) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = $ExePath + '.bak-' + $stamp
}
Copy-Item -LiteralPath $ExePath -Destination $bak -Force
Say-Ok ('已备份原程序：' + (Split-Path $bak -Leaf))

# --- 6. 打补丁（独立进程，隔离 exit 语义） ------------------------------
$tmpOut = Join-Path $env:TEMP ('pcl-unlock-' + [Guid]::NewGuid().ToString('N') + '.exe')
Say-Step '正在改写 IL（约 3-10 秒）…'

$argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InPath "{1}" -OutPath "{2}" -CecilPath "{3}"' -f $patcher, $ExePath, $tmpOut, $cecil
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = 'powershell.exe'
$psi.Arguments              = $argLine
$psi.UseShellExecute        = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

$proc   = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

if (($proc.ExitCode -ne 0) -or (-not (Test-Path -LiteralPath $tmpOut))) {
    Say-Err '补丁失败，原始文件未做任何修改。'
    Write-Host ''
    Write-Host '--- 补丁程序输出（末尾 25 行）---' -ForegroundColor DarkGray
    ($stdout -split "`r?`n" | Select-Object -Last 25) | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
    if ($stderr) { Write-Host $stderr -ForegroundColor DarkGray }
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
    exit 1
}

$checkLine = ($stdout -split "`r?`n" | Where-Object { $_ -match 'ALL CHECKS PASSED' })
if (-not $checkLine) {
    Say-Err '补丁产物未通过内置校验，已放弃替换。'
    ($stdout -split "`r?`n" | Select-Object -Last 20) | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
    exit 1
}
Say-Ok 'IL 改写完成，7 项自校验全部通过。'

# --- 7. 替换 ------------------------------------------------------------
try {
    Copy-Item -LiteralPath $tmpOut -Destination $ExePath -Force
}
catch {
    Say-Err ('替换失败：' + $_.Exception.Message)
    Say-Warn ('补丁产物保留在：' + $tmpOut + '，可手动复制覆盖。')
    exit 1
}
Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue

# --- 8. 结果 ------------------------------------------------------------
$newLen  = (Get-Item -LiteralPath $ExePath).Length
$newHash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash

Write-Host ''
Write-Host '=========================================' -ForegroundColor Green
Write-Host '  解锁成功' -ForegroundColor Green
Write-Host '=========================================' -ForegroundColor Green
Write-Host ('  文件：' + $ExePath)
Write-Host ('  大小：' + $newLen + ' 字节')
Write-Host ('  SHA256：' + $newHash)
Write-Host ('  备份：' + (Split-Path $bak -Leaf))
Write-Host ''
Write-Host '  现在启动 PCL，进入「下载 -> 原版游戏」' -ForegroundColor White
Write-Host '  即可看到版本列表并正常安装原版 MC。' -ForegroundColor White
Write-Host ''
Write-Host '  提示：PCL 自动更新会覆盖补丁，更新后重跑本脚本即可。' -ForegroundColor DarkGray
Write-Host ''
exit 0
