# RedMagic Monitor Control · 红魔显示器

**简体中文** · [English](README.en.md)

通过 macOS 菜单栏或 Windows 系统托盘控制 REDMAGIC GM001J 4K 标准版显示器，切换 Type-C、DP、HDMI 1、HDMI 2，调整亮度、对比度和 3.5 mm 耳机音量。

1.0.0 的 macOS 和 Windows 界面跟随系统语言，支持简体中文、繁体中文、英语、日语、韩语、西班牙语、俄语、法语、德语和葡萄牙语。

## 懒人福音

- **macOS（Apple Silicon，macOS 14 或更高版本）**　打开 DMG，把里面的应用拖进「应用程序」，再从那里打开。点击 macOS 菜单栏里的显示器图标即可打开控制面板。[下载 macOS 1.0.0 DMG](https://github.com/WeeTom/redmagic-monitor-control/releases/download/v1.0.0/RedMagicMonitor-1.0.0-macOS-arm64.dmg)
- **Windows x64**　解压 ZIP，将文件夹放在准备长期使用的位置，双击 `RedMagicMonitor.exe`。点击任务栏时钟旁的显示器图标打开面板。找不到图标时，展开隐藏图标（⌃）。[下载 Windows 1.0.0 ZIP](https://github.com/WeeTom/redmagic-monitor-control/releases/download/v1.0.0/RedMagicMonitor-1.0.0-windows-x64.zip)

**首次打开。** macOS 版没有 Developer ID 签名，也未经 Apple 公证。如果 macOS 拦截，先从「应用程序」尝试打开一次，再到「系统设置」→「隐私与安全性」，在该应用旁选择「仍要打开」并确认。如果 Windows SmartScreen 提示风险，确认文件来自上面的发布页，且系统提供该选项时，选择「更多信息」→「仍要运行」。

**首次连接（macOS 和 Windows）。** 接好显示线，打开应用即可自动识别 GM001J。应用会记住识别到的显示器，下次启动直接使用。从旧版升级会沿用原来的绑定。

- **DDC**　首次打开 DDC 页时，应用会从 EDID 识别连接的 GM001J。只有一台且序列号可唯一识别时会自动绑定；有多台时，从列表中选一台即可。
- **蓝牙**　在显示器菜单里开启蓝牙，再打开应用的蓝牙页。如果系统请求蓝牙访问权限，请允许。应用会查找附近的 GM001J 并核对设备身份。只有一台且通过核验时会自动绑定；有多台时，按地址选择与 DDC 对应的同一台显示器。
- **未找到显示器时**　检查显示线或显示器的蓝牙开关。Windows 上使用 DDC 时，还要确认显示器是当前活动的显示输出。回到相应页面，在 macOS 上点「重新搜索」，在 Windows 上点「刷新」。
- **换显示器时**　右键点击 macOS 菜单栏图标，选「选择要控制的显示器」。Windows 上点击控制页顶部的「GM001J 4K ▾」即可重新选择。

## 赞助 · Donation

如果这个工具帮到了你，欢迎扫码支持后续开发。点击下方二维码可放大，或在应用的「捐献」页扫描同一组收款码。

| Venmo | 支付宝 | 微信支付 |
| :---: | :---: | :---: |
| <a href="assets/donation/qr/venmo.png"><img src="assets/donation/qr/venmo.png" alt="Venmo 收款码" width="172"></a> | <a href="assets/donation/qr/alipay.png"><img src="assets/donation/qr/alipay.png" alt="支付宝收款码" width="172"></a> | <a href="assets/donation/qr/wechat-pay.png"><img src="assets/donation/qr/wechat-pay.png" alt="微信支付收款码" width="172"></a> |
| @weetom | ¥6.66 | ¥6.66 |

## macOS 快速开始

从下载的 DMG 安装后，直接从「应用程序」启动即可。自行构建时，准备 Python 3 和 Xcode Command Line Tools，在仓库根目录运行以下命令。

```sh
python3 build.py
open "build/红魔显示器.app"
```

点击菜单栏的显示器图标打开面板，底部可开启「登录时启动」。长期使用可将构建好的应用移到「应用程序」文件夹。

### 导出切源快捷应用

在任一控制页的输入源区域点「导出快捷方式…」，选择 Type-C、DP、HDMI 1 或 HDMI 2，再选择保存位置。导出后，访达会选中新建的 `.app`。例如，在「快捷指令」中添加「打开 App」操作，选择「切换到DP.app」，运行这条指令即可切到 DP。

菜单栏应用完全退出后，快捷应用仍可独立使用 DDC 和蓝牙。已绑定两个通道时，快捷应用先尝试 DDC，切换并回读成功后直接退出。DDC 无法发送时，通过蓝牙核对显示器身份，重选目标接口。若 DDC 已发送但切屏后无法回读，先查询蓝牙菜单，只有菜单仍指向其他接口才补发。蓝牙回读反映显示器菜单中的选择。DDC 成功后，显示器菜单可能仍保留原来的值。

导出时，应用会自动查找另一种连接方式。两个通道都能确认时，快捷应用会同时包含 DDC 和蓝牙。只找到一个通道也可以直接导出。如果有多台显示器，在两种控制页选好同一台后再导出即可。快捷应用首次使用蓝牙时，macOS 可能会请求授权。

## 两种控制方式

- **DDC** 支持四个输入源、屏幕亮度、对比度和耳机音量。三个滑块范围均为 0–100，也可按 1 微调。“恢复默认设置”只把亮度和对比度设为 50。音量调节使用显示器支持的厂商 DDC 指令 C8，已在原厂固件上验证设置为 0 后，显示器菜单显示 0，3.5 mm 耳机静音。
- **蓝牙** 支持四个输入源、8 种画面模式、HDR 和氛围灯。氛围灯有 7 种效果、3 档亮度和颜色选择，多彩流动模式还可以分别设置前后灯色。连接可供多次操作复用，闲置五分钟后断开。使用手机 App 时，可先在蓝牙页手动断开。
- **输入源与显示器菜单** DDC 读取活动视频端口，蓝牙读取显示器菜单中保存的输入选项。在一台实际显示 DP 画面的 GM001J 上，蓝牙仍报告 Type-C；通过蓝牙重选 DP 后，两次查询和实体菜单都确认了 DP。在 DDC 页面选择端口时，应用会在蓝牙已绑定并获授权时尝试同步菜单。其他工具切源后，也可在蓝牙页直接点选活动端口，即使该按钮已选中。
- **USB 与 HDMI** 在实测的 Type-C / DP 双机连接中，蓝牙切源时，键鼠的 USB 上行通道也随之切换。HDMI 2 已通过蓝牙切源并确认画面。HDMI 1 画面及两个 HDMI 端口的 DDC 切换尚待实机验证。
- **状态与回读** 首次使用默认 DDC，之后记住上次选择。切换面板时先显示缓存，再按需连接和补读。连续拖动只提交最新目标，写入后通过独立查询核对结果。回读失败时保留上次确认值，点刷新可重新读取。启动或唤醒后的自动检测只读。

## Windows 快速开始

升级时先退出旧托盘程序，然后用 1.0.0 ZIP 中的 EXE 替换原位置的程序。新版会继续使用已有的设备绑定和快捷方式。[下载与运行](#懒人福音)

在任一控制页的输入源区域点击「导出快捷方式」，选择接口并保存 `.lnk`。打开它即可切源，托盘程序会按需启动。四个接口均优先使用 DDC，必要时通过已绑定的蓝牙接续处理。快捷方式指向导出时的 EXE，移动程序后可重新导出。

如需自行构建，可下载并解压源码。[下载 1.0.0 源码 ZIP](https://github.com/WeeTom/redmagic-monitor-control/archive/refs/tags/v1.0.0.zip)

安装 .NET 10 SDK 后，可在 PowerShell 中克隆仓库并启动托盘程序。

```powershell
git clone --branch v1.0.0 https://github.com/WeeTom/redmagic-monitor-control.git
cd redmagic-monitor-control
dotnet run --project .\windows\RedMagicMonitor.csproj -c Release -- --show
```

Windows 说明提供重新选择显示器的方法、旧版绑定的保存位置，以及从源码构建自包含单文件 EXE 的命令。[Windows 构建与配置](windows/README.md) · [型号协议配置](device-profile.json) · [蓝牙接入说明](hardware/README.txt)

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
swiftc macos/Features.swift macos/InputShortcutExporter.swift tests/input_shortcut_export.swift -o build/test-shortcut-export
./build/test-shortcut-export
```

可用 `--preview /absolute/path.png` 渲染演示界面，加 `--preview-bluetooth` 可预览蓝牙页，加 `--preview-donation` 可预览捐献页。退出常驻应用后，`--probe` 会读取 DDC 状态，`--probe-keepalive` 检查两轮蓝牙查询是否复用同一连接。日志保存在 `~/Library/Logs/RedMagicDisplay/`。

## 许可证

项目采用 MIT 许可证。Apple Silicon DDC 传输使用 waydabber 的 m1ddc，保留了上游版权声明和本地修改记录。[项目许可证](LICENSE) · [m1ddc 许可证](third_party/m1ddc/LICENSE) · [m1ddc 修改说明](third_party/m1ddc/LOCAL-CHANGES.txt)
