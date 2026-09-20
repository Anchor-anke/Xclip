# Teams 文件拖拽修复验证

日期：2026-09-15

## 结论

已修复项目中可确定的文件拖出缺陷，最终 Release 构建及隔离回归通过。**尚无 Teams 实际附件接收或上传成功的证据。** 没有向 Teams 发送消息或上传测试文件。

## 修复内容

- 资料库列表、网格卡片、栈及拖拽容器行，改为共享的原生多项文件拖拽。
- 批量拖出按钮也展开内存附件归档；有任何文件无法准备时整批报错，不悄悄省略文件。
- 文件使用原生 `NSURL` writer，保留独立文件 URL、原名和数量。
- 按钮、可编辑/可选文本保持自己的鼠标交互；拖拽只在有效行区域且移动达到阈值后启动。
- 新增的命中检查同时验证 `bounds` 和 `visibleRect`，避免 macOS 返回过大的可见范围使按钮排除区阻挡整行。
- 保留普通复制、图片拖出格式、现有右键取消和用户存储语义。

Apple 的原生文件拖拽机制以文件 URL 为载荷：[Dragging Files](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/DraggingFiles.html)。本项目使用标准原生载荷是兼容性实现选择，不代表已获 Teams 客户端验收。

## 首轮文件拖拽验证

| 检查 | 结果 |
| --- | --- |
| arm64、x86_64 Release 构建 | 通过 |
| 现有 Xclip Local Development 签名、深度严格验签 | 通过，未更换证书 |
| NativeClipboardDragTests | 19 项通过 |
| QuickPasteTests | 126 项通过，含原生文件、内存附件、多文件、特殊文件名、原始字节及失败整批拒绝 |
| QuickPasteContextMenuTests | 34 项通过 |
| ClipboardSourceTests | 20 项通过 |
| MemoryOptimizationTests | 41 项通过 |
| LanguageTests | 39 项通过 |
| AppSmokeTests | 97 项通过 |
| 拖拽取消独立检查 | 117 个断言通过 |
| git diff --check | 通过 |

最终完整回归日志：`.build/teams-file-drag/release-smoke.log`。
构建日志：`.build/teams-file-drag/release-build.log`。

这些测试使用独立数据目录、应用标识、合成文件及命名剪贴板。未把数据格式检查当作 Teams 实收证据。

## 测试中发现并处理的问题

第一轮新增测试中的空 `NSTableView` 被 AppKit 缩小，导致触点落在表外；已改为包含实际行列的测试视口，保留原断言。随后测试发现生产代码仅检查 `visibleRect` 不足以限定行或按钮区域，已补充 `bounds` 检查及排除区域外仍能拖动的回归。

隔离 QA 界面确认列表选择、右键菜单、加入拖拽容器仍可操作。自动化拖拽尝试没有取得可确认的目标附件接收结果，不能标为跨应用验收通过。

## 本地产物与安装状态

- 修复版：`.build/teams-file-drag/ready/Xclip.app`
- ZIP：`.build/teams-file-drag/Xclip-Teams-file-drag-fix.zip`
- ZIP 指纹：`.build/teams-file-drag/SHA256SUMS`
- 修复版主程序 SHA-256：`c16ee776c3c630da53768affd892597bc1ae6f401b3105937ceda68e5298deb2`
- 旧应用完整备份：`.build/teams-file-drag/rollback/Xclip.app`，已核对与 `/Applications/Xclip.app` 主程序一致并验签。

本次未修改版本号、推送 Git 或发布 Release。首次更新尝试因旧进程仍在运行而由安装器停止；随后用户明确要求重新安装，已通过 Xclip 菜单正常退出旧版，并于 2026-09-15 完成 `/Applications/Xclip.app` 原子覆盖和重新启动。没有强制终止进程或清理其他安装副本。

安装后主程序 SHA-256 与上述候选完全一致，签名和 arm64/x86_64 检查通过，实际应用窗口正常打开。安装前界面显示 193 条历史；安装后只读数据库查询和重启后的界面仍显示 193 条，`PRAGMA quick_check` 返回 `ok`，原偏好文件保留。安装器只覆盖应用目录。原计划的逐文件指纹快照因本机 Python 不支持 `hashlib.file_digest` 未生成，未据此宣称完成历史和设置的逐字节审计。

本次实际使用的安装命令：

```sh
python3 scripts/install-local.py --source .build/teams-file-drag/ready/Xclip.app --destination /Applications/Xclip.app --no-cleanup
```

## 待验证

- 用户已看到允许使用合成 TXT 文件进行 Teams 自聊附件测试的确认项；截至本记录尚未获得该确认，因此未上传。
- Teams 桌面端实际单文件/多文件拖入附件预览，以及上传完成后的可用性仍待验证。

## 追加修复：不同图片被提示重复附件

用户随后提供 Teams 截图：已有一张图片附件，继续添加其他图片时提示“此文件已附加到邮件”。源码确认 `imageDragFile(for:)` 原先把所有图片导出为 `Xclip.png`，仅父目录按内容散列区分。这是可复现的文件名冲突；Teams 是否确实仅按文件名去重，尚未通过接收端实测确认。

现改为 `Xclip-<SHA-256 前 24 位>.png`，使不同图片内容获得不同附件文件名。同一图片数据重复拖出仍复用文件；每项仍同时提供 PNG、TIFF 和一个可读取的文件 URL，图片内容和临时文件生命周期保持不变。

追加的合成图片回归覆盖：相同显示名称的两张不同图片导出不同文件名、两份文件字节各自准确、重复拖出复用 URL、批量选择恰好暴露两项文件 URL，且没有文件名冲突或图片表示丢失。

### 本轮验证与安装

- arm64、x86_64 Release 构建通过，沿用 Xclip Local Development 证书；候选、回滚及安装版通过双架构严格验签。
- QuickPasteTests：140 项通过；NativeClipboardDragTests 19、LanguageTests 39、QuickPasteContextMenuTests 34、ClipboardSourceTests 20、MemoryOptimizationTests 41、AppSmokeTests 97 均通过。
- 构建日志：`.build/teams-image-names/build.log`；隔离回归日志：`.build/teams-image-names/smoke.log`。
- 当前候选：`.build/teams-image-names/ready/Xclip.app`；本轮更新前的完整应用备份：`.build/teams-image-names/rollback/Xclip.app`。
- 当前安装 `/Applications/Xclip.app` 与候选主程序 SHA-256 一致：`2e216a0923a7494a12a8a1cd289f8b17e8b54c6b2fc1dcccd24fe627ee017dcb`。
- 已通过应用菜单正常退出、使用 `--no-cleanup` 原子更新并重新启动。安装前后、重启前核对 227 个历史、附件和设置文件的 SHA-256，全部相同；重启界面显示 194 条历史，与本轮更新前一致。
- 本轮未向 Teams 上传图片或发送消息。实际连续添加不同图片的 Teams 附件预览仍待用户重试确认。
