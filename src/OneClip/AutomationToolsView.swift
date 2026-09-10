import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct AutomationToolsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var body: some View {
        TabView {
            AIWorkbenchView().tabItem { Label(AutomationL("AI 与翻译", "AI & translation"), systemImage: "sparkles") }
            ScriptWorkbenchView().tabItem { Label(AutomationL("脚本工作流", "Script workflows"), systemImage: "curlybraces") }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460)
        .environment(\.locale, appLanguage.locale)
    }
}

private struct AIWorkbenchView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var service = AIService.shared
    @ObservedObject private var privacy = PrivacyLock.shared
    @State private var output = ""
    @State private var taskKind = "总结"
    @State private var targetLanguage = ""
    @State private var customInstruction = ""
    @State private var credential = ""
    @State private var imageData: Data?
    @State private var imageName = ""
    @State private var status = AutomationMessage()
    @State private var isRunning = false
    @State private var request: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(AutomationL("发送前可查看输入、图片和服务地址。只有点击“发送”才会连接所配置的服务。", "Review the input, image and endpoint before sending. The service is contacted only when you click Send."))
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox(AutomationL("服务设置", "Service settings")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(AutomationL("接口", "Interface"), selection: $service.configuration.provider) {
                            ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                        }
                        TextField(AutomationL("服务地址", "Endpoint"), text: $service.configuration.endpoint)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button(AutomationL("使用 Ollama 本机地址", "Use local Ollama")) { service.configuration.provider = .ollama; service.configuration.endpoint = "http://127.0.0.1:11434" }
                            Button(AutomationL("使用 LM Studio 本机地址", "Use local LM Studio")) { service.configuration.provider = .compatible; service.configuration.endpoint = "http://127.0.0.1:1234/v1" }
                        }.font(.caption)
                        TextField(AutomationL("模型名称", "Model name"), text: $service.configuration.model).textFieldStyle(.roundedBorder)
                        HStack {
                            Text(AutomationL("随机程度", "Temperature"))
                            Slider(value: $service.configuration.temperature, in: 0...2, step: 0.1)
                            Text(service.configuration.temperature, format: .number.precision(.fractionLength(1))).monospacedDigit()
                        }
                        HStack {
                            SecureField(AutomationL("API Key（仅保存在本机钥匙串）", "API key (stored only in Keychain)"), text: $credential)
                            Button(AutomationL("保存凭证", "Save key")) { saveCredential() }.disabled(credential.isEmpty)
                            Button(AutomationL("删除凭证", "Delete key")) { credential = ""; saveCredential() }
                        }
                        Text(AutomationL("远程接口使用 HTTPS；支持 Bearer 凭证。模型须支持图片才能使用附图。", "Remote endpoints require HTTPS. Bearer authentication is supported. Attachments need an image-capable model."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(isRunning)
                HStack {
                    Picker(AutomationL("任务", "Task"), selection: $taskKind) {
                        Text(AutomationL("总结", "Summarize")).tag("总结"); Text(AutomationL("翻译", "Translate")).tag("翻译"); Text(AutomationL("自定义", "Custom")).tag("自定义")
                    }.pickerStyle(.segmented)
                    if taskKind == "翻译" { TextField(AutomationL("目标语言（默认简体中文）", "Target language (default: Simplified Chinese)"), text: $targetLanguage).frame(minWidth: 200, idealWidth: 260) }
                }
                if taskKind == "自定义" { TextField(AutomationL("处理说明（默认：处理提供的内容）", "Instructions (default: process the provided content)"), text: $customInstruction) }
                GroupBox(AutomationL("输入内容", "Input")) {
                    TextEditor(text: $service.draftInput).font(.body).frame(minHeight: 115)
                        .accessibilityLabel(AutomationL("发送给 AI 的输入内容", "Input to send to AI"))
                }
                HStack {
                    Button(AutomationL("从系统剪贴板读取文本", "Read clipboard text")) { guard !privacy.locked else { return }; service.draftInput = NSPasteboard.general.string(forType: .string) ?? "" }
                    Button(AutomationL("选择图片…", "Choose image…")) { chooseImage() }
                    if imageData != nil {
                        Text(imageName).lineLimit(1)
                        Button(AutomationL("移除图片", "Remove image")) { imageData = nil; imageName = "" }
                    }
                    Spacer()
                }.disabled(isRunning)
                if let imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                        .accessibilityLabel(AutomationL("将发送的图片：\(imageName)", "Image to send: \(imageName)"))
                }
                HStack {
                    Button(isRunning ? AutomationL("正在处理…", "Processing…") : AutomationL("发送", "Send")) { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(privacy.locked || isRunning || (service.draftInput.isEmpty && imageData == nil) || service.configuration.model.isEmpty)
                    if isRunning { ProgressView().controlSize(.small); Button(AutomationL("取消", "Cancel")) { request?.cancel() } }
                    Spacer()
                    Text(service.configuration.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !status.isEmpty { Text(status.text).font(.callout).textSelection(.enabled).accessibilityLabel(AutomationL("操作状态：\(status.text)", "Status: \(status.text)")) }
                GroupBox(AutomationL("结果", "Result")) {
                    TextEditor(text: $output).frame(minHeight: 130).accessibilityLabel(AutomationL("可编辑的 AI 处理结果", "Editable AI result"))
                }
                HStack {
                    Button(AutomationL("复制结果", "Copy result")) { guard !privacy.locked else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) }
                    Button(AutomationL("保存到历史", "Save to history")) {
                        guard !privacy.locked else { return }
                        do { try ClipboardManager.shared.addText(output); status = AutomationMessage("结果已保存到历史。", "Result saved to history.") }
                        catch { status = AutomationMessage(error: error) }
                    }
                }.disabled(output.isEmpty || isRunning)
            }.padding(8)
        }.onDisappear { request?.cancel() }
        .onReceive(service.$draftTaskKind) { taskKind = $0 == "translate" ? "翻译" : "总结" }
        .onChange(of: privacy.locked) { _, locked in
            if locked { request?.cancel(); output = ""; service.draftInput = ""; imageData = nil }
        }
    }

    private func saveCredential() {
        do {
            _ = try service.configuration.requestURL()
            try AutomationKeychain.save(credential, for: service.configuration.endpoint)
            status = credential.isEmpty ? AutomationMessage("当前服务的凭证已删除。", "Credential for this service deleted.") : AutomationMessage("凭证已保存至本机钥匙串。", "Credential saved in this Mac’s Keychain.")
            credential = ""
        } catch { status = AutomationMessage(error: error) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = AutomationL("选择图片", "Choose image")
        panel.prompt = AutomationL("选择", "Choose")
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try Data(contentsOf: url, options: .mappedIfSafe)
            guard file.count <= 8_388_608, let source = CGImageSourceCreateWithData(file as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), png.count <= 8_388_608 else {
                throw AutomationError.invalid("请选择不超过 8 MB、3200 万像素的图片。", "Choose an image up to 8 MB and 32 million pixels.")
            }
            imageData = png; imageName = url.lastPathComponent; status = AutomationMessage("已选择图片，点击发送后才会传输。", "Image selected. It will be sent only when you click Send.")
        } catch { status = AutomationMessage(error: error) }
    }

    private func send() {
        guard !privacy.locked else { return }
        let instruction: String
        switch taskKind {
        case "翻译": instruction = "请将用户提供的文字或图片中的文字翻译为\(targetLanguage.isEmpty ? "简体中文" : targetLanguage)，忠实原意，只返回译文。"
        case "自定义": instruction = customInstruction.isEmpty ? "请处理用户提供的内容。" : customInstruction
        default: instruction = "请用简体中文简洁总结用户提供的内容，忠实原文，不编造原文没有的信息。"
        }
        isRunning = true; status = AutomationMessage("正在等待服务返回…", "Waiting for the service…"); output = ""
        let submittedInput = service.draftInput, submittedImage = imageData
        request = Task { @MainActor in
            defer { isRunning = false; request = nil }
            do {
                let answer = try await service.generate(input: submittedInput, instruction: instruction, imageData: submittedImage)
                guard !privacy.locked else { return }
                output = answer; status = AutomationMessage("处理完成。", "Completed.")
            }
            catch is CancellationError { status = AutomationMessage("已取消。", "Cancelled.") }
            catch { status = Task.isCancelled ? AutomationMessage("已取消。", "Cancelled.") : AutomationMessage(error: error) }
        }
    }
}

private struct ScriptWorkbenchView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var service = ScriptService.shared
    @State private var selected: UUID?
    @State private var sample = "  Hello Xclip  "
    @State private var result = ""
    @State private var status = AutomationMessage()
    @State private var running = false
    @ObservedObject private var privacy = PrivacyLock.shared

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text(AutomationL("脚本是返回字符串的 JavaScript 表达式，输入变量为 input。它只能处理传入的文本；不提供网络、文件或系统接口。每次执行有 750 ms 时限。", "Scripts are JavaScript expressions that return a string, using input as the text. They have no network, file or system APIs. Each execution is limited to 750 ms."))
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) {
                    List(selection: $selected) {
                        ForEach(service.scripts) { script in
                            VStack(alignment: .leading) {
                                Text(script.displayName)
                                Text(script.enabled ? AutomationL("已启用 · \(triggerLabel(script.trigger))", "Enabled · \(triggerLabel(script.trigger))") : AutomationL("未自动执行", "Automatic execution disabled"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(script.id)
                        }
                    }
                    HStack {
                        Button(AutomationL("新增", "Add")) { let script = ClipboardScript(name: AutomationL("新脚本", "New script"), code: "input"); service.scripts.append(script); selected = script.id }
                        Button(AutomationL("删除", "Delete")) { service.scripts.removeAll { $0.id == selected }; selected = service.scripts.first?.id }.disabled(selected == nil)
                    }
                }.frame(minWidth: 140, idealWidth: 160)
                if let index = service.scripts.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(AutomationL("脚本名称", "Script name"), text: Binding(get: { service.scripts[index].displayName }, set: { service.scripts[index].name = $0 }))
                        Picker(AutomationL("执行时机", "Trigger"), selection: $service.scripts[index].trigger) {
                            Text(AutomationL("仅手动", "Manual only")).tag("manual")
                            Text(AutomationL("捕获文本时", "On text capture")).tag("copy")
                            Text(AutomationL("粘贴文本时", "On text paste")).tag("paste")
                        }
                        Toggle(AutomationL("启用此触发器（按左侧顺序执行）", "Enable this trigger (run in list order)"), isOn: $service.scripts[index].enabled)
                        HStack {
                            Button(AutomationL("上移", "Move up")) { service.scripts.swapAt(index, index - 1) }.disabled(index == 0)
                            Button(AutomationL("下移", "Move down")) { service.scripts.swapAt(index, index + 1) }.disabled(index + 1 == service.scripts.count)
                        }
                        TextEditor(text: $service.scripts[index].code).font(.system(.body, design: .monospaced))
                            .frame(minHeight: 170).accessibilityLabel(AutomationL("JavaScript 表达式", "JavaScript expression"))
                        Text(AutomationL("复杂逻辑示例：(() => { const value = input.trim(); return value.toUpperCase(); })()", "Example: (() => { const value = input.trim(); return value.toUpperCase(); })()"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(10).frame(minWidth: 260)
                } else { Text(AutomationL("选择或新建一个脚本。 ", "Select or add a script.")).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }.frame(minHeight: 310)
            GroupBox(AutomationL("测试输入", "Test input")) { TextEditor(text: $sample).frame(height: 75).accessibilityLabel(AutomationL("脚本测试输入", "Script test input")) }
            HStack {
                Button(running ? AutomationL("执行中…", "Running…") : AutomationL("测试选中脚本", "Test selected script")) { testSelected() }.disabled(selected == nil || running)
                if running { ProgressView().controlSize(.small) }
                Text(status.text).font(.callout)
            }
            GroupBox(AutomationL("测试结果", "Test result")) { TextEditor(text: $result).frame(minHeight: 80).accessibilityLabel(AutomationL("脚本测试结果", "Script test result")) }
        }.padding(8) }.onAppear { selected = service.scripts.first?.id }
        .onChange(of: privacy.locked) { _, locked in if locked { result = ""; sample = "" } }
    }

    private func triggerLabel(_ value: String) -> String { value == "copy" ? AutomationL("捕获时", "On capture") : value == "paste" ? AutomationL("粘贴时", "On paste") : AutomationL("手动", "Manual") }
    private func testSelected() {
        guard !privacy.locked else { return }
        guard let script = service.scripts.first(where: { $0.id == selected }) else { return }
        running = true; status = AutomationMessage(); result = ""
        let input = sample
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try service.execute(script, input: input) }
            DispatchQueue.main.async {
                running = false
                guard !privacy.locked else { return }
                switch outcome {
                case .success(let output): result = output; status = AutomationMessage("执行完成。", "Execution completed.")
                case .failure(let error): status = AutomationMessage(error: error)
                }
            }
        }
    }
}
