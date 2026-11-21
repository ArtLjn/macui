import AppKit
import SwiftUI

struct WallSettings: View {
    let model: WallModel
    @AppStorage(WallAppearance.followsWallpaper) private var followsWallpaper = true
    @AppStorage(WallAppearance.animatesWallpaper) private var animatesWallpaper = true
    @State private var baseURL = UserDefaults.standard.string(forKey: AIWallpaperConfiguration.baseURLKey) ?? ""
    @State private var aiModel = UserDefaults.standard.string(forKey: AIWallpaperConfiguration.modelKey) ?? ""
    @State private var apiKey = ""
    @State private var aiSettingsNotice: String?

    var body: some View {
        Form {
            Section("AI 搜索") {
                TextField("API 地址", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                TextField("模型名", text: $aiModel)
                SecureField("API Key", text: $apiKey, prompt: Text("留空以保留当前地址的密钥"))
                HStack {
                    Button("保存 AI 配置", action: saveAISettings)
                    if let aiSettingsNotice {
                        Text(aiSettingsNotice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("API Key 保存在 macOS 钥匙串。开启 AI 搜索后，搜索词会发送给配置的模型。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("外观与换图") {
                Toggle("窗口配色跟随桌面壁纸", isOn: $followsWallpaper)
                Toggle("更换壁纸时淡入淡出", isOn: $animatesWallpaper)
                if model.liveWallpaper.supportsBackground {
                    Toggle("退出 macui 后继续播放 2.5D", isOn: Binding(
                        get: { model.liveWallpaper.continuesAfterQuit },
                        set: { model.liveWallpaper.setContinuesAfterQuit($0) }
                    ))
                    .disabled(model.busy)
                    HStack {
                        Text(model.liveWallpaper.backgroundStatus).foregroundStyle(.secondary)
                        Spacer()
                        if model.liveWallpaper.isBackgroundPlaying {
                            Button("停止后台播放") { model.stopLiveWallpaper() }.disabled(model.busy)
                        } else {
                            Button("恢复后台播放") { model.liveWallpaper.resumeBackground() }
                                .disabled(model.busy || !model.liveWallpaper.canResumeBackground)
                        }
                    }
                    if let message = model.liveWallpaper.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section("图片筛选") {
                Text("4K 及以上原图")
                Text("保存和应用时检查原图像素。横图至少 3840 × 2160，竖图按对应方向校验。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("匹配显示器比例", isOn: Binding(
                    get: { model.matchScreen }, set: { model.changeMatchScreen($0) }
                ))
                Text("选择「填满」时，按目标显示器筛选需要裁切 18% 以内的壁纸。「适应」保留全图。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("下载位置") {
                Text(model.downloadFolder.path(percentEncoded: false))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("选择文件夹…", action: chooseFolder)
                    Button("在 Finder 中打开") { model.openDownloadFolder() }
                    if model.customDownloadFolder != nil {
                        Button("恢复默认") { model.changeDownloadFolder(nil) }
                    }
                }
                Text("用于保存离线图片和换图时下载的文件。目录变更后，先前下载的图片仍从原位置读取。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 530, height: 610)
    }

    private func saveAISettings() {
        do {
            try AIWallpaperConfiguration.save(baseURL: baseURL, model: aiModel, apiKey: apiKey)
            apiKey = ""
            model.invalidateAISearch()
            aiSettingsNotice = "已保存"
        } catch {
            aiSettingsNotice = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸下载文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if FileManager.default.fileExists(atPath: model.downloadFolder.path) {
            panel.directoryURL = model.downloadFolder
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.changeDownloadFolder(url)
        }
    }
}
