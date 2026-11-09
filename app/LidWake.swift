// LidWake menu bar app — a thin UI over the `lidwake` CLI, which does the real work.
import AppKit
import CoreImage
import SwiftUI

private let cliPath = "/usr/local/bin/lidwake"

@main
struct LidWakeApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(session)
        } label: {
            Image(systemName: session.status?.active == true ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Status: Decodable {
    struct Event: Decodable, Identifiable {
        let id: Int
        let type: String
        let arg: String
        let label: String
        var isTimer: Bool { type == "deadline" || type == "limit" }
    }
    struct Last: Decodable {
        let at: Int
        let reason: String
    }
    let active: Bool
    let started: Int?
    let then: String
    let battery: Int?
    let ac: Bool
    let conditions: [Event]
    let last: Last?
}

@MainActor
final class Session: ObservableObject {
    @Published var status: Status?
    @Published var error: String?
    @Published var remoteURL = ""
    private var timer: Timer?

    init() {
        refresh()
        loadRemoteURL()
        // The tunnel's public address shows up a few seconds after lidwaked starts
        // (and changes if cloudflared restarts), so re-read it along with the status.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.loadRemoteURL()
            }
        }
    }

    func refresh() {
        Task.detached {
            let (code, out) = Session.runCLI(["status", "--json"])
            let decoded = try? JSONDecoder().decode(Status.self, from: Data(out.utf8))
            await MainActor.run {
                if code == 0, let decoded {
                    self.status = decoded
                } else {
                    self.error = "lidwake CLI not found — run install.sh"
                }
            }
        }
    }

    func loadRemoteURL() {
        Task.detached {
            let (code, out) = Session.runCLI(["remote", "--url"])
            await MainActor.run {
                if code == 0 { self.remoteURL = out.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    /// Runs a CLI command, shows its error if it fails, then refreshes.
    func run(_ args: [String]) {
        error = nil
        Task.detached {
            let (code, out) = Session.runCLI(args)
            await MainActor.run {
                if code != 0 {
                    self.error = out.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "lidwake: ", with: "")
                }
                self.refresh()
            }
        }
    }

    nonisolated static func runCLI(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct PanelView: View {
    @EnvironmentObject var session: Session
    @AppStorage("untilClaude") private var untilClaude = true
    @AppStorage("process") private var process = ""
    @AppStorage("useDuration") private var useDuration = false
    @AppStorage("minutes") private var minutes = 60
    @AppStorage("unplug") private var unplug = false
    @AppStorage("battery") private var battery = 10.0
    @AppStorage("then") private var then = "sleep"
    @State private var showRemote = false

    private var active: Bool { session.status?.active == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LidWake").font(.headline)
                Spacer()
                Circle().fill(active ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(active ? "Awake" : "Idle").foregroundStyle(.secondary)
            }
            if let battery = session.status?.battery {
                Text("Battery \(battery)%\(session.status?.ac == true ? " · charging" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let status = session.status, status.active {
                activeView(status)
            } else {
                startView
            }

            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            DisclosureGroup("Remote control", isExpanded: $showRemote) { remoteView }
            Button("Quit menu bar app") { NSApp.terminate(nil) }
                .help("A running session keeps going; stop it from here, the CLI or the web page")
        }
        .padding()
        .frame(width: 300)
    }

    @ViewBuilder
    private func activeView(_ status: Status) -> some View {
        Text("Ends at the first of:").foregroundStyle(.secondary)
        ForEach(status.conditions) { event in
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.label)
                    if event.isTimer, let t = TimeInterval(event.arg) {
                        Text(Date(timeIntervalSince1970: t), style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if event.isTimer {
                    Button("+30m") { session.run(["extend", "\(event.id)", "30m"]) }.controlSize(.small)
                }
                Button { session.run(["remove", "\(event.id)"]) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
            }
        }
        Menu("Add event") {
            Button("Claude finishes a reply") { session.run(["add", "--claude"]) }
            Button("Timer: 30 minutes") { session.run(["add", "--for", "30m"]) }
            Button("Timer: 1 hour") { session.run(["add", "--for", "1h"]) }
            Button("Timer: 2 hours") { session.run(["add", "--for", "2h"]) }
            Button("Charger is unplugged") { session.run(["add", "--unplug"]) }
            Button("Battery drops to 20%") { session.run(["add", "--battery", "20"]) }
        }
        Picker("Then", selection: Binding(get: { status.then }, set: { session.run(["set", "then", $0]) })) {
            Text("Sleep").tag("sleep")
            Text("Shut down").tag("shutdown")
            Text("Nothing").tag("none")
        }
        HStack {
            Button("Stop & allow sleep") { session.run(["stop"]) }
            if status.then != "none" {
                Button("End now") { session.run(["end"]) }
            }
        }
    }

    @ViewBuilder
    private var startView: some View {
        Text("Stay awake with the lid closed until…").foregroundStyle(.secondary)
        Toggle("Claude finishes its reply", isOn: $untilClaude)
        TextField("Process exits (name, optional)", text: $process)
        Toggle("Time passes", isOn: $useDuration)
        if useDuration {
            Stepper("\(minutes) min", value: $minutes, in: 5...1440, step: 5)
        }
        Toggle("Charger is unplugged", isOn: $unplug)
        VStack(alignment: .leading, spacing: 2) {
            Text(battery == 0 ? "Battery limit: off" : "Battery drops to \(Int(battery))%")
            Slider(value: $battery, in: 0...50, step: 5)
        }
        Picker("Then", selection: $then) {
            Text("Sleep").tag("sleep")
            Text("Shut down").tag("shutdown")
            Text("Nothing").tag("none")
        }
        Button("Start") { session.run(["start", "--background"] + startArgs) }
            .keyboardShortcut(.defaultAction)
        if let last = session.status?.last {
            Text("Last: \(last.reason), \(Date(timeIntervalSince1970: TimeInterval(last.at)), style: .relative) ago")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var remoteView: some View {
        if session.remoteURL.isEmpty {
            Text("Remote server not set up — re-run install.sh").font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.remoteURL.hasPrefix("https://")
                     ? "Open on any device, from anywhere:"
                     : "Open on any device on this network (enable internet access with: lidwake remote --public cloudflare):")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let qr = qrImage(session.remoteURL) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160)
                }
                HStack {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.remoteURL, forType: .string)
                    }
                    Button("Open") { NSWorkspace.shared.open(URL(string: session.remoteURL)!) }
                }
                Text("The link contains your access token. Reset it with: lidwake remote --new-token")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    private var startArgs: [String] {
        var a: [String] = []
        if untilClaude { a.append("--claude") }
        let name = process.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { a += ["--process", name] }
        if useDuration { a += ["--for", "\(minutes)m"] }
        if unplug { a.append("--unplug") }
        a += ["--battery", "\(Int(battery))", "--then", then]
        return a
    }

    private func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
