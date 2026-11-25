import AVFoundation

// The headset's microphone held open, so the dongle plays sidetone, which it only does while an app uses the microphone
// (app/HeadsetProtocol.cs, MicrophoneCapture). The sound is dropped: only the capture matters. Needs the microphone permission.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "microphone")

    // The microphone whose name holds the headset's, from its first 16 characters, as on Windows.
    static func find(_ name: String) -> AVCaptureDevice? {
        if name.isEmpty { return nil }
        let part = String(name.prefix(16)).lowercased()
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
            .first { $0.localizedName.lowercased().contains(part) }
    }

    init(_ device: AVCaptureDevice) throws {
        super.init()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw GLiteError.io("Couldn't open the headset's microphone (\(error.localizedDescription))")
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw GLiteError.io("Couldn't open the headset's microphone") }
        session.addInput(input)
        session.addOutput(output)
        queue.async { self.session.startRunning() }
    }

    func stop() { queue.async { self.session.stopRunning() } }
}
