import FamilyControls
import ManagedSettings
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var auth = AuthorizationCenter.shared
    @State private var code = ""
    @State private var deviceName = Eyes.defaults.string(forKey: "device_name") ?? ""
    @State private var message = ""
    @State private var busy = false
    @State private var picking: String?           // the category being picked
    @State private var selection = FamilyActivitySelection()
    @State private var refresh = 0
    @State private var naming = false             // the name-your-categories sheet

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                screenTimeSection
                categorySection
                motionSection
                statusSection
            }
            .navigationTitle("iEyesApp")
            .onReceive(NotificationCenter.default.publisher(for: .eyesStateChanged)) { _ in refresh += 1 }
            .sheet(item: Binding(get: { picking.map { Picking(name: $0) } }, set: { picking = $0?.name })) { p in
                pickerSheet(p.name)
            }
            .sheet(isPresented: $naming, onDismiss: { Categories.logNames("naming"); refresh += 1 }) { namingSheet }
        }
    }

    // MARK: sections

    private var serverSection: some View {
        Section("Group") {
            if Server.enrolled {
                LabeledContent("Group", value: Eyes.defaults.string(forKey: "group") ?? "")
                LabeledContent("This device", value: Eyes.defaults.string(forKey: "label") ?? "")
            } else {
                TextField("Device name, e.g. iPhone16PM", text: $deviceName)
                    .onChange(of: deviceName) { _, v in Eyes.defaults.set(v, forKey: "device_name") }
                TextField("Code from eyes.geosketch.art", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button(busy ? "Joining…" : "Join") {
                    busy = true
                    let c = code, n = deviceName
                    Task.detached {
                        let err = Server.enroll(code: c, deviceName: n)
                        if err == nil { _ = Server.upload() }
                        await MainActor.run {
                            message = err ?? "Joined."
                            busy = false
                            refresh += 1
                        }
                    }
                }
                .disabled(busy || code.replacingOccurrences(of: "-", with: "").count != 8)
            }
        }
    }

    private var screenTimeSection: some View {
        Section {
            switch auth.authorizationStatus {
            case .approved:
                Label("Screen Time access allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            default:
                Button("Allow Screen Time access") {
                    Task {
                        do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual) }
                        catch { message = "Screen Time: \(error.localizedDescription)" }
                    }
                }
            }
        } header: { Text("Screen Time") } footer: {
            Text("iEyesApp records only how many minutes each app category is used today, in 1-minute steps. It never sees app names, content or what you type.")
        }
    }

    private var categorySection: some View {
        Section {
            let _ = refresh
            Button(Categories.picked.isEmpty ? "Select all categories" : "Change categories (\(Categories.picked.count) selected)") {
                selection = FamilyActivitySelection()
                picking = "all"
            }
            if !Categories.picked.isEmpty {
                let left = Categories.unnamed
                Button {
                    naming = true
                } label: {
                    if left > 0 {
                        Label("Name the categories (\(left) of \(Categories.picked.count) left)", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Label("All \(Categories.picked.count) categories named", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Text("All categories (total)").bold()
                    Spacer()
                    Text("\(Categories.reached(Categories.total)) min today").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Categories.picked, id: \.id) { item in
                    HStack {
                        Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        Label(item.token).labelStyle(.titleOnly)
                        Spacer()
                        Text("\(Categories.reached(item.id)) min").font(.caption).foregroundStyle(.secondary)
                        Menu(Categories.name(item.id) ?? "Name it") {
                            ForEach(Eyes.categories, id: \.self) { n in
                                Button(n) { Categories.setName(n, for: item.id); Categories.logNames("menu"); refresh += 1 }
                            }
                            Button("No name", role: .destructive) { Categories.setName(nil, for: item.id); refresh += 1 }
                        }
                        .font(.caption)
                    }
                }
            }
            if Monitor.isActive {
                Label("Monitoring in progress · \(Categories.picked.count) categories + total",
                      systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Button("Stop monitoring", role: .destructive) {
                    Monitor.stopAll()
                    Log.append([Log.row("monitor_stop")])
                    message = "Monitoring stopped."
                    refresh += 1
                }
                .font(.caption)
            } else {
                Button("Start monitoring") {
                    let errors = Monitor.armAll()
                    Motion.keepRecording()
                    Log.append([Log.row("monitor_start", detail: [("categories", Categories.picked.count),
                                                                 ("ladders", Categories.ladders.count),
                                                                 ("errors", errors.count)])])
                    message = errors.isEmpty ? "" : errors.joined(separator: "\n")
                    refresh += 1
                }
                .disabled(auth.authorizationStatus != .approved || Categories.picked.isEmpty)
            }
        } header: { Text("Categories") } footer: {
            Text("Select all categories in Apple's list (tap each category, or the \"All\" option, and no single apps). Then name each category: iOS does not tell apps which category is which, so iEyesApp shows each one's name and you choose the same name from the list.")
        }
    }

    private var motionSection: some View {
        Section {
            let _ = refresh
            Toggle("Keep running in background", isOn: Binding(
                get: { LiveMotion.wanted },
                set: { LiveMotion.wanted = $0; LiveMotion.shared.apply(); refresh += 1 }))
            if LiveMotion.wanted {
                switch LiveMotion.shared.authorization {
                case .authorizedAlways:
                    Label(LiveMotion.shared.running ? "Running: accelerometer · uploads every 10 min"
                                                    : "Starting…", systemImage: "bolt.horizontal.circle")
                        .foregroundStyle(.green).font(.caption)
                case .authorizedWhenInUse:
                    Text("Location is set to \"While Using\". For background running choose \"Always\" in Settings › iEyesApp › Location.")
                        .foregroundStyle(.orange).font(.caption)
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                        .font(.caption)
                case .denied, .restricted:
                    Text("Location access is off, so iEyesApp cannot keep running. Turn it on (Always) in Settings › iEyesApp › Location.")
                        .foregroundStyle(.red).font(.caption)
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                        .font(.caption)
                default:
                    Text("Waiting for location permission…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !Motion.available {
                Text("This device cannot record motion in the background.").foregroundStyle(.secondary)
            } else if Motion.denied {
                Text("Motion & Fitness access is off. Turn it on in Settings › Privacy & Security › Motion & Fitness.")
                    .foregroundStyle(.red).font(.caption)
            } else if let until = Motion.recordingUntil, until > Date() {
                Label("Accelerometer recording", systemImage: "waveform.path").foregroundStyle(.green)
                if let t = Motion.fetchedThrough {
                    LabeledContent("Read through", value: t.formatted(date: .omitted, time: .shortened))
                }
            } else {
                Text("Starts with monitoring.").foregroundStyle(.secondary)
            }
        } header: { Text("Motion") } footer: {
            Text("Without background running, iOS records only the accelerometer and iEyesApp reads it when it runs. With it on, iEyesApp keeps running using location permission (coarse, about 3 km; no location is ever stored), reads the accelerometer 5 times a second while unlocked and once a second while locked, and uploads every 10 minutes. iOS shows a blue location indicator in the status bar while it runs. If iOS stops iEyesApp, a notification asks you to tap it to resume.")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            let _ = refresh
            LabeledContent("Monitoring", value: "\(Monitor.monitoring.count) categories")
            LabeledContent("Files waiting to upload", value: "\(Chunks.files(in: Chunks.outbox).count)")
            LabeledContent("Server has files", value: "1–\(Eyes.defaults.integer(forKey: "have_through"))")
            let last = Eyes.defaults.double(forKey: "last_upload")
            LabeledContent("Last upload", value: last == 0 ? "never" :
                Date(timeIntervalSince1970: last).formatted(date: .abbreviated, time: .shortened))
            if let e = Eyes.defaults.string(forKey: "last_error"), !e.isEmpty {
                Text(e).foregroundStyle(.red).font(.caption)
            }
            if !message.isEmpty { Text(message).font(.caption) }
            Button("Upload now") {
                Task.detached {
                    IEyesApp.heartbeat("button")
                    let ok = Server.upload()
                    await MainActor.run { message = ok ? "Upload done." : "Upload stopped; will retry."; refresh += 1 }
                }
            }
            .disabled(!Server.enrolled)
        }
    }

    // MARK: picker

    private func pickerSheet(_ name: String) -> some View {
        NavigationStack {
            FamilyActivityPicker(headerText: "Select every category (no single apps)", selection: $selection)
                .navigationTitle("Categories")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { picking = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use") {
                            if selection.categoryTokens.isEmpty {
                                message = "No category was selected."
                            } else {
                                Categories.setPicked(selection.categoryTokens)
                                message = "\(selection.categoryTokens.count) categories selected" +
                                    (selection.applicationTokens.isEmpty ? "." : " (single apps ignored).")
                                _ = Monitor.armAll()
                            }
                            picking = nil
                            refresh += 1
                            if Categories.unnamed > 0 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { naming = true }
                            }
                        }
                    }
                }
        }
    }
}

extension ContentView {
    /// One row per picked category: iOS draws its real name and icon (the app itself cannot read
    /// them), and the participant picks the same name from the list.
    var namingSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Categories.picked, id: \.id) { item in
                        HStack {
                            Label(item.token).labelStyle(.titleAndIcon)
                            Spacer()
                            Menu {
                                ForEach(Eyes.categories, id: \.self) { n in
                                    Button(n) { Categories.setName(n, for: item.id); refresh += 1 }
                                }
                            } label: {
                                Text(Categories.name(item.id) ?? "Choose…")
                                    .foregroundStyle(Categories.name(item.id) == nil ? .orange : .accentColor)
                            }
                        }
                    }
                } footer: {
                    Text("For each row, choose the name shown on its left. This lets the study report \"Social 2 h\" instead of \"c10 2 h\". Nothing else about your apps is recorded.")
                }
            }
            .id(refresh)
            .navigationTitle("Name the categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { naming = false } }
            }
        }
    }
}

private struct Picking: Identifiable {
    let name: String
    var id: String { name }
}
