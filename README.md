# RedMagic Monitor Control · 红魔显示器

通过 macOS 菜单栏或 Windows 系统托盘控制 REDMAGIC GM001J 4K 标准版显示器，切换 Type-C、DP、HDMI 1、HDMI 2，调整亮度、对比度和 3.5 mm 耳机音量。macOS 应用版本为 0.5.1，支持 Apple Silicon 和 macOS 14 或更高版本。Windows 应用版本为 0.5.0，支持 x64。[Windows 构建与配置](windows/README.md)

## macOS 快速开始

准备 Python 3 和 Xcode Command Line Tools。在仓库根目录运行以下命令构建应用。

```sh
python3 build.py
```

首次使用时，将需要控制的通道绑定到自己的显示器。DDC 使用 EDID 中的字母数字序列号。运行以下命令，在 GM001J 条目下找到 `AN Serial`。

```sh
make -C third_party/m1ddc m1ddc
./third_party/m1ddc/m1ddc display list all detailed
```

蓝牙使用显示器广播名末尾的 12 位十六进制数，每两位一组，用冒号分隔。把下面的示例值换成实际值，只执行所需通道对应的配置行。

```sh
defaults write com.local.redmagic-display MonitorSerial -string 'YOUR_EDID_SERIAL'
defaults write com.local.redmagic-display BluetoothAddress -string 'AA:BB:CC:DD:EE:FF'
open "build/红魔显示器.app"
```

更换设备配置后，退出并重新打开应用。使用蓝牙时，请开启显示器菜单中的蓝牙，并允许 macOS 的蓝牙权限请求。点击菜单栏的显示器图标打开面板，底部可开启“登录时启动”。长期使用可将构建好的应用移到“应用程序”文件夹。

## 两种控制方式

- **DDC** 支持四个输入源、屏幕亮度、对比度和耳机音量。三个滑块范围均为 0–100，也可按 1 微调。“恢复默认设置”只把亮度和对比度设为 50。音量调节使用显示器支持的厂商 DDC 指令 C8，已在原厂固件上验证设置为 0 后，显示器菜单显示 0，3.5 mm 耳机静音。
- **蓝牙** 支持四个输入源、8 种画面模式、HDR 和氛围灯。氛围灯有 7 种效果、3 档亮度和颜色选择，多彩流动模式还可以分别设置前后灯色。连接可供多次操作复用，闲置五分钟后断开。使用手机 App 时，可先在蓝牙页手动断开。
- **输入源与显示器菜单** DDC 读取活动视频端口，蓝牙读取显示器菜单中保存的输入选项。在一台实际显示 DP 画面的 GM001J 上，蓝牙仍报告 Type-C；通过蓝牙重选 DP 后，两次查询和实体菜单都确认了 DP。在 DDC 页面选择端口时，应用会在蓝牙已配置并获授权时尝试同步菜单。其他工具切源后，也可在蓝牙页直接点选活动端口，即使该按钮已选中。
- **USB 与 HDMI** 在实测的 Type-C / DP 双机连接中，蓝牙切源时，键鼠的 USB 上行通道也随之切换。HDMI 2 已通过蓝牙切源并确认画面。HDMI 1 画面及两个 HDMI 端口的 DDC 切换尚待实机验证。
- **状态与回读** 首次使用默认 DDC，之后记住上次选择。切换面板时先显示缓存，再按需连接和补读。连续拖动只提交最新目标，写入后通过独立查询核对结果。回读失败时保留上次确认值，点刷新可重新读取。启动或唤醒后的自动检测只读。

## Windows 快速开始

Windows 上可直接下载并解压源码。[下载最新源码 ZIP](https://github.com/WeeTom/redmagic-monitor-control/archive/refs/heads/main.zip)

安装 .NET 10 SDK 后，可在 PowerShell 中克隆仓库并启动托盘程序。

```powershell
git clone https://github.com/WeeTom/redmagic-monitor-control.git
cd redmagic-monitor-control
dotnet run --project .\windows\RedMagicMonitor.csproj -c Release -- --show
```

首次使用时按 Windows 说明绑定显示器。源码也可构建成自包含的单文件 EXE。[Windows 构建与配置](windows/README.md) · [型号协议配置](device-profile.json) · [蓝牙接入说明](hardware/README.txt)

使用 Visual Studio 的 Developer PowerShell 和支持 C11 的 MSVC，可单独构建并运行协议测试。

```powershell
cl /nologo /std:c11 core\GMProtocol.c tests\protocol_test.c /Fe:protocol-test.exe
.\protocol-test.exe
```

## macOS 离线测试

在运行过 `python3 build.py` 的仓库内执行以下命令。协议测试和应用自检均可离线运行。

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined core/GMProtocol.c tests/protocol_test.c -o build/protocol-test
./build/protocol-test
"./build/红魔显示器.app/Contents/MacOS/RedMagicDisplay" --self-test
```

可用 `--preview /absolute/path.png` 渲染演示界面，加 `--preview-bluetooth` 可预览蓝牙页。退出常驻应用后，`--probe` 会读取 DDC 状态，`--probe-keepalive` 检查两轮蓝牙查询是否复用同一连接。日志保存在 `~/Library/Logs/RedMagicDisplay/`。

## 许可证

项目采用 MIT 许可证。Apple Silicon DDC 传输使用 waydabber 的 m1ddc，保留了上游版权声明和本地修改记录。[项目许可证](LICENSE) · [m1ddc 许可证](third_party/m1ddc/LICENSE) · [m1ddc 修改说明](third_party/m1ddc/LOCAL-CHANGES.txt)
