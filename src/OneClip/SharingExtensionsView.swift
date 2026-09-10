import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SharingExtensionsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var body: some View {
        TabView {
            ImageUploadWorkbench().tabItem { Label(AutomationL("图片上传", "Image upload"), systemImage: "icloud.and.arrow.up") }
            OfficialTranslationWorkbench().tabItem { Label(AutomationL("官方翻译 API", "Official translation APIs"), systemImage: "character.bubble") }
        }.padding(12).frame(minWidth: 520, minHeight: 460).environment(\.locale, appLanguage.locale)
    }
}

private struct ImageUploadWorkbench: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var service = ImageUploadService.shared
    @ObservedObject private var privacy = PrivacyLock.shared
    @State private var selected: SelectedUploadImage?
    @State private var credential = ""
    @State private var headersJSON = "{}"
    @State private var result = ""
    @State private var status = AutomationMessage()
    @State private var running = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(AutomationL("配置自己的图床或兼容 multipart 接口。选择图片并确认目的地址后再上传；不会自动读取剪贴板。", "Configure your image host or a multipart-compatible endpoint. Select an image and review the destination before uploading. The clipboard is never read automatically."))
                    .foregroundStyle(.secondary)
                Toggle(AutomationL("本次使用启用图片上传", "Enable image uploads for this session"), isOn: $service.enabled)
                GroupBox(AutomationL("上传设置", "Upload settings")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(AutomationL("完整上传地址（HTTPS）", "Full upload endpoint (HTTPS)"), text: $service.configuration.endpoint)
                        TextField(AutomationL("图片表单字段", "Image form field"), text: $service.configuration.imageField)
                        TextField(AutomationL("响应 URL 路径，如 data.url 或 files.0.url", "Response URL path, e.g. data.url or files.0.url"), text: $service.configuration.responseURLPath)
                        Text(AutomationL("附加表单字段（JSON；凭证请使用下面的钥匙串配置）", "Extra form fields (JSON; put credentials in the Keychain configuration below)"))
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $service.configuration.formFieldsJSON).font(.system(.body, design: .monospaced)).frame(height: 55)
                        HStack {
                            Picker(AutomationL("凭证位置", "Credential placement"), selection: $service.configuration.credentialLocation) {
                                Text(AutomationL("请求头", "Header")).tag("header")
                                Text(AutomationL("表单字段", "Form field")).tag("form")
                            }
                            TextField(AutomationL("字段名称", "Field name"), text: $service.configuration.credentialField)
                        }
                        TextField(AutomationL("凭证前缀（可留空）", "Credential prefix (optional)"), text: $service.configuration.credentialPrefix)
                        HStack {
                            SecureField(AutomationL("API 凭证", "API credential"), text: $credential)
                            Button(AutomationL("保存", "Save")) { saveCredential() }.disabled(credential.isEmpty)
                            Button(AutomationL("删除凭证", "Delete key")) { credential = ""; saveCredential() }
                        }
                        DisclosureGroup(AutomationL("附加请求头（JSON；保存到钥匙串）", "Additional headers (JSON; saved in Keychain)")) {
                            TextEditor(text: $headersJSON).font(.system(.body, design: .monospaced)).frame(height: 70)
                            HStack {
                                Button(AutomationL("保存请求头", "Save headers")) {
                                    do {
                                        _ = try SharingValidation.endpoint(service.configuration.endpoint)
                                        try SharingValidation.headers(SharingValidation.dictionary(headersJSON))
                                        try AutomationKeychain.save(headersJSON, for: service.configuration.headersAccount)
                                        status = AutomationMessage("请求头已保存到钥匙串。", "Headers saved in Keychain.")
                                    } catch { status = AutomationMessage(error: error) }
                                }
                                Button(AutomationL("清除请求头", "Clear headers")) {
                                    do { try AutomationKeychain.save("", for: service.configuration.headersAccount); headersJSON = "{}"; status = AutomationMessage("已清除。", "Cleared.") }
                                    catch { status = AutomationMessage(error: error) }
                                }
                            }
                        }
                    }.textFieldStyle(.roundedBorder).padding(8)
                }.disabled(running)
                HStack {
                    Button(AutomationL("选择图片…", "Choose image…")) { selectImage() }.disabled(running || privacy.locked)
                    if let selected { Text(selected.filename).lineLimit(1); Text(Int64(selected.data.count).formatted(.byteCount(style: .file).locale(appLanguage.locale))).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                if let selected, let image = NSImage(data: selected.data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 210).accessibilityLabel(AutomationL("待上传的图片", "Image to upload"))
                }
                GroupBox(AutomationL("本次目的地址", "Destination for this upload")) {
                    Text(service.configuration.endpoint.isEmpty ? AutomationL("请先填写上传地址", "Enter an upload endpoint") : service.configuration.endpoint)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                HStack {
                    Button(AutomationL("上传所选图片", "Upload selected image")) { upload() }
                        .buttonStyle(.borderedProminent).disabled(!service.enabled || selected == nil || running || privacy.locked)
                    if running { ProgressView().controlSize(.small); Button(AutomationL("取消", "Cancel")) { task?.cancel() } }
                }
                if !status.isEmpty { Text(status.text).textSelection(.enabled).font(.callout) }
                if !result.isEmpty {
                    Text(result).textSelection(.enabled)
                    Button(AutomationL("复制图片链接", "Copy image URL")) {
                        guard !privacy.locked else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
                    }
                }
            }.padding(12)
        }.onDisappear { task?.cancel() }
        .onChange(of: privacy.locked) { _, locked in if locked { task?.cancel(); selected = nil; result = ""; credential = ""; headersJSON = "{}" } }
    }
    private func saveCredential() {
        do {
            _ = try SharingValidation.endpoint(service.configuration.endpoint)
            try AutomationKeychain.save(credential, for: service.configuration.credentialAccount)
            status = credential.isEmpty ? AutomationMessage("凭证已删除。", "Credential deleted.") : AutomationMessage("凭证已保存到钥匙串。", "Credential saved in Keychain.")
            credential = ""
        } catch { status = AutomationMessage(error: error) }
    }
    private func selectImage() {
        guard !privacy.locked else { return }
        let panel = NSOpenPanel()
        panel.title = AutomationL("选择图片", "Choose image")
        panel.prompt = AutomationL("选择", "Choose")
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .webP, .tiff]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { selected = try SelectedUploadImage.read(url); status = AutomationMessage("图片已就绪，尚未上传。", "Image ready; nothing has been uploaded."); result = "" }
        catch { status = AutomationMessage(error: error) }
    }
    private func upload() {
        guard let image = selected, !privacy.locked else { return }
        running = true; result = ""; status = AutomationMessage("正在上传…", "Uploading…")
        task = Task { @MainActor in
            defer { running = false; task = nil }
            do {
                let url = try await service.upload(image)
                guard !privacy.locked, !Task.isCancelled else { return }
                result = url.absoluteString; status = AutomationMessage("上传完成。", "Upload completed.")
            } catch { status = Task.isCancelled ? AutomationMessage("已取消。", "Cancelled.") : AutomationMessage(error: error) }
        }
    }
}

private struct OfficialTranslationWorkbench: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var service = OfficialTranslationService.shared
    @ObservedObject private var privacy = PrivacyLock.shared
    @State private var input = ""
    @State private var output = ""
    @State private var credential = ""
    @State private var status = AutomationMessage()
    @State private var running = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(AutomationL("使用你的 DeepL 或 Google Cloud API 账户。点击翻译才会发送输入，服务可能按账户套餐计费。", "Use your own DeepL or Google Cloud API account. Input is sent only when you click Translate and may count toward your service plan."))
                    .foregroundStyle(.secondary)
                GroupBox(AutomationL("翻译设置", "Translation settings")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(AutomationL("服务", "Service"), selection: $service.configuration.provider) {
                            ForEach(OfficialTranslationProvider.allCases) { Text($0.title).tag($0) }
                        }.onChange(of: service.configuration.provider) { _, provider in service.configuration.targetLanguage = provider == .googleBasic ? "zh-CN" : "ZH"; credential = "" }
                        Text(service.configuration.provider.endpoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            TextField(AutomationL("来源语言（留空自动检测）", "Source language (blank = detect)"), text: $service.configuration.sourceLanguage)
                            TextField(AutomationL("目标语言代码", "Target language code"), text: $service.configuration.targetLanguage)
                        }
                        Text(AutomationL("DeepL 示例：ZH、EN-US、JA；Google 示例：zh-CN、en、ja。", "DeepL examples: ZH, EN-US, JA; Google examples: zh-CN, en, ja."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            SecureField(AutomationL("本服务的 API Key", "API key for this service"), text: $credential)
                            Button(AutomationL("保存", "Save")) { saveCredential() }.disabled(credential.isEmpty)
                            Button(AutomationL("删除", "Delete")) { credential = ""; saveCredential() }
                        }
                        Link(AutomationL("查看官方文档", "Official documentation"), destination: URL(string: service.configuration.provider == .googleBasic ? "https://cloud.google.com/translate/docs/reference/rest/v2/translate" : "https://developers.deepl.com/api-reference/translate/request-translation")!)
                    }.textFieldStyle(.roundedBorder).padding(8)
                }.disabled(running)
                GroupBox(AutomationL("待翻译内容", "Text to translate")) { TextEditor(text: $input).frame(minHeight: 130).accessibilityLabel(AutomationL("翻译输入", "Translation input")) }
                HStack {
                    Button(AutomationL("读取剪贴板文本", "Read clipboard text")) { guard !privacy.locked else { return }; input = NSPasteboard.general.string(forType: .string) ?? "" }.disabled(running || privacy.locked)
                    Spacer()
                    Button(AutomationL("翻译", "Translate")) { translate() }.buttonStyle(.borderedProminent).disabled(input.isEmpty || running || privacy.locked)
                    if running { ProgressView().controlSize(.small); Button(AutomationL("取消", "Cancel")) { task?.cancel() } }
                }
                if !status.isEmpty { Text(status.text).font(.callout).textSelection(.enabled) }
                GroupBox(AutomationL("翻译结果", "Translation result")) { TextEditor(text: $output).frame(minHeight: 130).accessibilityLabel(AutomationL("翻译结果", "Translation result")) }
                HStack {
                    Button(AutomationL("复制结果", "Copy result")) { guard !privacy.locked else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) }
                    Button(AutomationL("保存到历史", "Save to history")) {
                        guard !privacy.locked else { return }
                        do { try ClipboardManager.shared.addText(output); status = AutomationMessage("已保存。", "Saved.") }
                        catch { status = AutomationMessage(error: error) }
                    }
                }.disabled(output.isEmpty || running || privacy.locked)
            }.padding(12)
        }.onDisappear { task?.cancel() }
        .onChange(of: privacy.locked) { _, locked in if locked { task?.cancel(); input = ""; output = ""; credential = "" } }
    }
    private func saveCredential() {
        do {
            try AutomationKeychain.save(credential, for: service.configuration.provider.credentialAccount)
            status = credential.isEmpty ? AutomationMessage("凭证已删除。", "Credential deleted.") : AutomationMessage("凭证已保存到钥匙串。", "Credential saved in Keychain."); credential = ""
        } catch { status = AutomationMessage(error: error) }
    }
    private func translate() {
        guard !privacy.locked else { return }
        let text = input
        running = true; output = ""; status = AutomationMessage("正在翻译…", "Translating…")
        task = Task { @MainActor in
            defer { running = false; task = nil }
            do {
                let translated = try await service.translate(text)
                guard !privacy.locked, !Task.isCancelled else { return }
                output = translated; status = AutomationMessage("翻译完成。", "Translation completed.")
            } catch { status = Task.isCancelled ? AutomationMessage("已取消。", "Cancelled.") : AutomationMessage(error: error) }
        }
    }
}
