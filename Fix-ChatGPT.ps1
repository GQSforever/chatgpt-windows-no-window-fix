# Fix-ChatGPT.ps1
# 自动修复 Windows ChatGPT / OpenAI.Codex 的 cua_node runtime staging 问题
# 适用症状：
#   - ChatGPT 后台有进程但没有窗口
#   - %LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node 下反复出现 .staging-* 目录
#   - 新版本更新后 runtime hash 变化，正式 runtime 目录未生成
#
# 修复逻辑：
#   1. 获取当前 OpenAI.Codex Appx 包
#   2. 找到 app\resources\cua_node 源 runtime
#   3. 从最新 .staging-<runtimeId>-xxxx 中自动提取 runtimeId
#   4. 停止 ChatGPT
#   5. 使用 xcopy /G 完整复制 runtime
#   6. 校验 node.exe / node_repl.exe / manifest.json 与文件数
#   7. 修复成功后重新启动 ChatGPT

$ErrorActionPreference = "Stop"

function Write-Info($msg) {
    Write-Host "[INFO] $msg" -ForegroundColor Cyan
}

function Write-OK($msg) {
    Write-Host "[ OK ] $msg" -ForegroundColor Green
}

function Write-WarnMsg($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Write-Fail($msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
}

try {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "   ChatGPT Windows Runtime Auto Repair Tool" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host ""

    # 1. 获取当前 Appx 包
    Write-Info "正在检测 OpenAI.Codex 安装包..."
    $pkg = Get-AppxPackage OpenAI.Codex | Select-Object -First 1

    if (-not $pkg) {
        Write-Fail "未检测到 OpenAI.Codex / ChatGPT Windows 应用。"
        exit 1
    }

    Write-OK "检测到版本：$($pkg.Version)"
    Write-Info "安装位置：$($pkg.InstallLocation)"

    # 2. 定位 runtime 源和本地 runtime 根目录
    $src = Join-Path $pkg.InstallLocation "app\resources\cua_node"
    $root = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"

    if (-not (Test-Path $src)) {
        Write-Fail "未找到源 runtime：$src"
        exit 1
    }

    if (-not (Test-Path $root)) {
        Write-Info "本地 runtime 根目录不存在，正在创建..."
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }

    # 3. 查找最新 staging 目录
    Write-Info "正在检查失败的 .staging-* runtime..."

    $stagingList = Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".staging-*" } |
        Sort-Object LastWriteTime -Descending

    $staging = $stagingList | Select-Object -First 1

    if (-not $staging) {
        Write-WarnMsg "没有发现 .staging-* 目录。"

        $existing = Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike ".staging-*" }

        if ($existing) {
            Write-Info "当前存在以下正式 runtime："
            $existing | ForEach-Object {
                Write-Host "  - $($_.Name)  $($_.LastWriteTime)"
            }
        }

        Write-WarnMsg "当前没有明确证据表明是 cua_node staging 故障，因此未执行复制。"
        exit 0
    }

    Write-Info "最新 staging：$($staging.Name)"

    # staging 格式：.staging-<runtimeId>-<random>
    if ($staging.Name -match '^\.staging-([^-]+)-') {
        $runtimeId = $matches[1]
    }
    else {
        Write-Fail "无法从 staging 目录名识别 runtime ID：$($staging.Name)"
        exit 1
    }

    $dst = Join-Path $root $runtimeId

    Write-OK "检测到当前需要的 runtime ID：$runtimeId"
    Write-Info "目标目录：$dst"

    # 4. 校验源 runtime 必要文件
    $required = @(
        "bin\node.exe",
        "bin\node_repl.exe",
        "manifest.json"
    )

    Write-Info "正在校验安装包中的 runtime..."

    foreach ($rel in $required) {
        $p = Join-Path $src $rel
        if (-not (Test-Path $p)) {
            Write-Fail "源 runtime 缺少必要文件：$p"
            exit 1
        }
    }

    Write-OK "源 runtime 必要文件完整。"

    # 5. 如果目标 runtime 已经完整，则先比较文件数量
    $srcCount = (Get-ChildItem $src -Recurse -File -Force -ErrorAction SilentlyContinue).Count

    $dstAlreadyValid = $false
    if (Test-Path $dst) {
        $dstCountBefore = (Get-ChildItem $dst -Recurse -File -Force -ErrorAction SilentlyContinue).Count

        $requiredOK = $true
        foreach ($rel in $required) {
            if (-not (Test-Path (Join-Path $dst $rel))) {
                $requiredOK = $false
                break
            }
        }

        if ($requiredOK -and $dstCountBefore -eq $srcCount) {
            $dstAlreadyValid = $true
        }
    }

    if ($dstAlreadyValid) {
        Write-OK "正式 runtime 已经完整，无需重新复制。"
    }
    else {
        # 6. 停止 ChatGPT
        Write-Info "正在停止 ChatGPT 进程..."
        Get-Process ChatGPT -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 700

        # 7. 创建目标目录并复制
        Write-Info "正在创建/修复正式 runtime 目录..."
        New-Item -ItemType Directory -Path $dst -Force | Out-Null

        Write-Info "正在使用 xcopy /G 复制 runtime，请稍候..."
        Write-Host ""

        $xcopy = Join-Path $env:SystemRoot "System32\xcopy.exe"

        & $xcopy "$src\*" "$dst\" /E /I /H /Y /G

        $xcopyExit = $LASTEXITCODE

        Write-Host ""

        # xcopy:
        # 0 = copied successfully
        # 1 = no files found
        # 2 = Ctrl+C
        # 4 = initialization error
        # 5 = disk write error
        if ($xcopyExit -ne 0) {
            Write-Fail "xcopy 返回错误码：$xcopyExit"
            exit $xcopyExit
        }

        Write-OK "xcopy 完成。"
    }

    # 8. 最终验证
    Write-Info "正在执行最终校验..."

    $dstCount = (Get-ChildItem $dst -Recurse -File -Force -ErrorAction SilentlyContinue).Count

    $allRequiredOK = $true
    foreach ($rel in $required) {
        $p = Join-Path $dst $rel
        $exists = Test-Path $p
        Write-Host ("  {0,-20} : {1}" -f $rel, $exists)
        if (-not $exists) {
            $allRequiredOK = $false
        }
    }

    Write-Host ""
    Write-Host "  Source files : $srcCount"
    Write-Host "  Target files : $dstCount"
    Write-Host ""

    if (-not $allRequiredOK) {
        Write-Fail "目标 runtime 仍缺少必要文件。"
        exit 1
    }

    if ($srcCount -ne $dstCount) {
        Write-Fail "源/目标文件数量不一致，修复可能不完整。"
        exit 1
    }

    Write-OK "runtime 修复成功：$runtimeId"

    # 9. 提示 staging 残留数量，但不自动删除
    $leftover = Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".staging-$runtimeId-*" }

    if ($leftover) {
        Write-WarnMsg "发现 $($leftover.Count) 个失败的 staging 残留目录。"
        Write-Host "      为避免误删，脚本不会自动清理；确认 ChatGPT 正常后可手动删除。"
    }

    # 10. 启动 ChatGPT
    Write-Info "正在启动 ChatGPT..."

    try {
        Start-Process "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
        Start-Sleep -Seconds 3
    }
    catch {
        Write-WarnMsg "无法通过 AppsFolder 自动启动，请从开始菜单手动打开 ChatGPT。"
    }

    # 11. 检查窗口状态
    $chatgpt = Get-Process ChatGPT -ErrorAction SilentlyContinue

    if ($chatgpt) {
        $window = $chatgpt |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1

        if ($window) {
            Write-OK "检测到 ChatGPT 主窗口。"
            Write-Host "      PID              : $($window.Id)"
            Write-Host "      MainWindowHandle : $($window.MainWindowHandle)"
        }
        else {
            Write-WarnMsg "ChatGPT 已启动，但暂未检测到非零 MainWindowHandle。"
            Write-Host "      如果窗口稍后仍未出现，可重新运行本脚本或进一步检查 renderer。"
        }
    }
    else {
        Write-WarnMsg "暂未检测到 ChatGPT 进程，请从开始菜单手动启动。"
    }

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host " 修复流程结束" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Fail $_.Exception.Message
    Write-Host ""
    exit 1
}
