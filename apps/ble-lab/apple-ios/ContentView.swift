// ContentView.swift: Minimal UI for HopBleLab iOS.
// The log file is the primary artifact; UI shows last 40 lines and link status.

import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @State private var logLines: [String] = []
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.blue)
                Text("BLE Lab: Running")
                    .font(.headline)
                Spacer()
                Text("auth=\(CBCentralManager.authorization.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logLines.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(lineColor(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider()
            Text("Documents/blelab.log")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(6)
        }
        .onAppear { refreshLog() }
        .onReceive(refreshTimer) { _ in refreshLog() }
    }

    private func refreshLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = docs.appendingPathComponent("blelab.log")
        if let content = try? String(contentsOf: logURL, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count != logLines.count { logLines = lines }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("LINK UP") || line.contains("PROOF") { return .green }
        if line.contains("CLOSED") || line.contains("FAILED") || line.contains("WARN") { return .red }
        if line.contains("STATUS") { return .yellow }
        return .primary
    }
}
