import AVFoundation
import Foundation

/// Takes a single still photo on demand (not a continuous feed - the session is started
/// fresh per capture and torn down right after, so the camera indicator light isn't on
/// any longer than necessary and there's no persistent camera access to reason about).
final class CameraCapture: NSObject {
    static let shared = CameraCapture()

    private let photosDir: URL
    private let sessionQueue = DispatchQueue(label: "spyprotect.camera")

    private override init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpyProtect/Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photosDir = dir
        super.init()
    }

    /// Deletes every captured snapshot. Called alongside EventStore.clearAll() so
    /// "Clear All Logs" doesn't leave orphaned photos on disk with nothing left
    /// referencing them.
    func clearAllPhotos() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Completion runs on the main queue with an absolute file path, or nil if no camera
    /// is available, access was denied, or capture otherwise failed.
    func capture(completion: @escaping (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.runCapture(completion: completion) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.runCapture(completion: completion) }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async { completion(nil) }
        @unknown default:
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// Runs on `sessionQueue`. Front-facing built-in camera if there is one (laptops),
    /// falling back to whatever default video device exists (external webcam on a
    /// desktop Mac).
    private func runCapture(completion: @escaping (String?) -> Void) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        session.addOutput(output)

        session.startRunning()

        // Give the sensor a moment to adjust exposure before capturing, otherwise the
        // very first frame off a cold start is often washed out or completely black.
        sessionQueue.asyncAfter(deadline: .now() + 1.5) {
            let delegate = PhotoCaptureDelegate(photosDir: self.photosDir) { path in
                session.stopRunning()
                DispatchQueue.main.async { completion(path) }
            }
            self.activeDelegate = delegate
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    // Retained for the duration of one capture - AVCapturePhotoCaptureDelegate is only
    // weakly referenced by AVFoundation.
    private var activeDelegate: PhotoCaptureDelegate?
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let photosDir: URL
    private let onComplete: (String?) -> Void

    init(photosDir: URL, onComplete: @escaping (String?) -> Void) {
        self.photosDir = photosDir
        self.onComplete = onComplete
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            NSLog("SpyProtect: photo capture failed: \(error?.localizedDescription ?? "no data")")
            onComplete(nil)
            return
        }
        let url = photosDir.appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            onComplete(url.path)
        } catch {
            NSLog("SpyProtect: failed to save photo: \(error)")
            onComplete(nil)
        }
    }
}
