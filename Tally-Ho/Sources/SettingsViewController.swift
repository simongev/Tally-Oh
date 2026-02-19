//
//  SettingsViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  A UITableViewController presenting two sections:
//    Section 0 — ✈️ Aircraft
//    Section 1 — 🛫 Airports
//  Each row has a toggle switch controlling one setting in ARVisualizationSettings.
//

import UIKit

class SettingsViewController: UITableViewController {

    // MARK: - Types

    private struct SettingsRow {
        let title: String
        let subtitle: String?
        let getter: (ARVisualizationSettings) -> Bool
        let setter: (inout ARVisualizationSettings, Bool) -> Void
    }

    private struct SettingsSection {
        let header: String
        let rows: [SettingsRow]
    }

    // MARK: - Properties

    private var settings: ARVisualizationSettings
    private let onDismiss: (ARVisualizationSettings) -> Void

    private let sections: [SettingsSection] = [
        SettingsSection(header: "✈️  Aircraft", rows: [
            SettingsRow(
                title: "Show Aircraft",
                subtitle: "Display all aircraft in AR",
                getter: { $0.showAircraft },
                setter: { $0.showAircraft = $1 }
            ),
            SettingsRow(
                title: "Show Labels",
                subtitle: "Display info labels above aircraft",
                getter: { $0.showAircraftLabels },
                setter: { $0.showAircraftLabels = $1 }
            ),
            SettingsRow(
                title: "Show Aircraft Type",
                subtitle: "e.g. B738, C172 (when available)",
                getter: { $0.showAircraftType },
                setter: { $0.showAircraftType = $1 }
            ),
            SettingsRow(
                title: "Show Altitude",
                subtitle: "Altitude in feet MSL",
                getter: { $0.showAircraftAltitude },
                setter: { $0.showAircraftAltitude = $1 }
            ),
        ]),
        SettingsSection(header: "🛫  Airports", rows: [
            SettingsRow(
                title: "Show Airports",
                subtitle: "Display airport cones in AR",
                getter: { $0.showAirports },
                setter: { $0.showAirports = $1 }
            ),
            SettingsRow(
                title: "Show Labels",
                subtitle: "Display ICAO code and distance",
                getter: { $0.showAirportLabels },
                setter: { $0.showAirportLabels = $1 }
            ),
            SettingsRow(
                title: "Show Distance",
                subtitle: "Distance from your position in NM",
                getter: { $0.showAirportDistance },
                setter: { $0.showAirportDistance = $1 }
            ),
            SettingsRow(
                title: "Large Airports",
                subtitle: "International & major airports",
                getter: { $0.showLargeAirports },
                setter: { $0.showLargeAirports = $1 }
            ),
            SettingsRow(
                title: "Medium Airports",
                subtitle: "Regional airports",
                getter: { $0.showMediumAirports },
                setter: { $0.showMediumAirports = $1 }
            ),
            SettingsRow(
                title: "Small Airports",
                subtitle: "Local & general aviation airports",
                getter: { $0.showSmallAirports },
                setter: { $0.showSmallAirports = $1 }
            ),
        ])
    ]

    // MARK: - Init

    init(settings: ARVisualizationSettings, onDismiss: @escaping (ARVisualizationSettings) -> Void) {
        self.settings = settings
        self.onDismiss = onDismiss
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    @objc private func doneTapped() {
        dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.onDismiss(self.settings)
        }
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")

        cell.textLabel?.text = row.title
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)

        cell.detailTextLabel?.text = row.subtitle
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)

        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = row.getter(settings)
        toggle.tag = indexPath.section * 100 + indexPath.row
        toggle.addTarget(self, action: #selector(switchToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        return cell
    }

    // MARK: - Toggle Action

    @objc private func switchToggled(_ sender: UISwitch) {
        let section = sender.tag / 100
        let row     = sender.tag % 100
        guard section < sections.count, row < sections[section].rows.count else { return }
        sections[section].rows[row].setter(&settings, sender.isOn)
    }
}
