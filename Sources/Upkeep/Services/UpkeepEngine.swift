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
        private let itemsLock = NSLock()
        private let ptr: OpaquePointer?
        private var items: [BrewPackageItem] = []

        private struct WireBrewPackage: Codable {
            let name: String
            let description: String
            let version: String
            let is_cask: Bool
            let is_installed: Bool
            let is_outdated: Bool
            let is_pinned: Bool
            let homepage: String

            func toItem() -> BrewPackageItem {
                BrewPackageItem(
                    name: name,
                    description: description,
                    version: version,
                    isCask: is_cask,
                    isInstalled: is_installed,
                    isOutdated: is_outdated,
                    isPinned: is_pinned,
                    homepage: homepage
                )
            }
        }

        public init() {
            self.ptr = upkeep_brew_index_new()
        }

        deinit {
            if let ptr {
                upkeep_brew_index_free(ptr)
            }
        }

        public var count: Int {
            guard let ptr else { return 0 }
            return Int(upkeep_brew_index_count(ptr))
        }

        public func load(items: [BrewPackageItem]) {
            let wire = items.map {
                WireBrewPackage(
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

            itemsLock.lock()
            self.items = items
            itemsLock.unlock()

            // Rust index uses its own internal RwLock; no outer Swift lock needed.
            _ = jsonStr.withCString { cstr in
                upkeep_brew_index_load_json(ptr, cstr)
            }
        }

        /// Zero-copy raw-byte loader for Homebrew `formula.json` and `cask.json`.
        /// Parses both files and merges local Cellar/Caskroom state in parallel inside Rust.
        @discardableResult
        public func loadAPI(formulaeData: Data?, casksData: Data?, prefix: String = "/opt/homebrew") -> Int {
            guard let ptr else { return 0 }
            let fData = formulaeData ?? Data()
            let cData = casksData ?? Data()
            let loadedCount: UInt32 = fData.withUnsafeBytes { fBuf in
                cData.withUnsafeBytes { cBuf in
                    prefix.withCString { pPtr in
                        upkeep_brew_index_load_api_bytes(
                            ptr,
                            fBuf.bindMemory(to: UInt8.self).baseAddress,
                            fData.count,
                            cBuf.bindMemory(to: UInt8.self).baseAddress,
                            cData.count,
                            pPtr
                        )
                    }
                }
            }
            return Int(loadedCount)
        }

        /// Returns installed packages (with outdated/pinned/description metadata) from the merged Rust index.
        public func installedPackages() -> [BrewPackageItem] {
            guard let ptr, let rawPtr = upkeep_brew_index_installed_json(ptr) else { return [] }
            defer { upkeep_string_free(rawPtr) }
            let json = String(cString: rawPtr)
            guard let decoded = try? JSONDecoder().decode([WireBrewPackage].self, from: Data(json.utf8)) else {
                return []
            }
            return decoded.map { $0.toItem() }
        }

        /// Searches directly inside the Rust index and decodes only the top-N hits into Swift.
        public func searchJSON(query: String, filterCasks: Bool?, limit: Int = 80) -> [BrewPackageItem] {
            guard let ptr else { return [] }
            let filterMode: Int32 = filterCasks == nil ? -1 : (filterCasks! ? 1 : 0)
            let rawPtr: UnsafeMutablePointer<CChar>? = query.withCString { qPtr in
                upkeep_brew_index_search_json(ptr, qPtr, UInt32(max(1, limit)), filterMode)
            }
            guard let rawPtr else { return [] }
            defer { upkeep_string_free(rawPtr) }
            let json = String(cString: rawPtr)
            guard let decoded = try? JSONDecoder().decode([WireBrewPackage].self, from: Data(json.utf8)) else {
                return []
            }
            return decoded.map { $0.toItem() }
        }

        /// Zero-allocation index search when Swift already holds the matching `items` slice.
        public func search(query: String, filterCasks: Bool?, limit: Int = 120) -> [BrewPackageItem] {
            guard let ptr else { return [] }
            let filterMode: Int32 = filterCasks == nil ? -1 : (filterCasks! ? 1 : 0)
            var matches = [UpkeepMatch](repeating: UpkeepMatch(index: 0, score: 0), count: max(1, limit))

            let count = query.withCString { qPtr in
                matches.withUnsafeMutableBufferPointer { buf in
                    upkeep_brew_index_search_fast(ptr, qPtr, filterMode, buf.baseAddress, UInt32(buf.count))
                }
            }

            itemsLock.lock()
            let snapshot = items
            itemsLock.unlock()

            var results: [BrewPackageItem] = []
            results.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let idx = Int(matches[i].index)
                if idx < snapshot.count {
                    results.append(snapshot[idx])
                }
            }
            return results
        }
    }
    #endif

    // MARK: - Zero-Allocation Fuzzy Matcher

    @inline(__always)
    private static func toLowerAscii(_ b: UInt8) -> UInt8 {
        (b >= 65 && b <= 90) ? (b | 0x20) : b
    }

    /// Zero-allocation UTF-8 fuzzy matcher (or Rust thread-local nucleo when linked).
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
        // Fast path: zero allocations and zero FFI overhead when no ESC (0x1B) byte is present.
        guard input.utf8.contains(0x1B) else { return input }

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

    // MARK: - Two-Phase & Parallel Application Scanner

    /// Phase 1 instant app discovery (<15ms): reads app names, paths, and Info.plist bundle IDs
    /// without blocking on recursive directory size walks.
    public static func scanInstalledApplicationsMetadata() async -> [MoleInstalledApp] {
        #if USE_RUST_UPKEEP_CORE
        return await Task.detached(priority: .userInitiated) {
            let capacity = 1024
            var records = [UpkeepAppRecord](repeating: UpkeepAppRecord(), count: capacity)
            let count = records.withUnsafeMutableBufferPointer { buf in
                upkeep_scan_applications_metadata(buf.baseAddress, UInt32(buf.count))
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
                    size: nil
                ))
            }
            return apps
        }.value
        #else
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dirs = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
            var apps: [MoleInstalledApp] = []

            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let fullPath = (dir as NSString).appendingPathComponent(item)
                    let name = (item as NSString).deletingPathExtension
                    let bundleId = Bundle(path: fullPath)?.bundleIdentifier
                    apps.append(MoleInstalledApp(
                        name: name,
                        bundleId: bundleId,
                        source: "Applications",
                        uninstallName: name,
                        path: fullPath,
                        size: nil
                    ))
                }
            }
            return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
        #endif
    }

    /// Full parallel scanner of /Applications and ~/Applications with APFS-accurate bundle sizes.
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
        let metadataApps = await scanInstalledApplicationsMetadata()
        return await withTaskGroup(of: MoleInstalledApp.self) { group in
            for app in metadataApps {
                group.addTask {
                    let size = calculatePathSize(atPath: app.path)
                    return MoleInstalledApp(
                        name: app.name,
                        bundleId: app.bundleId,
                        source: app.source,
                        uninstallName: app.uninstallName,
                        path: app.path,
                        size: size
                    )
                }
            }

            var results: [MoleInstalledApp] = []
            results.reserveCapacity(metadataApps.count)
            for await app in group {
                results.append(app)
            }
            return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        #endif
    }

    /// Computes accurate physical disk usage for a single file or directory path.
    public static func calculatePathSize(atPath path: String) -> Int64 {
        #if USE_RUST_UPKEEP_CORE
        return path.withCString { cstr in
            Int64(upkeep_calculate_path_size(cstr))
        }
        #else
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        let url = URL(fileURLWithPath: path)
        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        let keySet = Set(keys)
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keySet),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(bytes)
        }
        return total
        #endif
    }

    /// Parallel Rust Uninstaller inspector (~/Library leftovers + APFS sizes + Caskroom match).
    public static func inspectAppForUninstallRust(
        app: MoleInstalledApp,
        brewPrefix: String = "/opt/homebrew"
    ) async -> UninstallInspection? {
        #if USE_RUST_UPKEEP_CORE
        return await Task.detached(priority: .userInitiated) {
            struct WireLeftover: Decodable {
                let path: String
                let display_path: String
                let category: String
                let size_bytes: UInt64
            }
            struct WirePayload: Decodable {
                let leftovers: [WireLeftover]
                let homebrew_cask_token: String?
            }

            let rawPtr: UnsafeMutablePointer<CChar>? = app.name.withCString { namePtr in
                (app.bundleId ?? "").withCString { bidPtr in
                    app.path.withCString { pathPtr in
                        brewPrefix.withCString { prefixPtr in
                            upkeep_inspect_app_uninstall_json(namePtr, bidPtr, pathPtr, prefixPtr)
                        }
                    }
                }
            }
            guard let rawPtr else { return nil }
            defer { upkeep_string_free(rawPtr) }
            let json = String(cString: rawPtr)
            guard let decoded = try? JSONDecoder().decode(WirePayload.self, from: Data(json.utf8)) else {
                return nil
            }
            let leftovers = decoded.leftovers.map {
                UninstallLeftoverItem(
                    path: $0.path,
                    displayPath: $0.display_path,
                    category: $0.category,
                    sizeBytes: Int64($0.size_bytes)
                )
            }
            return UninstallInspection(
                app: app,
                leftovers: leftovers,
                homebrewCaskToken: decoded.homebrew_cask_token
            )
        }.value
        #else
        return nil
        #endif
    }
}
