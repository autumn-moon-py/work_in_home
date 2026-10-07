# win_share

Mac 与 Windows 之间按需互访对方目录的桌面工具。单个 Flutter 工程同时构建两端，界面共用，平台差异全部收敛在各自的 `LocalSide` 实现里。

## 两个方向

| 方向 | 源端做什么 | 目标端看到什么 |
| --- | --- | --- |
| Windows → Mac | 为每个共享区建一个 SMB 共享（UAC 提权） | Mac 上挂载为 `/Volumes/<共享名>`，可开机自动挂载 |
| Mac → Windows | 只发布**一个容器共享**，各共享区是容器内的真实子目录 | Windows 上一个盘符，路径为 `<盘符>:\<容器内相对路径>` |

反向之所以用"容器"模型：一个盘符只能映射一个共享根，逐条映射会耗光盘符，所以 Mac 侧只发布一个容器目录，由它承载所有共享区。

另一端登录后盘符自动恢复（`net use /persistent:yes`），共享区子文件夹随盘符一起出现。

## 互相发现与数据同步

- 两端各起一个同端口（47824）HTTP 服务，一次 `POST /sync` 完成双向交换：发起方带上自己的快照，对端合并后把对端快照同包回传。因此只有"知道对端地址"的一端需要主动发起。
- 条目靠"方向 + 共享名"跨端对齐（两端 id 各自生成、不可比），靠 `updatedAt` 判新旧；删除会留下墓碑随快照广播，避免被对端的旧快照复活。
- 源端拥有目录与授权账户，访问方拥有挂载偏好，合并时按角色各取自己那一半字段。

## 环境与依赖

- Flutter SDK（本仓库约定用 `fvm flutter`）
- 两端都需要 ZeroTier 之类的虚拟网络互通；Mac 侧额外需要 SSH 私钥，用于对 Windows 执行 PowerShell
- 依赖仅 `tray_manager`（macOS 菜单栏常驻）与 `window_manager`，其余走系统自带能力（`sharing` / `mount` / `diskutil` / `osascript` / `security` / PowerShell）

## 构建与运行

```bash
fvm flutter analyze            # 静态检查（本项目不写测试）
fvm flutter run -d macos       # 开发运行
fvm flutter build macos --debug
fvm flutter build windows      # 在 Windows 机器上执行
```

macOS 构建产物：`build/macos/Build/Products/Debug/win_share.app`。

## 首次使用

**Mac 侧（作为源端）**

1. 「设置 Windows 连接…」填 Windows 的虚拟网络地址、SSH 用户与私钥路径，以及 Mac 上用于文件共享的账户名。
2. 「设置容器目录…」选一个容器目录（默认 `~/WinShare`）、SMB 共享名（ASCII，如 `macshare`）与 Windows 盘符（留空自动探测）。
3. 点「发布并映射」：发布容器（弹系统授权框）→ 在对端登记凭据 → 映射盘符。首次会要求输入本机账户密码，只写进钥匙串用于在对端登记，之后可复用。
4. 添加共享区时选「Mac → Windows」，目录必须落在容器目录内，Windows 侧路径为 `<盘符>:\<相对路径>`。

**Windows 侧（作为访问方）**

1. 「设置 Mac 连接…」填 Mac 的虚拟网络地址与 Mac 上的账户名。
2. 「设置 Mac 共享…」填要映射的 Mac 容器共享名与盘符。
3. 「映射到本机」输入一次 Mac 账户密码，交给 Windows 凭据管理器登记。

**Windows 侧（作为源端）**

添加共享区时选「Windows → Mac」并选目录，点「创建共享」（弹 UAC）；Mac 侧会通过同步拿到这条记录，在 Finder 里点「挂载」即可。Windows 上需要有一个能用于网络登录的账户（默认 `winshare`，菜单「共享账户说明…」里有创建脚本），空密码账户无法从网络登录 SMB。

**macOS 侧还需**：在 系统设置 → 通用 → 共享 → 文件共享 → 选项 里勾选用于 SMB 登录的账户，否则 Windows 侧会报密码错误或拒绝访问。

## 配置与日志

| 内容 | Mac | Windows |
| --- | --- | --- |
| 配置（共享区、容器设置、对端连接） | `~/Library/Application Support/win_share/shares.json` | `%APPDATA%\win_share\shares.json` |
| 日志（按天，保留 7 天） | `~/Library/Logs/win_share/win_share-YYYY-MM-DD.log` | `%LOCALAPPDATA%\win_share\logs\` |
| 凭据 | 钥匙串 `win_share.smb` | Windows 凭据管理器 |

日志 tag：`app` 启动锚点（含 pid）、`tick` 每轮巡检的挂载表快照、`health` 自动挂载决策与状态翻转、`mount` / `unmount` 单次耗时与结果、`orphan` 无配置归属的挂载点、`sync` 数据交换、`channel` 发布与映射。

## 排障

- **某个共享没挂上**：先看当天日志的 `health` 与 `mount` 行，再用系统视角交叉核对：

  ```bash
  mount | grep -i smbfs
  nc -vz -G 3 <对端IP> 445
  ls /Volumes/
  ```

  自动挂载只在 Mac 侧生效，触发条件为启动首轮、本轮之前处于已挂载、或对端由不可达转为可达，并受 30 秒退避约束（避免认证失败反复弹窗）。

- **Windows 看不到 Mac 的共享区**：跑 `fvm dart run tools/probe/publish_check.dart` 自检共享点、盘符与容器判定。判定结果里 `ok` 表示在 Windows 侧能读到该子目录；`missing` 表示共享根连得上但读不到子目录，通常是目录不在容器内或相对路径对不上；`unreachable` 表示连共享根都失败，指向凭据或网络。
- **两端数据不同步**：确认对端地址填了、两端 47824 端口可达；日志里 `sync` 行会给出失败原因。
- **虚拟网络不通**：`fvm dart run tools/probe/mac_probe.dart --seconds 60` 与 Windows 侧的 `tools/probe/win_probe.ps1` 对跑，看是否互相收到 `[RECV]`。

## 目录结构

```
lib/
  main.dart          入口：按平台选 LocalSide，装配主题与窗口
  model.dart         数据模型与配置落盘（ConfigStore）
  side.dart          LocalSide 抽象与视图模型
  ui.dart            两端共用界面与设置对话框
  side_mac.dart      Mac 侧动作：挂载、发布容器、SSH 驱动 Windows、自动挂载巡检
  side_win.dart      Windows 侧动作：建/删共享、映射盘符
  smb_mac.dart       macOS SMB 编排（mount / diskutil / 访问路径符号链接）
  smb_win.dart       Windows SMB 编排（本机 PowerShell / UAC 提权 / net use）
  publish_mac.dart   macOS 共享发布、钥匙串凭据、SSH 远程执行
  sync.dart          两端共享区数据同步
  log.dart           按天滚动的追踪日志
tools/probe/         排障探针（Mac / Windows / 发布自检）
```

## 开发约定

项目结构、AI 可调用的工具与探针、动手前必须知道的坑，见 [AGENTS.md](AGENTS.md)。
