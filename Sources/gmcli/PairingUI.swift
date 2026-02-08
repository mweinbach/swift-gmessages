#if os(macOS)

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class PairingUIModel: ObservableObject {
    @Published var qrURL: String
    @Published var statusText: String

    init(qrURL: String, statusText: String) {
        self.qrURL = qrURL
        self.statusText = statusText
    }

    func copyURLToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(qrURL, forType: .string)
    }

    func openURLInBrowser() {
        guard let url = URL(string: qrURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
struct PairingQRCodeView: View {
    @ObservedObject var model: PairingUIModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Google Messages Pairing")
                .font(.title2.weight(.semibold))

            Text("Scan this QR code with the Google Messages app on your phone.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Group {
                if let image = makeQRCodeImage(from: model.qrURL) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 360)
                        .padding(12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.black.opacity(0.1), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 360, height: 360)
                        .overlay(Text("Failed to generate QR code").foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.headline)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("Pairing URL")
                    .font(.headline)
                Text(model.qrURL)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button("Copy URL") { model.copyURLToClipboard() }
                    Button("Open in Browser") { model.openURLInBrowser() }
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 720)
    }

    private func makeQRCodeImage(from string: String) -> NSImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.correctionLevel = "M"
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }

        // Scale up sharply so it stays crisp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}

@MainActor
final class PairingUIWindowController {
    let model: PairingUIModel
    private let window: NSWindow

    init(qrURL: String) {
        self.model = PairingUIModel(qrURL: qrURL, statusText: "Waiting for pairing...")

        let view = PairingQRCodeView(model: model)
        let hosting = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.title = "Google Messages Pairing"
        w.center()
        w.contentView = hosting
        self.window = w
    }

    func showAndActivate() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }
}

#endif

