# 截图启动响应优化验证

日期：2026-09-15

## 用户问题与证据

用户明确反馈：按截图快捷键后，选区界面出现慢；首轮更新后仍觉得慢，并以 PixPin 的响应为参照。

当前倒计时设置读取为 0。原实现每次额外等待 250ms，再逐屏启动 `screencapture`、落盘 PNG、在主线程两次解码，全部完成后才创建选区。

## 实现

- 截图标注通过 `SCScreenshotManager` 直接获取 CGImage，排除本进程窗口，不再为选区底图做 PNG 往返。
- 取消固定 250ms 等待，避免隐藏应用再激活的窗口切换；截图面板关闭窗口显示动画。
- 按显示器 ID 并发取图，仅在整批成功、布局仍一致时显示。保持 Retina 输出、权限检查和取消语义。
- 仅缓存显示器与过滤器元数据，每次重新取图；显示器模式、位置、分辨率、旋转发生变化或收到屏幕参数通知时失效。错误、取消，以及没有识别到本进程身份时也不复用元数据。没有后台预采集、持续录屏或帧缓存。
- 窗口准备后，显式完成画布布局并绘制首帧，避免只刷新窗口而仍将画布留待之后绘制。
- 首次框选前只创建尺寸和操作提示；完成选区后才创建标注工具栏，重置后复用。全屏模式和全选仍立即具备工具栏。
- 本地 `ScreenshotStartup` 日志只记阶段名和累计耗时，不记录窗口标题、图片或路径。

系统接口依据：本地 macOS SDK 的 `SCScreenshotManager.h`、`SCStream.h`、`SCError.h`，以及 [Apple captureImage 文档](https://developer.apple.com/documentation/ScreenCaptureKit/SCScreenshotManager/captureImage%28contentFilter%3Aconfiguration%3AcompletionHandler%3A%29)。项目最低系统保持 macOS 14。

## 回归

| 检查 | 结果 |
| --- | --- |
| ScreenshotSessionTests | 51 项通过 |
| CaptureDesktopSnapshotTests（第二轮） | 65 项通过；元数据复用、失效竞态、每次新图、并发、取消、失败、Retina、权限错误分类 |
| CaptureAnnotationInteractionTests（最终源码） | 146 项通过；含工具栏延迟创建、重选复用、全选和全图模式；日志 `.build/capture-startup/present/interaction-tests.log` |
| 现有 CaptureTests | 72 项通过；合成图片、权限状态及 OCR |
| 首轮最终 Release 隔离 AppSmokeTests | 97 项通过；另含 QuickPaste 140、原生拖拽 19 等回归 |

合成 OCR 首次在沙盒中因系统无法创建视频像素缓冲失败；同一测试程序在系统服务可访问环境重跑通过。未通过请求额外屏幕权限解决该测试环境问题。

## 实际桌面验证与计时口径

计时起点为 `ScreenshotCoordinator.start()`，终点为首个画布第一次 `draw` 结束，包含权限复核、图像采集、界面创建和绘制；不等于物理按键到显示器出光的测量。

首轮安装后，使用侧栏截图入口连续三次测得 614.7、646.8、649.0ms。采集完成约在 302–315ms，之后到首帧另需约 310–342ms。选区显示、真实拖动框选、工具栏出现及 Esc 取消均成功，未复制或保存测试屏幕。

自动化按键没有触发 Carbon 全局快捷键，因此这三次数据来自共享截图流程的侧栏入口。用户反馈自己的快捷键能唤起选区但仍慢。未对 PixPin 做相同口径的数值基准，不据此宣称已达到 PixPin 速度。

早期一次线程采样未覆盖实际采集时段，不能用于归因具体 CPU 热点。后续 `.build/capture-startup/final/capture-thread-sample.txt` 覆盖截图和取消调用；同时存在自动化 AX 查询造成的主线程布局工作，因此自动化计时不能直接作为物理快捷键耗时。

第二轮（安装 PID 91487）同口径实测：首次 326.6ms，后两次 231.6、173.1ms。重复截图采集完成在 44.5–57.7ms；画布准备约 54–60ms，剩余等待主要发生在激活窗口后到首次 `draw` 之前（约 115–150ms）。

第三轮尝试显式调用 `NSWindow.displayIfNeeded()`（PID 94658）：首次 318.0ms，后两次 253.7、250.5ms。该调用未消除首次绘制等待，不能宣称这一步已加速。原始阶段日志保存在 `.build/capture-startup/final/live-timing.log`。

### 最终安装版

最终版在窗口准备后完成画布布局并显式绘制。安装路径 `/Applications/Xclip.app`，运行 PID 2159，三次相同侧栏入口测试如下：

| 次数 | 采集完成 | 窗口激活完成 | 首个画布绘制完成 |
| --- | ---: | ---: | ---: |
| 应用重启后首次 | 158.0ms | 223.6ms | 225.4ms |
| 第二次 | 58.3ms | 83.5ms | 83.8ms |
| 第三次 | 64.1ms | 75.8ms | 76.1ms |

窗口激活到首次 draw 完成的间隔降到约 0.3–1.8ms。计时仍只代表应用内首个画布绘制，不代表物理按键或全部显示器刷新；用户快捷键的主观体验与 PixPin 同口径对比仍待用户确认。

最终版通过真实 UI 复核：冻结桌面画布可见，连续三次可进入选区并 Esc 取消；第三次拖动框选后出现尺寸、取消与完成并复制按钮，再取消回到剪贴板历史。未复制、保存或上传测试屏幕。最终日志：`.build/capture-startup/present/live-timing.log`。

## 首帧绘制原理验证

使用 200 个 320×220 的屏幕外合成面板验证，不读取真实屏幕，不激活窗口。单独 `NSWindow.displayIfNeeded()` 同步进入 draw 为每组 0/10；依次调用窗口 `displayIfNeeded()`、画布 `layoutSubtreeIfNeeded()` 和 `display()`，在显式/隐式 layer、已 orderFront/尚未 orderFront 四组均 10/10 同步绘制。日志包括调用和 draw 的进入/退出时间：`.build/capture-startup/draw-probe/repeated-results.jsonl`。该测试只证明调用行为，不证明实际应用耗时。

## 日志和回滚

- 第一轮：`.build/capture-startup/`；第二轮：`.build/capture-startup/round2/`；最终版：`.build/capture-startup/present/`。
- 优化前应用备份：`.build/capture-startup/rollback/Xclip.app`。
- 第一轮主程序 SHA-256：`865e8867b8adfefe9ef8a32bcccacedeb23012f50a0c59289708820c07c5f80f`。
- 最终已安装主程序 SHA-256：`40a67f578ce98685fcfbb4214d06ba44aec9fa45e436a0056a8bce97aa724072`，与候选包一致。最终更新前备份：`.build/capture-startup/present/rollback/Xclip.app`。
- 最终 Release 构建、严格签名验证、arm64/x86_64 架构验证均通过；继续使用既有签名身份。
- 各轮安装前后，重启前 229 个历史、附件和设置文件的 SHA-256 一致；最终重启界面仍为 196 条历史。
- 未改版本号、提交或推送 Git、发布 Release，未清理其他应用副本。
