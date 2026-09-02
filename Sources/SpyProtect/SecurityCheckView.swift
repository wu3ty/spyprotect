import SwiftUI
import AppKit

final class SecurityCheckModel: ObservableObject {
    @Published var checks: [SecurityCheck] = []
    @Published var isRunning = false

    func run() {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let results = SecurityChecker.runChecks()
            DispatchQueue.main.async {
                self.checks = results
                self.isRunning = false
            }
        }
    }
}

struct SecurityCheckView: View {
    @ObservedObject var model: SecurityCheckModel

    private var secureCount: Int { model.checks.filter { $0.status == .secure }.count }
    private var warningCount: Int { model.checks.filter { $0.status == .warning }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isRunning {
                VStack {
                    Spacer()
                    ProgressView("Checking...")
                        .padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.checks) { check in
                            SecurityCheckRow(check: check)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
        .onAppear { if model.checks.isEmpty { model.run() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Security Check")
                    .font(.title2).bold()
                if !model.isRunning {
                    Text(warningCount == 0
                         ? "All automatically-checkable items look good."
                         : "\(warningCount) item(s) need attention.")
                        .font(.subheadline)
                        .foregroundStyle(warningCount == 0 ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            Button {
                model.run()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-run checks")
            .disabled(model.isRunning)
        }
        .padding(16)
    }
}

struct SecurityCheckRow: View {
    let check: SecurityCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .font(.title2)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.body).bold()
                Text(check.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if check.status != .secure {
                    Button {
                        if let url = check.settingsURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(check.hint, systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                    .disabled(check.settingsURL == nil)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch check.status {
        case .secure:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .manual:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}
