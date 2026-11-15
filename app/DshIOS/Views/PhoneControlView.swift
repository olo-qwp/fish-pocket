import SwiftUI

/// 「操控手机」（侧边栏的独立入口）：用户自己装的 iCTRL 在不在跑，以及从这里启动、停止它。
///
/// iCTRL 是第三方开源 App，靠 XCUITest 在本机提供一个只听 127.0.0.1:8200 的自动化服务，
/// 智能体通过它点按、输入、读别的 App 的屏幕（用法写在内置 skill 的
/// `references/phone-control.md`）。这里只做桥：查它的公开状态接口、打开它自己的
/// `ictrl://start` / `ictrl://stop` 链接。装它、签名、挂开发者镜像都在 iCTRL 和
/// SideStore 里，本 App 不碰；详细步骤放在官网教程里，页面里只给入口。
struct PhoneControlView: View {
    @StateObject private var service = PhoneControlService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle().fill(service.state.tint).frame(width: 8, height: 8)
                        Text(service.state.title)
                    }
                    .foregroundStyle(.secondary)
                } label: {
                    Label("iCTRL 服务", systemImage: "hand.tap")
                }
                switch service.state {
                case .running:
                    Button("停止服务", role: .destructive) { service.stop() }
                case .stopped:
                    Button("启动服务") { service.start() }
                case .notInstalled, .checking:
                    EmptyView()
                }
            } footer: {
                switch service.state {
                case .running:
                    Text("智能体现在可以替你点按、输入、读取其他 App 的屏幕。它操作时屏幕会被占用，顶部会显示 iOS 的「Automation Running」提示；同时按住两个音量键也能停止。点「停止服务」后 iCTRL 会发一条通知，长按它并点「停止」才会真的停下。")
                case .stopped:
                    Text("启动后智能体才能操作其他 App。如果点了没反应、或 iCTRL 打不开，多半是签名过期了：免费 Apple ID 签的 App 每 7 天要在 SideStore 里刷新一次。")
                case .notInstalled:
                    Text("这个功能要先在手机上装好 iCTRL（第三方开源 App，需要开发者模式），本 App 不会替你安装。")
                case .checking:
                    EmptyView()
                }
            }
            .groupedRow()

            Section {
                Link(destination: AppLinks.phoneControlGuide) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                    } label: {
                        Label("设置教程", systemImage: "book")
                    }
                }
            } header: {
                Text("怎么装")
            } footer: {
                Text("需要 iOS 17.4 或更高版本，第一次设置要用一次电脑。教程里有常见问题。")
            }
            .groupedRow()

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("先用本机能力", systemImage: "iphone")
                        .font(.subheadline.weight(.semibold))
                    Text("日历、提醒、通讯录、照片这类事，智能体会直接用本机能力去做，又快又准。只有必须点开别的 App 才能完成时，它才会用 iCTRL。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Label("截图会发给模型服务商", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                    Text("智能体看到的其他 App 画面，会随对话发给你选的模型服务商。付款、删除、替你发消息前，它会先问你；密码和验证码由你自己输入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Label("保持「仅本机」", systemImage: "lock")
                        .font(.subheadline.weight(.semibold))
                    Text("iCTRL 自带远程访问和近场发现，打开后同一网络里的设备也能请求控制这台手机。用本 App 时不需要它们，建议一直关着。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("使用须知")
            }
            .groupedRow()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("操控手机")
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.refresh() }
        // 从 iCTRL 回来（启动、停止都会跳过去）时重新查一次。
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { Task { await service.refresh() } }
        }
    }
}

@MainActor 
final class PhoneControlService: ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, stopped, running

        var title: String {
            switch self {
            case .checking: String(localized: "检查中…")
            case .notInstalled: String(localized: "未安装")
            case .stopped: String(localized: "未运行")
            case .running: String(localized: "运行中")
            }
        }

        var tint: Color {
            switch self {
            case .running: .green
            case .stopped: .orange
            case .notInstalled, .checking: .gray
            }
        }
    }

    @Published private(set) var state: State = .checking

    /// iCTRL's unauthenticated status endpoint; it answers only on this phone.
    private static let whoami = URL(string: "http://127.0.0.1:8200/whoami")!
    private static let probe = URL(string: "ictrl://")!

    func refresh() async {
        guard UIApplication.shared.canOpenURL(Self.probe) else {
            state = .notInstalled
            return
        }
        state = await Self.isRunning() ? .running : .stopped
    }

    /// Opens the runner the same way iCTRL's own 启动服务 does; it hands control back through the callback.
    func start() {
        open("ictrl://start?callback=\(DshLink.scheme)://")
        Task {
            // The runner needs a few seconds; we are usually back by then.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if await Self.isRunning() { state = .running; return }
            }
        }
    }

    /// Any app may ask; iCTRL then asks the user to confirm with a notification.
    func stop() {
        open("ictrl://stop?callback=\(DshLink.scheme)://")
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    private static func isRunning() async -> Bool {
        var request = URLRequest(url: whoami, timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
