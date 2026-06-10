import AppKit
import Foundation
import LineupCore

enum UpdateChecker {
    private static let latestURL = URL(string: "https://api.github.com/repos/hcaiano/lineup/releases/latest")!

    static func checkInteractively() {
        var request = URLRequest(url: latestURL)
        request.setValue("Lineup", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<LatestRelease, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(UpdateError.badStatus(http.statusCode))
            } else if let data {
                do {
                    result = .success(try JSONDecoder().decode(LatestRelease.self, from: data))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(UpdateError.emptyResponse)
            }

            DispatchQueue.main.async {
                present(result)
            }
        }.resume()
    }

    private static func present(_ result: Result<LatestRelease, Error>) {
        // Accessory apps don't own key focus; without this the alert can open BEHIND
        // whatever the user is working in and look like the check silently failed.
        NSApp.activate(ignoringOtherApps: true)
        switch result {
        case .success(let release):
            let current = currentVersion()
            guard SemVer.isNewer(release.tagName, than: current) else {
                showMessage(
                    title: "Lineup is up to date",
                    message: "You're running version \(current).")
                return
            }

            guard let asset = release.dmgAsset else {
                showMessage(
                    title: "Update found, but no DMG is attached",
                    message: "Version \(release.tagName) is available on GitHub, but Lineup couldn't find a downloadable DMG.")
                return
            }

            let alert = NSAlert()
            alert.messageText = "Lineup \(release.tagName) is available"
            alert.informativeText = "You're running version \(current). Download the latest DMG from GitHub?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(asset.browserDownloadURL)
            }

        case .failure:
            showMessage(
                title: "Couldn't check for updates",
                message: "Check your internet connection and try again.")
        }
    }

    private static func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}

private struct LatestRelease: Decodable {
    let tagName: String
    let assets: [ReleaseAsset]

    var dmgAsset: ReleaseAsset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateError: Error {
    case badStatus(Int)
    case emptyResponse
}
