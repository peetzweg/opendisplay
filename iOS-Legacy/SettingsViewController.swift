// SettingsViewController.swift — minimal settings sheet: device name,
// connection status, links. Ported from the modern app's SettingsView
// (perf-overlay/Metal-toggle sections dropped — MVP scope).

import UIKit

final class SettingsViewController: UITableViewController {
    private let receiver: PhoneReceiverLegacy

    init(receiver: PhoneReceiverLegacy) {
        self.receiver = receiver
        // .insetGrouped is iOS 13+; .grouped is the iOS-12-compatible style.
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OpenDisplay"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
    }

    @objc private func close() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2   // listening port, connection
        case 1: return 1   // device name
        default: return 2  // mac app link, github link
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Status"
        case 1: return "Name"
        default: return "About"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "Shown in the Mac app's WiFi connection menu." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Listening"
            cell.detailTextLabel?.text = "Port 9000"
            cell.selectionStyle = .none
            return cell
        case (0, 1):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Connection"
            cell.detailTextLabel?.text = receiver.connected ? "Connected" : "Waiting for Mac"
            cell.selectionStyle = .none
            return cell
        case (1, 0):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            let field = UITextField()
            field.placeholder = "Device name"
            field.text = UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name
            field.addTarget(self, action: #selector(nameChanged(_:)), for: .editingChanged)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                field.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
            ])
            return cell
        case (2, 0):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Get the Mac app"
            return cell
        default:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "GitHub — peetzweg/opendisplay"
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (2, 0):
            UIApplication.shared.open(macAppURL)
        case (2, 1):
            if let url = URL(string: "https://github.com/peetzweg/opendisplay") {
                UIApplication.shared.open(url)
            }
        default: break
        }
    }

    @objc private func nameChanged(_ field: UITextField) {
        let name = field.text ?? ""
        UserDefaults.standard.set(name, forKey: "deviceName")
        receiver.setServiceName(name)
    }
}
