import Foundation

/// A saved power limit. A run share of 1.0 means the app runs freely.
struct AppLimit: Codable, Equatable {
    var runShare = 1.0
    var efficiencyCoresOnly = false

    var isActive: Bool { runShare < 1.0 || efficiencyCoresOnly }
}

/// Saves limits per app so they come back when the app is relaunched.
final class LimitStore {
    private static let defaultsKey = "appLimits"
    private var limits: [String: AppLimit]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let savedLimits = try? JSONDecoder().decode([String: AppLimit].self, from: data) {
            limits = savedLimits
        } else {
            limits = [:]
        }
    }

    var hasLimits: Bool { !limits.isEmpty }

    func limit(for key: String) -> AppLimit {
        limits[key] ?? AppLimit()
    }

    func setLimit(_ limit: AppLimit, for key: String) {
        limits[key] = limit.isActive ? limit : nil
        save()
    }

    func removeAll() {
        limits.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(limits) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
