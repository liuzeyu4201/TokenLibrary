import SwiftUI

@main
struct TokenLibraryApp: App {
    var body: some Scene {
        WindowGroup {
            TokenLibraryRoot()
        }
        .defaultSize(width: 1100, height: 720)
        Settings {
            Form {
                Text("TokenLibrary · 固定账号 · 无注册")
                Text("备份窗口 03:00 暂停云端写入，本地仍可编辑")
            }
            .padding()
            .frame(width: 360)
        }
    }
}
