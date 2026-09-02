import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(named: "AppIcon") ?? Bundle.main.path(forResource: "AppIcon", ofType: "icns").flatMap(NSImage.init(contentsOfFile:)) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 64))
            }

            VStack(spacing: 4) {
                Text("SpyProtect")
                    .font(.title).bold()
                Text("Version \(version) (\(build))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Watches for activity while your screen is locked - failed unlock attempts (with a snapshot), USB devices connecting or disconnecting, HID/keyboard-class devices, and apps launching - so you know if anyone tried to get in while you were away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            Text("Built with Swift and AppKit/SwiftUI.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/wu3ty/spyprotect/blob/main/LICENSE")!)
            } label: {
                Text("Licensed under the MIT License")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(32)
        .frame(width: 420, height: 420)
    }
}
