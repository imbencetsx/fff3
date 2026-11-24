import SwiftUI
import Fff3Core

private enum CalibrationSection: String, CaseIterable {
    case white = "White balance", colour = "Colour", brightness = "Brightness"
}

struct ColorCalibrationSheet: View {
    let model: AppModel
    var initialColor = Rgb.white
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var testColor = Rgb.white
    @State private var draft = ColorCalibration()
    @State private var section = CalibrationSection.white
    @State private var saveFailed = false
    @State private var customColor = Color.orange

    private var device: KnownDevice? { model.devices.first { $0.id == selectedID } }
    private var adjustment: ColorAdjustment { draft.adjustment(for: testColor) }
    private var hasChanges: Bool { draft != (device?.colorCalibration ?? ColorCalibration()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate colours").font(.title2.weight(.semibold))
            Text("Choose a colour to edit its own settings. Saved colour overrides keep their settings. Uncalibrated colours inherit your White balance. Save all colours for this strip when finished.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Strip", selection: $selectedID) {
                ForEach(model.devices) { device in
                    Text("\(device.displayName) · \(device.id.uuidString.prefix(4))").tag(Optional(device.id))
                }
            }
            .disabled(hasChanges)
            .onChange(of: selectedID) { _, id in
                guard let id, let device = model.devices.first(where: { $0.id == id }) else { return }
                model.beginColorCalibration(id)
                draft = device.colorCalibration ?? ColorCalibration()
                testColor = initialColor
                model.previewCalibrationColor(initialColor)
            }
            Picker("Adjustment", selection: $section) {
                ForEach(CalibrationSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            testColours
            HStack {
                ColorPicker("Custom colour", selection: $customColor, supportsOpacity: false)
                Button("Add colour") { addCustomColor() }
            }
            Text("Editing \(testColor.toHex()) · Greys use their own brightness curve.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            adjustments.frame(minHeight: 150, alignment: .top)
            Text("Applies to whites, the colour wheel, music sync and Spotify. Built-in controller effects keep their own colours. Reducing channels or brightness makes the strip dimmer.")
                .font(.caption).foregroundStyle(.secondary)
            Text(hasChanges ? "Unsaved changes. Save or cancel before choosing another strip." : "Saved balance is loaded automatically whenever this strip connects.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset this colour") {
                    var changed = draft
                    changed.reset(testColor)
                    setDraft(changed)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save calibration") {
                    guard let selectedID else { return }
                    if model.updateColorCalibration(selectedID, draft) { dismiss() }
                    else { saveFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { selectedID = model.targetDevices.first?.id ?? model.devices.first?.id }
        .onDisappear { model.endColorCalibration() }
        .alert("Could not save calibration", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your adjustments are still here. Check that your Mac has free disk space and try saving again.")
        }
    }

    @ViewBuilder private var adjustments: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch section {
            case .white:
                Text("Adjust the red, green and blue balance for this colour only. For a blue-tinted white, choose White and lower Blue. If a dark grey looks red, select that grey and lower Red; your White setting stays saved.")
                    .font(.callout).foregroundStyle(.secondary)
                slider("Red", keyPath: \.red, range: 0...100)
                slider("Green", keyPath: \.green, range: 0...100)
                slider("Blue", keyPath: \.blue, range: 0...100)
            case .colour:
                Text("Shift this colour’s hue or saturation without changing your other calibration colours. Hue has no effect on neutral white or grey.")
                    .font(.callout).foregroundStyle(.secondary)
                slider("Hue", keyPath: \.hue, range: -180...180, suffix: "°")
                slider("Saturation", keyPath: \.saturation, range: 0...200)
            case .brightness:
                Text("Adjust this colour’s brightness and gamma independently. Gamma above 1 darkens intermediate channel levels; below 1 brightens them. Pure white stays unchanged by gamma.")
                    .font(.callout).foregroundStyle(.secondary)
                slider("Brightness", keyPath: \.brightness, range: 0...100)
                slider("Gamma", keyPath: \.gamma, range: 50...250, suffix: "")
            }
        }
    }

    private var testColours: some View {
        let greys: [Rgb] = [.white, Rgb(0x808080), Rgb(0x404040), Rgb(0x202020), Rgb(0x101010)]
        let names = ["White", "Grey", "Dark", "Red", "Green", "Blue", "Orange", "Yellow", "Cyan", "Magenta"]
        var labels = Dictionary(uniqueKeysWithValues: zip(ColorCalibration.standardColors, names))
        labels[Rgb(0x101010)] = "Very dark"
        labels[Rgb(0x404040)] = "Dim grey"
        let extra = draft.colors.contains(initialColor) || greys.contains(initialColor) ? [] : [initialColor]
        let tests = (greys + draft.colors.filter { !greys.contains($0) } + extra).map { color in
            (labels[color] ?? color.toHex(), color)
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(tests, id: \.0) { name, color in
                    Button {
                        testColor = color
                        model.previewCalibrationColor(color)
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 5).fill(Color(color))
                                .frame(width: 42, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary, lineWidth: 1))
                            Text(name).font(.caption)
                        }
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(testColor == color ? Color.accentColor.opacity(0.2) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Test \(name.lowercased())")
                    .accessibilityAddTraits(testColor == color ? .isSelected : [])
                }
            }
        }
    }

    private func addCustomColor() {
        guard let color = NSColor(customColor).usingColorSpace(.sRGB) else { return }
        let rgb = Rgb.of(Int((color.redComponent * 255).rounded()),
                         Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        var changed = draft
        changed.set(changed.adjustment(for: rgb), for: rgb)
        testColor = rgb
        setDraft(changed)
        model.previewCalibrationColor(rgb)
    }

    private func setDraft(_ calibration: ColorCalibration) {
        draft = calibration
        if let selectedID { model.previewColorCalibration(selectedID, calibration) }
    }

    private func slider(_ title: String, keyPath: WritableKeyPath<ColorAdjustment, Int>, range: ClosedRange<Double>, suffix: String = "%") -> some View {
        HStack {
            Text(title).frame(width: 76, alignment: .leading)
            Slider(value: Binding(get: { Double(adjustment[keyPath: keyPath]) }, set: { value in
                var changed = adjustment
                changed[keyPath: keyPath] = Int(value)
                var profile = draft
                profile.set(changed, for: testColor)
                setDraft(profile)
            }), in: range, step: 1)
            .accessibilityLabel(title)
            Text(keyPath == \.gamma ? String(format: "%.2f", Double(adjustment.gamma) / 100) : "\(adjustment[keyPath: keyPath])\(suffix)")
                .monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}
