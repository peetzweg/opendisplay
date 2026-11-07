# Independent cursor refresh

Mac cursor position polling runs at 240 Hz with quarter-point movement
precision. iPad uses a CADisplayLink requesting up to the panel's 120 Hz maximum,
independent of video FPS, and pauses while idle or hidden. Cursor image changes
settle briefly to suppress transient shape flicker.

The combined preview recorded 119–120 Hz display callbacks and the user
confirmed more responsive pointer movement. This does not change hardware
input report rate or prove video FPS/physical presentation latency. The UDP
acknowledgement correctness fix is proposed separately; this change retains
existing TCP fallback. Validate battery/thermal behavior on more devices.

## 简体中文

Mac 光标位置采样为 240 Hz，保留四分之一桌面点精度。iPad 独立光标请求最高
120 Hz 显示回调，静止或隐藏时暂停。光标图像短暂稳定后更新，减少瞬时形状闪烁。
组合预览测得 119–120 Hz 回调，用户确认移动更跟手。这不改变硬件上报频率，
也不证明视频帧率或物理显示延迟。UDP 确认修复另提，保留 TCP 回退；更多设备
功耗与温度表现仍需验证。
