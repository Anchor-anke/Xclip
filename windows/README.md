# Xclip Windows 预览版

与 `src/OneClip` 中的 macOS 版并行开发的 Windows 原生客户端，使用 .NET 10 / Windows Forms。当前是核心功能预览版，尚未达到 macOS 0.4.0 的全部功能范围，也尚未完成 Windows 实机验收。

## 使用

目标环境为 Windows 11 x64。解压预览 ZIP 到可写的普通文件夹，双击 `Xclip.exe`；保留同目录全部文件。包自带运行时，无需另装 .NET。也可构建 ARM64 候选包，需在对应设备单独验证。

- `Ctrl+Alt+V`：打开历史。搜索内容或来源应用，使用方向键选择，`Enter` 向打开面板前的应用发送粘贴快捷键。
- `Ctrl+Alt+A`：框选截图。支持八点调整、移动选区、方向键微调、箭头、文字、马赛克、撤销、复制完成与另存 PNG。
- 关闭窗口或按 `Esc` 后留在托盘；双击托盘图标再次打开。退出请使用托盘菜单。
- 历史列表支持复制、收藏、置顶、删除与单步撤销。搜索框保留原生文字编辑快捷键。
- 勾选「暂停记录」停止收集新内容；本次进程退出后该开关不保留。手动截图仍能保存到历史。
- 快捷键被占用时显示提示，仍可使用托盘入口。首版快捷键固定，不占用 Windows 自带的 `Win+V`。

自动粘贴需要原应用仍存在、窗口激活成功、修饰键已经松开。无法自动粘贴时内容保留在剪贴板，切换到目标应用按 `Ctrl+V`。系统对输入注入存在权限限制，普通进程不能保证向管理员窗口自动粘贴，参见 [Microsoft SendInput 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)。应用显示“发送粘贴快捷键”不等于目标业务应用已接收内容。

## 数据

数据目录为 `%LOCALAPPDATA%\Xclip`：`history.json` 保存元数据，`attachments` 保存 PNG，`history.lock` 用于写入互斥。全部内容仅保存在本机，应用不配置任何云服务。

默认保留最近 300 条普通历史，收藏和置顶受保护，总条目上限 1000。单段文本最多 1,048,576 字符，单张 PNG 最多 32 MB，图片附件总量最多 512 MB。达到受保护内容或总量上限时报告错误，不自动删除收藏内容。数据未加密，请按个人文件管理。

记录文本为纯文本，图片为 PNG；文件历史保存原路径，文件移动或删除后无法再次粘贴，首版不备份文件实体。启动不会主动收集运行前已经存在的剪贴板内容，并尊重来源应用提供的 Windows 剪贴板历史排除标记；应用无法识别所有未标记的敏感内容。

删除/清理可单步撤销，后续采集或修改历史会使该撤销失效；重启后不保留撤销。附件清理保留当前历史及当前撤销需要的图片。退出应用后可复制整个数据目录作手动备份。数据格式有版本检查，损坏或被外部修改的数据不会被静默覆盖。详见 [核心存储说明](Xclip.Core/README.md)。

Windows 与 macOS 目前各自保存历史，不共享运行数据库，不支持直接导入 macOS 备份。Windows 更新时从托盘退出，保留数据目录，再解压新包到应用目录；首版不提供覆盖安装器、自动更新或开机启动设置。

## 开发与构建

开发机安装 [.NET 10 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)。在仓库根目录用 PowerShell 运行：

```powershell
./windows/build.ps1
# ARM64 候选包：
./windows/build.ps1 -Runtime win-arm64
```

输出在 `windows/artifacts/`，包括完整应用目录、ZIP 与 SHA256。脚本先跑跨平台核心测试，在架构匹配的 Windows 主机运行隔离的原生窗体/图像合成 smoke；ARM64 交叉构建不会冒充 ARM64 实测。首次构建需下载微软目标与运行时包。

也可逐项运行：

```powershell
dotnet run --project windows/Xclip.Core.Tests -c Release
dotnet build windows/Xclip.Windows -c Release
dotnet run --project windows/Xclip.Windows -c Release
```

macOS/Linux 能通过项目中的 `EnableWindowsTargeting` 编译 Windows 程序，但不能运行 Windows UI，见 [微软跨系统构建说明](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100)。核心测试可跨平台执行：

```sh
dotnet run --project windows/Xclip.Core.Tests -c Release
dotnet publish windows/Xclip.Windows -c Release -r win-x64 --self-contained true -o windows/artifacts/win-x64
```

`.github/workflows/windows.yml` 提供独立 Windows CI：编译 x64/ARM64，运行核心测试及匹配架构的原生 smoke，上传候选包，不自动发布 Release。运行结果以 GitHub Actions 中对应提交的记录为准。

开发烟雾入口：`Xclip.exe --smoke-test`，只操作临时数据和生成图像，不读取真实剪贴板或屏幕。可设置 `XCLIP_SMOKE_OUTPUT` 输出窗体图像与结果文件。该入口的离屏合成与布局通过，也不能替代全局快捷键、中文输入法、多屏混合 DPI、真实截图或跨应用粘贴验收。

## 首版边界

暂不包含富文本格式保留、内容编辑、拖拽粘贴、OCR、长截图、录屏、贴图、AI、脚本、局域网同步、备份互通和语言切换。截图文字为固定大小红色文字，马赛克为固定像素块；标注后可撤销，暂不提供对象二次选中编辑。Windows 10 及其他系统版本未作兼容承诺。

此预览包尚未进行 Windows 代码签名，也未完成 Windows 实机测试。操作清单见 [Windows 验证方法](TESTING.md)。

图标复用仓库现有 Xclip 资源，许可证和归属见随包 `LICENSE.txt` 与 `NOTICE.md`。
