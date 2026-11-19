# 红魔显示器 Windows 版

这是 REDMAGIC GM001J 4K 的独立 Windows x64 托盘程序。双击 `RedMagicMonitor.exe` 会启动托盘图标，单击图标开关面板。首次打开为 DDC，之后恢复上次查看的页签。「登录时启动」默认关闭，可在面板内调整。

## 本机配置

程序从 `%LOCALAPPDATA%\RedMagicMonitor\settings.json` 读取设备绑定和上次页签。填写显示器 EDID 序列号和 FFD2 蓝牙地址，并照下面的格式保存。在没有填写 EDID 序列号时，DDC 要求系统中恰好有一台有效 EDID 的 GM001J。蓝牙连接会先核对 FFD2 身份。

```json
{
  "LastPage": "Ddc",
  "MonitorSerial": "<显示器 EDID 序列号>",
  "BluetoothAddress": "00:00:00:00:00:00"
}
```

## 切源与调节

DDC 使用按 EDID 绑定的 Windows 显示输出。Windows 常规查询失败时，程序会在支持的 NVIDIA 输出上复读同一功能，核对功能码、校验和与取值范围。耳机音量需要有效的显示器 3.5 mm 音量回包。拖动音量滑块时，面板预览数值，松手后提交最终值。恢复默认只调整亮度和对比度至 50。

GM001J 的活动视频输入、蓝牙输入源读数和实体 OSD 的「输入信号」可能不同。现场曾同时看到 Windows 画面、DDC 的 DP 回读、蓝牙的 Type-C 回读和实体菜单的 Type-C。蓝牙页显示 DDC 与蓝牙各自的读数，并标出上次确认的缓存值。实体菜单以显示器上的显示为准。

蓝牙页通过 WinRT 查询输入源、图像模式、HDR 和氛围灯。切源完成需要两次独立确认。闲置五分钟释放连接，也可在面板中手动断开。下一次需要蓝牙时按需重连。日志保存于 `%LOCALAPPDATA%\RedMagicMonitor\monitor.log`。

在 DDC 页明确选择输入源并获得视频输入回读后，程序通过已配置的蓝牙通道核对菜单值。两个读数已一致时直接确认。菜单值不一致时，程序复核当前视频源，再向蓝牙提交一次同目标设置，随后查询两次。

在 Windows 蓝牙页点击 Type-C 时，程序先通过 DDC 切换视频，再核对蓝牙菜单。这用于从 Windows DP 切回合盖的 Mac。即使菜单已经显示 Type-C，仍可再次点击。切走 DP 后若 Windows 失去视频回读，面板会分别显示视频源与菜单的确认状态。DDC 不可用时会尝试原有蓝牙命令。其他输入源继续通过蓝牙切换。启动、切页和刷新只查询。

## 构建与验证

使用 .NET 10 SDK，在本目录运行以下命令可生成自包含的 Windows x64 EXE。

```powershell
dotnet publish .\RedMagicMonitor.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false
```

`--show` 可在启动时打开面板。`--probe-ddc` 和 `--probe-bluetooth` 各运行一次查询并退出，分别在本机数据目录生成 `ddc-read.json` 和 `bluetooth-read.json`。用 `--data-dir` 可指定单独的配置和日志目录。

在本目录运行 `dotnet run --project ..\tests\windows\ProtocolChecks.csproj -c Release` 可离线检查端口映射、蓝牙组帧与音量回包解析。

程序图标采用项目的 macOS 应用图案。深色和浅色托盘图标取自同一图案的显示器轮廓。[图标源文件](../assets/Icon.swift)

协议与硬件参考见仓库中的[型号配置](../device-profile.json)和[蓝牙接入说明](../hardware/README.txt)。
