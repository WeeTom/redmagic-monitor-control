# 红魔显示器 Windows 版

这是 REDMAGIC GM001J 4K 的独立 Windows x64 托盘程序。双击 `RedMagicMonitor.exe` 会启动托盘图标，单击图标开关面板。首次打开为 DDC，之后恢复上次查看的页签。「登录时启动」默认关闭，可在面板内调整。

[下载 Windows x64 1.0.0](https://github.com/WeeTom/redmagic-monitor-control/releases/download/v1.0.0/RedMagicMonitor-1.0.0-windows-x64.zip)

程序在启动时按 Windows 首选语言列表选择界面语言，支持简体中文、繁體中文、English、日本語、한국어、Español、Русский、Français、Deutsch 和 Português。列表中没有受支持的语言时使用英文。

## 本机配置

首次打开 DDC 或蓝牙页，应用会查找 GM001J。DDC 识别当前活动输出的 EDID；蓝牙扫描广播，并查询 Windows 已连接的同型号设备。单台设备通过核验后自动绑定。发现多台时，点击列表中的目标：DDC 显示序列号及输出名称，蓝牙显示地址。在两页中选择同一台物理显示器。若未发现设备，请检查显示线或显示器 OSD 的蓝牙开关，然后点「刷新」。

绑定信息和上次页签保存在 `%LOCALAPPDATA%\RedMagicMonitor\settings.json`。应用会优先使用已有绑定；换显示器时，点击相应页顶部的「GM001J 4K ▾」重新选择。蓝牙会读取 FFD2 身份并检查控制服务，再记住地址；正常使用无需在终端输入序列号或地址。以前手工填写的 `MonitorSerial`、`BluetoothAddress` 与 `LastPage` 仍然有效。

## 切源与调节

DDC 使用按 EDID 绑定的 Windows 显示输出。Windows 常规查询失败时，程序会在支持的 NVIDIA 输出上复读同一功能，核对功能码、校验和与取值范围。耳机音量需要有效的显示器 3.5 mm 音量回包。拖动音量滑块时，面板预览数值，松手后提交最终值。恢复默认只调整亮度和对比度至 50。

GM001J 的活动视频输入、蓝牙输入源读数和实体 OSD 的「输入信号」可能不同。现场曾同时看到 Windows 画面、DDC 的 DP 回读、蓝牙的 Type-C 回读和实体菜单的 Type-C。蓝牙页显示 DDC 与蓝牙各自的读数，并标出上次确认的缓存值。实体菜单以显示器上的显示为准。

蓝牙页通过 WinRT 查询输入源、图像模式、HDR 和氛围灯。切源完成需要两次独立确认。闲置五分钟释放连接，也可在面板中手动断开。下一次需要蓝牙时按需重连。日志保存于 `%LOCALAPPDATA%\RedMagicMonitor\monitor.log`。

在 DDC 页明确选择输入源并获得视频输入回读后，程序通过已配置的蓝牙通道核对菜单值。两个读数已一致时直接确认。菜单值不一致时，程序复核当前视频源，再向蓝牙提交一次同目标设置，随后查询两次。

在 Windows 蓝牙页点击 Type-C 时，程序先通过 DDC 切换视频，再核对蓝牙菜单。这用于从 Windows DP 切回合盖的 Mac。即使菜单已经显示 Type-C，仍可再次点击。切走 DP 后若 Windows 失去视频回读，面板会分别显示视频源与菜单的确认状态。DDC 不可用时会尝试原有蓝牙命令。其他输入源继续通过蓝牙切换。启动、切页和刷新只查询。

## 导出输入源快捷方式

在 DDC 或蓝牙页的「输入源」区域点击「导出快捷方式」，选择 Type-C、DP、HDMI 1 或 HDMI 2，再选保存位置。双击生成的 Windows 快捷方式（`.lnk`）时，程序才会切到指定接口。可为每个接口分别保存一个快捷方式，也可从第三方软件打开它。托盘已运行时会接收切换请求，未运行时会自动启动。重复打开同一快捷方式可重新请求该接口。

支持单独指定程序和参数的工具也可直接运行 `RedMagicMonitor.exe`。例如，参数 `--switch-input type-c` 会切到 Type-C。四个接口的参数值分别为 `type-c`、`dp`、`hdmi-1` 和 `hdmi-2`。快捷方式指向导出时的程序位置，移动程序后可重新导出。

快捷方式也会在需要时自动查找显示器。首次使用即可通过 DDC 切换；DDC 不可用且蓝牙尚未绑定时会发现并验证唯一的蓝牙目标。发现多台时请先在托盘中选择。四个接口的快捷方式都优先通过 DDC 切换视频。确认 DDC 指令尚未发送时，程序可直接尝试通过已绑定的蓝牙连接切源。若 DDC 已尝试写入，程序会先查询蓝牙菜单。连续两次读到目标就结束菜单核对。若菜单值不符，程序会复核活动视频，仅在它已到达目标，或 DDC 报错且原输入持续得到确认时，才补发一次蓝牙设置。

第三方软件可等待切换请求进程退出，再读取退出码。`0` 表示活动视频已确认在目标接口，`1` 表示切换失败或活动视频未确认，`2` 表示切换参数无效。切离 Windows 后可能失去 DDC 回读，此时即使蓝牙菜单显示目标，也会返回 `1`。面板和 `monitor.log` 会分别列出活动视频输入和蓝牙菜单的确认情况。

## 构建与验证

使用 .NET 10 SDK，在本目录运行以下命令可生成自包含的 Windows x64 EXE。

```powershell
dotnet publish .\RedMagicMonitor.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false
```

`--show` 可在启动时打开面板。`--probe-ddc` 和 `--probe-bluetooth` 各运行一次查询并退出，分别在本机数据目录生成 `ddc-read.json` 和 `bluetooth-read.json`。用 `--data-dir` 可指定单独的配置和日志目录。

在本目录运行 `dotnet run --project ..\tests\windows\ProtocolChecks.csproj -c Release` 可离线检查语言匹配和翻译资源、端口映射、蓝牙组帧与音量回包解析。

程序图标采用项目的 macOS 应用图案。深色和浅色托盘图标取自同一图案的显示器轮廓。[图标源文件](../assets/Icon.swift)

协议与硬件参考见仓库中的[型号配置](../device-profile.json)和[蓝牙接入说明](../hardware/README.txt)。
