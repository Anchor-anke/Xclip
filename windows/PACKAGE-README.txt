Xclip Windows 核心功能预览版 0.1.0

目标：Windows 11。请使用与你的设备架构匹配的 win-x64 或 win-arm64 包。
解压整个 ZIP 后双击 Xclip.exe，保留同一目录的全部文件。无需另外安装 .NET。

Ctrl+Alt+V 打开历史，输入搜索词、方向键选择，Enter 粘贴。
Ctrl+Alt+A 截图，选区、箭头、文字、马赛克、撤销、复制或保存 PNG。
关闭历史窗口后留在托盘，退出请使用托盘菜单。
快捷键被占用时，可从托盘打开历史和截图。
自动粘贴失败时，切换到目标应用按 Ctrl+V。

数据：%LOCALAPPDATA%\Xclip
历史和 PNG 只存在本机，未加密。默认保留 300 条普通历史，收藏/置顶受保护。
文件历史仅保留原路径，原文件移动/删除后不能粘贴。
暂停记录只对本次运行生效。删除可单步撤销，后续采集/修改或重启使撤销失效。
备份前从托盘退出，复制整个数据目录。不要在运行中编辑 history.json。
更新前从托盘退出，再替换程序文件；不要删除 LocalAppData 中的数据目录。

本版尚未完成 Windows 实机验收，也未进行 Windows 代码签名。
尚不包含 OCR、长截图、录屏、AI、局域网同步及 Mac 数据导入。
多屏混合缩放、中文输入、Office/浏览器/管理员窗口粘贴需在 Windows 实测。

LICENSE.txt 和 NOTICE.md 为项目许可与来源说明；运行时许可及第三方声明见 licenses 目录。
构建所含 .NET 运行时由 Microsoft 及贡献者提供，采用 MIT 许可：
https://github.com/dotnet/runtime/blob/main/LICENSE.TXT
https://github.com/dotnet/runtime/blob/main/THIRD-PARTY-NOTICES.TXT

项目：https://github.com/Anchor-anke/Xclip
