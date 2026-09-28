# 键盘与触控板预览

[English](HARDWARE_INPUT.md) | 简体中文

本地实现基于 `main` 的 `2e74ced51924bbda14a4d897a8459b710b37a7d9`，围绕 [硬件键盘需求 #6](https://github.com/peetzweg/opendisplay/issues/6) 开发。
已有社区工作包括 kdbhalala 的 [#247](https://github.com/peetzweg/opendisplay/pull/247) 和 Portgas443 的 [#251](https://github.com/peetzweg/opendisplay/pull/251)。本实现独立编写；提交上游前应与这些 PR 协调，并保留原作者署名。

## 功能

- iPad 捕获物理键盘按下/松开事件，由 Mac 键盘布局和输入法决定文字。Mac 负责长按重复；不传输 iPad 合成的 Unicode 文本。
- 触控板相对移动可跨 Mac 显示器，支持按钮、拖动和滚动。指针默认速度 1.25×，滚动默认 0.5×，可独立调整及反转滚动方向。
- 双指滚动只通过 UIKit 滚动手势采集。手势累计位移逐次求差，保留立即反向；结束时不把坐标归零当作反向移动。
- 首次进入前台、设备连接及视图加入窗口时重新获取输入焦点与指针锁定。失焦、后台、断线、停止捕获时释放本会话按键与按钮。
- 不记录输入文字、按键序列或剪贴板内容。

## 中英双语

新增功能使用 `Shared/InputStrings.xcstrings`，英文为源语言，包含简体中文 `zh-Hans`，随系统/应用语言偏好选择。新增控件、提示、无障碍标签和带分辨率/目标帧率的连接状态均已纳入目录。

这仅覆盖本分支新增功能，不代表已完成全项目的 [#269](https://github.com/peetzweg/opendisplay/issues/269)。原有产品文案、日语、西班牙语及网站仍属于后续工作。

| English | 简体中文 |
|---|---|
| Keyboard & trackpad input | 键盘与触控板输入 |
| Pointer speed | 指针速度 |
| Scroll speed | 滚动速度 |
| Reverse scroll direction | 反转滚动方向 |
| Reset trackpad settings | 重置触控板设置 |


## 兼容性与边界

预览中的可选消息分为协议 4（键盘/绝对指针）、5（相对指针）、6（桌面点滚动）；最低兼容版本保持 1。仅向具备能力的对端发送新增消息。具体上游协议编号需要维护者协调，不能把本地预览编号当作上游已发布的协议。

Command-Tab、Globe/Home、媒体键等可能被 iPadOS 保留。新 Mac 配旧接收端、旧 Mac 配新接收端仍应保留视频与原有触摸能力，但完整跨版本真机矩阵尚未全部验收。

## 验证

构建命令及真机检查步骤见 [英文说明](HARDWARE_INPUT.md#validation-commands)。单元测试替换事件投递端，只验证事件和状态，不向用户应用输入。用户已在真实 iPad 妙控键盘上确认英文、中文、长按重复、首次输入、双指滚动和更跟手的光标；其余组合不能仅以编译通过视为验收。

本地 iOS 真机签名需要自己的开发证书、描述文件、独立开发 Bundle ID 与开发者模式。不要提交私钥、签名描述文件或个人开发配置。

保留原项目 GPL-3.0 许可和署名。

## 本轮追加

新增可选的 Command/Option 交换，覆盖左右键与键盘、点击、拖动、滚动修饰位。默认关闭；开启后使用 Option+Tab、Option+空格操作 Mac，原来的 Command 组合键仍归 iPadOS。

直接监听握手与视频就绪，并在切回前台、窗口获得焦点时短暂重试输入接管；保持根视图身份，释放旧按键状态。组合预览完成两次不重启、不缩放窗口的切换测试，均恢复键盘焦点与鼠标锁定。用户随后确认其它输入问题已解决。
