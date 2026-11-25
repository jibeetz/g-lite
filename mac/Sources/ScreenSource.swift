import Foundation
import CoreMedia
import ScreenCaptureKit

// The screen and the sound the Screen and Audio effects follow (app/Screen.cs, ScreenCapture, and app/LiveEffects.cs, AudioLoopback):
// one ScreenCaptureKit stream of the main display, shrunk to 160 × 90 at 10 frames a second, which also carries the Mac's sound on
// macOS 13 and up. It runs while an effect uses it. Both need the Screen Recording permission.
// One per monitor ("" the main one, else a display id), shared by the effects that follow it.
final class ScreenSource: NSObject {
    static let width = 160, height = 90, audioSize = 1024
    private static var sources: [String: ScreenSource] = [:]
    // The main display's, which also carries the sound for Audio.
    static var shared: ScreenSource { source("") }

    static func source(_ monitor: String) -> ScreenSource {
        if let source = sources[monitor] { return source }
        let source = ScreenSource(monitor: monitor)
        sources[monitor] = source
        return source
    }

    // The displays to pick from: "" the main one, then the others by id, each with its label.
    static func monitors() -> [(id: String, label: String)] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.enumerated().map { index, id in
            (id == main ? "" : "\(id)", (id == main ? "Main" : "Monitor \(index + 1)") + ", \(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))")
        }.sorted { $0.id.isEmpty && !$1.id.isEmpty }
    }

    let monitor: String
    init(monitor: String) { self.monitor = monitor }

    private let gate = NSLock()
    private let queue = DispatchQueue(label: "screen")
    private var users = Set<ObjectIdentifier>()
    private var stream: AnyObject?
    private var starting = false
    private var pixels: [UInt8] = []
    private var ring = [Float](repeating: 0, count: 4096)
    private var ringAt = 0, sampleRate = 48000.0
    private var lastAudio = Date.distantPast
    private(set) var failure: String?
    // Whether any sound came since the capture started, for --screen.
    var heardAudio: Bool { gate.lock(); defer { gate.unlock() }; return lastAudio != .distantPast }

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    // Asks once; macOS shows its own prompt, and the permission counts after G-Lite is opened again.
    static func ask() { _ = CGRequestScreenCaptureAccess() }

    static let permissionProblem = "Allow G-Lite in Privacy & Security, Screen Recording, then open G-Lite again."

    func use(_ user: AnyObject) {
        gate.lock()
        users.insert(ObjectIdentifier(user))
        let start = stream == nil && !starting
        if start { starting = true }
        gate.unlock()
        if start { begin() }
    }

    func release(_ user: AnyObject) {
        gate.lock()
        users.remove(ObjectIdentifier(user))
        let stop = users.isEmpty ? stream : nil
        if users.isEmpty { stream = nil; pixels = [] }
        gate.unlock()
        if #available(macOS 12.3, *), let stop = stop as? SCStream { stop.stopCapture { _ in } }
    }

    private func begin() {
        guard #available(macOS 12.3, *) else { finish(nil, "The Screen effect needs macOS 12.3 or later."); return }
        if !ScreenSource.allowed { ScreenSource.ask(); finish(nil, ScreenSource.permissionProblem); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            let wanted = UInt32(self.monitor) ?? CGMainDisplayID()
            guard let display = content?.displays.first(where: { $0.displayID == wanted })
                    ?? content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content?.displays.first else {
                self.finish(nil, error.map { "Couldn't see the screen: \($0.localizedDescription)" } ?? ScreenSource.permissionProblem)
                return
            }
            let config = SCStreamConfiguration()
            config.width = ScreenSource.width
            config.height = ScreenSource.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3
            if #available(macOS 13, *), self.monitor.isEmpty {
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
            }
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                if #available(macOS 13, *), self.monitor.isEmpty { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue) }
            } catch {
                self.finish(nil, "Couldn't capture the screen: \(error.localizedDescription)")
                return
            }
            stream.startCapture { error in
                self.finish(error == nil ? stream : nil, error.map { "Couldn't capture the screen: \($0.localizedDescription)" })
            }
        }
    }

    private func finish(_ started: AnyObject?, _ problem: String?) {
        gate.lock()
        starting = false
        failure = problem
        if users.isEmpty { gate.unlock(); if #available(macOS 12.3, *), let stream = started as? SCStream { stream.stopCapture { _ in } }; return }
        stream = started
        gate.unlock()
    }

    // The last frame, for the Screen box's preview.
    func image() -> CGImage? {
        gate.lock(); let frame = pixels; gate.unlock()
        guard frame.count == ScreenSource.width * ScreenSource.height * 4, let provider = CGDataProvider(data: Data(frame) as CFData) else { return nil }
        return CGImage(width: ScreenSource.width, height: ScreenSource.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: ScreenSource.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // Each area's average colour, areas as fractions of the screen; nil before the first frame.
    func sample(_ areas: [CGRect]) -> [Int]? {
        gate.lock(); let frame = pixels; gate.unlock()
        let width = ScreenSource.width, height = ScreenSource.height
        guard frame.count == width * height * 4 else { return nil }
        return areas.map { area in
            let left = max(0, min(width - 1, Int(area.minX * CGFloat(width)))), top = max(0, min(height - 1, Int(area.minY * CGFloat(height))))
            let right = max(left + 1, min(width, Int(area.maxX * CGFloat(width)))), bottom = max(top + 1, min(height, Int(area.maxY * CGFloat(height))))
            var red = 0, green = 0, blue = 0
            for y in top..<bottom {
                for x in left..<right {
                    let at = (y * width + x) * 4
                    blue += Int(frame[at]); green += Int(frame[at + 1]); red += Int(frame[at + 2])
                }
            }
            let count = max(1, (right - left) * (bottom - top))
            return (red / count) << 16 | (green / count) << 8 | blue / count
        }
    }

    // Levels from 0 to 1, log spaced from 40 Hz to 16 kHz, over the last 1024 samples (app/LiveEffects.cs, AudioLoopback.Bands); nil
    // when no sound comes (macOS 12, or no permission).
    func bands(_ count: Int) -> [Double]? {
        gate.lock()
        let running = stream != nil, rate = sampleRate
        // No sound playing sends no samples, which would leave the last sound in the ring.
        if Date().timeIntervalSince(lastAudio) > 0.15 { for i in ring.indices { ring[i] = 0 } }
        let size = ScreenSource.audioSize
        var real = [Double](repeating: 0, count: size)
        for i in 0..<size {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(size - 1))
            real[i] = Double(ring[(ringAt - size + i + ring.count) % ring.count]) * window
        }
        gate.unlock()
        guard running else { return nil }
        var imaginary = [Double](repeating: 0, count: size)
        ScreenSource.fourier(&real, &imaginary)
        let low = 40.0, high = min(16000, rate / 2)
        return (0..<count).map { band in
            let from = low * pow(high / low, Double(band) / Double(count)), to = low * pow(high / low, Double(band + 1) / Double(count))
            let first = max(1, Int(from * Double(size) / rate)), last = max(first, Int(to * Double(size) / rate))
            var peak = 0.0
            var bin = first
            while bin <= last && bin < size / 2 { peak = max(peak, hypot(real[bin], imaginary[bin])); bin += 1 }
            // A full-scale sine through the Hann window peaks at a quarter of the size.
            let decibels = 20 * log10(peak / (Double(size) / 4) + 1e-9)
            return max(0, min(1, (decibels + 60) / 54))
        }
    }

    // In-place radix-2 FFT.
    static func fourier(_ real: inout [Double], _ imaginary: inout [Double]) {
        let length = real.count
        var j = 0
        for i in 1..<length {
            var bit = length >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { real.swapAt(i, j); imaginary.swapAt(i, j) }
        }
        var span = 2
        while span <= length {
            let angle = -2 * Double.pi / Double(span), stepReal = cos(angle), stepImaginary = sin(angle)
            for start in stride(from: 0, to: length, by: span) {
                var turnReal = 1.0, turnImaginary = 0.0
                for offset in 0..<span / 2 {
                    let top = start + offset, bottom = top + span / 2
                    let productReal = real[bottom] * turnReal - imaginary[bottom] * turnImaginary
                    let productImaginary = real[bottom] * turnImaginary + imaginary[bottom] * turnReal
                    real[bottom] = real[top] - productReal
                    imaginary[bottom] = imaginary[top] - productImaginary
                    real[top] += productReal
                    imaginary[top] += productImaginary
                    let nextReal = turnReal * stepReal - turnImaginary * stepImaginary
                    turnImaginary = turnReal * stepImaginary + turnImaginary * stepReal
                    turnReal = nextReal
                }
            }
            span <<= 1
        }
    }
}

@available(macOS 12.3, *)
extension ScreenSource: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { screenFrame(sampleBuffer) } else { audioFrame(sampleBuffer) }
    }

    private func screenFrame(_ sampleBuffer: CMSampleBuffer) {
        // Idle frames (nothing changed on screen) carry no image.
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let width = min(ScreenSource.width, CVPixelBufferGetWidth(image)), height = min(ScreenSource.height, CVPixelBufferGetHeight(image))
        let stride = CVPixelBufferGetBytesPerRow(image)
        var copy = [UInt8](repeating: 0, count: ScreenSource.width * ScreenSource.height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width * 4 { copy[(y * ScreenSource.width) * 4 + x] = row[x] }
        }
        gate.lock(); pixels = copy; gate.unlock()
    }

    // Float samples, one buffer per channel (ScreenCaptureKit's format), averaged into the ring.
    private func audioFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                flags: 0, blockBufferOut: nil)
        let list = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        let audioList = list.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: audioList,
                                                                      bufferListSize: needed, blockBufferAllocator: nil,
                                                                      blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(audioList)
        let interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = max(1, Int(description.mChannelsPerFrame))
        guard let first = buffers.first, let firstData = first.mData else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / (interleaved ? channels : 1)
        gate.lock()
        sampleRate = description.mSampleRate
        lastAudio = Date()
        for frame in 0..<frames {
            var sum: Float = 0
            if interleaved {
                let samples = firstData.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
            } else {
                for buffer in buffers { if let data = buffer.mData { sum += data.assumingMemoryBound(to: Float.self)[frame] } }
            }
            ring[ringAt] = sum / Float(interleaved ? channels : buffers.count)
            ringAt = (ringAt + 1) % ring.count
        }
        gate.unlock()
    }
}

// The Screen effect on the devices lit by areas (the G560's four corners, the Litra's seven back zones): each area's colour every
// 100 ms, boosted and smoothed as on Windows (app/Screen.cs; ZonesPage and LightPage, Sampled), handed to send when one moved.
final class ScreenFollower {
    // The G560's areas, bottom left, bottom right, top left, top right (app/ZoneLighting.cs, ScreenZones), and the Litra's seven
    // columns (app/LitraProtocol.cs, ScreenZones).
    static let corners = [CGRect(x: 0.05, y: 0.55, width: 0.4, height: 0.35), CGRect(x: 0.55, y: 0.55, width: 0.4, height: 0.35),
                          CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.35), CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.35)]
    static let columns = (0..<7).map { CGRect(x: (Double($0) / 7 + 0.01), y: 0.1, width: 1.0 / 7 - 0.02, height: 0.8) }

    private let send: ([Int]) -> Void
    private var timer: Timer?
    private var source: ScreenSource?
    private var shown: [Int] = [], sent: [Int] = []
    private var nextRefresh = Date.distantPast
    // Areas, monitor, boost, update rate, smoothing, brightness and pause, from the Screen box.
    var setup: ScreenSettings { didSet { if running && (setup.monitor != oldValue.monitor || setup.interval != oldValue.interval) { stop(); start() } } }
    var problem: String? { shown.isEmpty ? source?.failure : nil }

    init(setup: ScreenSettings, send: @escaping ([Int]) -> Void) {
        self.setup = setup
        self.send = send
        Presence.watch()
    }

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let source = ScreenSource.source(setup.monitor)
        source.use(self)
        self.source = source
        timer = Timer.scheduledTimer(withTimeInterval: Double(setup.interval) / 1000, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.release(self)
        source = nil
        shown = []; sent = []
    }

    private func tick() {
        // Paused while the screen is off or locked: nothing is sent, so the lights keep the last colours.
        if setup.pauseWhenLocked && Presence.away { return }
        guard let sampled = source?.sample(setup.zones.map { $0.area }) else { return }
        let fresh = shown.count != sampled.count
        if fresh { shown = [Int](repeating: 0, count: sampled.count) }
        for i in sampled.indices {
            let target = LiveEffects.scale(LiveEffects.boost(sampled[i], setup.boost), Double(setup.bright) / 100)
            shown[i] = fresh || !setup.smooth ? target : LiveEffects.blend(shown[i], target, 0.45)
        }
        // Sent when a colour moved, and every 2 s anyway, as on Windows.
        let refresh = Date() >= nextRefresh
        if !refresh && sent.count == shown.count && !zip(sent, shown).contains(where: { LiveEffects.distance($0, $1) > 6 }) { return }
        if refresh { nextRefresh = Date().addingTimeInterval(2) }
        sent = shown
        send(shown)
    }
}
