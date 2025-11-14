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

    // Staging variables - changes only saved when Done is pressed
    private var stagingShowCallsign: Bool = true
    private var stagingShowAltitude: Bool = true
    private var stagingShowGroundSpeed: Bool = false
    private var stagingShowVerticalRate: Bool = false
    private var stagingShowTrack: Bool = false
    private var stagingShowGroundAircraft: Bool = true
    private var stagingShowLargeAirports: Bool = true
    private var stagingShowMediumAirports: Bool = true
    private var stagingShowSmallAirports: Bool = true
    private var stagingShowHeliports: Bool = false
    private var stagingShowSeaplaneBases: Bool = false
    private var stagingShowBalloonports: Bool = false
    private var stagingAircraftMaxDistance: Double = 40.0
    private var stagingAirportMaxDistance: Double = 30.0

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Settings"
        view.backgroundColor = .systemBackground

        // Load current settings into staging variables
        loadCurrentSettings()

        setupTableView()
        setupNavigationBar()
    }

    private func loadCurrentSettings() {
        stagingShowCallsign = settings.showCallsign
        stagingShowAltitude = settings.showAltitude
        stagingShowGroundSpeed = settings.showGroundSpeed
        stagingShowVerticalRate = settings.showVerticalRate
        stagingShowTrack = settings.showTrack
        stagingShowGroundAircraft = settings.showGroundAircraft
        stagingShowLargeAirports = settings.showLargeAirports
        stagingShowMediumAirports = settings.showMediumAirports
        stagingShowSmallAirports = settings.showSmallAirports
        stagingShowHeliports = settings.showHeliports
        stagingShowSeaplaneBases = settings.showSeaplaneBases
        stagingShowBalloonports = settings.showBalloonports
        stagingAircraftMaxDistance = settings.aircraftMaxDistance
        stagingAirportMaxDistance = settings.airportMaxDistance
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
        // Commit all staging changes to AppSettings
        settings.showCallsign = stagingShowCallsign
        settings.showAltitude = stagingShowAltitude
        settings.showGroundSpeed = stagingShowGroundSpeed
        settings.showVerticalRate = stagingShowVerticalRate
        settings.showTrack = stagingShowTrack
        settings.showGroundAircraft = stagingShowGroundAircraft
        settings.showLargeAirports = stagingShowLargeAirports
        settings.showMediumAirports = stagingShowMediumAirports
        settings.showSmallAirports = stagingShowSmallAirports
        settings.showHeliports = stagingShowHeliports
        settings.showSeaplaneBases = stagingShowSeaplaneBases
        settings.showBalloonports = stagingShowBalloonports
        settings.aircraftMaxDistance = stagingAircraftMaxDistance
        settings.airportMaxDistance = stagingAirportMaxDistance

        // Notify AR view that settings have changed
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)

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
            // Reset actual settings
            self?.settings.resetToDefaults()
            // Reload staging variables from reset settings
            self?.loadCurrentSettings()
            // Reload table to show reset values
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
            ("Callsign", stagingShowCallsign, #selector(toggleCallsign)),
            ("Altitude", stagingShowAltitude, #selector(toggleAltitude)),
            ("Ground Speed", stagingShowGroundSpeed, #selector(toggleGroundSpeed)),
            ("Vertical Rate", stagingShowVerticalRate, #selector(toggleVerticalRate)),
            ("Track", stagingShowTrack, #selector(toggleTrack))
        ]

        let (title, isOn, action) = labelOptions[indexPath.row]
        cell.configure(title: title, isOn: isOn, target: self, action: action)

        return cell
    }

    private func aircraftFilterCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell
        cell.configure(
            title: "Show Aircraft on Ground",
            isOn: stagingShowGroundAircraft,
            target: self,
            action: #selector(toggleGroundAircraft)
        )
        return cell
    }

    private func airportTypeCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchCell

        let types = [
            ("Large Airports", stagingShowLargeAirports, #selector(toggleLargeAirports)),
            ("Medium Airports", stagingShowMediumAirports, #selector(toggleMediumAirports)),
            ("Small Airports", stagingShowSmallAirports, #selector(toggleSmallAirports)),
            ("Heliports", stagingShowHeliports, #selector(toggleHeliports)),
            ("Seaplane Bases", stagingShowSeaplaneBases, #selector(toggleSeaplaneBases)),
            ("Balloonports", stagingShowBalloonports, #selector(toggleBalloonports))
        ]

        let (title, isOn, action) = types[indexPath.row]
        cell.configure(title: title, isOn: isOn, target: self, action: action)

        return cell
    }

    private func sliderCell(for indexPath: IndexPath, isAircraft: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SliderCell", for: indexPath) as! SliderCell

        let currentValue = isAircraft ? stagingAircraftMaxDistance : stagingAirportMaxDistance
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
        stagingShowCallsign = sender.isOn
    }

    @objc private func toggleAltitude(_ sender: UISwitch) {
        stagingShowAltitude = sender.isOn
    }

    @objc private func toggleGroundSpeed(_ sender: UISwitch) {
        stagingShowGroundSpeed = sender.isOn
    }

    @objc private func toggleVerticalRate(_ sender: UISwitch) {
        stagingShowVerticalRate = sender.isOn
    }

    @objc private func toggleTrack(_ sender: UISwitch) {
        stagingShowTrack = sender.isOn
    }

    @objc private func toggleGroundAircraft(_ sender: UISwitch) {
        stagingShowGroundAircraft = sender.isOn
    }

    @objc private func toggleLargeAirports(_ sender: UISwitch) {
        stagingShowLargeAirports = sender.isOn
    }

    @objc private func toggleMediumAirports(_ sender: UISwitch) {
        stagingShowMediumAirports = sender.isOn
    }

    @objc private func toggleSmallAirports(_ sender: UISwitch) {
        stagingShowSmallAirports = sender.isOn
    }

    @objc private func toggleHeliports(_ sender: UISwitch) {
        stagingShowHeliports = sender.isOn
    }

    @objc private func toggleSeaplaneBases(_ sender: UISwitch) {
        stagingShowSeaplaneBases = sender.isOn
    }

    @objc private func toggleBalloonports(_ sender: UISwitch) {
        stagingShowBalloonports = sender.isOn
    }

    @objc private func aircraftDistanceChanged(_ sender: UISlider) {
        stagingAircraftMaxDistance = Double(sender.value)
    }

    @objc private func airportDistanceChanged(_ sender: UISlider) {
        stagingAirportMaxDistance = Double(sender.value)
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

        // Round current value to nearest 5 NM
        let roundedValue = round(currentValue / 5.0) * 5.0
        slider.value = Float(roundedValue)
        updateValueLabel(roundedValue)

        slider.removeTarget(nil, action: nil, for: .allEvents)
        slider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        slider.addTarget(target, action: action, for: .valueChanged)
    }

    @objc private func sliderValueChanged(_ sender: UISlider) {
        // Round to nearest 5 NM increment
        let roundedValue = round(Double(sender.value) / 5.0) * 5.0
        sender.value = Float(roundedValue)
        updateValueLabel(roundedValue)
    }

    private func updateValueLabel(_ value: Double) {
        valueLabel.text = String(format: "%.0f NM", value)
    }
}

// MARK: - Notification Name Extension

extension Notification.Name {
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
