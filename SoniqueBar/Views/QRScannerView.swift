import SwiftUI
import AVFoundation
import Vision
import AppKit

struct QRScannerView: NSViewRepresentable {
    let onScan: (String) -> Void

    class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let parent: QRScannerView
        var session: AVCaptureSession?
        var didScan = false

        init(_ parent: QRScannerView) { self.parent = parent }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !didScan,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let request = VNDetectBarcodesRequest { [weak self] req, _ in
                guard let self,
                      !self.didScan,
                      let result = req.results?.first as? VNBarcodeObservation,
                      result.symbology == .qr,
                      let payload = result.payloadStringValue else { return }
                self.didScan = true
                self.session?.stopRunning()
                DispatchQueue.main.async { self.parent.onScan(payload) }
            }

            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                .perform([request])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return view }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(context.coordinator,
                                       queue: DispatchQueue(label: "qr.scan"))
        guard session.canAddOutput(output) else { return view }
        session.addOutput(output)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer?.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }
            .forEach { $0.frame = nsView.bounds }
    }
}
