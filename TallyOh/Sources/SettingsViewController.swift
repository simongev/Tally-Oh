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
        case .aircraftDistance: return AppSettings.DistanceOption.allCases.count
        case .airportTypes: return 3 // large, medium, small
        case .airportDistance: return AppSettings.DistanceOption.allCases.count
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
            return distanceCell(for: indexPath, isAircraft: true)
        case .airportTypes:
            return airportTypeCell(for: indexPath)
        case .airportDistance:
            return distanceCell(for: indexPath, isAircraft: false)
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
            ("Small Airports", settings.showSmallAirports, #selector(toggleSmallAirports))
        ]

        let (title, isOn, action) = types[indexPath.row]
        cell.configure(title: title, isOn: isOn, target: self, action: action)

        return cell
    }

    private func distanceCell(for indexPath: IndexPath, isAircraft: Bool) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

        let option = AppSettings.DistanceOption.allCases[indexPath.row]
        let currentSetting = isAircraft ? settings.aircraftMaxDistance : settings.airportMaxDistance

        cell.textLabel?.text = option.displayName
        cell.accessoryType = option == currentSetting ? .checkmark : .none

        return cell
    }
}

// MARK: - UITableViewDelegate

extension SettingsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .aircraftDistance:
            let option = AppSettings.DistanceOption.allCases[indexPath.row]
            settings.aircraftMaxDistance = option
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)

        case .airportDistance:
            let option = AppSettings.DistanceOption.allCases[indexPath.row]
            settings.airportMaxDistance = option
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)

        default:
            break
        }
    }
}

// MARK: - Switch Actions

extension SettingsViewController {

    @objc private func toggleCallsign(_ sender: UISwitch) {
        settings.showCallsign = sender.isOn
    }

    @objc private func toggleAltitude(_ sender: UISwitch) {
        settings.showAltitude = sender.isOn
    }

    @objc private func toggleGroundSpeed(_ sender: UISwitch) {
        settings.showGroundSpeed = sender.isOn
    }

    @objc private func toggleVerticalRate(_ sender: UISwitch) {
        settings.showVerticalRate = sender.isOn
    }

    @objc private func toggleTrack(_ sender: UISwitch) {
        settings.showTrack = sender.isOn
    }

    @objc private func toggleGroundAircraft(_ sender: UISwitch) {
        settings.showGroundAircraft = sender.isOn
    }

    @objc private func toggleLargeAirports(_ sender: UISwitch) {
        settings.showLargeAirports = sender.isOn
    }

    @objc private func toggleMediumAirports(_ sender: UISwitch) {
        settings.showMediumAirports = sender.isOn
    }

    @objc private func toggleSmallAirports(_ sender: UISwitch) {
        settings.showSmallAirports = sender.isOn
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
