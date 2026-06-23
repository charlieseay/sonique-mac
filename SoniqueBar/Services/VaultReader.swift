import Foundation

/// Provides read access to vault Standards/ and other reference documents
struct VaultReader {

    private static let vaultPath = "/Users/charlieseay/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"

    /// Read a Standards/ document
    static func readStandard(_ filename: String) -> String? {
        let path = "\(vaultPath)/Standards/\(filename)"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read any vault file by relative path
    static func readVaultFile(_ relativePath: String) -> String? {
        let path = "\(vaultPath)/\(relativePath)"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// List available Standards/ files
    static func listStandards() -> [String] {
        let standardsPath = "\(vaultPath)/Standards"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: standardsPath) else {
            return []
        }
        return files.filter { $0.hasSuffix(".md") }.sorted()
    }

    /// Get brief template
    static func getBriefTemplate() -> String {
        readStandard("Brief and Delivery Standard.md") ?? "Brief template not found"
    }
}
