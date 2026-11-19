GM001J 蓝牙 Central 接入

Windows 蓝牙客户端和外接按键硬件均可复用 core/GMProtocol.c 和 core/GMProtocol.h。传输层需要由各平台提供，设备及 GATT 服务信息见仓库根目录的 device-profile.json。

1. 连接目标显示器，在身份服务读取 FFD2，用返回的六字节地址确认设备。订阅控制服务的 FFE2 通知。FFE1、FFE2 和 FFD2 使用标准 Bluetooth Base UUID 展开的特征 UUID。
2. 使用 64 位单调递增的毫秒时钟驱动状态机。传输就绪时调用 gm_poll，将返回的三个字节作为一次 FFE1 Write Without Response 发出。每个连接串行执行一条操作。
3. 通知可能拆分或合并协议帧。经 gm_decode 解析后，将每一帧交给 gm_frame_reply。开始新查询或更换连接时重置解码器。设置成功以独立的状态查询确认为准。
4. 断线后最多调用一次 gm_reconnect，重新校验身份、订阅通知，再继续轮询。已发出的设置在重连后会进入状态核对阶段。
5. 外接按键的去抖由硬件实现。等待前次操作完成并释放按钮后，再接收下一次按键。
