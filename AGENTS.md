# AGENTS.md

给进入本仓库的 AI 的须知：这个项目有哪些东西可以直接调用、怎么验证、动手前必须知道什么。

## 1. 项目是什么

`win_share` 是一个 Flutter 桌面工具，让 Mac 与 Windows 互相按需访问对方的目录：

- **Windows → Mac**：Windows 建 SMB 共享，Mac 把它挂到 `/Volumes/<共享名>`（支持开机自动挂载）。
- **Mac → Windows**：Mac 只发布**一个容器共享**，Windows 把它映射成一个盘符，各共享区是盘符下的子文件夹。

两端是**同一个工程**：界面共用，平台差异收敛在 `LocalSide` 实现里。

## 2. AI 可直接调用的能力

### 2.1 MCP 工具

| 工具 | server_name / tool_name | 用途 |
| --- | --- | --- |
| 代码模式 | `integrated_code_mode` / `Exec` | 在隔离 V8 里跑 JS，用 `await tools.<name>(args)` 编排其它工具；`ALL_TOOLS` 可查运行时工具清单 |
| 界面观测与操作 | `ide_mcp.config.ext.computer-use` / `get_app_state`、`list_apps`、`click`、`type_text` … | 直接读运行中实例的界面状态（`disableScreenshot: false` 可拿截图）。本应用 bundle id 为 `com.machome.winShare` |
| 录制回放 | 「Record & Replay」MCP：`event_stream_start`、`event_stream_status`、`event_stream_stop` | 录制操作事件；状态查询会返回产物路径。macOS 需要辅助功能与屏幕录制权限 |

`server_name` 以 `Exec` 里 `ALL_TOOLS` 的实际返回为准，别按上面的表格名猜。

注意：`get_app_state` 读不到 Flutter 的控件树（无障碍树里只有一个空 group），**界面文案只能靠截图看**；要精确状态优先读日志与系统挂载表（见 2.3）。

插件：`trae-remote-official:computer-use`（同上的桌面操作入口）、`trae-remote-official:lark`（飞书）。

### 2.2 仓库内探针脚本

| 命令 | 作用 | 代价 |
| --- | --- | --- |
| `fvm dart run tools/probe/publish_check.dart` | 反向共享链路自检：本机账户、对外地址、已注册共享点、Windows 可用盘符、当前盘符映射、容器判定用例 | 只读，不提权、不弹窗 |
| `fvm dart run tools/probe/mac_probe.dart --seconds 60 [--to <IP>]` | 局域网广播探针（UDP 47823），验证 ZeroTier 虚拟网内广播能否双向到达 | 只读网络探测 |
| `tools/probe/win_probe.ps1` | Windows 侧同款广播探针，零依赖（.NET UdpClient）：`powershell -ExecutionPolicy Bypass -File win_probe.ps1 -Seconds 60` | 需在 Windows 上执行 |
| `fvm dart run tools/fix/nfd_fix.dart scan\|normalize\|delete` | 处理 Windows 共享上的 NFD 文件名（看得到但删不掉），详见第 5、6 节 | 需 SSH 到 Windows；`normalize` 会改服务端文件名 |

### 2.3 运行期证据

应用是后台常驻的，出问题的证据在日志和系统状态里，不在终端里。

| 证据 | Mac | Windows |
| --- | --- | --- |
| 日志（按天，保留 7 天） | `~/Library/Logs/win_share/win_share-YYYY-MM-DD.log` | `%LOCALAPPDATA%\win_share\logs\` |
| 配置 | `~/Library/Application Support/win_share/shares.json` | `%APPDATA%\win_share\shares.json` |
| 凭据 | 钥匙串 `win_share.smb`（账户 = 本机用户名） | Windows 凭据管理器（`cmdkey` 登记；SSH 会话里改用 `net use` 直接带凭据） |

日志 tag：`app`（启动锚点，含 pid）、`tick`（每轮巡检的挂载表快照）、`health`（自动挂载决策与挂载状态翻转）、`mount` / `unmount`（单次挂载耗时与结果）、`orphan`（无配置归属的挂载点）、`sync`（与对端交换数据）、`channel`（发布与盘符映射）、`login`（开机自启动的注册、注销与状态读取）。

系统侧可直接查：

```bash
mount | grep -i smbfs                                  # Mac 上真实的 SMB 挂载
nc -vz -G 3 <windows_ip> 445                           # 对端 SMB 端口是否可达
ls /Volumes/
sfltool dumpbtm | grep -i -B2 -A6 machome                # 登录项/后台项的真实登记情况（无需 sudo）
```

## 3. 构建与运行

```bash
fvm flutter analyze            # 静态检查（本项目不写测试）
fvm flutter run -d macos       # 开发运行
fvm flutter build macos --debug
fvm flutter build windows      # 在 Windows 机器上执行
```

Windows 那台机器上装了多个 Flutter（PATH 上的 `flutter` 与 `fvm` 解析到的可以不是同一个版本）。`pub get` 与 `build` 必须走同一个入口，否则会用 A 版本的框架配 B 版本的引擎，报出像 `The getter 'engineId' isn't defined for the class 'PlatformDispatcher'` 这种指向 Flutter 自身源码的错。遇到就 `fvm flutter clean && fvm flutter pub get && fvm flutter build windows --debug` 一把过（构建前记得先停掉正在运行的 `win_share.exe`，它会锁住 `build` 目录）。

## 4. 架构地图

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 入口：按平台选 `WindowsSide` / `MacSide`，装配主题与窗口 |
| `lib/model.dart` | `ShareLink` / `PublishSettings` / `PeerTarget` 与 `ConfigStore`（配置落盘） |
| `lib/side.dart` | `LocalSide` 抽象及视图模型 `LinkView` / `ChannelView`，界面只认这一层 |
| `lib/ui.dart` | 两端共用界面、卡片、各设置对话框、菜单栏常驻 |
| `lib/side_mac.dart` | Mac 侧动作：挂载、发布容器、SSH 驱动 Windows、**自动挂载巡检** |
| `lib/side_win.dart` | Windows 侧动作：建/删共享、映射盘符 |
| `lib/smb_mac.dart` | macOS SMB 编排：`mount` 命令解析、`diskutil` 卸载、自定义访问路径符号链接 |
| `lib/smb_win.dart` | Windows SMB 编排：本机 PowerShell、UAC 提权、`net use` 映射 |
| `lib/publish_mac.dart` | macOS 共享发布（`sharing` 提权）、钥匙串凭据、SSH 远程执行 PowerShell |
| `lib/sync.dart` | 两端共享区数据同步：同端口 HTTP，一次 POST 双向交换快照 |
| `lib/login_item.dart` | macOS 开机自启动：`SMAppService.mainApp` 的 Dart 封装，原生实现在 `macos/Runner/MainFlutterWindow.swift` |
| `lib/autostart_win.dart` | Windows 开机自启动：当前用户 `HKCU\...\Run` 键的读写（`reg.exe`），入口在主窗口 AppBar 的「更多」菜单 |
| `lib/log.dart` | 按天滚动的追踪日志 |

端口：`47824` 共享区同步（POST `/sync`）；`47823` 广播探针。

## 5. 动手前必须知道的约定与坑

- **不要代替用户点 UAC / 系统授权框**。建共享走 UAC 提权、发布容器走 macOS 授权框，都是用户在场的交互；AI 只准备命令，不触发提权动作。
- **密码不落盘到项目里**。Mac 存钥匙串、Windows 存凭据管理器；代码里只在内存或 stdin 传递。
- **Windows 侧 PowerShell 有三个坑**：错误会以 CLIXML 序列化（`publish_mac.dart` 的 `_readable` 负责还原）；脚本里的全角括号会让分词器报 `MissingEndParenthesis`；一律用 `-EncodedCommand`（UTF-16LE base64）传脚本并在开头切 UTF-8 输出。
- **驱动 Windows 的 PowerShell 必须用 `pwsh` 且不带 `-ExecutionPolicy`**（`publish_mac.dart` 的 `_runOnWindows`、`smb_win.dart` 的 `_runLocal`/`_runElevated`）。实测：`-ExecutionPolicy Bypass` 与 `-EncodedCommand` 同时出现时，整条命令会被本机安全策略静默杀掉（无任何输出、退出码 -1）；`powershell`（5.1）即使是 ssh 的直接子进程、只带 `-NoProfile -EncodedCommand` 也同样被杀（ssh 返回 255）。表现是「发布并映射」每一步都失败，但日志里看不到任何 PowerShell 报错。
- **共享区不能用符号链接**：macOS 的 SMB 服务会把链接原样交给 Windows，Windows 无法解析，所以共享区必须是容器目录内的真实子目录。
- **SSH 会话里看不到盘符映射**，也不能用 `cmdkey` 存凭据；Windows 侧的相关实现绕开了这两点，别改回去。
- **自动挂载只在 Mac 侧**（`windowsToMac` 方向）。触发条件是：启动首轮、本轮前处于已挂载、或对端由不可达转为可达；并受 `_retryAfter` 退避约束，避免认证失败反复弹窗。改这段逻辑（`side_mac.dart` 的 `checkHealth`）要连"掉线期间重挂窗口会被消耗"这条一起考虑。
- **Windows 侧的自动挂载靠盘符**：`net use /persistent:yes` 让整个容器在登录后恢复，共享区子文件夹随盘符一起出现，没有逐条挂载。
- **开机自启动两端各有一套，开关状态都以系统为唯一真相**，不在 `shares.json` 里另存；两边的登记都记着**当时的可执行文件绝对路径**，所以 `flutter clean`、换构建产物或搬目录后，都要在界面上重新点一次开关。
  - Mac：`SMAppService.mainApp`（要求 macOS 13+，更低版本原生侧回 `unsupported`），入口在菜单栏菜单里。本应用是 adhoc 签名、无 Team ID，若 `register()` 报 `Operation not permitted`，先怀疑签名而不是代码。
  - Windows：当前用户 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `win_share` 值（`reg.exe` 读写，HKCU 不需要管理员）。入口在主窗口 AppBar 的「更多」菜单。注意 `HKCU` 是**按登录用户**生效的，用 SSH 排查时要确认 SSH 用户和桌面登录用户是同一个（`query user` 对比 `whoami`）。
- **NFD 文件名在 Mac 侧删不掉**：Windows 共享上若存在 Unicode 分解形式（NFD）的文件名（日文等组合字符，如 `ヴ` = `U+30A6 U+3099`），macOS 的 SMB 客户端删除时会把名字归一化成 NFC 发送，服务端匹配不到，`rm` 报 `Directory not empty`、Finder 同样删不掉；但 `ls` / `stat` 因客户端缓存看起来一切正常，容易误判成权限或占用问题。判定 NFD 必须用序数比较（`[string]::Equals(..., [StringComparison]::Ordinal)`）——pwsh 7 基于 ICU，`-ne` 是文化敏感比较，会把 NFC 与 NFD 判为相等，导致扫描恒为 0。

## 6. 常见任务怎么做

| 任务 | 建议路径 |
| --- | --- |
| 排查"某个共享没挂上" | 先读当天日志的 `tick` / `health` / `mount` 行，再用 `mount \| grep smbfs` 与 `nc -vz <ip> 445` 交叉核对，最后才看界面截图 |
| 排查反向链路（Windows 看不到共享区） | `fvm dart run tools/probe/publish_check.dart`，它覆盖共享点、盘符与容器判定 |
| 验证 ZeroTier 连通性 | `mac_probe.dart` 与 `win_probe.ps1` 对跑，看是否互相收到 `[RECV]` |
| 改完代码验证 | `fvm flutter analyze` 必须干净；再重启实例（`kill <pid>` 后 `open build/macos/Build/Products/Debug/win_share.app`）看日志与 `/Volumes` |
| 需要看运行实例的界面 | MCP `get_app_state` + 截图，bundle id `com.machome.winShare` |
| 排查"重启后应用没自己起来" | 两端都先看日志里的 `login` 行确认注册结果。Mac：`sfltool dumpbtm \| grep -i -A6 machome` 应出现 `Disposition: [enabled, ...]`；被「系统设置 > 通用 > 登录项」手动关掉后状态会变成 `requiresApproval`，需要在菜单里重开一次。Windows：`reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v win_share`；用 SSH 查时先确认 SSH 用户与桌面登录用户是同一个（`query user` vs `whoami`），否则查的是别人的 HKCU |
| 文件"看得到但删不掉"（多为日文名素材） | 多半是 NFD：`fvm dart run tools/fix/nfd_fix.dart scan --share <共享名>` 列清单，`normalize --share <共享名>` 批量归一化为 NFC（之后 Mac 侧可正常删/改/移），`delete --path <Mac 路径>` 直接从 Windows 侧兜底删除。设计见 `docs/superpowers/specs/2026-10-05-win-nfd-delete-fix-design.md` |
