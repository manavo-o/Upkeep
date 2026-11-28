import Foundation
import CUpkeepCore

/// Swift bindings for the Rust `upkeep_core` C ABI.
public enum UpkeepEngine {

    /// Decodes a NUL-terminated UTF-8 JSON buffer returned by Rust without intermediate String/Data copies.
    @inline(__always)
    fileprivate static func decodeRustJSON<T: Decodable>(
        _ type: T.Type,
        from rawPtr: UnsafeMutablePointer<CChar>
    ) -> T? {
        let length = strlen(rawPtr)
        let data = Data(bytesNoCopy: rawPtr, count: length, deallocator: .none)
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Parallel Rust scan of Homebrew Cellar, Caskroom, and pinned kegs on disk.
    public static func scanBrewDirs(prefix: String = "/opt/homebrew") -> [BrewPackageItem]? {
        struct WireBrewPackage: Decodable {
            let name: String
            let description: String
            let version: String
            let is_cask: Bool
            let is_installed: Bool
            let is_outdated: Bool
            let is_pinned: Bool
            let homepage: String
        }
        let rawPtr: UnsafeMutablePointer<CChar>? = prefix.withCString { pPtr in
            upkeep_scan_brew_dirs_json(pPtr)
        }
        guard let rawPtr else { return nil }
        defer { upkeep_string_free(rawPtr) }
        guard let decoded = decodeRustJSON([WireBrewPackage].self, from: rawPtr) else { return nil }
        return decoded.map {
            BrewPackageItem(
                name: $0.name,
                description: $0.description,
                version: $0.version,
                isCask: $0.is_cask,
                isInstalled: $0.is_installed,
                isOutdated: $0.is_outdated,
                isPinned: $0.is_pinned,
                homepage: $0.homepage
            )
        }
    }

    // MARK: - Persistent Rust Brew Search Index

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

        /// Immediately evicts the in-memory Rust slab and Swift snapshot to minimize idle RAM.
        public func clear() {
            itemsLock.lock()
            items.removeAll()
            itemsLock.unlock()
            if let ptr {
                upkeep_brew_index_clear(ptr)
            }
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

        /// Streaming disk-file loader for Homebrew `formula.json` and `cask.json`.
        /// Streams directly into Rust's contiguous byte slab without loading raw JSON into Swift RAM.
        @discardableResult
        public func loadAPIFiles(formulaePath: String?, casksPath: String?, prefix: String = "/opt/homebrew") -> Int {
            guard let ptr else { return 0 }
            let fPath = formulaePath ?? ""
            let cPath = casksPath ?? ""
            let loadedCount: UInt32 = fPath.withCString { fPtr in
                cPath.withCString { cPtr in
                    prefix.withCString { pPtr in
                        upkeep_brew_index_load_api_files(ptr, fPtr, cPtr, pPtr)
                    }
                }
            }
            return Int(loadedCount)
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

        /// Loads the compact binary Homebrew catalog cache (<5ms) and merges local Cellar/Caskroom state in parallel.
        @discardableResult
        public func loadBinaryCache(path: String, prefix: String = "/opt/homebrew") -> Int {
            guard let ptr else { return 0 }
            let loaded: UInt32 = path.withCString { cPtr in
                prefix.withCString { pPtr in
                    upkeep_brew_index_load_binary_cache(ptr, cPtr, pPtr)
                }
            }
            return Int(loaded)
        }

        /// Persists the current Homebrew catalog index to a compact binary cache file atomically.
        @discardableResult
        public func saveBinaryCache(path: String) -> Bool {
            guard let ptr else { return false }
            return path.withCString { cPtr in
                upkeep_brew_index_save_binary_cache(ptr, cPtr)
            }
        }

        /// Refreshes local Cellar/Caskroom/pinned state in-place (~5ms) without re-parsing API JSON.
        @discardableResult
        public func refreshLocal(prefix: String = "/opt/homebrew") -> Int {
            guard let ptr else { return 0 }
            let count: UInt32 = prefix.withCString { pPtr in
                upkeep_brew_index_refresh_local(ptr, pPtr)
            }
            return Int(count)
        }

        /// Returns installed packages (with outdated/pinned/description metadata) from the merged Rust index.
        public func installedPackages() -> [BrewPackageItem] {
            guard let ptr, let rawPtr = upkeep_brew_index_installed_json(ptr) else { return [] }
            defer { upkeep_string_free(rawPtr) }
            guard let decoded = UpkeepEngine.decodeRustJSON([WireBrewPackage].self, from: rawPtr) else {
                return []
            }
            return decoded.map { $0.toItem() }
        }

        /// Searches directly inside the Rust index and decodes only the top-N hits into Swift.
        public func searchJSON(
            query: String,
            filterCasks: Bool?,
            limit: Int = 80,
            installedOnly: Bool = false
        ) -> [BrewPackageItem] {
            searchJSON(query: query, filterCasks: filterCasks, limit: limit, installedOnly: installedOnly, token: nil)
        }

        private func searchJSON(
            query: String,
            filterCasks: Bool?,
            limit: Int,
            installedOnly: Bool,
            token: OpaquePointer?
        ) -> [BrewPackageItem] {
            guard let ptr else { return [] }
            let filterMode: Int32 = filterCasks == nil ? -1 : (filterCasks! ? 1 : 0)
            let rawPtr: UnsafeMutablePointer<CChar>? = query.withCString { qPtr in
                upkeep_brew_index_search_cancellable_json(ptr, qPtr, UInt32(max(1, limit)), filterMode, installedOnly, token)
            }
            guard let rawPtr else { return [] }
            defer { upkeep_string_free(rawPtr) }
            guard let decoded = UpkeepEngine.decodeRustJSON([WireBrewPackage].self, from: rawPtr) else {
                return []
            }
            return decoded.map { $0.toItem() }
        }

        private final class SearchCancellation: @unchecked Sendable {
            let token = upkeep_brew_search_cancellation_new()
            func cancel() { upkeep_brew_search_cancel(token) }
            deinit { upkeep_brew_search_cancellation_free(token) }
        }

        func searchCancellable(query: String, filterCasks: Bool?, limit: Int) async throws -> [BrewPackageItem] {
            let cancellation = SearchCancellation()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let hits = await Task.detached(priority: .userInitiated) {
                    self.searchJSON(query: query, filterCasks: filterCasks, limit: limit,
                                    installedOnly: false, token: cancellation.token)
                }.value
                try Task.checkCancellation()
                return hits
            } onCancel: {
                cancellation.cancel()
            }
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

    // MARK: - Zero-Allocation Fuzzy Matcher

    /// UTF-8 fuzzy matching with Rust’s thread-local nucleo matcher.
    public static func scoreFuzzy(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let s = query.withCString { qPtr in
            candidate.withCString { cPtr in
                upkeep_fuzzy_score(qPtr, cPtr)
            }
        }
        return s >= 0 ? Int(s) : nil
    }

    // MARK: - Fast Byte-Stream ANSI Escape Stripper

    public static func stripANSI(_ input: String) -> String {
        // Fast path: zero allocations and zero FFI overhead when no ESC (0x1B) byte is present.
        guard input.utf8.contains(0x1B) else { return input }

        return input.withCString { cstr in
            guard let out = upkeep_strip_ansi(cstr) else { return input }
            defer { upkeep_string_free(out) }
            return String(cString: out)
        }
    }

    // MARK: - Mole Clean Parser (Dual Delimiters: '·' and '|')

    public static func parseMoleCleanOutput(_ raw: String, isDryRun: Bool) -> MoleCleanSummary {
        struct WireSummary: Decodable {
            let total_reclaimed: String
            let item_count: Int
            let lines: [String]
            let is_dry_run: Bool
        }
        let decoded: WireSummary? = raw.withCString { cstr in
            guard let out = upkeep_parse_mole_clean_json(cstr, isDryRun) else { return nil }
            defer { upkeep_string_free(out) }
            return decodeRustJSON(WireSummary.self, from: out)
        }
        if let decoded {
            return MoleCleanSummary(
                totalReclaimed: decoded.total_reclaimed,
                itemCount: decoded.item_count,
                lines: decoded.lines,
                isDryRun: decoded.is_dry_run
            )
        }

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
        return await Task.detached(priority: .userInitiated) {
            struct AppMetadata: Decodable {
                let name: String
                let bundle_id: String
                let path: String
            }

            guard let raw = upkeep_scan_applications_metadata_json() else { return [] }
            defer { upkeep_string_free(raw) }
            return (decodeRustJSON([AppMetadata].self, from: raw) ?? []).map { app in
                MoleInstalledApp(
                    name: app.name,
                    bundleId: app.bundle_id.isEmpty ? nil : app.bundle_id,
                    source: "Applications",
                    uninstallName: app.name,
                    path: app.path,
                    size: nil
                )
            }
        }.value
    }

    /// Full parallel scanner of /Applications and ~/Applications with APFS-accurate bundle sizes.
    public static func scanInstalledApplications() async -> [MoleInstalledApp] {
        await sizeInstalledApplications(scanInstalledApplicationsMetadata())
    }

    static func sizeInstalledApplications(_ apps: [MoleInstalledApp]) async -> [MoleInstalledApp] {
        let paths = apps.map(\.path)
        let sizes = await calculatePathSizes(paths)
        return zip(apps, sizes).map { app, size in
            MoleInstalledApp(
                name: app.name,
                bundleId: app.bundleId,
                source: app.source,
                uninstallName: app.uninstallName,
                path: app.path,
                size: size
            )
        }
    }

    private static func calculatePathSizes(_ paths: [String]) async -> [Int64] {
        guard !paths.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let allocated = paths.map { strdup($0) }
            defer { for pointer in allocated { free(pointer) } }
            if allocated.allSatisfy({ $0 != nil }) {
                let input = allocated.map { $0.map { UnsafePointer($0) } }
                var output = [UInt64](repeating: 0, count: input.count)
                if upkeep_calculate_path_sizes(input, &output, input.count) {
                    return output.map { Int64(clamping: $0) }
                }
            }
            return paths.map { calculatePathSize(atPath: $0) }
        }.value
    }

    /// Computes accurate physical disk usage for a single file or directory path.
    public static func calculatePathSize(atPath path: String) -> Int64 {
        return path.withCString { cstr in
            Int64(upkeep_calculate_path_size(cstr))
        }
    }

    /// Parallel Rust Uninstaller inspector (Mole-parity leftovers + APFS sizes + Caskroom match).
    public static func inspectAppForUninstallRust(
        app: MoleInstalledApp,
        brewPrefix: String = "/opt/homebrew"
    ) async -> UninstallInspection? {
        return await Task.detached(priority: .userInitiated) {
            struct WireLeftover: Decodable {
                let path: String
                let display_path: String
                let category: String
                let size_bytes: UInt64
                let is_system: Bool?
                let default_selected: Bool?
                let holdback_reason: String?
            }
            struct WirePayload: Decodable {
                let leftovers: [WireLeftover]
                let homebrew_cask_token: String?
                let has_sibling_app: Bool?
                let official_uninstaller_vendor: String?
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
            guard let decoded = decodeRustJSON(WirePayload.self, from: rawPtr) else {
                return nil
            }
            let leftovers = decoded.leftovers.map {
                UninstallLeftoverItem(
                    path: $0.path,
                    displayPath: $0.display_path,
                    category: $0.category,
                    sizeBytes: Int64($0.size_bytes),
                    isSystem: $0.is_system ?? false,
                    defaultSelected: $0.default_selected ?? true,
                    holdbackReason: $0.holdback_reason
                )
            }
            return UninstallInspection(
                app: app,
                leftovers: leftovers,
                homebrewCaskToken: decoded.homebrew_cask_token,
                hasSiblingApp: decoded.has_sibling_app ?? false,
                officialUninstallerVendor: decoded.official_uninstaller_vendor
            )
        }.value
    }

    /// Comprehensive native macOS Cleaner dry-run scanner (~50-150ms via Rust getattrlistbulk + Rayon).
    public static func scanCleanerNative() async -> CleanerScanResult {
        return await Task.detached(priority: .userInitiated) {
            struct WireCleanerItem: Decodable {
                let id: String
                let category: String
                let name: String
                let path: String
                let display_path: String
                let size_bytes: UInt64
                let default_selected: Bool
                let holdback_reason: String?
                let requires_admin: Bool?
            }
            struct WireCleanerCategory: Decodable {
                let id: String
                let title: String
                let total_bytes: UInt64
                let items: [WireCleanerItem]
            }
            struct WireCleanerPayload: Decodable {
                let total_bytes: UInt64
                let selected_bytes: UInt64
                let item_count: Int
                let scan_duration_ms: UInt64
                let categories: [WireCleanerCategory]
            }
            guard let rawPtr = upkeep_scan_cleaner_json() else {
                return CleanerScanResult.empty
            }
            defer { upkeep_string_free(rawPtr) }
            guard let payload = decodeRustJSON(WireCleanerPayload.self, from: rawPtr) else {
                return CleanerScanResult.empty
            }
            let categories = payload.categories.map { cat in
                CleanerCategory(
                    id: cat.id,
                    title: cat.title,
                    totalBytes: Int64(cat.total_bytes),
                    items: cat.items.map { item in
                        CleanerItem(
                            id: item.id,
                            category: item.category,
                            name: item.name,
                            path: item.path,
                            displayPath: item.display_path,
                            sizeBytes: Int64(item.size_bytes),
                            defaultSelected: item.default_selected,
                            holdbackReason: item.holdback_reason,
                            requiresAdmin: item.requires_admin ?? false
                        )
                    }
                )
            }
            return CleanerScanResult(
                totalBytes: Int64(payload.total_bytes),
                selectedBytes: Int64(payload.selected_bytes),
                itemCount: payload.item_count,
                scanDurationMs: Int(payload.scan_duration_ms),
                categories: categories
            )
        }.value
    }

    /// Safe parallel native Rust Cleaner executor with strict allowlist & symlink guards.
    public static func cleanPathsNative(_ paths: [String], dryRun: Bool = false) async -> CleanExecutionResult {
        return await Task.detached(priority: .userInitiated) {
            struct WireFailedItem: Decodable {
                let path: String
                let error: String
            }
            struct WireExecPayload: Decodable {
                let reclaimed_bytes: UInt64
                let removed_count: Int
                let failed_items: [WireFailedItem]
                let duration_ms: UInt64
                let dry_run: Bool
            }
            guard let jsonData = try? JSONEncoder().encode(paths),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                return CleanExecutionResult.empty(dryRun: dryRun)
            }
            let rawPtr: UnsafeMutablePointer<CChar>? = jsonStr.withCString { cstr in
                upkeep_clean_paths_json(cstr, dryRun)
            }
            guard let rawPtr else {
                return CleanExecutionResult.empty(dryRun: dryRun)
            }
            defer { upkeep_string_free(rawPtr) }
            guard let payload = decodeRustJSON(WireExecPayload.self, from: rawPtr) else {
                return CleanExecutionResult.empty(dryRun: dryRun)
            }
            return CleanExecutionResult(
                reclaimedBytes: Int64(payload.reclaimed_bytes),
                removedCount: payload.removed_count,
                failedItems: payload.failed_items.map { CleanFailedItem(path: $0.path, error: $0.error) },
                durationMs: Int(payload.duration_ms),
                dryRun: payload.dry_run
            )
        }.value
    }
}
