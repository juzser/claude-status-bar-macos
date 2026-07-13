import Foundation

/// Whether the `cux` CLI is installed on this machine, independent of
/// whether it currently manages any accounts.
public enum CuxAvailability {
    public static func isInstalled(
        candidates: [String] = CuxRefresher.binaryCandidates,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        candidates.contains(where: isExecutable)
    }
}
