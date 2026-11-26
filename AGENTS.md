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

### 2.2 仓库内脚本

| 命令 | 作用 | 代价 |
| --- | --- | --- |
| `fvm dart run tools/probe/publish_check.dart` | 反向共享链路自检：本机账户、对外地址、已注册共享点、Windows 可用盘符、当前盘符映射、容器判定用例 | 只读，不提权、不弹窗 |
| `fvm dart run tools/probe/mac_probe.dart --seconds 60 [--to <IP>]` | 局域网广播探针（UDP 47823），验证 ZeroTier 虚拟网内广播能否双向到达 | 只读网络探测 |
| `tools/probe/win_probe.ps1` | Windows 侧同款广播探针，零依赖（.NET UdpClient）：`powershell -ExecutionPolicy Bypass -File win_probe.ps1 -Seconds 60` | 需在 Windows 上执行 |
| `fvm dart run tools/fix/nfd_fix.dart scan\|normalize\|delete` | 处理 Windows 共享上的 NFD 文件名（看得到但删不掉），详见第 5、6 节 | 需 SSH 到 Windows；`normalize` 会改服务端文件名 |
| `node tools/lock-release/release.js <路径> [--dry-run] [--include-external]` | 释放指定文件/文件夹的本地进程占用——SMB 卷上「目录改名 Permission denied」的处置手段，详见第 5 节 | 会 SIGTERM 可安全重启的 IDE 语言服务；`--dry-run` 只列出、不发信号 |

`tools/lock-release/install.sh` 装它：把薄壳扩展装进 IDE 扩展目录（Trae CN / VS Code），并把 CLI 软链到 `~/.local/bin/lock-release`。装好后 IDE 资源管理器右键有「释放占用」。成因、证据与安全策略见 `docs/superpowers/specs/2026-10-10-lock-release-design.md`。

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
- **自动挂载只在 Mac 侧**（`windowsToMac` 方向）。触发条件是：启动首轮、本轮前处于已挂载、对端由不可达转为可达、或上次失败仍在重试队列里；失败后按 1/2/5/15/30 分钟阶梯继续重试，既避免认证失败反复弹窗，也不至于一次失败就永久放弃。改这段逻辑（`side_mac.dart` 的 `checkHealth`）要连"掉线期间重挂窗口会被消耗"这条一起考虑。
- **挂载表只认两段式 `host/share`**：共享内联接点（junction）被 macOS 访问时会按需建立 `host/share/sub/...` 的子挂载，遍历共享区能膨胀到上千条。`smbMounts()` 把这类条目归入 `submounts` 只做告警，不参与挂载状态判定。
- **Windows 侧的自动挂载靠盘符**：`net use /persistent:yes` 让整个容器在登录后恢复，共享区子文件夹随盘符一起出现，没有逐条挂载。
- **开机自启动两端各有一套，开关状态都以系统为唯一真相**，不在 `shares.json` 里另存；两边的登记都记着**当时的可执行文件绝对路径**，所以 `flutter clean`、换构建产物或搬目录后，都要在界面上重新点一次开关。
  - Mac：`SMAppService.mainApp`（要求 macOS 13+，更低版本原生侧回 `unsupported`），入口在菜单栏菜单里。本应用是 adhoc 签名、无 Team ID，若 `register()` 报 `Operation not permitted`，先怀疑签名而不是代码。
  - Windows：当前用户 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `win_share` 值（`reg.exe` 读写，HKCU 不需要管理员）。入口在主窗口 AppBar 的「更多」菜单。注意 `HKCU` 是**按登录用户**生效的，用 SSH 排查时要确认 SSH 用户和桌面登录用户是同一个（`query user` 对比 `whoami`）。
- **NFD 文件名在 Mac 侧删不掉**：Windows 共享上若存在 Unicode 分解形式（NFD）的文件名（日文等组合字符，如 `ヴ` = `U+30A6 U+3099`），macOS 的 SMB 客户端删除时会把名字归一化成 NFC 发送，服务端匹配不到，`rm` 报 `Directory not empty`、Finder 同样删不掉；但 `ls` / `stat` 因客户端缓存看起来一切正常，容易误判成权限或占用问题。判定 NFD 必须用序数比较（`[string]::Equals(..., [StringComparison]::Ordinal)`）——pwsh 7 基于 ICU，`-ne` 是文化敏感比较，会把 NFC 与 NFD 判为相等，导致扫描恒为 0。
- **macOS 上 SMB 卷的「目录重命名」会偶发 `Permission denied`（EPERM）**：与 Windows 共享权限无关，根因是 macOS SMB 客户端的**本地目录枚举缓存**（`dir_cache`）。特征很好认：**只有目录**重命名会失败、**文件**重命名/移动从不失败；快速连发时 10–40% 随机失败，放慢节奏即恢复；同一操作在 Windows 侧（`[IO.Directory]::Move`）与 NTFS 本地重命名 100% 成功，服务端日志也无任何拒绝记录。修法：写 `/etc/nsmb.conf` 的 `[default]` 段（`dir_cache_max_cnt=0`，必要时再加 `dir_cache_off=yes`）并**重挂**共享使其生效（重启后新建的挂载自动带上）；实测开启该配置后压测由 10–40% 失败降到 0/120。应急绕法（不建议长期依赖）：`cp -R` + `rm -rf`，或在 Windows 侧经 SSH 用 `[IO.Directory]::Move`。（若你遇到的是**确定性**失败——每次必失败、文件改名却从不失败——那是下一条的原因。）
- **SMB 卷上的「目录改名」被确定性拒绝（`Permission denied` / EACCES）：目录子树里有文件正被本地进程打开**（2026-10-10 实测）。与上一条 `dir_cache` 的偶发失败是两回事，区分特征：本条**每次都失败**、**文件改名完全不受影响**、被拒的是该目录**及其全部祖先目录**。按实测，只要子树内（任意深度）有文件被打开，祖先链上的目录改名就会被服务端以 `STATUS_ACCESS_DENIED` 拒绝，客户端报 EACCES。证据与边界：
  - 服务端无责：从 Windows 侧以 DELETE 权限打开 `D:\跑团\...\第一章` 与 `...\images` 均为 `OK`（目录本身没有共享冲突句柄），NTFS 也无异常。
  - 新建目录（哪怕含子目录、含文件）改名 20/20 成功，说明不是"目录不能改名"。
  - 受控复现：新建 `__v1/sub/f.txt` 并用 `python3 -c "open(path)"` 只读打开它，`mv __v1` 立即 EACCES；kill 掉该进程后同一条 `mv` 立即成功。同样的实验在本机 APFS 上**不**阻塞，所以这是该 SMB 挂载的行为。
  - 从 Windows 侧 `[IO.Directory]::Move` **同样被拒**：Mac 客户端持有的 SMB 句柄在服务端一样挡路，所以"绕到 Windows 侧改名"这条路走不通（这与 `dir_cache` 那条的应急绕法不同）。
  - 真凶是一个常见扩展：`kisstkondoros.vscode-gutter-preview`（Image preview）的 LSP（`~/.trae-cn/extensions/kisstkondoros.vscode-gutter-preview-*/dist/server.js`）。它的 `copyFile()` 用 `createReadStream`/`createWriteStream` 把图片复制到工作区 temp 时**把源图与临时文件的 fd 都泄漏了**，fd 呈成对形态：`Nu`（temp 副本）+ `Nr`（卷上原图）；该扩展 `activationEvents: onStartupFinished`，启动即常驻，于是它"看过"哪张图，那张图所在的目录树从此改不了名，直到进程退出。
  - 处置：`lock-release <路径>`（IDE 里则是资源管理器右键「释放占用」）。默认只终止可安全重启的 IDE 语言服务（C1），IDE 核心进程（renderer / extensionHost / fileWatcher）拒绝终止并提示重载窗口（C2），其他进程只报告、要 `--include-external` 才终止（C3）。**释放可能不持久**——语言服务会被 IDE 的 LanguageClient 自动重启，所以释放后要尽快改名。
  - 遗留：`dist/server.js` 的泄漏点只坐实到 `copyFile` 这一层，没逐行定位；释放的持久性未做长时观察（观察到过一次 LSP 重启后并未重新抓取图片 fd 的正面迹象）。
- **SMB 共享目录里的「文件夹」删不掉（`Resource busy` / EBUSY）——根因尚未定论，别急着下结论**。现象（实测）：该目录里**删文件正常**、建目录/重命名/改 xattr 都正常，**只有删子目录**失败；上层目录、其他共享、Windows 侧本地删除全都正常。已排除：NFD 名、ACL/权限、共享配置（跑团/项目 参数逐项相同）、NTFS 健康（`chkdsk D: /scan` 干净）、macOS 客户端挂载会话（新建临时共享 + 全新挂载会话，同样失败）。已观察到的相关性：出问题的目录在 Windows 侧**独占打开会失败**（`err=32 ERROR_SHARING_VIOLATION`），即服务端确实有它的句柄，而 `Get-SmbOpenFile` 里查不到（指向本地进程句柄）；关闭当时打开着该目录（或其 `images` 子目录）的程序后立即恢复正常。**不要采信"Mac 侧进程 cwd 停在该目录里"这个解释**：用后台 bash 进程与 `os.chdir` 两种方式构造均**未能复现**（2026-10-09 实测），它曾把我自己带偏。有效绕法：把待删目录先移出该目录再删，或从 Windows 侧删（不经 SMB，见 `tools/fix/nfd_fix.dart delete --path <Mac 路径>`）。**2026-10-10 新增线索（未验证）**：上一条的根因——`gutter-preview` 长期持有 `images` 子目录里的图片 fd——很可能就是本条里那个"服务端句柄"的来源，两条可能是同一个原因；排查时先用 `lock-release <目录>` 把这一层排掉，再考虑其他解释。

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
| 目录改名报 `Permission denied`（每次必失败、文件改名却正常） | 是"子树里有文件被本地进程打开"（见第 5 节）：先 `lsof \| grep -F '<目录>'` 看是谁，再 `lock-release <目录>` 释放；IDE 里也有右键「释放占用」。释放后要尽快改名 |
