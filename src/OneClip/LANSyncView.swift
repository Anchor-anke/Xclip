import SwiftUI
import AppKit

struct LANSyncView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var service = LANSyncService.shared
    @ObservedObject private var clipboard = ClipboardManager.shared
    @State private var selectedID: UUID?
    @State private var text = ""
    @State private var message = AutomationMessage()
    @State private var acceptedLocalNetwork = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(AutomationL("局域网共享", "LAN sharing"), systemImage: "network").font(.title2.bold())
                Text(AutomationL("在同一网络的手机或电脑浏览器打开共享链接，可以接收当前共享项目，或发送文本和文件到这台 Mac 的历史。", "Open the link in a phone or computer browser on the same network to receive shared content or send text and files to this Mac."))
                    .foregroundStyle(.secondary)
                GroupBox(AutomationL("共享连接", "Connection")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !service.isRunning {
                            Toggle(AutomationL("我确认当前是可信局域网，允许持有链接的人查看和发送共享内容", "I trust this local network and allow people with the link to access shared content"), isOn: $acceptedLocalNetwork)
                            Text(AutomationL("此连接采用 HTTP，传输没有加密。服务默认关闭，每次开启都会生成新链接。", "This connection uses unencrypted HTTP. Sharing starts disabled and each session gets a new link."))
                                .font(.callout).foregroundStyle(.secondary)
                            Button(AutomationL("开启局域网共享", "Enable LAN sharing")) { service.start() }
                                .buttonStyle(.borderedProminent).disabled(!acceptedLocalNetwork)
                        } else {
                            ForEach(service.links, id: \.self) { link in
                                HStack {
                                    Text(String(link.split(separator: "#").first ?? "")).textSelection(.enabled)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Button(AutomationL("复制完整链接", "Copy full link")) {
                                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string)
                                        message = AutomationMessage("已复制含访问令牌的完整链接，请只交给可信设备。", "Full link copied with its access token. Share it only with trusted devices.")
                                    }
                                    Button(AutomationL("在本机打开", "Open locally")) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
                                }
                            }
                            Text(AutomationL("完整链接包含访问令牌；这里只显示地址。停止共享会撤销所有旧链接。更换网络后请关闭再开启。", "The full link contains an access token. Stopping sharing revokes previous links. Restart sharing after changing networks."))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(AutomationL("关闭共享并撤销链接", "Stop sharing and revoke links"), role: .destructive) { service.stop(); acceptedLocalNetwork = false }
                        }
                        Text(service.status).font(.callout).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox(AutomationL("主动共享一个历史项目", "Share a selected history item")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(AutomationL("选择项目", "Select item"), selection: $selectedID) {
                            Text(AutomationL("请选择要共享的内容", "Choose content to share")).tag(nil as UUID?)
                            ForEach(clipboard.clipboardItems.prefix(200)) { item in
                                Text("\(item.type.displayName) · \(String(item.displayContent.prefix(60)))").tag(Optional(item.id))
                            }
                        }
                        HStack {
                            Button(AutomationL("共享选中项", "Share selected item")) {
                                guard let item = clipboard.clipboardItems.first(where: { $0.id == selectedID }) else { return }
                                do { try service.publish(item: item); message = AutomationMessage("已更新当前共享内容。", "Shared content updated.") }
                                catch { message = AutomationMessage(error: error) }
                            }.disabled(selectedID == nil || !service.isRunning)
                            Button(AutomationL("清空共享内容", "Clear shared content")) { service.clearSharedContent() }.disabled(!service.isRunning)
                            Spacer()
                        }
                        Text(service.sharedDescription).font(.callout)
                        Text(AutomationL("仅主动选中的一项可被读取，不会暴露历史列表。支持最多 16 个普通文件，总计 8 MB；文件夹请先压缩。", "Only the selected item is shared, never your history list. Up to 16 regular files, totaling 8 MB; compress folders first."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox(AutomationL("自动传输", "Automatic transfer")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(AutomationL("将新捕获内容自动共享到已连接浏览器", "Automatically share new captures with connected browsers"), isOn: $service.shareNewCaptures)
                        Toggle(AutomationL("允许浏览器发送内容到本机历史", "Allow browser uploads into this Mac's history"), isOn: $service.receiveIncoming)
                        Text(AutomationL("开关只对本次会话生效。浏览器每两秒刷新当前共享项；接收内容只保存历史，不写入系统剪贴板，也不会自动回传。", "These switches apply to this session only. Browsers refresh the shared item every two seconds. Received items enter history without changing the system clipboard or being sent back."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.disabled(!service.isRunning)
                if !service.recentDevices.isEmpty {
                    GroupBox(AutomationL("最近连接的设备", "Recently connected devices")) {
                        ForEach(service.recentDevices, id: \.self) { address in
                            Label(address, systemImage: "desktopcomputer").frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                    }
                }
                GroupBox(AutomationL("临时共享文本", "Share temporary text")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $text).frame(minHeight: 120).accessibilityLabel(AutomationL("要主动共享的文本", "Text to share"))
                        Button(AutomationL("共享这段文本", "Share this text")) {
                            do { try service.publishText(text); message = AutomationMessage("已更新当前共享文本。", "Shared text updated.") }
                            catch { message = AutomationMessage(error: error) }
                        }.disabled(text.isEmpty || !service.isRunning)
                    }.padding(8)
                }
                HStack { Label(AutomationL("本次已接收 \(service.receivedCount) 条", "Received this session: \(service.receivedCount)"), systemImage: "arrow.down.circle"); Spacer() }
                    .foregroundStyle(.secondary)
                if !message.isEmpty { Text(message.text).font(.callout).textSelection(.enabled).accessibilityLabel(AutomationL("操作结果：\(message.text)", "Result: \(message.text)")) }
            }.padding(20)
        }.frame(minWidth: 520, minHeight: 460)
        .environment(\.locale, appLanguage.locale)
    }
}
