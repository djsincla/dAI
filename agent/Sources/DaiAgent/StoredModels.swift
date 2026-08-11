import Foundation

/// What weights this machine has on disk.
///
/// Distinct from what it has loaded, and the distinction turned out to matter a
/// great deal. `residentModels` reports what is in memory this second, which is
/// empty on a healthy machine nobody has asked anything of yet: orca held
/// eighteen gigabytes of weights and reported holding nothing, and the fleet
/// view agreed with it. An operator reading that would have redistributed
/// weights that were already there, over the same network, to the machine that
/// already had them.
///
/// So possession is reported separately. The catalogue reconciles against this
/// one; the router uses residency, because what it is avoiding is a cold load.
///
/// Scanned rather than remembered. A file somebody deleted, a volume that did
/// not mount, an interrupted copy - none of them announce themselves, and a
/// cached answer would keep asserting a model was present long after it was
/// not.
public enum StoredModels {
    /// Model ids on disk under `base`, mapped to gigabytes.
    ///
    /// The layout is `<base>/models/<org>/<repo>`, which is what
    /// swift-transformers writes. Note it is not the `models--org--repo` form
    /// the Python hub client uses: copying a Python cache here produces a
    /// directory that looks right and is never found.
    public static func scan(base: URL) -> [String: Double] {
        let root = base.appendingPathComponent("models")
        let fm = FileManager.default
        var out: [String: Double] = [:]

        guard let orgs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            return out
        }
        // Bundles are directories with an extension, and descending into one
        // reports its internals as models: an ANE package produced a phantom
        // "ane_embed.mlpackage/Data" that the catalogue could never match to
        // anything and no node could ever be told to stop holding.
        for org in orgs where isDirectory(org) && org.pathExtension.isEmpty {
            guard let repos = try? fm.contentsOfDirectory(
                at: org, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for repo in repos where isDirectory(repo) {
                let id = "\(org.lastPathComponent)/\(repo.lastPathComponent)"
                out[id] = gigabytes(of: repo)
            }
        }

        // Core ML models sit directly under the root as `.mlpackage` bundles
        // rather than in org/repo form, and are reported under the same id the
        // ANE runtime advertises so the catalogue can match them at all.
        if let entries = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) {
            for entry in entries where entry.pathExtension == "mlpackage" {
                out["ane:embed"] = gigabytes(of: entry)
            }
        }
        return out
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Size on disk, in GB, walking the whole tree.
    ///
    /// Reported so a machine's contribution to storage is visible next to what
    /// it contributes in compute. Failures are counted as zero rather than
    /// skipped: a directory that cannot be read is not evidence of absence, but
    /// claiming a size nobody measured would be worse.
    static func gigabytes(of directory: URL) -> Double {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory,
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var bytes = 0
        for case let url as URL in walker {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return Double(bytes) / 1_073_741_824
    }
}
