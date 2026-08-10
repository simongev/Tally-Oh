//
//  SettingsViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//

import UIKit

// MARK: - ARVisualizationSettings + Persistence

extension ARVisualizationSettings {

    private static let udKey = "ARVisualizationSettings"

    func save() {
        let d: [String: Any] = [
            "showAircraft":          showAircraft,
            "aircraftMaxDistance":   aircraftMaxDistance,
            "showCallsign":          showCallsign,
            "showAircraftType":      showAircraftType,
            "showAircraftAltitude":  showAircraftAltitude,
            "callsignFilter":        callsignFilter,
            "showAircraftSpeed":     showAircraftSpeed,
            "showAircraftDistance":  showAircraftDistance,
            "showGroundAircraft":    showGroundAircraft,
            "showAirports":          showAirports,
            "airportMaxDistance":    airportMaxDistance,
            "showLargeAirports":     showLargeAirports,
            "showMediumAirports":    showMediumAirports,
            "showSmallAirports":     showSmallAirports,
            "showAirportDistance":   showAirportDistance,
            "showHUD":               showHUD,
            "hudBrightness":         hudBrightness.rawValue,
        ]
        UserDefaults.standard.set(d, forKey: ARVisualizationSettings.udKey)
    }

    static func load() -> ARVisualizationSettings? {
        guard let d = UserDefaults.standard.dictionary(forKey: udKey) else { return nil }
        var s = ARVisualizationSettings()
        s.showAircraft         = d["showAircraft"]         as? Bool   ?? s.showAircraft
        s.aircraftMaxDistance  = d["aircraftMaxDistance"]  as? Double ?? s.aircraftMaxDistance
        s.showCallsign         = d["showCallsign"]         as? Bool   ?? s.showCallsign
        s.showAircraftType     = d["showAircraftType"]     as? Bool   ?? s.showAircraftType
        s.showAircraftAltitude = d["showAircraftAltitude"] as? Bool   ?? s.showAircraftAltitude
        s.callsignFilter       = d["callsignFilter"]       as? String ?? s.callsignFilter
        s.showAircraftSpeed    = d["showAircraftSpeed"]    as? Bool   ?? s.showAircraftSpeed
        s.showAircraftDistance = d["showAircraftDistance"] as? Bool   ?? s.showAircraftDistance
        s.showGroundAircraft   = d["showGroundAircraft"]   as? Bool   ?? s.showGroundAircraft
        s.showAirports         = d["showAirports"]         as? Bool   ?? s.showAirports
        s.airportMaxDistance   = d["airportMaxDistance"]   as? Double ?? s.airportMaxDistance
        s.showLargeAirports    = d["showLargeAirports"]    as? Bool   ?? s.showLargeAirports
        s.showMediumAirports   = d["showMediumAirports"]   as? Bool   ?? s.showMediumAirports
        s.showSmallAirports    = d["showSmallAirports"]    as? Bool   ?? s.showSmallAirports
        s.showAirportDistance  = d["showAirportDistance"]  as? Bool   ?? s.showAirportDistance
        s.showHUD              = d["showHUD"]              as? Bool   ?? s.showHUD
        if let raw = d["hudBrightness"] as? Int, let b = HUDBrightness(rawValue: raw) {
            s.hudBrightness = b
        }
        // Re-build the normalised filter cache after loading from disk.
        s.updateFilter()
        return s
    }
}

// MARK: - SettingsViewController

class SettingsViewController: UITableViewController {

    // MARK: Row kinds

    private enum RowKind {
        case toggle(
            title: String,
            subtitle: String,
            getter: (ARVisualizationSettings) -> Bool,
            setter: (inout ARVisualizationSettings, Bool) -> Void
        )
        case slider(
            title: String,
            subtitle: String,
            unit: String,
            min: Double, max: Double, step: Double,
            getter: (ARVisualizationSettings) -> Double,
            setter: (inout ARVisualizationSettings, Double) -> Void
        )
        case textField(
            title: String,
            placeholder: String,
            getter: (ARVisualizationSettings) -> String,
            setter: (inout ARVisualizationSettings, String) -> Void
        )
        /// A tappable row that lets the user pick one value from a list of callsigns.
        /// Tapping presents an action sheet. `options` is the list of nearby callsigns;
        /// `nil` in getter/setter means "None — hide all within 2 NM".
        case callsignPicker(
            title: String,
            subtitle: String,
            options: [String],
            getter: (ARVisualizationSettings) -> String?,
            setter: (inout ARVisualizationSettings, String?) -> Void
        )
        /// A non-interactive row that displays an auto-detected value (e.g. ADS-B ownship).
        case readOnlyValue(title: String, subtitle: String, value: String)
        /// A tappable row that lets the user pick one value from a small fixed list of
        /// display-name options (e.g. HUD brightness). `options` pairs a raw Int value
        /// with its display name.
        case optionPicker(
            title: String,
            subtitle: String,
            options: [(value: Int, name: String)],
            getter: (ARVisualizationSettings) -> Int,
            setter: (inout ARVisualizationSettings, Int) -> Void
        )
    }

    private struct Section {
        let header: String
        let footer: String?
        let rows: [RowKind]
        init(header: String, footer: String? = nil, rows: [RowKind]) {
            self.header = header
            self.footer = footer
            self.rows   = rows
        }
    }

    // MARK: Data

    private var settings: ARVisualizationSettings
    private let onDismiss: (ARVisualizationSettings) -> Void
    /// Whether the user is currently airborne on a WiFi-only connection.
    /// When true an extra "My Airplane" section is shown with a picker.
    private let wifiInAir: Bool
    /// Callsigns of aircraft detected within 2 NM at the time settings was opened.
    private let nearbyCallsigns: [String]
    /// Callsign of the ownship as reported by the ADS-B receiver (nil when not connected).
    /// When non-nil, "My Airplane" is shown as a read-only display instead of a picker.
    private let adsbOwnshipCallsign: String?

    private lazy var sections: [Section] = {
        var result: [Section] = [
        Section(header: "✈️  Aircraft", rows: [
            .toggle(
                title: "Show Aircraft",
                subtitle: "Display aircraft markers in AR",
                getter: { $0.showAircraft },
                setter: { $0.showAircraft = $1 }
            ),
            .toggle(
                title: "Show Callsign",
                subtitle: "Callsign label on each aircraft",
                getter: { $0.showCallsign },
                setter: { $0.showCallsign = $1 }
            ),
            .toggle(
                title: "Show Aircraft Type",
                subtitle: "e.g. B738, C172",
                getter: { $0.showAircraftType },
                setter: { $0.showAircraftType = $1 }
            ),
            .toggle(
                title: "Show Aircraft on Ground",
                subtitle: "Include aircraft at or below 50 ft",
                getter: { $0.showGroundAircraft },
                setter: { $0.showGroundAircraft = $1 }
            ),
            .toggle(
                title: "Show Altitude",
                subtitle: "Altitude in feet MSL",
                getter: { $0.showAircraftAltitude },
                setter: { $0.showAircraftAltitude = $1 }
            ),
            .toggle(
                title: "Show Speed",
                subtitle: "Ground speed in knots on label",
                getter: { $0.showAircraftSpeed },
                setter: { $0.showAircraftSpeed = $1 }
            ),
            .toggle(
                title: "Show Distance",
                subtitle: "Distance in NM on aircraft label",
                getter: { $0.showAircraftDistance },
                setter: { $0.showAircraftDistance = $1 }
            ),
            .slider(
                title: "Max Distance",
                subtitle: "Aircraft shown within this range",
                unit: "NM",
                min: 5, max: 50, step: 5,
                getter: { $0.aircraftMaxDistance },
                setter: { $0.aircraftMaxDistance = $1 }
            ),
        ]),
        Section(header: "🛫  Airports", rows: [
            .toggle(
                title: "Large Airports",
                subtitle: "International & major airports",
                getter: { $0.showLargeAirports },
                setter: { $0.showLargeAirports = $1 }
            ),
            .toggle(
                title: "Medium Airports",
                subtitle: "Regional airports",
                getter: { $0.showMediumAirports },
                setter: { $0.showMediumAirports = $1 }
            ),
            .toggle(
                title: "Small Airports",
                subtitle: "Local & general aviation airports",
                getter: { $0.showSmallAirports },
                setter: { $0.showSmallAirports = $1 }
            ),
            .toggle(
                title: "Show Distance",
                subtitle: "Distance in NM on airport label",
                getter: { $0.showAirportDistance },
                setter: { $0.showAirportDistance = $1 }
            ),
            .slider(
                title: "Max Distance",
                subtitle: "Airports shown within this range",
                unit: "NM",
                min: 5, max: 50, step: 5,
                getter: { $0.airportMaxDistance },
                setter: { $0.airportMaxDistance = $1 }
            ),
        ]),
        Section(header: "📟  HUD", rows: [
            .toggle(
                title: "Show HUD",
                subtitle: "Horizon line and speed/altitude readout",
                getter: { $0.showHUD },
                setter: { $0.showHUD = $1 }
            ),
            .optionPicker(
                title: "HUD Brightness",
                subtitle: "Dimmer keeps traffic markers visible underneath",
                options: HUDBrightness.allCases.map { ($0.rawValue, $0.displayName) },
                getter: { $0.hudBrightness.rawValue },
                setter: { $0.hudBrightness = HUDBrightness(rawValue: $1) ?? $0.hudBrightness }
            ),
        ])]
        if wifiInAir {
            result.append(Section(
                header: "🛩️  My Airplane",
                footer: "On WiFi, the app cannot auto-detect which aircraft you are on. " +
                        "Select your callsign to hide only your aircraft and show everything else. " +
                        "Without a selection, all traffic within 2 NM is hidden.",
                rows: [
                    .callsignPicker(
                        title: "I'm Flying",
                        subtitle: nearbyCallsigns.isEmpty
                            ? "No aircraft detected within 2 NM yet"
                            : "Select your aircraft from those nearby",
                        options: nearbyCallsigns,
                        getter: { $0.wifiOwnshipCallsign },
                        setter: { $0.wifiOwnshipCallsign = $1 }
                    )
                ]
            ))
        } else if let ownship = adsbOwnshipCallsign {
            result.append(Section(
                header: "🛩️  My Airplane",
                footer: "Your aircraft is automatically identified by the ADS-B receiver.",
                rows: [
                    .readOnlyValue(
                        title: "I'm Flying",
                        subtitle: "Auto-detected from ADS-B",
                        value: ownship
                    )
                ]
            ))
        }
        return result
    }()

    // MARK: Init

    init(settings: ARVisualizationSettings,
         wifiInAir: Bool = false,
         nearbyCallsigns: [String] = [],
         adsbOwnshipCallsign: String? = nil,
         onDismiss: @escaping (ARVisualizationSettings) -> Void) {
        self.settings             = settings
        self.wifiInAir            = wifiInAir
        self.nearbyCallsigns      = nearbyCallsigns
        self.adsbOwnshipCallsign  = adsbOwnshipCallsign
        self.onDismiss            = onDismiss
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )
        tableView.register(ToggleCell.self,         forCellReuseIdentifier: "toggle")
        tableView.register(SliderCell.self,         forCellReuseIdentifier: "slider")
        tableView.register(TextFieldCell.self,      forCellReuseIdentifier: "textField")
        tableView.register(CallsignPickerCell.self, forCellReuseIdentifier: "callsignPicker")
        tableView.register(CallsignPickerCell.self, forCellReuseIdentifier: "optionPicker")
        tableView.register(ReadOnlyValueCell.self,  forCellReuseIdentifier: "readOnlyValue")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.keyboardDismissMode = .onDrag
    }

    @objc private func doneTapped() {
        view.endEditing(true)
        dismiss(animated: true) { self.onDismiss(self.settings) }
    }

    // MARK: DataSource

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case let .toggle(title, subtitle, getter, setter):
            let cell = tableView.dequeueReusableCell(withIdentifier: "toggle", for: indexPath) as! ToggleCell
            cell.configure(
                title: title,
                subtitle: subtitle,
                isOn: getter(settings)
            ) { [weak self] newValue in
                guard let self else { return }
                setter(&self.settings, newValue)
            }
            return cell

        case let .slider(title, subtitle, unit, min, max, step, getter, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: "slider", for: indexPath) as! SliderCell
            cell.configure(
                title: title, subtitle: subtitle, unit: unit,
                minValue: min, maxValue: max, step: step,
                current: getter(settings)
            ) { [weak self] newValue in
                guard let self else { return }
                let rows = self.sections[indexPath.section].rows
                if case let .slider(_, _, _, _, _, _, _, setter) = rows[indexPath.row] {
                    setter(&self.settings, newValue)
                }
            }
            return cell

        case let .textField(title, placeholder, getter, setter):
            let cell = tableView.dequeueReusableCell(withIdentifier: "textField", for: indexPath) as! TextFieldCell
            cell.configure(
                title: title,
                placeholder: placeholder,
                current: getter(settings)
            ) { [weak self] newValue in
                guard let self else { return }
                let rows = self.sections[indexPath.section].rows
                if case let .textField(_, _, _, setter) = rows[indexPath.row] {
                    setter(&self.settings, newValue)
                }
            }
            return cell

        case let .callsignPicker(title, subtitle, _, getter, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: "callsignPicker", for: indexPath) as! CallsignPickerCell
            cell.configure(title: title, subtitle: subtitle, current: getter(settings))
            return cell

        case let .readOnlyValue(title, subtitle, value):
            let cell = tableView.dequeueReusableCell(withIdentifier: "readOnlyValue", for: indexPath) as! ReadOnlyValueCell
            cell.configure(title: title, subtitle: subtitle, value: value)
            return cell

        case let .optionPicker(title, subtitle, options, getter, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: "optionPicker", for: indexPath) as! CallsignPickerCell
            let currentName = options.first(where: { $0.value == getter(settings) })?.name
            cell.configure(title: title, subtitle: subtitle, current: currentName)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    // MARK: Selection (callsign picker)

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]

        if case let .optionPicker(title, _, options, getter, setter) = row {
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
            let current = getter(settings)
            for option in options {
                let isSelected = option.value == current
                let optionTitle = (isSelected ? "✓ " : "") + option.name
                alert.addAction(UIAlertAction(title: optionTitle, style: .default) { [weak self] _ in
                    guard let self else { return }
                    setter(&self.settings, option.value)
                    tableView.reloadRows(at: [indexPath], with: .none)
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let popover = alert.popoverPresentationController,
               let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            }
            present(alert, animated: true)
            return
        }

        guard case let .callsignPicker(_, _, options, _, setter) = row else { return }

        let alert = UIAlertController(
            title: "Which airplane are you on?",
            message: nil,
            preferredStyle: .actionSheet
        )

        // "None" resets to the default 2 NM exclusion zone.
        let noneTitle = (settings.wifiOwnshipCallsign == nil ? "✓ " : "") + "None — hide all within 2 NM"
        alert.addAction(UIAlertAction(title: noneTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            setter(&self.settings, nil)
            tableView.reloadRows(at: [indexPath], with: .none)
        })

        for callsign in options {
            let isSelected = settings.wifiOwnshipCallsign == callsign
            let title = (isSelected ? "✓ " : "") + callsign
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                setter(&self.settings, callsign)
                tableView.reloadRows(at: [indexPath], with: .none)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // Required for iPad popover presentation.
        if let popover = alert.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }

        present(alert, animated: true)
    }

    // MARK: Actions

}

// MARK: - ToggleCell

/// Reusable toggle cell that owns its UISwitch.
/// Using configure(onChange:) avoids adding a new target on every dequeue.
final class ToggleCell: UITableViewCell {

    private let toggle = UISwitch()
    private var onChange: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        detailTextLabel?.textColor = .secondaryLabel
        detailTextLabel?.font = .systemFont(ofSize: 13)
        detailTextLabel?.numberOfLines = 2
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        textLabel?.text       = title
        detailTextLabel?.text = subtitle
        toggle.isOn           = isOn
        self.onChange         = onChange
    }

    @objc private func switchChanged() {
        onChange?(toggle.isOn)
    }
}

// MARK: - SliderCell

final class SliderCell: UITableViewCell {

    private let titleLabel    = UILabel()
    private let subtitleLabel = UILabel()
    private let valueLabel    = UILabel()
    private let slider        = UISlider()

    private var step: Double   = 10
    private var minVal: Double = 20
    private var unit: String   = "NM"
    private var onChange: ((Double) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.font    = .systemFont(ofSize: 16, weight: .medium)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor    = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        valueLabel.font            = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor       = .systemBlue
        valueLabel.textAlignment   = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        topRow.axis = .horizontal; topRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [topRow, subtitleLabel, slider])
        stack.axis = .vertical; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])

        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String, unit: String = "NM",
                   minValue: Double, maxValue: Double, step: Double,
                   current: Double, onChange: @escaping (Double) -> Void) {
        self.step     = step
        self.minVal   = minValue
        self.unit     = unit
        self.onChange = onChange
        titleLabel.text    = title
        subtitleLabel.text = subtitle
        slider.minimumValue = Float(minValue)
        slider.maximumValue = Float(maxValue)
        slider.value        = Float(current)
        updateValueLabel(current)
    }

    private func snapped(_ raw: Float) -> Double {
        let steps = round((Double(raw) - minVal) / step)
        return minVal + steps * step
    }

    private func updateValueLabel(_ val: Double) {
        valueLabel.text = String(format: "%.0f \(unit)", val)
    }

    @objc private func sliderChanged() { updateValueLabel(snapped(slider.value)) }

    @objc private func sliderReleased() {
        let v = snapped(slider.value)
        slider.value = Float(v)
        updateValueLabel(v)
        onChange?(v)
    }
}

// MARK: - TextFieldCell

final class TextFieldCell: UITableViewCell {

    private let titleLabel = UILabel()
    private let field      = UITextField()
    private var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        field.borderStyle       = .roundedRect
        field.font              = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType     = .no
        field.clearButtonMode        = .whileEditing
        field.returnKeyType          = .done
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(textDone),    for: .editingDidEndOnExit)

        let stack = UIStackView(arrangedSubviews: [titleLabel, field])
        stack.axis = .horizontal; stack.spacing = 12; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, placeholder: String,
                   current: String, onChange: @escaping (String) -> Void) {
        titleLabel.text      = title
        field.placeholder    = placeholder
        field.text           = current
        self.onChange        = onChange
    }

    @objc private func textChanged() { onChange?(field.text ?? "") }
    @objc private func textDone()    { field.resignFirstResponder() }
}

// MARK: - CallsignPickerCell

/// Tappable row that shows the currently-selected callsign (or "None") with a
/// disclosure indicator. The action sheet is driven by SettingsViewController's
/// didSelectRowAt, not by the cell itself.
final class CallsignPickerCell: UITableViewCell {

    private let valueLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        detailTextLabel?.textColor = .secondaryLabel
        detailTextLabel?.font      = .systemFont(ofSize: 13)
        detailTextLabel?.numberOfLines = 2

        valueLabel.font      = .systemFont(ofSize: 15)
        valueLabel.textColor = .systemBlue
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))
        arrow.tintColor = .systemGray3
        arrow.preferredSymbolConfiguration = .init(textStyle: .footnote)

        // Build the accessory once; configure() just updates valueLabel.text.
        let stack = UIStackView(arrangedSubviews: [valueLabel, arrow])
        stack.axis      = .horizontal
        stack.spacing   = 4
        stack.alignment = .center
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        stack.frame = CGRect(origin: .zero, size: size)
        accessoryView = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String, current: String?) {
        textLabel?.text       = title
        detailTextLabel?.text = subtitle
        valueLabel.text = current ?? "None"
        // Re-fit the accessory stack after the label text changes.
        if let stack = accessoryView {
            let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            stack.frame = CGRect(origin: .zero, size: size)
        }
    }
}

// MARK: - ReadOnlyValueCell

/// Non-interactive row that displays an auto-detected value (e.g. the ADS-B ownship callsign).
/// Styled identically to CallsignPickerCell but without a disclosure indicator or selection.
final class ReadOnlyValueCell: UITableViewCell {

    private let valueLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        detailTextLabel?.textColor = .secondaryLabel
        detailTextLabel?.font      = .systemFont(ofSize: 13)
        detailTextLabel?.numberOfLines = 2

        valueLabel.font      = .systemFont(ofSize: 15)
        valueLabel.textColor = .secondaryLabel
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        accessoryView = valueLabel
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String, value: String) {
        textLabel?.text       = title
        detailTextLabel?.text = subtitle
        valueLabel.text       = value
        valueLabel.sizeToFit()
    }
}
