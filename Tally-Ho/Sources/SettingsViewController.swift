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
    }

    private struct Section {
        let header: String
        let rows: [RowKind]
    }

    // MARK: Data

    private var settings: ARVisualizationSettings
    private let onDismiss: (ARVisualizationSettings) -> Void

    private lazy var sections: [Section] = [
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
                title: "Show Airports",
                subtitle: "Display airport cone markers in AR",
                getter: { $0.showAirports },
                setter: { $0.showAirports = $1 }
            ),
            .toggle(
                title: "Show Distance",
                subtitle: "Distance in NM on airport label",
                getter: { $0.showAirportDistance },
                setter: { $0.showAirportDistance = $1 }
            ),
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
            .slider(
                title: "Max Distance",
                subtitle: "Airports shown within this range",
                unit: "NM",
                min: 5, max: 50, step: 5,
                getter: { $0.airportMaxDistance },
                setter: { $0.airportMaxDistance = $1 }
            ),
        ])
    ]

    // MARK: Init

    init(settings: ARVisualizationSettings, onDismiss: @escaping (ARVisualizationSettings) -> Void) {
        self.settings  = settings
        self.onDismiss = onDismiss
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
        tableView.register(ToggleCell.self, forCellReuseIdentifier: "toggle")
        tableView.register(SliderCell.self,      forCellReuseIdentifier: "slider")
        tableView.register(TextFieldCell.self,   forCellReuseIdentifier: "textField")
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
            let cell = tableView.dequeueReusableCell(withIdentifier: "toggle", for: indexPath)
            cell.textLabel?.text = title
            cell.textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            cell.detailTextLabel?.text = subtitle
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.font = .systemFont(ofSize: 13)
            cell.detailTextLabel?.numberOfLines = 2
            cell.selectionStyle = .none

            let sw = UISwitch()
            sw.isOn = getter(settings)
            sw.tag  = indexPath.section * 1000 + indexPath.row
            sw.addTarget(self, action: #selector(switchToggled(_:)), for: .valueChanged)
            cell.accessoryView = sw
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
        }
    }

    // MARK: Actions

    @objc private func switchToggled(_ sw: UISwitch) {
        let sec = sw.tag / 1000
        let row = sw.tag % 1000
        guard sec < sections.count, row < sections[sec].rows.count else { return }
        if case let .toggle(_, _, _, setter) = sections[sec].rows[row] {
            setter(&settings, sw.isOn)
        }
    }
}

// MARK: - ToggleCell

final class ToggleCell: UITableViewCell {

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        detailTextLabel?.textColor = .secondaryLabel
        detailTextLabel?.font = .systemFont(ofSize: 13)
        detailTextLabel?.numberOfLines = 2
    }

    required init?(coder: NSCoder) { fatalError() }
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
