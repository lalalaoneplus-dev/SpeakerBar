// SpeakerBar — menu bar app to keep a Bluetooth speaker connected and switch
// audio output with a global hotkey (default: ⌥⌘B toggles speaker <-> Mac speakers).
//
// - Pick a paired Bluetooth speaker from the menu; it becomes the managed target.
// - While the speaker is the active route, a watchdog reconnects it if it drops,
//   and an inaudible 25 Hz pulse every 5 minutes stops the speaker's auto-standby.
// - Registers itself as a login item so it reconnects after restart.

import AppKit
import IOBluetooth
import AVFoundation
import CoreAudio
import Carbon
import ServiceManagement
import ApplicationServices

// MARK: - Logging (NSLog + ~/Library/Logs/SpeakerBar.log)

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SpeakerBar.log")

func slog(_ message: String) {
    NSLog("SpeakerBar: %@", message)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - CoreAudio helpers

struct AudioOut {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
}

enum CA {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func outputDevices() -> [AudioOut] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var result: [AudioOut] = []
        for id in ids {
            var streamAddr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            var nameAddr = address(kAudioDevicePropertyDeviceNameCFString)
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
                  let cfName = nameRef?.takeRetainedValue() else { continue }

            var transportAddr = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &tSize, &transport)

            result.append(AudioOut(id: id, name: (cfName as String), transport: transport))
        }
        return result
    }

    static func defaultOutput() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var dev = id
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        }
    }

    static func builtIn() -> AudioOut? {
        outputDevices().first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
    }

    static func find(named name: String) -> AudioOut? {
        let want = name.trimmingCharacters(in: .whitespaces).lowercased()
        let devs = outputDevices()
        return devs.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == want }
            ?? devs.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased().contains(want) }
    }
}

// MARK: - Equalizer: presets + biquad filter bank (RBJ audio-EQ cookbook)

let eqBandFreqs: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

let eqFactoryPresets: [(name: String, gains: [Double])] = [
    ("Flat",          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ("Bass Boost",    [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
    ("Bass Reducer",  [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
    ("Treble Boost",  [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
    ("Vocal / Dialogue", [-3, -2, 0, 2, 4, 4, 3, 2, 0, -2]),
    ("Rock",          [5, 4, 3, 1, -0.5, -0.5, 1, 3, 4, 5]),
    ("Pop",           [-1, 0, 2, 4, 4, 2, 0, -1, -1, -1]),
    ("Jazz",          [4, 3, 1, 2, -1, -1, 0, 1, 2, 3]),
    ("Classical",     [4, 3, 2, 0, -1, -1, 0, 2, 3, 4]),
    ("Dance / Electronic", [5, 4, 2, 0, -1, 0, 2, 3, 4, 5]),
    ("Loudness (low volume)", [6, 4, 0, -1, -2, -2, -1, 0, 3, 5]),
]

// One set of biquad coefficients per band. Swapped atomically (class ref) when
// the user moves a slider; the realtime IO callback only ever reads.
final class EQCoeffs {
    // b0 b1 b2 a1 a2 per band, plus linear preamp
    let c: [[Double]]
    let preamp: Double
    init(gains: [Double], preampDB: Double, sampleRate: Double) {
        var all: [[Double]] = []
        for (i, f0) in eqBandFreqs.enumerated() {
            let g = i < gains.count ? gains[i] : 0
            let A = pow(10.0, g / 40.0)
            let w0 = 2.0 * Double.pi * f0 / sampleRate
            let cw = cos(w0), sw = sin(w0)
            var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
            if i == 0 || i == eqBandFreqs.count - 1 {
                // Shelves at the extremes sound more natural than narrow peaks.
                let S = 0.9
                let alpha = sw / 2.0 * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0)
                let twoRootAalpha = 2.0 * sqrt(A) * alpha
                if i == 0 { // low shelf
                    b0 = A * ((A + 1) - (A - 1) * cw + twoRootAalpha)
                    b1 = 2 * A * ((A - 1) - (A + 1) * cw)
                    b2 = A * ((A + 1) - (A - 1) * cw - twoRootAalpha)
                    a0 = (A + 1) + (A - 1) * cw + twoRootAalpha
                    a1 = -2 * ((A - 1) + (A + 1) * cw)
                    a2 = (A + 1) + (A - 1) * cw - twoRootAalpha
                } else { // high shelf
                    b0 = A * ((A + 1) + (A - 1) * cw + twoRootAalpha)
                    b1 = -2 * A * ((A - 1) + (A + 1) * cw)
                    b2 = A * ((A + 1) + (A - 1) * cw - twoRootAalpha)
                    a0 = (A + 1) - (A - 1) * cw + twoRootAalpha
                    a1 = 2 * ((A - 1) - (A + 1) * cw)
                    a2 = (A + 1) - (A - 1) * cw - twoRootAalpha
                }
            } else { // peaking
                let Q = 1.1
                let alpha = sw / (2.0 * Q)
                b0 = 1 + alpha * A
                b1 = -2 * cw
                b2 = 1 - alpha * A
                a0 = 1 + alpha / A
                a1 = -2 * cw
                a2 = 1 - alpha / A
            }
            all.append([b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0])
        }
        c = all
        preamp = pow(10.0, preampDB / 20.0)
    }
}

// Per-channel filter memory. Only touched on the IO thread.
final class EQChannelState {
    var x1 = [Double](repeating: 0, count: eqBandFreqs.count)
    var x2 = [Double](repeating: 0, count: eqBandFreqs.count)
    var y1 = [Double](repeating: 0, count: eqBandFreqs.count)
    var y2 = [Double](repeating: 0, count: eqBandFreqs.count)
    func reset() {
        for i in 0..<eqBandFreqs.count { x1[i] = 0; x2[i] = 0; y1[i] = 0; y2[i] = 0 }
    }
}

// MARK: - Equalizer: system-wide audio tap (macOS 14.2+ Core Audio process tap)

// Taps every process except SpeakerBar itself (mute-when-tapped), runs the samples
// through the biquad bank, and re-renders them to the physical output device via a
// private aggregate device — so the system default output stays the real speaker,
// volume keys keep working, and no virtual driver is needed.
final class SystemEQTap {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "speakerbar.eq.io")
    private var states: [EQChannelState] = [EQChannelState(), EQChannelState()]
    private(set) var outputDeviceID: AudioDeviceID = 0
    private(set) var sampleRate: Double = 48000
    var coeffs: EQCoeffs = EQCoeffs(gains: [Double](repeating: 0, count: 10), preampDB: 0, sampleRate: 48000)
    private var callbackCount: Int = 0

    var isRunning: Bool { procID != nil }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uidRef) == noErr,
              let uid = uidRef?.takeRetainedValue() else { return nil }
        return uid as String
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &obj)
        }
        return err == noErr ? obj : nil
    }

    @available(macOS 14.2, *)
    func start(outputDevice: AudioDeviceID, gains: [Double], preampDB: Double) -> Bool {
        stop()
        guard let outUID = Self.deviceUID(outputDevice) else {
            slog("EQ: no UID for output device \(outputDevice)")
            return false
        }
        var exclude: [AudioObjectID] = []
        if let own = Self.ownProcessObject() { exclude = [own] }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        desc.name = "SpeakerBar EQ Tap"
        desc.isPrivate = true

        var newTap = AudioObjectID(0)
        var err = AudioHardwareCreateProcessTap(desc, &newTap)
        guard err == noErr else {
            slog("EQ: tap creation failed (\(err)) — is System Audio Recording permission granted?")
            return false
        }
        tapID = newTap

        // Device sample rate for filter design.
        var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var sr: Double = 48000
        var srSize = UInt32(MemoryLayout<Double>.size)
        if AudioObjectGetPropertyData(outputDevice, &srAddr, 0, nil, &srSize, &sr) == noErr, sr > 0 {
            sampleRate = sr
        }
        coeffs = EQCoeffs(gains: gains, preampDB: preampDB, sampleRate: sampleRate)
        states.forEach { $0.reset() }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SpeakerBar EQ",
            kAudioAggregateDeviceUIDKey as String: "com.prakrin.speakerbar.eq.aggregate",
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: desc.uuid.uuidString,
            ]],
        ]
        var newAgg = AudioObjectID(0)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
        guard err == noErr else {
            slog("EQ: aggregate device creation failed (\(err))")
            destroyTapOnly()
            return false
        }
        aggregateID = newAgg
        callbackCount = 0

        var newProc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) {
            [weak self] _, inputData, _, outputData, _ in
            self?.process(input: inputData, output: outputData)
        }
        guard err == noErr, let proc = newProc else {
            slog("EQ: IOProc creation failed (\(err))")
            stop()
            return false
        }
        procID = proc
        err = AudioDeviceStart(aggregateID, proc)
        guard err == noErr else {
            slog("EQ: AudioDeviceStart failed (\(err))")
            stop()
            return false
        }
        outputDeviceID = outputDevice
        slog("EQ: running (output \(outputDevice), \(Int(sampleRate)) Hz)")
        return true
    }

    private func process(input: UnsafePointer<AudioBufferList>, output: UnsafePointer<AudioBufferList>) {
        callbackCount += 1
        if callbackCount == 1 { slog("EQ: first IO callback") }
        let co = coeffs
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: output))

        // Gather input channel pointers (+ stride) — tap is float32, 1 interleaved
        // stereo buffer or per-channel buffers depending on layout.
        var inChans: [(ptr: UnsafeMutablePointer<Float>, stride: Int)] = []
        for buf in inABL {
            guard let data = buf.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let n = max(1, Int(buf.mNumberChannels))
            for ch in 0..<n { inChans.append((p + ch, n)) }
        }
        var outChans: [(ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = []
        for buf in outABL {
            guard let data = buf.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let n = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * n)
            for ch in 0..<n { outChans.append((p + ch, n, frames)) }
        }
        guard !inChans.isEmpty, !outChans.isEmpty else { return }
        let inFrames = Int(inABL[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(inABL[0].mNumberChannels)))

        while states.count < outChans.count { states.append(EQChannelState()) }

        for (ci, oc) in outChans.enumerated() {
            let ic = inChans[min(ci, inChans.count - 1)] // mono tap → duplicate
            let st = states[ci]
            let frames = min(inFrames, oc.frames)
            for f in 0..<frames {
                var s = Double(ic.ptr[f * ic.stride]) * co.preamp
                for b in 0..<co.c.count {
                    let k = co.c[b]
                    let y = k[0] * s + k[1] * st.x1[b] + k[2] * st.x2[b] - k[3] * st.y1[b] - k[4] * st.y2[b]
                    st.x2[b] = st.x1[b]; st.x1[b] = s
                    st.y2[b] = st.y1[b]; st.y1[b] = y
                    s = y
                }
                oc.ptr[f * oc.stride] = Float(max(-1.0, min(1.0, s)))
            }
            if inFrames < oc.frames {
                for f in inFrames..<oc.frames { oc.ptr[f * oc.stride] = 0 }
            }
        }
    }

    func updateFilters(gains: [Double], preampDB: Double) {
        coeffs = EQCoeffs(gains: gains, preampDB: preampDB, sampleRate: sampleRate)
    }

    @available(macOS 14.2, *)
    private func destroyTapOnly() {
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    func stop() {
        if let proc = procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if #available(macOS 14.2, *) { destroyTapOnly() }
        if outputDeviceID != 0 { slog("EQ: stopped") }
        outputDeviceID = 0
    }
}

// MARK: - Keep-awake tone generator

// Streams (mostly) silence to the speaker so the A2DP link stays busy, with a short
// low-frequency pulse every `period` seconds so the speaker's signal detector never
// sees "no audio" long enough to trigger auto-standby. 25 Hz at this amplitude is
// inaudible on small speakers/soundbars.
final class KeepAlive {
    private var engine: AVAudioEngine?
    private(set) var deviceID: AudioDeviceID = 0

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(device: AudioDeviceID) {
        stop()
        let engine = AVAudioEngine()
        guard let au = engine.outputNode.audioUnit else { return }
        var dev = device
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = hwRate > 0 ? hwRate : 44100
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }

        let period = 300.0, pulseLen = 3.0, freq = 25.0, amp = 0.015
        var t = 0.0
        let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for frame in 0..<Int(frameCount) {
                let phase = t.truncatingRemainder(dividingBy: period)
                let v: Float = phase < pulseLen ? Float(amp * sin(2 * .pi * freq * t)) : 0
                for buf in buffers {
                    buf.mData?.assumingMemoryBound(to: Float.self)[frame] = v
                }
                t += 1.0 / sr
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)

        do {
            try engine.start()
            self.engine = engine
            self.deviceID = device
            slog("keep-alive running on device \(device)")
        } catch {
            slog("keep-alive failed to start: \(error)")
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        deviceID = 0
    }
}

// MARK: - Equalizer window

final class EQWindowController: NSWindowController, NSWindowDelegate {
    var onChange: (() -> Void)?           // sliders / preamp moved
    var onEnableToggle: ((Bool) -> Void)?
    var onPresetPicked: ((String) -> Void)?
    var onSaveCustom: ((String) -> Void)?
    var onDeleteCustom: ((String) -> Void)?

    let enableBox = NSButton(checkboxWithTitle: "Equalizer On", target: nil, action: nil)
    let presetPopup = NSPopUpButton()
    let saveButton = NSButton(title: "Save As…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    var sliders: [NSSlider] = []
    var valueLabels: [NSTextField] = []
    let preampSlider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: nil, action: nil)
    let preampLabel = NSTextField(labelWithString: "Preamp: 0.0 dB")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "SpeakerBar Equalizer"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        enableBox.target = self
        enableBox.action = #selector(enableToggled)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)

        let topRow = NSStackView(views: [enableBox, NSView(), presetPopup, saveButton, deleteButton])
        topRow.orientation = .horizontal
        topRow.spacing = 10

        var columns: [NSView] = []
        for (i, f) in eqBandFreqs.enumerated() {
            let valueLabel = NSTextField(labelWithString: "0")
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            valueLabel.alignment = .center
            let slider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: self, action: #selector(sliderMoved(_:)))
            slider.isVertical = true
            slider.tag = i
            slider.numberOfTickMarks = 9
            slider.allowsTickMarkValuesOnly = false
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.heightAnchor.constraint(equalToConstant: 170).isActive = true
            let freqLabel = NSTextField(labelWithString: f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
            freqLabel.font = .systemFont(ofSize: 10)
            freqLabel.alignment = .center
            let col = NSStackView(views: [valueLabel, slider, freqLabel])
            col.orientation = .vertical
            col.alignment = .centerX
            col.spacing = 4
            sliders.append(slider)
            valueLabels.append(valueLabel)
            columns.append(col)
        }
        let bandRow = NSStackView(views: columns)
        bandRow.orientation = .horizontal
        bandRow.distribution = .equalSpacing
        bandRow.spacing = 14

        preampSlider.target = self
        preampSlider.action = #selector(sliderMoved(_:))
        preampSlider.tag = -1
        preampSlider.translatesAutoresizingMaskIntoConstraints = false
        preampSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let resetButton = NSButton(title: "Reset (Flat)", target: self, action: #selector(resetPressed))
        let bottomRow = NSStackView(views: [preampLabel, preampSlider, NSView(), resetButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10

        let root = NSStackView(views: [topRow, bandRow, bottomRow])
        root.orientation = .vertical
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func refresh(enabled: Bool, gains: [Double], preamp: Double, presetName: String, customNames: [String]) {
        enableBox.state = enabled ? .on : .off
        for (i, s) in sliders.enumerated() {
            s.doubleValue = i < gains.count ? gains[i] : 0
            valueLabels[i].stringValue = String(format: "%+.1f", s.doubleValue)
        }
        preampSlider.doubleValue = preamp
        preampLabel.stringValue = String(format: "Preamp: %+.1f dB", preamp)

        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.menu?.addItem(.separator())
        for p in eqFactoryPresets { presetPopup.addItem(withTitle: p.name) }
        if !customNames.isEmpty {
            presetPopup.menu?.addItem(.separator())
            for n in customNames.sorted() { presetPopup.addItem(withTitle: n) }
        }
        presetPopup.selectItem(withTitle: presetName)
        if presetPopup.selectedItem == nil { presetPopup.selectItem(withTitle: "Custom") }
        deleteButton.isEnabled = customNames.contains(presetName)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        if sender.tag >= 0 {
            valueLabels[sender.tag].stringValue = String(format: "%+.1f", sender.doubleValue)
        } else {
            preampLabel.stringValue = String(format: "Preamp: %+.1f dB", sender.doubleValue)
        }
        presetPopup.selectItem(withTitle: "Custom")
        deleteButton.isEnabled = false
        onChange?()
    }

    @objc private func enableToggled() { onEnableToggle?(enableBox.state == .on) }

    @objc private func presetChanged() {
        guard let name = presetPopup.titleOfSelectedItem, name != "Custom" else { return }
        onPresetPicked?(name)
    }

    @objc private func resetPressed() { onPresetPicked?("Flat") }

    @objc private func savePressed() {
        let alert = NSAlert()
        alert.messageText = "Save preset as"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "My preset"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { onSaveCustom?(name) }
        }
    }

    @objc private func deletePressed() {
        guard let name = presetPopup.titleOfSelectedItem else { return }
        onDeleteCustom?(name)
    }

    var currentGains: [Double] { sliders.map(\.doubleValue) }
    var currentPreamp: Double { preampSlider.doubleValue }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard
    private let keepAlive = KeepAlive()
    private let btQueue = DispatchQueue(label: "speakerbar.bt")
    private var hotKeyRef: EventHotKeyRef?
    private var watchdog: Timer?
    private var connecting = false
    // Bumped on every user route change; in-flight connect jobs from an older
    // generation abort instead of applying a stale result over a newer choice.
    private var routeGeneration = 0

    // Reconnect controller: a SINGLE pending retry with exponential backoff.
    // Without this, the disconnect notification (3 s) and watchdog (25 s) each
    // spawned their own openConnection() forever, flooding the shared Bluetooth
    // radio and disrupting the keyboard/mouse when the speaker can't take audio.
    private var reconnectWorkItem: DispatchWorkItem?
    private var failureStreak = 0
    private let backoffSchedule: [TimeInterval] = [8, 20, 45, 90, 180, 300]
    private var disconnectNotification: IOBluetoothUserNotification?
    private var signalSources: [DispatchSourceSignal] = []

    // Persisted state
    private var targetAddress: String? {
        get { defaults.string(forKey: "targetAddress") }
        set { defaults.set(newValue, forKey: "targetAddress") }
    }
    private var targetName: String? {
        get { defaults.string(forKey: "targetName") }
        set { defaults.set(newValue, forKey: "targetName") }
    }
    private var routeIsSpeaker: Bool {
        get { defaults.bool(forKey: "routeIsSpeaker") }
        set { defaults.set(newValue, forKey: "routeIsSpeaker") }
    }
    private var keepAwakeEnabled: Bool {
        get { defaults.object(forKey: "keepAwake") == nil ? true : defaults.bool(forKey: "keepAwake") }
        set { defaults.set(newValue, forKey: "keepAwake") }
    }

    private var targetDevice: IOBluetoothDevice? {
        guard let addr = targetAddress else { return nil }
        return IOBluetoothDevice(addressString: addr)
    }

    // MARK: EQ state

    private let eqTap = SystemEQTap()
    private var eqWindow: EQWindowController?

    private var eqEnabled: Bool {
        get { defaults.bool(forKey: "eqEnabled") }
        set { defaults.set(newValue, forKey: "eqEnabled") }
    }
    private var eqGains: [Double] {
        get { (defaults.array(forKey: "eqGains") as? [Double]) ?? [Double](repeating: 0, count: 10) }
        set { defaults.set(newValue, forKey: "eqGains") }
    }
    private var eqPreamp: Double {
        get { defaults.double(forKey: "eqPreamp") }
        set { defaults.set(newValue, forKey: "eqPreamp") }
    }
    private var eqPresetName: String {
        get { defaults.string(forKey: "eqPresetName") ?? "Flat" }
        set { defaults.set(newValue, forKey: "eqPresetName") }
    }
    private var eqCustomPresets: [String: [Double]] {
        get { (defaults.dictionary(forKey: "eqCustomPresets") as? [String: [Double]]) ?? [:] }
        set { defaults.set(newValue, forKey: "eqCustomPresets") }
    }

    // The physical device audio should reach, given the current route.
    private func currentPhysicalDevice() -> AudioOut? {
        if routeIsSpeaker, let name = targetName { return CA.find(named: name) }
        return CA.builtIn()
    }

    private var eqActive: Bool { eqEnabled && eqTap.isRunning }

    // Start/stop/rebuild the tap to match current settings. Safe to call often.
    func applyEQ() {
        guard #available(macOS 14.2, *) else {
            startKeepAliveIfNeeded()
            return
        }
        guard eqEnabled else {
            eqTap.stop()
            startKeepAliveIfNeeded() // EQ off → raw keep-alive guards standby again
            return
        }
        guard let phys = currentPhysicalDevice() else {
            // Target device not present (e.g. speaker offline) — don't leave a tap
            // pointing at a vanished device, which would keep other apps muted.
            eqTap.stop()
            return
        }
        if !eqTap.isRunning || eqTap.outputDeviceID != phys.id {
            if eqTap.start(outputDevice: phys.id, gains: eqGains, preampDB: eqPreamp) {
                // The tap now continuously drives the speaker; a second raw audio
                // client (keep-alive) on the same BT device causes contention that
                // can drop the link — so stop it while the tap owns the device.
                keepAlive.stop()
            } else {
                // Never leave system audio muted by a dead tap; fall back to direct
                // (un-EQ'd) output, which always works since the speaker is default.
                eqTap.stop()
                startKeepAliveIfNeeded()
            }
        } else {
            eqTap.updateFilters(gains: eqGains, preampDB: eqPreamp)
            keepAlive.stop()
        }
    }

    // Keep-alive only runs when the EQ tap is NOT driving the device (else contention).
    private func startKeepAliveIfNeeded() {
        guard keepAwakeEnabled, !eqActive, routeIsSpeaker,
              let name = targetName, let dev = CA.find(named: name) else { return }
        if !keepAlive.isRunning || keepAlive.deviceID != dev.id {
            keepAlive.start(device: dev.id)
        }
    }

    // Called from signal handlers / terminate: make sure nothing leaves the system
    // audio muted or the BT link half-owned.
    func emergencyCleanup() {
        eqTap.stop()
        keepAlive.stop()
    }

    // If the app is force-quit / killed / logged out (SIGTERM etc.), tear down the
    // audio tap first — otherwise a muted-when-tapped tap could leave the whole
    // system silent until coreaudiod notices the process is gone.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.emergencyCleanup()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        registerHotKey()
        registerLoginItemOnce()
        primePermissions()
        installSignalHandlers()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        watchdog = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }

        registerDisconnectNotification()

        // After login/restart, restore the speaker route.
        if routeIsSpeaker, targetAddress != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.activateSpeaker(userInitiated: true) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.applyEQ() }
        }
        slog("launched (target=\(targetName ?? "none"), route=\(routeIsSpeaker ? "speaker" : "builtin"))")
    }

    // MARK: Route control

    @objc func toggleRoute() {
        slog("hotkey pressed (route: \(routeIsSpeaker ? "speaker" : "builtin") → \(routeIsSpeaker ? "builtin" : "speaker"))")
        routeIsSpeaker ? switchToBuiltIn() : activateSpeaker(userInitiated: true)
    }

    // Cancel any pending backoff retry (called when the user changes intent or a
    // fresh attempt begins). Main-thread only.
    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    // Schedule exactly ONE reconnect. Deduplicates: if a retry is already pending
    // or a connect is in flight, does nothing. Delay grows with the failure streak.
    private func scheduleReconnect() {
        guard routeIsSpeaker, targetAddress != nil else { return }
        if connecting || reconnectWorkItem != nil { return }
        let delay = backoffSchedule[min(failureStreak, backoffSchedule.count - 1)]
        slog("reconnect scheduled in \(Int(delay)) s (failure streak \(failureStreak))")
        let item = DispatchWorkItem { [weak self] in
            self?.reconnectWorkItem = nil
            self?.activateSpeaker(userInitiated: false)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // userInitiated: the user clicked the speaker / pressed the hotkey / hit Reconnect
    // Now / woke the Mac. Only these attempts are allowed to pop the Control Center
    // menu (the UI-scripting fallback); automatic backoff retries never do, so a speaker
    // that is off or out of Bluetooth-audio mode can't spam the menu or the BT radio.
    func activateSpeaker(userInitiated: Bool) {
        guard let device = targetDevice, let name = targetName else {
            slog("no speaker selected")
            return
        }
        cancelReconnect()
        if userInitiated { failureStreak = 0 }
        routeIsSpeaker = true
        routeGeneration += 1
        let gen = routeGeneration
        connecting = true
        updateIcon()

        // True while this job's result is still the user's latest choice.
        let stillWanted: () -> Bool = { [weak self] in
            DispatchQueue.main.sync {
                guard let self else { return false }
                return gen == self.routeGeneration && self.routeIsSpeaker
            }
        }

        // Common failure exit: bump streak, clear connecting, schedule ONE backoff retry.
        let fail: (String) -> Void = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, gen == self.routeGeneration else { return }
                self.connecting = false
                self.failureStreak += 1
                slog(reason)
                self.flashFailure()
                self.updateIcon()
                self.scheduleReconnect()
            }
        }

        btQueue.async { [weak self] in
            guard let self, stillWanted() else { return }
            var ok = device.isConnected()
            if !ok {
                slog("connecting to \(name)…")
                ok = device.openConnection() == kIOReturnSuccess
            }
            guard ok else {
                fail("could not open link to \(name) (powered on / in range?)")
                return
            }
            // Wait for CoreAudio to publish the device, then make it default.
            var audioDev: AudioOut?
            for _ in 0..<12 {
                audioDev = CA.find(named: name)
                if audioDev != nil { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if audioDev == nil && userInitiated {
                guard stillWanted() else { return }
                // Link is up but the audio profile didn't attach (some speakers, e.g.
                // Bose Solo 5, need the deep connect the Bluetooth menu does). Reproduce
                // the manual click — ONLY for user-initiated attempts (never in the
                // background, where a popping menu would wreck what the user is doing).
                slog("no audio device via API — trying Control Center click")
                DispatchQueue.main.sync { self.connectViaControlCenter() }
                for _ in 0..<24 {
                    audioDev = CA.find(named: name)
                    if audioDev != nil { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            guard let audioDev else {
                fail("\(name) linked but no audio device appeared — is it on & in Bluetooth mode?")
                return
            }
            DispatchQueue.main.async {
                guard gen == self.routeGeneration, self.routeIsSpeaker else {
                    slog("dropping stale connect result for \(name)")
                    return
                }
                self.connecting = false
                self.failureStreak = 0
                CA.setDefaultOutput(audioDev.id)
                self.applyEQ()                 // starts tap if EQ on (stops keep-alive)
                self.startKeepAliveIfNeeded()  // starts keep-alive only if EQ off
                slog("routed audio to \(audioDev.name)")
                self.updateIcon()
            }
        }
    }

    func switchToBuiltIn() {
        cancelReconnect()
        failureStreak = 0
        routeIsSpeaker = false
        routeGeneration += 1
        connecting = false
        keepAlive.stop()
        if let builtIn = CA.builtIn() {
            CA.setDefaultOutput(builtIn.id)
            slog("routed audio to \(builtIn.name)")
        }
        applyEQ()
        updateIcon()
    }

    private func watchdogTick() {
        applyEQ() // keeps the tap alive on either route; rebuilds after device changes
        guard routeIsSpeaker, let device = targetDevice, let name = targetName else { return }
        if !device.isConnected() {
            // Route through the controller — respects backoff & dedup, no direct spam.
            scheduleReconnect()
            return
        }
        // Connected: make sure it is still the default output and keep-alive is alive.
        if let audioDev = CA.find(named: name) {
            failureStreak = 0
            if CA.defaultOutput() != audioDev.id { CA.setDefaultOutput(audioDev.id) }
            startKeepAliveIfNeeded()
        } else {
            // Baseband-connected but no audio sink: don't hammer, let backoff handle it.
            scheduleReconnect()
        }
    }

    @objc private func didWake() {
        guard routeIsSpeaker else { return }
        slog("woke from sleep, restoring speaker")
        keepAlive.stop()
        failureStreak = 0
        cancelReconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.activateSpeaker(userInitiated: true) }
    }

    // Clicks the device row in the Control Center Bluetooth menu — the same action as a
    // manual connect, which performs full audio-profile negotiation that openConnection()
    // does not. Rows are matched by MAC via AXIdentifier ("bluetooth-device-XX:XX:..."),
    // so it is immune to device renames and localisation. Requires Accessibility.
    private func connectViaControlCenter() {
        guard let addr = targetAddress else { return }
        let mac = addr.replacingOccurrences(of: "-", with: ":").uppercased()
        let script = """
        tell application "System Events" to tell process "ControlCenter"
            click (first menu bar item of menu bar 1 whose description is "Bluetooth")
            delay 1.2
            set b to (first checkbox of scroll area 1 of group 1 of window 1 whose value of attribute "AXIdentifier" is "bluetooth-device-\(mac)")
            if value of b is 0 then click b
            delay 0.5
            key code 53
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            slog("Control Center fallback failed: \(error[NSAppleScript.errorMessage] ?? error)")
            // Close a possibly stuck-open panel.
            NSAppleScript(source: "tell application \"System Events\" to key code 53")?.executeAndReturnError(nil)
        } else {
            slog("Control Center fallback clicked \(mac)")
        }
    }

    // Surface the Accessibility grant dialog on first launch so the fallback works later.
    private func primePermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            slog("Accessibility granted ✓")
        } else {
            slog("Accessibility not yet granted — approve SpeakerBar in System Settings > Privacy & Security > Accessibility")
        }
    }

    private func registerDisconnectNotification() {
        // Unregister the previous token first — registering twice made the handler
        // fire twice per drop, doubling the reconnect load.
        disconnectNotification?.unregister()
        disconnectNotification = targetDevice?.register(forDisconnectNotification: self,
                                                        selector: #selector(deviceDisconnected(_:device:)))
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard routeIsSpeaker, device.addressString == targetAddress else { return }
        keepAlive.stop()
        // IOBluetooth's disconnect notification is one-shot — re-arm for the next drop.
        registerDisconnectNotification()
        slog("\(device.name ?? "speaker") disconnected")
        scheduleReconnect() // single, backoff-aware retry
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Bluetooth Speakers", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let audioDevices = paired.filter { $0.deviceClassMajor == kBluetoothDeviceClassMajorAudio }
        if audioDevices.isEmpty {
            let item = NSMenuItem(title: "No paired audio devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for device in audioDevices.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let name = (device.name ?? device.addressString ?? "?").trimmingCharacters(in: .whitespaces)
            let isTarget = device.addressString == targetAddress
            let title = device.isConnected() ? "\(name)  ●" : name
            let item = NSMenuItem(title: title, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [device.addressString ?? "", device.name ?? name]
            item.state = (isTarget && routeIsSpeaker) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let macItem = NSMenuItem(title: "Mac Speakers", action: #selector(selectBuiltIn), keyEquivalent: "")
        macItem.target = self
        macItem.state = routeIsSpeaker ? .off : .on
        menu.addItem(macItem)

        menu.addItem(.separator())
        let hotkeyInfo = NSMenuItem(title: "⌥⌘B — toggle speaker / Mac", action: nil, keyEquivalent: "")
        hotkeyInfo.isEnabled = false
        menu.addItem(hotkeyInfo)

        let eq = NSMenuItem(title: eqEnabled ? "Equalizer… (On — \(eqPresetName))" : "Equalizer…",
                            action: #selector(openEQWindow), keyEquivalent: "e")
        eq.target = self
        eq.state = eqEnabled ? .on : .off
        menu.addItem(eq)

        let awake = NSMenuItem(title: "Keep Speaker Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        awake.target = self
        awake.state = keepAwakeEnabled ? .on : .off
        menu.addItem(awake)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let reconnect = NSMenuItem(title: "Reconnect Now", action: #selector(reconnectNow), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SpeakerBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 2, !info[0].isEmpty else { return }
        targetAddress = info[0]
        targetName = info[1]
        failureStreak = 0
        registerDisconnectNotification()
        activateSpeaker(userInitiated: true)
    }

    @objc private func selectBuiltIn() { switchToBuiltIn() }

    @objc private func toggleKeepAwake() {
        keepAwakeEnabled.toggle()
        if !keepAwakeEnabled {
            keepAlive.stop()
        } else {
            startKeepAliveIfNeeded()
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            slog("login item toggle failed: \(error)")
        }
    }

    @objc private func reconnectNow() {
        if targetAddress != nil { activateSpeaker(userInitiated: true) }
    }

    // MARK: EQ window + actions

    @objc private func openEQWindow() {
        if eqWindow == nil {
            let wc = EQWindowController()
            wc.onEnableToggle = { [weak self] on in
                guard let self else { return }
                self.eqEnabled = on
                self.applyEQ()
                self.refreshEQWindow()
                slog("EQ \(on ? "enabled" : "disabled") by user")
            }
            wc.onChange = { [weak self] in
                guard let self, let w = self.eqWindow else { return }
                self.eqGains = w.currentGains
                self.eqPreamp = w.currentPreamp
                self.eqPresetName = "Custom"
                self.applyEQ()
            }
            wc.onPresetPicked = { [weak self] name in
                guard let self else { return }
                var gains: [Double]?
                if let factory = eqFactoryPresets.first(where: { $0.name == name }) {
                    gains = factory.gains
                } else if let custom = self.eqCustomPresets[name] {
                    gains = custom
                }
                guard let gains else { return }
                self.eqGains = gains
                // Headroom: pull preamp down by the largest boost so hot mixes don't clip.
                self.eqPreamp = -(gains.max() ?? 0) / 2
                self.eqPresetName = name
                self.applyEQ()
                self.refreshEQWindow()
            }
            wc.onSaveCustom = { [weak self] name in
                guard let self else { return }
                var customs = self.eqCustomPresets
                customs[name] = self.eqGains
                self.eqCustomPresets = customs
                self.eqPresetName = name
                self.refreshEQWindow()
            }
            wc.onDeleteCustom = { [weak self] name in
                guard let self else { return }
                var customs = self.eqCustomPresets
                customs.removeValue(forKey: name)
                self.eqCustomPresets = customs
                if self.eqPresetName == name { self.eqPresetName = "Custom" }
                self.refreshEQWindow()
            }
            eqWindow = wc
        }
        refreshEQWindow()
        NSApp.activate(ignoringOtherApps: true)
        eqWindow?.showWindow(nil)
        eqWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func refreshEQWindow() {
        eqWindow?.refresh(enabled: eqEnabled, gains: eqGains, preamp: eqPreamp,
                          presetName: eqPresetName, customNames: Array(eqCustomPresets.keys))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave no tap behind: a dangling tap would keep other apps muted.
        cancelReconnect()
        eqTap.stop()
        keepAlive.stop()
    }

    private func registerLoginItemOnce() {
        guard !defaults.bool(forKey: "didRegisterLoginItem") else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: "didRegisterLoginItem")
            slog("registered as login item")
        } catch {
            slog("login item registration failed: \(error)")
        }
    }

    private func updateIcon() {
        let symbol = routeIsSpeaker ? "hifispeaker.fill" : "hifispeaker"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SpeakerBar")
        image?.isTemplate = true
        statusItem.button?.image = image
        // Dimmed icon = connect in progress; steady = settled.
        statusItem.button?.appearsDisabled = connecting
        statusItem.button?.title = ""
    }

    // Brief "!" next to the icon when a speaker switch failed.
    private func flashFailure() {
        updateIcon()
        statusItem.button?.title = " !"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusItem.button?.title = ""
        }
    }

    // MARK: Global hotkey (default ⌥⌘B; override with `defaults write com.prakrin.speakerbar hotKeyCode/hotKeyMods`)

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { AppDelegate.shared?.toggleRoute() }
            return noErr
        }, 1, &eventType, nil, nil)

        let code = defaults.object(forKey: "hotKeyCode") == nil
            ? UInt32(kVK_ANSI_B) : UInt32(defaults.integer(forKey: "hotKeyCode"))
        let mods = defaults.object(forKey: "hotKeyMods") == nil
            ? UInt32(cmdKey | optionKey) : UInt32(defaults.integer(forKey: "hotKeyMods"))
        let hotKeyID = EventHotKeyID(signature: OSType(0x53504B52) /* 'SPKR' */, id: 1)
        let status = RegisterEventHotKey(code, mods, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        slog("hotkey registration status \(status)")
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
