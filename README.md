# Windows 版 ChatGPT 有进程却没有窗口：cua_node 运行时部署失败的排查、修复与更新后复发记录

> 首次记录：2026-09-08；更新：2026-09-24。第 8 节记录 9 月 9 日复发，第 9 节提供当时的修复脚本；第 10 节链接 9 月 24 日的新取证与迁移对照。

双击 ChatGPT，任务管理器里能看到进程，桌面上却始终没有窗口。应用没有立即退出，也没有弹出错误提示，单从界面上很难判断它卡在了哪里。

我这次遇到的问题，最终定位到了 `cua_node` 运行时的本地部署阶段。手动使用带 `/G` 参数的 `xcopy` 补齐对应 runtime 目录后，渲染进程恢复，主窗口句柄变为非零，窗口正常出现。

本文记录这次故障的判断依据、修复步骤和验证方法，适用于同样出现运行时部署异常的情况。它是一份个人排障记录，不是官方通用修复方案。

> 记录说明：本文依据两次排障对话中的实际输出与修复确认整理。下文命令是面向复用编写的操作模板，不是原始终端记录的逐字重放；复用时需结合当前安装包、本次启动日志和 runtime 目录状态核对路径；第 8 节补充了本机这次复发的实际路径。本文只讨论“后台有进程，但无法打开窗口”。

## 1. 先确认：应用启动到了哪一步

这次故障最明显的现象是：

- 启动后可以找到 ChatGPT 进程。
- 没有可见主窗口。
- 排查时未观察到对应的 renderer 渲染进程。
- 当时检查到的 `MainWindowHandle` 为 `0`。

在 PowerShell 中，可以先执行：

```powershell
Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, MainWindowTitle, MainWindowHandle
```

如果没有输出，说明采样时没有找到这个名称的进程，应先确认实际进程名，或者排查启动后立即退出的情况。

如果有输出，但窗口标题为空、句柄为 `0`，说明这次查询没有找到对应的可见主窗口。**这只是排查入口，不能单独证明 `cua_node` 出了问题。** 隐藏窗口、托盘运行以及启动尚未完成，也可能得到 `0`；多进程应用也不要求每个子进程都拥有主窗口。这些限制来自 Windows 对该属性的定义。[Microsoft：Process.MainWindowHandle](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.mainwindowhandle)

接下来查看进程命令行：

```powershell
Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" |
    Select-Object ProcessId, ParentProcessId, ExecutablePath, CommandLine |
    Format-List
```

对于命令行中使用 `--type=renderer` 标识渲染进程的版本，可以进一步筛选：

```powershell
Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" |
    Where-Object { $_.CommandLine -match '--type=renderer' } |
    Select-Object ProcessId, ParentProcessId, CommandLine
```

该筛选依赖具体版本的进程名称和参数形式，空结果也需要结合完整进程列表判断。对我这次故障而言，“有主进程、无窗口、未见 renderer”的组合提示：应继续检查窗口出现之前的初始化步骤。

## 2. 关键线索：cua_node 的 staging 没有完成

这次排障最终落在 `cua_node` runtime staging 上。这里的 staging，可以理解为：把应用提供的运行时文件准备到实际使用的目录，供后续启动流程使用。

对本次现象，可以作如下概括：

```text
ChatGPT 进程启动
    ↓
准备 cua_node 运行时文件
    ↓
本地部署未完成
    ↓
启动流程未正常推进到窗口出现
    ↓
任务管理器里有进程，桌面上没有窗口
```

这张图表示本次排障得到的故障链，不代表对所有版本内部启动顺序的源码级确认。

真正有价值的证据，是对照故障启动日志中的运行时部署信息，确认**从哪里复制、复制到哪里、失败发生在哪一步**。可以在已经确认的日志目录中搜索：

```powershell
$logRoot = Read-Host '请输入本次启动日志所在的目录'

if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
    throw '日志目录不存在，请检查路径。'
}

Get-ChildItem -LiteralPath $logRoot -Recurse -File -ErrorAction Stop |
    Where-Object { $_.Extension -in '.log', '.txt', '.jsonl' } |
    Select-String -Pattern 'cua_node', 'staging', 'runtime' -Context 3, 5
```

先按时间确认是本次启动的日志，再看匹配行前后的完整错误。关键词命中只负责定位，普通的成功日志也可能包含这些词。日志位置和文件格式可能随版本变化，以上后缀筛选也需要按实际文件调整。

**如果没有运行时部署失败的证据，不要仅凭“没有窗口”就执行后面的复制步骤。**

## 3. 修复前，确认两个目录

这次有效的操作是：把与当前安装版本匹配的 `cua_node` 文件，完整复制到应用实际期待的 runtime 目录。

需要先明确两条路径：

| 路径 | 应当指向什么 |
| --- | --- |
| 源目录 | 当前安装版本提供的、需要部署的 `cua_node` 运行时目录 |
| 目标目录 | 本次启动日志中记录的实际 runtime 目标目录 |

源目录和目标目录必须对应同一套文件层级。例如，应用期待文件位于 `目标目录\node.exe`，就不能复制成 `目标目录\cua_node\node.exe`。这里的 `node.exe` 仅用于说明目录层级，实际入口应以当前版本的文件结构为准。

版本号、目录名、用户路径都应使用自己机器上的值。不同版本的文件不能因为名字相同就混用；也不要从不明来源下载一份 runtime 替换进去。

如果日志没有提供足够的信息，就先保留日志继续定位，不应猜测一个目录直接覆盖。

## 4. 使用 xcopy 补齐运行时文件

先正常退出 ChatGPT，并确认其相关进程已经退出，避免程序同时写入 runtime 目录。任务管理器仍有残留时，可在确认没有进行中的任务后结束对应进程。

下面的命令在 **PowerShell** 中运行。输入的路径不需要额外包裹引号。

### 4.1 检查源目录与目标目录

```powershell
$sourceInput = Read-Host '请输入已确认的 cua_node 源目录'
$targetInput = Read-Host '请输入启动日志中的 runtime 目标目录'

if (-not (Test-Path -LiteralPath $sourceInput -PathType Container)) {
    throw '源目录不存在，请检查当前安装版本和目录层级。'
}
if (-not [IO.Path]::IsPathRooted($targetInput)) {
    throw '目标目录必须是完整的绝对路径。'
}

$runtimeSource = (Resolve-Path -LiteralPath $sourceInput).Path.TrimEnd('\')
$runtimeTarget = [IO.Path]::GetFullPath($targetInput).TrimEnd('\')
$comparison = [StringComparison]::OrdinalIgnoreCase

if ($runtimeTarget -eq [IO.Path]::GetPathRoot($runtimeTarget).TrimEnd('\')) {
    throw '目标不能是磁盘根目录。'
}
if ($runtimeSource.Equals($runtimeTarget, $comparison) -or
    $runtimeSource.StartsWith($runtimeTarget + '\', $comparison) -or
    $runtimeTarget.StartsWith($runtimeSource + '\', $comparison)) {
    throw '源目录和目标目录不能相同，也不能互相包含。'
}

Write-Host "源目录：$runtimeSource"
Write-Host "目标目录：$runtimeTarget"
Get-ChildItem -LiteralPath $runtimeSource -Force | Select-Object Name, Mode
```

检查显示的绝对路径，并与日志逐项对照。这里的检查用于避免明显的路径错误，不能替代对版本和目标位置的人工确认。

### 4.2 保留现有目录，再复制

为了保留恢复依据，先把已有目标目录另存为相邻的备份目录。此步骤需要足够的磁盘空间；备份失败时应停止。

```powershell
if (Test-Path -LiteralPath $runtimeTarget) {
    if (-not (Test-Path -LiteralPath $runtimeTarget -PathType Container)) {
        throw '目标路径已存在，但不是目录。'
    }

    $runtimeBackup = $runtimeTarget + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $runtimeBackup) {
        throw '备份目录已存在，请检查后再操作。'
    }
    Copy-Item -LiteralPath $runtimeTarget -Destination $runtimeBackup -Recurse -Force -ErrorAction Stop
    Write-Host "已备份到：$runtimeBackup"
}

# 复制源目录内的全部内容，保留相对目录结构。
& xcopy.exe (Join-Path $runtimeSource '*') $runtimeTarget /E /H /I /Y /G
$copyExitCode = $LASTEXITCODE

if ($copyExitCode -ne 0) {
    throw "xcopy 未正常完成，退出码：$copyExitCode。请保留错误输出继续检查。"
}
```

这里没有使用 `/C` 忽略复制错误。修复的目标是准备完整的运行时，出现文件复制失败时，应先处理错误再启动应用。

这套模板是对当时成功操作的整理，保留了关键的 `/G` 参数，并增加了路径检查、备份和退出码检查。它不是无需核对路径的一键修复脚本。

## 5. 为什么这里使用 /G

`xcopy` 的 `/G` 与加密文件的复制有关：目标不支持加密时，允许创建解密后的目标文件。其他参数分别用于复制子目录、包含隐藏和系统文件、将目标视为目录，以及允许覆盖已有文件。[Microsoft：xcopy 参数说明](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/xcopy)

本次成功修复使用了 `/G`，因此记录方案时需要保留它。但仅凭“带 `/G` 的复制成功了”，还不能证明这台机器上最底层的原因一定是某一种加密或文件系统缺陷，也不能证明其他复制方式必然失败。

能确认的结论是：**手动补齐对应运行时目录，恢复了这次故障中的窗口启动。** 对文件属性、包部署机制或复制 API 的进一步归因，需要原始错误码和更充分的对照证据。

## 6. 验证：不仅看“复制完成”

当时的排障记录中，成功复制的数量是 **4683 个文件**。这个数字只对应当时那份运行时，不是其他版本必须满足的标准，也不等同于文件完整性的独立证明。

可以先检查复制出的文件是否存在、长度是否一致。沿用前面 PowerShell 会话中的变量：

```powershell
$sourceFiles = @(Get-ChildItem -LiteralPath $runtimeSource -Recurse -File -Force -ErrorAction Stop)
if ($sourceFiles.Count -eq 0) {
    throw '源目录没有文件，请重新检查。'
}

$copyProblems = @(
    foreach ($file in $sourceFiles) {
        $relativePath = $file.FullName.Substring($runtimeSource.Length).TrimStart('\')
        $copiedPath = Join-Path $runtimeTarget $relativePath

        if (-not (Test-Path -LiteralPath $copiedPath -PathType Leaf)) {
            "缺少文件：$relativePath"
        } elseif ((Get-Item -LiteralPath $copiedPath -Force -ErrorAction Stop).Length -ne $file.Length) {
            "文件长度不同：$relativePath"
        }
    }
)

if ($copyProblems.Count -gt 0) {
    $copyProblems
    throw '文件检查未通过，请先处理上述问题。'
}
Write-Host "已检查 $($sourceFiles.Count) 个源文件，目标均存在且长度一致。"
```

这是缺失文件和长度的检查，不是逐字节校验，也不会识别目标目录里的额外旧文件。若仍怀疑复制内容有问题，可对对应文件进一步比较 SHA-256。

文件检查通过后，从原来的入口重新启动 ChatGPT，再执行第一节的进程检查命令。

本次修复前后的变化如下：

| 检查项 | 修复前 | 修复后 |
| --- | --- | --- |
| ChatGPT 后台进程 | 存在 | 存在 |
| renderer 渲染进程 | 当时未观察到 | 恢复出现 |
| 主窗口句柄 | 当时检查为 `0` | 主窗口所属进程出现非零句柄 |
| 可见窗口 | 无法打开 | 正常出现 |

**可见窗口出现，是本次修复的验收标准。** 如果只是复制命令执行成功，窗口仍未出现，就还不能认定问题解决。

## 7. 再次遇到相同现象时，怎样判断是否适用

可以按下面的顺序缩小范围：

1. 检查进程是否存在，并确认是否确实没有可见窗口。
2. 检查进程命令行，观察该版本的渲染进程是否启动。
3. 查看同一次启动的日志，寻找 `cua_node` 运行时部署失败的具体信息。
4. 只有确认属于该问题后，才核对版本和两条路径，备份并补齐文件。
5. 重新启动，以窗口是否出现验证结果。

如果复制后仍然失败，应保存新的日志和复制错误，重新判断故障环节。应用更新后也需要重新确认版本与目录，不能把本次路径当成永久固定位置。

这次经历让我更清楚地认识到：**“进程存在”只说明程序已经开始执行，并不代表图形界面已经完成初始化。** 找到启动流程停住的位置，再做与证据对应的修复，比只根据“打不开”这个表面现象反复尝试更有效。

## 8. 2026-09-09 更新：新版本下再次出现无窗口，重新补齐 runtime 后恢复

9 月 8 日修复后，应用已经可以正常使用；9 月 9 日再次打开时，又出现了无法显示窗口的现象。重新检查发现，安装包版本和本次启动生成的 staging 目录中的 runtime ID 都发生了变化。

### 8.1 两次故障的版本与结果

| 记录日期 | OpenAI.Codex 包版本 | 对应 runtime ID | 修复结果 |
| --- | --- | --- | --- |
| 2026-09-08 | `26.901.5003.0` | `6a86821985684e13` | 手动复制后源、目标均为 4683 个文件；主窗口句柄变为非零，窗口出现 |
| 2026-09-09 | `26.901.6511.0` | `b474a88d5d105afa` | 按当前版本重新使用 `xcopy /G` 补齐对应目录后，我确认问题已修复 |

两次记录可以确认包版本已变化，但没有单独记录更新由哪个入口触发，因此不把“Microsoft Store 自动更新”作为已验证事实。

**昨天补齐的旧 runtime 目录仍然存在，并不代表新版本所需的 runtime 已经准备完成。** 这次复发说明，前一天的手动修复没有保证后续版本所需 runtime 能自动部署成功；它仍然只是针对当次目录的恢复措施。

### 8.2 今天修复前的实际输出

查询安装包：

```powershell
Get-AppxPackage OpenAI.Codex |
    Select-Object Name, Version, Status, InstallLocation
```

当时输出为：

```text
Name         Version       Status InstallLocation
----         -------       ------ ---------------
OpenAI.Codex 26.901.6511.0     Ok C:\Program Files\WindowsApps\OpenAI.Codex_26.901.6511.0_x64__2p2nqsd0c76g0
```

查询 runtime 根目录：

```powershell
Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node" -Directory -Force |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, LastWriteTime
```

当时得到：

```text
Name                             LastWriteTime
----                             -------------
.staging-b474a88d5d105afa-vhWLct   2026-09-09 14:58:59
.staging-b474a88d5d105afa-yDvdHo   2026-09-09 14:58:21
6a86821985684e13                  2026-09-08 18:32:29
```

这次列表中有两份带新 ID 的 staging 目录，但没有正式的 `b474a88d5d105afa` 目录；旧 ID 的正式目录仍在。这是本次判断新 runtime 尚未完成部署的直接线索。

同次 `Get-Process ChatGPT` 查询没有输出，所以不能把昨天“后台进程存在、句柄为 0、未见 renderer”的全部观测直接套到今天。今天保留下来的直接证据是：无窗口的实际现象、包版本变化、上述目录状态，以及再次手动补齐后的恢复确认。

### 8.3 这次修复使用的路径

本次源目录由当前安装包位置拼接 `app\resources\cua_node` 得到，目标目录使用本次故障对应的新 runtime ID：

```text
源目录：
C:\Program Files\WindowsApps\OpenAI.Codex_26.901.6511.0_x64__2p2nqsd0c76g0\app\resources\cua_node

目标目录：
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\b474a88d5d105afa
```

这里的 `%LOCALAPPDATA%` 是路径说明中的环境变量占位符；PowerShell 中应写作 `$env:LOCALAPPDATA`。本次文件层级中的检查入口为：

```text
bin\node.exe
bin\node_repl.exe
manifest.json
```

核对当前版本和目录、退出应用后，沿用第 4 节带 `/G` 的复制方法，并按第 6 节检查复制结果，再重新启动应用。我随后在排障对话中确认“修好了”。

今天的对话没有保留复制后的文件计数、renderer 列表或窗口句柄数值，因此不把昨天的 **4683** 或非零句柄数值写成今天的测试结果。

### 8.4 对后续排障的补充

再次遇到无窗口时，应同时核对**当前包版本、本次启动对应的 runtime ID、正式目录是否存在，以及 staging 的生成时间**。不要直接复用昨天的 hash，也不要将旧版本 runtime 改名充当新版本文件。目录中可能保留历史 staging，不能仅凭“最新目录”就无条件决定复制目标；应结合本次启动时间和日志确认。

本次复发及恢复与运行时部署未完成的判断一致，但没有新增底层复制错误码或源码证据，仍不足以进一步断言具体加密机制或复制 API 是根因。


## 9. 修复脚本下载与双击运行

将排障对话中生成的两个脚本放到仓库根目录，方便遇到相同故障时复用：

| 文件 | 用途 | 下载 |
| --- | --- | --- |
| [Fix-ChatGPT.bat](./Fix-ChatGPT.bat) | 双击运行的入口，调用同目录下的 PowerShell 脚本，结束后暂停显示结果 | [下载 BAT](https://raw.githubusercontent.com/GQSforever/chatgpt-windows-no-window-fix/main/Fix-ChatGPT.bat) |
| [Fix-ChatGPT.ps1](./Fix-ChatGPT.ps1) | 检测安装包和 staging、复制并检查 runtime、尝试启动应用 | [下载 PS1](https://raw.githubusercontent.com/GQSforever/chatgpt-windows-no-window-fix/main/Fix-ChatGPT.ps1) |

### 9.1 使用方法

1. 下载上面两个文件，保留完整文件名，放在**同一个文件夹**中。也可以在仓库首页选择 **Code → Download ZIP**，解压后使用根目录中的文件。若直接下载链接在浏览器中显示代码，请使用“另存为”，避免保存成网页或附加 `.txt` 后缀。
2. 先按前文核对故障：当前版本对应的 runtime 未部署完成，本次启动生成了新的 staging 目录。脚本按修改时间选择最新 staging，并不会独立验证它与当前安装包的对应关系；如果只是历史残留或对应关系不明确，应先继续排查。
3. 保存正在进行的工作。脚本在需要复制 runtime 时会强制结束 `ChatGPT` 进程。
4. **双击 `Fix-ChatGPT.bat`**。它会自动调用同目录下的 `Fix-ChatGPT.ps1`，无需单独打开 PowerShell。
5. 等待复制和检查结束，查看窗口内的输出。若应用未自动打开，从开始菜单手动启动；最终以 ChatGPT 窗口正常出现为准。

两个文件的放置方式：

```text
chatgpt_fix/
├── Fix-ChatGPT.bat  ← 双击这个文件
└── Fix-ChatGPT.ps1
```

也可以为 `Fix-ChatGPT.bat` 创建桌面快捷方式，但应保持原来的两个文件放在一起。BAT 中的 `-ExecutionPolicy Bypass` 用于本次 PowerShell 调用，不会通过 `Set-ExecutionPolicy` 修改系统的持久执行策略。

### 9.2 脚本实际执行的步骤

- 获取当前 `OpenAI.Codex` 安装包，定位包内的 `app\resources\cua_node`。
- 从修改时间最新的 `.staging-<runtimeId>-<随机后缀>` 目录名提取 runtime ID。
- 检查源目录中的 `bin\node.exe`、`bin\node_repl.exe` 和 `manifest.json`。
- 若目标目录的必要文件存在且文件数量相同，跳过复制；否则结束 ChatGPT 进程，使用 `xcopy /E /I /H /Y /G` 复制到正式目录。
- 检查复制退出码、目标必要文件和源/目标文件数量。
- 尝试启动 ChatGPT，等待约 3 秒后检查是否出现非零 `MainWindowHandle`。
- 提示 staging 残留，但不自动删除。

### 9.3 验证范围与限制

这里上传的是当时生成的脚本，发布时已通过 PowerShell 语法解析检查。前文确认成功的是手动复制修复；没有将“脚本生成完成”当作整套脚本已经实机验证成功。

脚本的文件检查是“必要文件存在 + 数量一致”，不是逐文件内容或哈希校验；它显示“runtime 修复成功”也不等于窗口已经恢复。若需要更细的检查，可以使用第 6 节的方法。

自动脚本与第 4 节手动模板有所不同：**它不备份已有目标目录，复制时可能覆盖同名文件**。此外，没有发现 staging 时会跳过复制并退出；未检测到窗口时只发出提示，不一定返回失败退出码。请阅读实际输出，不要仅凭 BAT 显示“脚本已结束”判断修复成功。

PS1 保留 UTF-8 BOM，以便 Windows PowerShell 5.1 正确读取中文内容。

## 10. 2026-09-24：查明本机与正常安装环境的关键差异

[阅读完整的 9 月 24 日取证报告](./incidents/2026-09-24-no-window-followup.md)。这次取证比早期记录多了直接的复制错误码、安装卷与文件保护状态，以及重装迁移前后的对照，因此以下结论以新报告为准：

- 更新后的 `cua_node` 运行时需要重新准备。原包实际位于非系统应用卷，源文件为 `Application Protected`；普通复制在本机报 `ERROR_ENCRYPTION_FAILED (6000)`。
- 当前版本会逐文件回退到读写复制，但该步骤在窗口出现前同步执行，可能造成长时间无窗口。**取证后运行了修复脚本，不能断言若继续等待，原启动一定不会自行完成。**
- 将商店应用重装到系统盘后，新包文件显示未加密，运行时文件完整生成。这是本机迁移后的已观察结果；下一次自动更新的表现尚未验证，且其他用户有迁回系统盘仍未解决的反例。
- 旧 E 盘 `WindowsApps` 仍有其他应用在使用，不能当作 ChatGPT 的备份直接删除。原有 `Fix-ChatGPT` 脚本仍是按版本进行的事后恢复工具，不能根治应用的复制兼容问题。
