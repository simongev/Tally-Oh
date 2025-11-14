//
//  SettingsViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Settings screen for configuring filters and display options
//

import UIKit

class SettingsViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let settings = AppSettings.shared

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Settings"
        view.backgroundColor = .systemBackground

        setupTableView()
        setupNavigationBar()
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Reset",
            style: .plain,
            target: self,
            action: #selector(resetTapped)
        )
    }

    private func setupTableView() {
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(SwitchCell.self, forCellReuseIdentifier: "SwitchCell")
        tableView.register(SliderCell.self, forCellReuseIdentifier: "SliderCell")
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func resetTapped() {
        let alert = UIAlertController(
            title: "Reset Settings",
            message: "Reset all settings to default values?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            self?.settings.resetToDefaults()
            self?.tableView.reloadData()
        })

        present(alert, animated: true)
    }

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case aircraftLabels
        case aircraftFilters
        case aircraftDistance
        case airportTypes
        case airportDistance

        var title: String {
            switch self {
            case .aircraftLabels: return "Aircraft Labels"
            case .aircraftFilters: return "Aircraft Filters"
            case .aircraftDistance: return "Aircraft Distance"
            case .airportTypes: return "Airport Types"
            case .airportDistance: return "Airport Distance"
            }
        }

        var footer: String? {
            switch self {
            case .aircraftLabels: return "Select which information to display on aircraft labels"
            case .aircraftFilters: return "Filter which aircraft are displayed"
            case .aircraftDistance: return "Maximum distance for displaying aircraft"
            case .airportTypes: return "Select which airport types to display"
            case .airportDistance: return "Maximum distance for displaying airports"
            }
        }
    }
}

// MARK: - UITableViewDataSource

extension SettingsViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }

        switch section {
        case .aircraftLabels: return 5 // callsign, altitude, speed, vr, track
        case .aircraftFilters: return 1 // show ground aircraft
        case .aircraftDistance: return 1 // single slider
        case .airportTypes: return 6 // large, medium, small, heliport, seaplane, balloonport
        case .airportDistance: return 1 // single slider
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        }

        switch section {
        case .aircraftLabels:
            return aircraftLabelCell(for: indexPath)
        case .aircraftFilters:
            return aircraftFilterCell(for: indexPath)
        case .aircraftDistance:
            return sliderCell(for: indexPath, isAircraft: true)
        case .airportTypes:
            return airportTypeCell(for: indexPath)
        case .airportDistance:
            return sliderCell(for: indexPath, isAircraft: false)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return Section(rawValue: section)?.title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return Section(rawValue: section)?.footer
    }

    // MARK: - Cell Generators

    private func aircraftLabelCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell

        let labelOptions = [
            ("Callsign", settings.showCallsign, #selector(toggleCallsign)),
            ("Altitude", settings.showAltitude, #selector(toggleAltitude)),
            ("Ground Speed", settings.showGroundSpeed, #selector(toggleGroundSpeed)),
            ("Vertical Rate", settings.showVerticalRate, #selector(toggleVerticalRate)),
            ("Track", settings.showTrack, #selector(toggleTrack))
        ]

        let (title, isOn, action) = labelOptions[indexPath.row]
        cell.configure(title: title, isOn: isOn, target: self, action: action)

        return cell
    }

    private func aircraftFilterCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell
        cell.configure(
            title: "Show Aircraft on Ground",
            isOn: settings.showGroundAircraft,
            target: self,
            action: #selector(toggleGroundAircraft)
        )
        return cell
    }

    private func airportTypeCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell

        let types = [
            ("Large Airports", settings.showLargeAirports, #selector(toggleLargeAirports)),
            ("Medium Airports", settings.showMediumAirports, #selector(toggleMediumAirports)),
            ("Small Airports", settings.showSmallAirports, #selector(toggleSmallAirports)),
            ("Heliports", settings.showHeliports, #selector(toggleHeliports)),
            ("Seaplane Bases", settings.showSeaplaneBases, #selector(toggleSeaplaneBases)),
            ("Balloonports", settings.showBalloonports, #selector(toggleBalloonports))
        ]

        let (title, isOn, action) = types[indexPath.row]
        cell.configure(title: title, isOn: isOn, target: self, action: action)

        return cell
    }

    private func sliderCell(for indexPath: IndexPath, isAircraft: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SliderCell", for: indexPath) as! SliderCell

        let currentValue = isAircraft ? settings.aircraftMaxDistance : settings.airportMaxDistance
        let title = isAircraft ? "Aircraft" : "Airports"
        let action = isAircraft ? #selector(aircraftDistanceChanged) : #selector(airportDistanceChanged)

        cell.configure(
            title: title,
            currentValue: currentValue,
            minValue: AppSettings.minDistance,
            maxValue: AppSettings.maxDistance,
            target: self,
            action: action
        )

        return cell
    }
}

// MARK: - UITableViewDelegate

extension SettingsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // No selection handling needed - switches and sliders handle their own input
    }
}

// MARK: - Switch Actions

extension SettingsViewController {

    @objc private func toggleCallsign(_ sender: UISwitch) {
        settings.showCallsign = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleAltitude(_ sender: UISwitch) {
        settings.showAltitude = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleGroundSpeed(_ sender: UISwitch) {
        settings.showGroundSpeed = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleVerticalRate(_ sender: UISwitch) {
        settings.showVerticalRate = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleTrack(_ sender: UISwitch) {
        settings.showTrack = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleGroundAircraft(_ sender: UISwitch) {
        settings.showGroundAircraft = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleLargeAirports(_ sender: UISwitch) {
        settings.showLargeAirports = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleMediumAirports(_ sender: UISwitch) {
        settings.showMediumAirports = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleSmallAirports(_ sender: UISwitch) {
        settings.showSmallAirports = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleHeliports(_ sender: UISwitch) {
        settings.showHeliports = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleSeaplaneBases(_ sender: UISwitch) {
        settings.showSeaplaneBases = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleBalloonports(_ sender: UISwitch) {
        settings.showBalloonports = sender.isOn
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func aircraftDistanceChanged(_ sender: UISlider) {
        settings.aircraftMaxDistance = Double(sender.value)
        // Post notification for AR view to update
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func airportDistanceChanged(_ sender: UISlider) {
        settings.airportMaxDistance = Double(sender.value)
        // Post notification for AR view to update
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }
}

// MARK: - Custom Switch Cell

class SwitchCell: UITableViewCell {

    private let switchControl = UISwitch()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryView = switchControl
        selectionStyle = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, isOn: Bool, target: Any?, action: Selector) {
        textLabel?.text = title
        switchControl.isOn = isOn
        switchControl.removeTarget(nil, action: nil, for: .allEvents)
        switchControl.addTarget(target, action: action, for: .valueChanged)
    }
}

// MARK: - Custom Slider Cell

class SliderCell: UITableViewCell {

    private let slider = UISlider()
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let stackView = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        // Configure title label
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .secondaryLabel

        // Configure value label
        valueLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        valueLabel.textColor = .label
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Configure slider
        slider.minimumValue = 10
        slider.maximumValue = 50
        slider.isContinuous = true

        // Configure stack view
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Create top row with title and value
        let topRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        topRow.axis = .horizontal
        topRow.spacing = 8

        stackView.addArrangedSubview(topRow)
        stackView.addArrangedSubview(slider)

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        currentValue: Double,
        minValue: Double,
        maxValue: Double,
        target: Any?,
        action: Selector
    ) {
        titleLabel.text = title
        slider.minimumValue = Float(minValue)
        slider.maximumValue = Float(maxValue)
        slider.value = Float(currentValue)
        updateValueLabel(currentValue)

        slider.removeTarget(nil, action: nil, for: .allEvents)
        slider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        slider.addTarget(target, action: action, for: .valueChanged)
    }

    @objc private func sliderValueChanged(_ sender: UISlider) {
        updateValueLabel(Double(sender.value))
    }

    private func updateValueLabel(_ value: Double) {
        valueLabel.text = String(format: "%.0f NM", value)
    }
}

// MARK: - Notification Name Extension

extension Notification.Name {
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
