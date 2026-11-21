import Foundation
#if USE_RUST_UPKEEP_CORE
import CUpkeepCore
#endif

/// Unified high-performance dual-engine: bridges to the Rust `upkeep_core` C-ABI
/// when linked (`USE_RUST_UPKEEP_CORE`), with fast zero-allocation Swift fallbacks.
public enum UpkeepEngine {

    public static var isUsingRustCore: Bool {
        #if USE_RUST_UPKEEP_CORE
        return true
        #else
        return false
        #endif
    }

    // MARK: - Persistent Rust Brew Search Index

    #if USE_RUST_UPKEEP_CORE
    public final class RustBrewIndex: @unchecked Sendable {
        private let lock = NSLock()
        private let ptr: OpaquePointer?
        private var items: [BrewPackageItem] = []

        public init() {
            self.ptr = upkeep_brew_index_new()
        }

        deinit {
            if let ptr {
                upkeep_brew_index_free(ptr)
            }
        }

        public func load(items: [BrewPackageItem]) {
            struct WirePkg: Encodable {
                let name: String
                let description: String
                let version: String
                let is_cask: Bool
                let is_installed: Bool
                let is_outdated: Bool
                let is_pinned: Bool
                let homepage: String
            }
            let wire = items.map {
                WirePkg(
                    name: $0.name,
                    description: $0.description,
                    version: $0.version,
                    is_cask: $0.isCask,
                    is_installed: $0.isInstalled,
                    is_outdated: $0.isOutdated,
                    is_pinned: $0.isPinned,
                    homepage: $0.homepage
                )
            }
            guard let data = try? JSONEncoder().encode(wire),
                  let jsonStr = String(data: data, encoding: .utf8),
                  let ptr else { return }

            lock.lock()
            self.items = items
            _ = jsonStr.withCString { cstr in
                upkeep_brew_index_load_json(ptr, cstr)
            }
            lock.unlock()
        }

        public func search(query: String, filterCasks: Bool?, limit: Int = 120) -> [BrewPackageItem] {
            guard let ptr else { return [] }
            let filterMode: Int32 = filterCasks == nil ? -1 : (filterCasks! ? 1 : 0)
            var matches = [UpkeepMatch](repeating: UpkeepMatch(index: 0, score: 0), count: max(1, limit))

            lock.lock()
            let count = query.withCString { qPtr in
                matches.withUnsafeMutableBufferPointer { buf in
                    upkeep_brew_index_search_fast(ptr, qPtr, filterMode, buf.baseAddress, UInt32(buf.count))
                }
            }
            var results: [BrewPackageItem] = []
            results.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let idx = Int(matches[i].index)
                if idx < items.count {
                    results.append(items[idx])
                }
            }
            lock.unlock()
            return results
        }
    }
    #endif

    // MARK: - Zero-Allocation Fuzzy Matcher

    @inline(__always)
    private static func toLowerAscii(_ b: UInt8) -> UInt8 {
        (b >= 65 && b <= 90) ? (b | 0x20) : b
    }

    /// Zero-allocation UTF-8 fuzzy matcher (or Rust nucleo when linked).
    public static func scoreFuzzy(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        #if USE_RUST_UPKEEP_CORE
        let s = query.withCString { qPtr in
            candidate.withCString { cPtr in
                upkeep_fuzzy_score(qPtr, cPtr)
            }
        }
        return s >= 0 ? Int(s) : nil
        #else
        let qView = query.utf8
        let cView = candidate.utf8
        let qCount = qView.count
        let cCount = cView.count

        if qCount > cCount { return nil }

        // Fast path: Exact match
        if qCount == cCount {
            var equal = true
            var qIt = qView.makeIterator()
            var cIt = cView.makeIterator()
            while let qb = qIt.next(), let cb = cIt.next() {
                if toLowerAscii(qb) != toLowerAscii(cb) {
                    equal = false
                    break
                }
            }
            if equal { return 10_000 }
        }

        // Fast path: Prefix match
        var isPrefix = true
        var qIt = qView.makeIterator()
        var cIt = cView.makeIterator()
        while let qb = qIt.next(), let cb = cIt.next() {
            if toLowerAscii(qb) != toLowerAscii(cb) {
                isPrefix = false
                break
            }
        }
        if isPrefix {
            return 5_000 - (cCount - qCount)
        }

        // Subsequence matching with word boundary and consecutive character bonuses
        var qi = qView.startIndex
        var ci = cView.startIndex
        let qEnd = qView.endIndex
        let cEnd = cView.endIndex

        var score = 0
        var consecutive = 0
        var prevMatched = false
        var prevChar: UInt8 = 0

        while qi < qEnd && ci < cEnd {
            let qb = toLowerAscii(qView[qi])
            let cb = toLowerAscii(cView[ci])

            if qb == cb {
                score += 10
                if prevMatched {
                    consecutive += 1
                    score += consecutive * 15
                } else {
                    consecutive = 0
                }

                if ci == cView.startIndex {
                    score += 25
                } else if prevChar == 45 || prevChar == 95 || prevChar == 32 || prevChar == 47 || prevChar == 46 {
                    score += 20
                }

                prevMatched = true
                qi = qView.index(after: qi)
            } else {
                prevMatched = false
            }

            prevChar = cView[ci]
            ci = cView.index(after: ci)
        }

        return qi == qEnd ? score : nil
        #endif
    }

    // MARK: - Fast Byte-Stream ANSI Escape Stripper

    public static func stripANSI(_ input: String) -> String {
        #if USE_RUST_UPKEEP_CORE
        return input.withCString { cstr in
            guard let out = upkeep_strip_ansi(cstr) else { return input }
            defer { upkeep_string_free(out) }
            return String(cString: out)
        }
        #else
        var result = [UInt8]()
        result.reserveCapacity(input.utf8.count)

        var iterator = input.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x1B { // ESC
                guard let next = iterator.next() else { break }
                if next == 0x5B { // '[' (CSI)
                    while let c = iterator.next() {
                        if (0x40...0x7E).contains(c) { break }
                    }
                } else if next == 0x5D { // ']' (OSC)
                    while let c = iterator.next() {
                        if c == 0x07 || c == 0x1B { break }
                    }
                }
            } else {
                result.append(byte)
            }
        }

        return String(decoding: result, as: UTF8.self)
        #endif
    }

    // MARK: - Mole Clean Parser (Dual Delimiters: '·' and '|')

    public static func parseMoleCleanOutput(_ raw: String, isDryRun: Bool) -> MoleCleanSummary {
        #if USE_RUST_UPKEEP_CORE
        struct WireSummary: Decodable {
            let total_reclaimed: String
            let item_count: Int
            let lines: [String]
            let is_dry_run: Bool
        }
        let decoded: WireSummary? = raw.withCString { cstr in
            guard let out = upkeep_parse_mole_clean_json(cstr, isDryRun) else { return nil }
            defer { upkeep_string_free(out) }
            let json = String(cString: out)
            return try? JSONDecoder().decode(WireSummary.self, from: Data(json.utf8))
        }
        if let decoded {
            return MoleCleanSummary(
                totalReclaimed: decoded.total_reclaimed,
                itemCount: decoded.item_count,
                lines: decoded.lines,
                isDryRun: decoded.is_dry_run
            )
        }
        #endif

        let cleaned = stripANSI(raw)
        var lines: [String] = []
        var totalReclaimed = "0 B"
        var parsedItemCount: Int? = nil
        var fallbackItemCount = 0

        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("✓") || trimmed.hasPrefix("○") || trimmed.hasPrefix("➤") || trimmed.hasPrefix("◎") {
                lines.append(trimmed)
                if (trimmed.hasPrefix("✓") && !trimmed.contains("Nothing to clean")) || trimmed.hasPrefix("○") {
                    fallbackItemCount += 1
                }
            }

            for marker in ["Removed:", "Would remove:", "Potential space:"] {
                if let range = trimmed.range(of: marker) {
                    let tail = String(trimmed[range.upperBound...])
                    let parts: [String]
                    if tail.contains("|") {
                        parts = tail.components(separatedBy: "|")
                    } else {
                        parts = tail.components(separatedBy: "·")
                    }

                    if let first = parts.first {
                        totalReclaimed = first.trimmingCharacters(in: .whitespaces)
                    }

                    for part in parts {
                        let lower = part.lowercased().trimmingCharacters(in: .whitespaces)
                        if lower.contains("items") {
                            let digits = lower.filter { $0.isNumber }
                            if let num = Int(digits) {
                                parsedItemCount = num
                            }
                        }
                    }
                }
            }
        }

        return MoleCleanSummary(
            totalReclaimed: totalReclaimed,
            itemCount: parsedItemCount ?? fallbackItemCount,
            lines: lines,
            isDryRun: isDryRun
        )
    }

    // MARK: - Parallel Application Scanner with Accurate APFS Bundle Sizes

    public static func scanInstalledApplications() async -> [MoleInstalledApp] {
        #if USE_RUST_UPKEEP_CORE
        return await Task.detached(priority: .userInitiated) {
            let capacity = 1024
            var records = [UpkeepAppRecord](repeating: UpkeepAppRecord(), count: capacity)
            let count = records.withUnsafeMutableBufferPointer { buf in
                upkeep_scan_applications(buf.baseAddress, UInt32(buf.count))
            }
            var apps: [MoleInstalledApp] = []
            apps.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                var rec = records[i]
                let name = withUnsafePointer(to: &rec.name.0) { String(cString: $0) }
                let bundleIdStr = withUnsafePointer(to: &rec.bundle_id.0) { String(cString: $0) }
                let path = withUnsafePointer(to: &rec.path.0) { String(cString: $0) }
                apps.append(MoleInstalledApp(
                    name: name,
                    bundleId: bundleIdStr.isEmpty ? nil : bundleIdStr,
                    source: "Applications",
                    uninstallName: name,
                    path: path,
                    size: Int64(rec.app_size_bytes)
                ))
            }
            return apps
        }.value
        #else
        let fm = FileManager.default
        let dirs = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var appPaths: [(name: String, path: String, bundleId: String?)] = []

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let fullPath = (dir as NSString).appendingPathComponent(item)
                let name = (item as NSString).deletingPathExtension
                let bundle = Bundle(path: fullPath)
                appPaths.append((name: name, path: fullPath, bundleId: bundle?.bundleIdentifier))
            }
        }

        return await withTaskGroup(of: MoleInstalledApp.self) { group in
            for entry in appPaths {
                group.addTask {
                    let size = calculateDirectorySize(atPath: entry.path)
                    return MoleInstalledApp(
                        name: entry.name,
                        bundleId: entry.bundleId,
                        source: "Applications",
                        uninstallName: entry.name,
                        path: entry.path,
                        size: size
                    )
                }
            }

            var results: [MoleInstalledApp] = []
            results.reserveCapacity(appPaths.count)
            for await app in group {
                results.append(app)
            }
            return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        #endif
    }

    /// Calculates accurate physical disk usage inside an app bundle without skipping nested
    /// `.framework`/`.app` packages and without double-counting symlinks or hardlinks.
    private static func calculateDirectorySize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(bytes)
        }
        return total
    }
}
