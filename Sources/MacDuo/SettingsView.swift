import SwiftUI

private let muted = Color.secondary

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var loginItem: LoginItemManager
    @State private var showsCalibration = false
    @State private var showsScreenAccess = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header
                effectControl
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    adjustments
                    details
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
        .onChange(of: model.permissionNeeded) { _, needed in
            if needed { showsScreenAccess = true }
        }
        .onChange(of: model.message) { _, message in
            if message != nil { showsScreenAccess = true }
        }
        .onAppear {
            showsScreenAccess = model.permissionNeeded || model.message != nil
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 21, weight: .regular))
                .accessibilityHidden(true)
            Text("MacDuo")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.5)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.sensorAvailable ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text(model.angle.map { "Lid \(Int($0.rounded()))°" } ?? "No sensor")
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(model.sensorMessage)
            .accessibilityElement(children: .combine)
        }
    }

    private var effectControl: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep your desktop in place.")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if model.isStarting { ProgressView().controlSize(.mini) }
                    Text(model.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("Effect", isOn: Binding(
                get: { model.isEnabled },
                set: { model.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Enable or pause the effect (⌃⌥⌘D)")
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview").font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("Preview mode", selection: $model.previewShowsObserver) {
                    Text("Observer").tag(true)
                    Text("Display").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 154)
                .help("Observer shows the illusion. Display shows the image drawn on the screen.")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ProjectionPreview(configuration: model.previewProjection, progress: model.previewProgress,
                              strength: model.strength, observerView: model.previewShowsObserver)
                .frame(height: 172)
                .accessibilityLabel("Simulated desktop projection at \(Int(model.displayedAngle.rounded())) degrees")

            Text(model.previewShowsObserver ? "Dashed outline: original image plane" : "Counterprojection on the display")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { model.displayedAngle },
                    set: { model.previewFollowsLid = false; model.previewAngle = $0.rounded() }
                ), in: 8...130)
                .controlSize(.small)
                .accessibilityLabel("Preview angle")
                Text("\(Int(model.displayedAngle.rounded()))°")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                Divider().frame(height: 12)
                Toggle("Follow lid", isOn: Binding(
                    get: { model.previewFollowsLid && model.sensorAvailable },
                    set: { model.previewFollowsLid = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .disabled(!model.sensorAvailable)
                    .help("Use the live sensor angle in the preview")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)))
    }

    private var adjustments: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open angle").font(.system(size: 12, weight: .medium))
                    Button("Use current") { model.useCurrentAngle() }
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                        .disabled(!model.sensorAvailable)
                        .help("Set the reference angle to the current lid position (70–125°)")
                }
                .frame(width: 92, alignment: .leading)
                Slider(value: Binding(
                    get: { model.startAngle },
                    set: { model.startAngle = $0.rounded() }
                ), in: 70...125)
                    .controlSize(.small)
                    .accessibilityLabel("Open angle")
                    .help("The reference position where the desktop stays anchored")
                value("\(Int(model.startAngle.rounded()))°")
            }
            HStack(spacing: 14) {
                Text("Softness")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 92, alignment: .leading)
                Slider(value: $model.strength, in: 0...1.4)
                    .controlSize(.small)
                    .accessibilityLabel("Projection softness")
                    .help("Zero keeps the projection sharp; higher values add frosted glass")
                value("\(Int((model.strength * 100).rounded()))%")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            launchAtLogin
            DisclosureGroup("Calibration", isExpanded: $showsCalibration) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep your head still. Adjust the viewpoint until the image stays in place.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    calibrationSlider("Eye height", value: $model.eyeHeight, range: 0.4...3)
                    calibrationSlider("Distance", value: $model.eyeDistance, range: 1.5...5)
                    Text("Measured in display heights from the hinge. No camera required.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            DisclosureGroup(isExpanded: $showsScreenAccess) {
                screenAccess
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            } label: {
                HStack(spacing: 6) {
                    Text("Screen access")
                    if model.permissionNeeded {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Permission required")
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!loginItem.isApplicationBundle || loginItem.requiresApproval)
            .help("Start quietly in the menu bar when you log in")

            if let message = loginItem.statusMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loginItem.requiresApproval {
                HStack(spacing: 10) {
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                    Button("Remove login item") { loginItem.setEnabled(false) }
                }
                .controlSize(.small)
            }
        }
    }

    private var screenAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One snapshot per fold, held in memory. No video, audio or uploads.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message)
                    .foregroundStyle(model.permissionNeeded ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if model.permissionNeeded {
                    Button("Retry access") { model.retryScreenRecordingPermission() }
                        .disabled(model.isStarting)
                    Button("Open Settings") { model.openScreenRecordingSettings() }
                } else {
                    Button("Test capture") { model.testSingleSnapshot() }
                        .disabled(model.isStarting || !model.sensorAvailable)
                        .help("Enable the effect, take one test snapshot and discard it immediately")
                }
                Spacer(minLength: 0)
                Text("\(model.snapshotCount) captured")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "menubar.rectangle").accessibilityHidden(true)
            Text("Always in your menu bar")
            Spacer()
            Text("⌃⌥⌘D")
                .font(.system(size: 10, design: .monospaced))
            Text("to toggle")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Divider() }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
    }

    private func calibrationSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))) + "×")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 11))
    }
}

struct DemoDesktopArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.28, green: 0.45, blue: 0.60), Color(red: 0.60, green: 0.73, blue: 0.72), Color(red: 0.90, green: 0.78, blue: 0.63)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(red: 0.33, green: 0.58, blue: 0.54).gradient).frame(width: w * 1.3, height: h * 1.4).rotationEffect(.degrees(-30)).offset(x: -w * 0.5, y: h * 0.35)
                Ellipse().fill(LinearGradient(colors: [Color(red: 0.90, green: 0.88, blue: 0.70), Color(red: 0.38, green: 0.63, blue: 0.65)], startPoint: .top, endPoint: .bottom)).frame(width: w * 0.5, height: h * 1.7).rotationEffect(.degrees(38)).offset(x: w * 0.48, y: -h * 0.2)
                HStack(spacing: 9) {
                    Image(systemName: "apple.logo")
                    Text("Finder").bold(); Text("File"); Text("Edit"); Text("View")
                    Spacer(); Image(systemName: "wifi"); Text("09:41")
                }.font(.system(size: 6)).padding(.horizontal, 9).frame(height: 13).background(.white.opacity(0.22))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 9) {
                        trafficLights
                        Text("FAVORITES").font(.system(size: 5, weight: .semibold)).foregroundStyle(muted).padding(.top, 5)
                        Label("Desktop", systemImage: "desktopcomputer")
                        Label("Documents", systemImage: "doc")
                        Label("Downloads", systemImage: "arrow.down.circle")
                        Spacer()
                    }.font(.system(size: 6)).padding(9).frame(width: w * 0.2).background(Color(red: 0.93, green: 0.94, blue: 0.93))
                    VStack(alignment: .leading, spacing: 13) {
                        HStack { Text("A good day.").font(.system(size: 9, weight: .semibold)); Spacer(); Image(systemName: "square.grid.2x2").font(.system(size: 7)) }
                        HStack(spacing: 15) {
                            folder("Projects", tint: Color(red: 0.42, green: 0.64, blue: 0.85))
                            folder("Ideas", tint: Color(red: 0.42, green: 0.64, blue: 0.85))
                            folder("Travel", tint: Color(red: 0.42, green: 0.64, blue: 0.85))
                        }
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.78, green: 0.68, blue: 0.54).gradient).frame(width: 33, height: 32)
                            VStack(alignment: .leading, spacing: 4) { Text("Room for something new.").font(.system(size: 7, weight: .medium)); Text("Everything in its place.").font(.system(size: 5)).foregroundStyle(muted) }
                        }
                        Spacer(minLength: 0)
                    }.padding(11).frame(maxWidth: .infinity).background(Color.white)
                }
                .frame(width: w * 0.77, height: h * 0.66)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .offset(x: w * 0.07, y: h * 0.16)
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: "sun.max.fill").font(.system(size: 16)).foregroundStyle(Color(red: 0.83, green: 0.62, blue: 0.28))
                    Text("A little less.\nA little lighter.").font(.system(size: 10, weight: .medium, design: .serif)).lineSpacing(2)
                    Text("A small reminder.").font(.system(size: 5)).foregroundStyle(muted)
                }.padding(11).frame(width: w * 0.27, height: h * 0.47, alignment: .topLeading)
                    .background(Color(red: 0.99, green: 0.97, blue: 0.89), in: RoundedRectangle(cornerRadius: 6))
                    .rotationEffect(.degrees(3)).shadow(color: .black.opacity(0.15), radius: 7, y: 4)
                    .offset(x: w * 0.68, y: h * 0.40)
                HStack(spacing: 5) {
                    dockIcon("face.smiling", .blue)
                    dockIcon("safari", .white)
                    dockIcon("message.fill", .green)
                    dockIcon("envelope.fill", .blue)
                    dockIcon("calendar", .white)
                    dockIcon("music.note", .pink)
                    dockIcon("gearshape.fill", .gray)
                }.padding(5).background(.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                    .position(x: w / 2, y: h - 16)
            }
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 3) { ForEach([Color(red: 0.96, green: 0.40, blue: 0.36), .orange, .green], id: \.self) { Circle().fill($0).frame(width: 4, height: 4) } }
    }
    private func folder(_ label: String, tint: Color) -> some View {
        VStack(spacing: 4) { Image(systemName: "folder.fill").font(.system(size: 24)).foregroundStyle(tint.gradient); Text(label).font(.system(size: 5)) }
    }
    private func dockIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(color == .white ? Color.blue : .white)
            .frame(width: 19, height: 19).background(color.gradient, in: RoundedRectangle(cornerRadius: 4))
    }
}
