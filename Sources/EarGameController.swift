import AppKit
import CoreMotion
import QuartzCore

final class EarGameController: NSObject, NSWindowDelegate, CMHeadphoneMotionManagerDelegate {
    let window: NSWindow
    private let canvas = FruitGameView()
    private var game = FruitGame()
    private var engine = HeadPointerEngine()
    private var manager: CMHeadphoneMotionManager?
    private var motionQueue: OperationQueue?
    private var inbox = MotionInbox()
    private var presenter = PointerPresenter()
    private var telemetry = MotionTelemetry()
    private var simulationTimer: DispatchSourceTimer?
    private var generation = 0
    private var displayLink: CADisplayLink?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var lastStatusRefresh = 0.0
    private var mouseMode = false
    private var observers: [NSObjectProtocol] = []
    private let status = NSTextField(wrappingLabelWithString: "点击「连接耳机」开始，正视屏幕并稳定约 2 秒。")
    private let connectButton = NSButton(title: "连接耳机 · 校准", target: nil, action: nil)
    private let reverseX = NSButton(checkboxWithTitle: "左右反向", target: nil, action: nil)
    private let reverseY = NSButton(checkboxWithTitle: "上下反向", target: nil, action: nil)
    private let range = NSSlider(value: 8, minValue: 3, maxValue: 20, target: nil, action: nil)
    private let rangeLabel = NSTextField(labelWithString: "左右各 8°")
    private let verticalRange = NSSlider(value: 5, minValue: 2, maxValue: 12, target: nil, action: nil)
    private let verticalRangeLabel = NSTextField(labelWithString: "上下各 5°")
    private let settingsPopover = NSPopover()
    private let settingsButton = NSButton()
    private let inputChoice = NSPopUpButton(frame: .zero,pullsDown: false)
    private let defaults = UserDefaults.standard
    private let collectMetrics = CommandLine.arguments.contains("--benchmark-motion")
    private var pendingStart = false
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        loadSettings(); buildUI(); buildSettings()
        canvas.onMouseMove = { [weak self] point in
            guard let self else { return }
            let idleMenu = (self.game.phase == .ready || self.game.phase == .finished) && self.engine.mode != .running && self.engine.mode != .calibrating
            guard self.mouseMode || idleMenu else { return }
            self.game.setPointer(point); self.syncCanvas()
        }
        canvas.onActivate = { [weak self] in self?.activate() }
        canvas.onPrimaryAction = { [weak self] in self?.primaryAction() }
        canvas.onPause = { [weak self] in self?.togglePause() }
        if collectMetrics { canvas.onFrameDrawn = { [weak self] duration in self?.telemetry.rendered(at: ProcessInfo.processInfo.systemUptime,duration: duration) } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.pause("系统休眠或会话切换，游戏已暂停") })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.game.phase == .playing || self.engine.mode == .running else { return }
            self.pause("窗口已切到后台，游戏已暂停")
        })
        displayLink = window.displayLink(target: self, selector: #selector(displayFrame(_:)))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        displayLink?.add(to: .main, forMode: .common)
        syncCanvas(); refresh()
    }

    private func text(_ value: String, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.font = .systemFont(ofSize: size); return label
    }

    private func buildUI() {
        window.title = "耳机切水果"; window.delegate = self; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.11,green: 0.10,blue: 0.095,alpha: 1)
        window.minSize = NSSize(width: 760,height: 520)
        window.center()
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = window.backgroundColor.cgColor; window.contentView = root
        let bar = NSStackView(); bar.spacing = 12; bar.alignment = .centerY
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for: .horizontal)
        connectButton.target = self; connectButton.action = #selector(primaryAction)
        connectButton.bezelStyle = .rounded; connectButton.keyEquivalent = "\r"
        connectButton.setContentHuggingPriority(.required,for: .horizontal)
        settingsButton.image = NSImage(systemSymbolName: "gearshape",accessibilityDescription: "设置")
        settingsButton.imagePosition = .imageOnly; settingsButton.isBordered = false
        settingsButton.toolTip = "设置（⌘,）"; settingsButton.target = self; settingsButton.action = #selector(showSettings)
        settingsButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        bar.addArrangedSubview(status); bar.addArrangedSubview(spacer); bar.addArrangedSubview(connectButton); bar.addArrangedSubview(settingsButton)
        bar.translatesAutoresizingMaskIntoConstraints = false; canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar); root.addSubview(canvas)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor,constant: 10),bar.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -14),bar.heightAnchor.constraint(equalToConstant: 32),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor,constant: 10),canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 12),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -12),canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -12)
        ])
    }
    private func loadSettings() {
        defaults.register(defaults: ["FruitSlice.horizontal":8.0,"FruitSlice.vertical":5.0,"FruitSlice.mouse":false,"FruitSlice.reverseX":false,"FruitSlice.reverseY":false])
        range.doubleValue = min(20,max(3,defaults.double(forKey: "FruitSlice.horizontal")))
        verticalRange.doubleValue = min(12,max(2,defaults.double(forKey: "FruitSlice.vertical")))
        reverseX.state = defaults.bool(forKey: "FruitSlice.reverseX") ? .on : .off
        reverseY.state = defaults.bool(forKey: "FruitSlice.reverseY") ? .on : .off
        mouseMode = defaults.bool(forKey: "FruitSlice.mouse")
        updateRangeLabels()
    }
    private func updateRangeLabels() {
        rangeLabel.stringValue = "左右各 \(Int(range.doubleValue.rounded()))°"
        verticalRangeLabel.stringValue = "上下各 \(Int(verticalRange.doubleValue.rounded()))°"
    }
    private func buildSettings() {
        let content = NSViewController()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20,left: 20,bottom: 20,right: 20)
        stack.wantsLayer = true; stack.layer?.backgroundColor = NSColor(calibratedWhite: 0.16,alpha: 1).cgColor
        content.view = stack
        stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let heading = text("游戏设置",size: 18); heading.font = .systemFont(ofSize: 18,weight: .semibold); stack.addArrangedSubview(heading)
        inputChoice.addItems(withTitles: ["耳机控制","鼠标控制"]); inputChoice.selectItem(at: mouseMode ? 1 : 0)
        inputChoice.target = self; inputChoice.action = #selector(settingsChanged)
        inputChoice.widthAnchor.constraint(equalToConstant: 300).isActive = true; stack.addArrangedSubview(inputChoice)
        let separator = NSBox(); separator.boxType = .separator; separator.widthAnchor.constraint(equalToConstant: 300).isActive = true; stack.addArrangedSubview(separator)
        stack.addArrangedSubview(text("头部活动范围",size: 13))
        for (label,slider) in [(rangeLabel,range),(verticalRangeLabel,verticalRange)] {
            slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
            label.widthAnchor.constraint(equalToConstant: 98).isActive = true
            slider.target = self; slider.action = #selector(settingsChanged)
            let row = NSStackView(views: [label,slider]); row.spacing = 12; stack.addArrangedSubview(row)
        }
        let hint = text("范围越小，轻轻移动就能覆盖全场。",size: 12); hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
        for button in [reverseX,reverseY] { button.target = self; button.action = #selector(settingsChanged) }
        let directions = NSStackView(views: [reverseX,reverseY]); directions.spacing = 16; stack.addArrangedSubview(directions)
        let reset = NSButton(title: "恢复默认",target: self,action: #selector(resetSettings))
        let done = NSButton(title: "完成",target: self,action: #selector(closeSettings)); done.keyEquivalent = "\r"
        let space = NSView(); space.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let buttons = NSStackView(views: [reset,space,done]); buttons.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(buttons)
        settingsPopover.contentViewController = content; settingsPopover.behavior = .transient
        settingsPopover.appearance = window.appearance
        settingsPopover.contentSize = NSSize(width: 340,height: 340)
    }
    @objc func showSettings() {
        if settingsPopover.isShown { closeSettings(); return }
        if game.phase == .playing || engine.mode == .running || engine.mode == .calibrating { pause("已暂停") }
        settingsPopover.show(relativeTo: settingsButton.bounds,of: settingsButton,preferredEdge: .minY)
    }
    @objc private func closeSettings() { settingsPopover.performClose(nil); window.makeFirstResponder(canvas); refresh() }
    @objc private func resetSettings() {
        range.doubleValue = 8; verticalRange.doubleValue = 5; reverseX.state = .off; reverseY.state = .off
        inputChoice.selectItem(at: 0); settingsChanged()
    }
    @objc func primaryAction() {
        if engine.mode == .calibrating { return }
        if game.phase == .playing { pause("已暂停"); return }
        if game.phase == .finished { game.returnToMenu() }
        if mouseMode {
            if game.phase == .paused { game.resume() } else { game.start(seed: UInt64(Date().timeIntervalSince1970*1000)) }
            previousTick = now; window.makeFirstResponder(canvas); syncCanvas(); refresh()
        } else { connect() }
    }
    @objc func recalibrate() { if !mouseMode { connect() } }
    func saveSettingsPreview(to url: URL) throws {
        guard let view = settingsPopover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds,to: bitmap) }
        if let data = bitmap.representation(using: .png,properties: [:]) { try data.write(to: url) }
    }
    func show() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas); NSApp.activate(ignoringOtherApps: true) }
    func prepareGameplayPreview() {
        mouseMode = true
        game.start(seed: 7)
        game.setPointer(CGPoint(x: 230,y: 350))
        game.fruits = [
            FlyingFruit(id: 100,kind: .apple,position: CGPoint(x: 410,y: 350),velocity: CGPoint(x: 10,y: -80),radius: 36),
            FlyingFruit(id: 101,kind: .orange,position: CGPoint(x: 610,y: 350),velocity: CGPoint(x: -15,y: -110),radius: 35),
            FlyingFruit(id: 102,kind: .melon,position: CGPoint(x: 660,y: 190),velocity: CGPoint(x: -25,y: -100),radius: 40),
            FlyingFruit(id: 103,kind: .lime,position: CGPoint(x: 290,y: 460),velocity: CGPoint(x: 40,y: -250),radius: 32),
            FlyingFruit(id: 104,kind: .bomb,position: CGPoint(x: 850,y: 330),velocity: CGPoint(x: -25,y: -150),radius: 30)
        ]
        game.setPointer(CGPoint(x: 760,y: 350))
        previousTick = now; syncCanvas(); refresh()
    }
    func prepareMotionBenchmark() {
        prepareGameplayPreview(); mouseMode = false
        game.pause()
        game.setPointer(CGPoint(x: FruitGame.flightBounds.midX,y: FruitGame.flightBounds.midY))
        engine.nodEnabled = false
        engine.halfRangeDegrees = range.doubleValue
        engine.verticalHalfRangeDegrees = verticalRange.doubleValue
        telemetry = MotionTelemetry(); inbox = MotionInbox()
        presenter.reset(game.pointer)
        let start = now
        let neutral = AttitudeRotation.from(pitch: 0.2, yaw: 1.2, roll: 0.1)
        engine.begin(time: start - 2.6, cursor: game.pointer, screen: FruitGame.flightBounds)
        for index in 0...130 {
            let time = start - 2.6 + Double(index)/50
            _ = engine.ingest(time: time, timestamp: time, source: 1, pitch: 0.2, yaw: 1.2, orientation: neutral)
        }
        game.resume()
        let incoming = inbox
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        source.setEventHandler {
            let time = ProcessInfo.processInfo.systemUptime, t = time - start
            let pitch = sin(t*1.1)*0.12, yaw = sin(t*1.6)*0.3
            incoming.push(MotionSample(receivedAt: time, timestamp: time, source: 1, pitch: pitch, yaw: yaw,
                                       orientation: neutral * .from(pitch: pitch, yaw: yaw)))
        }
        simulationTimer = source; source.resume()
        previousTick = start; syncCanvas(); refresh()
    }
    func benchmarkDescription() -> String { telemetry.description(at: now) + String(format: " · 平均场景更新 %.2f ms", telemetry.averageDrawMilliseconds) + " · 已切开 \(game.sliced) 个水果" }
    func savePreview(to url: URL) throws {
        let root = window.contentView!
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds,to: bitmap) }
        let composite = NSImage(size: root.bounds.size)
        composite.lockFocusFlipped(root.isFlipped)
        NSImage(cgImage: bitmap.cgImage!,size: root.bounds.size).draw(in: root.bounds)
        if let rendered = canvas.previewImage() {
            NSGraphicsContext.saveGraphicsState()
            let frame = canvas.convert(canvas.bounds,to: root)
            NSBezierPath(roundedRect: frame,xRadius: 20,yRadius: 20).addClip()
            let scale = min(frame.width/1000,frame.height/600)
            let fitted = CGRect(x: frame.midX-500*scale,y: frame.midY-300*scale,width: 1000*scale,height: 600*scale)
            rendered.draw(in: fitted,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation,let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png,properties: [:]) else { return }
        try data.write(to: url)
    }

    @objc private func connect() {
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .denied || authorization == .restricted { pause("运动权限不可用"); refresh(); return }
        disconnect()
        settingsPopover.performClose(nil)
        pendingStart = game.phase == .ready || game.phase == .finished
        mouseMode = false
        game.pause()
        game.setPointer(CGPoint(x: FruitGame.flightBounds.midX,y: FruitGame.flightBounds.midY))
        engine.begin(time: now, cursor: game.pointer, screen: FruitGame.flightBounds)
        presenter.reset(game.pointer); telemetry = MotionTelemetry()
        engine.halfRangeDegrees = range.doubleValue
        engine.verticalHalfRangeDegrees = verticalRange.doubleValue
        engine.nodEnabled = false
        engine.invertX = reverseX.state == .on; engine.invertY = reverseY.state == .on
        let motionManager = CMHeadphoneMotionManager()
        manager = motionManager; motionManager.delegate = self
        generation += 1; let session = generation
        let incoming = MotionInbox(); inbox = incoming
        let queue = OperationQueue()
        queue.name = "AirPods.GameMotion"; queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1; motionQueue = queue
        motionManager.startConnectionStatusUpdates()
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            if let error {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == session else { return }
                    self.pause("运动接口错误：\(message)")
                }
                return
            }
            if let motion {
                let a = motion.attitude, q = a.quaternion
                incoming.push(MotionSample(receivedAt: ProcessInfo.processInfo.systemUptime, timestamp: motion.timestamp,
                                           source: motion.sensorLocation.rawValue, pitch: a.pitch, yaw: a.yaw,
                                           orientation: AttitudeRotation(x: q.x, y: q.y, z: q.z, w: q.w)))
            }
        }
        window.makeFirstResponder(canvas); syncCanvas(); refresh()
    }

    private func disconnect() {
        simulationTimer?.cancel(); simulationTimer = nil
        generation += 1
        manager?.delegate = nil; manager?.stopDeviceMotionUpdates(); manager?.stopConnectionStatusUpdates(); manager = nil
        motionQueue?.cancelAllOperations(); motionQueue = nil
        inbox = MotionInbox()
    }

    private func receive(_ sample: MotionSample) {
        guard NSApp.isActive, window.isKeyWindow else { pause("回到游戏窗口后，请继续并校准"); return }
        let wasCalibrating = engine.mode == .calibrating
        if collectMetrics { telemetry.sample(sample) }
        if let output = engine.ingest(time: sample.receivedAt, timestamp: sample.timestamp, source: sample.source,
                                      pitch: sample.pitch, yaw: sample.yaw, orientation: sample.orientation) {
            presenter.submit(output.position)
        }
        if wasCalibrating && engine.mode == .running {
            if pendingStart { game.start(seed: UInt64(Date().timeIntervalSince1970*1000)); pendingStart = false }
            else { game.resume() }
            previousTick = now
        }
        if engine.mode == .paused { game.pause(); disconnect(); syncCanvas() }
    }

    private func activate() {
        guard NSApp.isActive, window.isKeyWindow else { return }
        if !mouseMode && engine.mode != .running {
            if FruitGame.playButton.contains(game.pointer) && (game.phase == .ready || game.phase == .finished) { primaryAction() }
            return
        }
        game.activate(); window.makeFirstResponder(canvas); syncCanvas(); refresh()
    }

    @objc private func togglePause() {
        if game.phase == .playing || engine.mode == .running || engine.mode == .calibrating { pause("已暂停，点击「继续并校准」恢复") }
        else if mouseMode { game.resume(); previousTick = now; syncCanvas(); refresh() }
        else { connect() }
    }

    private func pause(_ reason: String) {
        game.pause(); engine.pause(reason); disconnect(); syncCanvas(); refresh()
    }

    func stop() { game.pause(); engine.stop(); mouseMode = false; disconnect(); syncCanvas(); refresh() }
    @objc private func settingsChanged() {
        range.doubleValue = range.doubleValue.rounded(); verticalRange.doubleValue = verticalRange.doubleValue.rounded()
        if game.phase == .playing || engine.mode == .running || engine.mode == .calibrating { pause("已暂停") }
        mouseMode = inputChoice.indexOfSelectedItem == 1
        defaults.set(range.doubleValue,forKey: "FruitSlice.horizontal"); defaults.set(verticalRange.doubleValue,forKey: "FruitSlice.vertical")
        defaults.set(reverseX.state == .on,forKey: "FruitSlice.reverseX"); defaults.set(reverseY.state == .on,forKey: "FruitSlice.reverseY")
        defaults.set(mouseMode,forKey: "FruitSlice.mouse")
        updateRangeLabels(); syncCanvas(); refresh()
    }
    @objc private func displayFrame(_ link: CADisplayLink) { tick() }
    private func tick() {
        let time = now, delta = time - previousTick
        previousTick = time
        let batch = inbox.drain()
        if collectMetrics { telemetry.addDropped(batch.dropped) }
        for sample in batch.samples {
            receive(sample)
            if engine.mode == .paused { break }
        }
        engine.tick(time: time)
        if engine.mode == .paused && manager != nil { game.pause(); disconnect(); syncCanvas() }
        if engine.mode == .running { game.setPointer(presenter.frame(delta: delta)) }
        game.hoverMenu(delta: delta, enabled: mouseMode || engine.mode == .running)
        if game.phase == .playing { game.update(delta: delta) }
        if mouseMode || game.phase == .playing || engine.mode == .running || engine.mode == .calibrating { syncCanvas() }
        if time - lastStatusRefresh >= 0.2 { lastStatusRefresh = time; refresh() }
    }
    private func syncCanvas() {
        canvas.game = game; canvas.trackingEnabled = mouseMode || engine.mode == .running
        canvas.submitFrame()
    }
    private func refresh() {
        connectButton.isEnabled = engine.mode != .calibrating
        if engine.mode == .calibrating {
            status.stringValue = "正视屏幕，保持头部稳定…"; connectButton.title = "校准中…"
        } else if game.phase == .playing {
            status.stringValue = mouseMode ? "鼠标控制" : "耳机已连接"; connectButton.title = "暂停"
        } else if game.phase == .finished {
            status.stringValue = "本局完成"; connectButton.title = "再来一局"
        } else if game.phase == .paused || engine.mode == .paused {
            status.stringValue = !mouseMode && engine.message.contains("数据") ? "请戴好耳机后继续" : "已暂停"
            connectButton.title = "继续"
        } else {
            status.stringValue = mouseMode ? "鼠标模式" : "耳机模式"
            connectButton.title = "开始游戏"
        }
        if !mouseMode && CMHeadphoneMotionManager.authorizationStatus() == .denied { status.stringValue = "请在系统设置中允许运动数据权限" }
        status.textColor = game.phase == .playing ? .systemGreen : .secondaryLabelColor
        connectButton.isHidden = (game.phase == .ready || game.phase == .finished) && engine.mode != .calibrating && engine.mode != .paused
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        // Brief disconnect/reconnect events can accompany a normal bud handoff.
        // Actual loss of fresh data is handled by the 0.6-second watchdog.
    }
    func windowWillClose(_ notification: Notification) { pause("窗口已关闭，游戏已暂停") }
    func shutdown() {
        settingsPopover.performClose(nil); stop(); displayLink?.invalidate(); displayLink = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
