import AppKit

final class FruitSliceApp: NSObject, NSApplicationDelegate {
    private var controller: EarGameController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = EarGameController()
        buildMenus()
        controller.show()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--preview-game") ?? arguments.firstIndex(of: "--preview-playing") ?? arguments.firstIndex(of: "--benchmark-motion") ?? arguments.firstIndex(of: "--preview-settings"), arguments.count > index+1 {
            let benchmark = arguments.contains("--benchmark-motion")
            if arguments.contains("--preview-playing") { controller.prepareGameplayPreview() }
            if benchmark { DispatchQueue.main.asyncAfter(deadline: .now()+0.35) { [self] in controller.prepareMotionBenchmark() } }
            if arguments.contains("--preview-settings") { DispatchQueue.main.asyncAfter(deadline: .now()+0.25) { [self] in controller.showSettings() } }
            DispatchQueue.main.asyncAfter(deadline: .now()+(benchmark ? 4.5 : 0.8)) { [self] in
                let measured = benchmark ? controller.benchmarkDescription() : ""
                do {
                    let url = URL(fileURLWithPath: arguments[index+1])
                    if arguments.contains("--preview-settings") { try controller.saveSettingsPreview(to: url) }
                    else { try controller.savePreview(to: url) }
                } catch { fputs("Preview failed: \(error)\n",stderr) }
                if benchmark { print("SIMULATED MOTION BENCHMARK: " + measured) }
                NSApp.terminate(nil)
            }
        }
    }
    private func buildMenus() {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "关于耳机切水果",action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent: "")
        app.addItem(.separator())
        let settings = NSMenuItem(title: "设置…",action: #selector(EarGameController.showSettings),keyEquivalent: ",")
        settings.target = controller; app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏耳机切水果",action: #selector(NSApplication.hide(_:)),keyEquivalent: "h")
        app.addItem(withTitle: "显示全部",action: #selector(NSApplication.unhideAllApplications(_:)),keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "退出耳机切水果",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = app; bar.addItem(appItem)
        let game = NSMenu()
        let start = NSMenuItem(title: "开始 / 暂停",action: #selector(EarGameController.primaryAction),keyEquivalent: "p")
        start.target = controller; game.addItem(start)
        let recenter = NSMenuItem(title: "重新校准",action: #selector(EarGameController.recalibrate),keyEquivalent: "r")
        recenter.target = controller; game.addItem(recenter)
        let item = NSMenuItem(title: "游戏",action: nil,keyEquivalent: "");item.submenu = game; bar.addItem(item)
        NSApp.mainMenu = bar
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTests(); runHeadPointerTests(); runMotionPipelineTests(); runFruitGameTests()
} else {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: .darkAqua)
    app.setActivationPolicy(.regular)
    let delegate = FruitSliceApp()
    app.delegate = delegate
    app.run()
}
