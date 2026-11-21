#ifndef UPKEEP_CORE_H
#define UPKEEP_CORE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BrewSearchIndex BrewSearchIndex;

typedef struct {
    uint32_t index;
    uint32_t score;
} UpkeepMatch;

typedef struct {
    char name[256];
    char bundle_id[256];
    char path[1024];
    uint64_t app_size_bytes;
} UpkeepAppRecord;

/// Creates a new in-memory nucleo fuzzy search index for Homebrew packages.
BrewSearchIndex *upkeep_brew_index_new(void);

/// Frees a BrewSearchIndex instance.
void upkeep_brew_index_free(BrewSearchIndex *ptr);

/// Returns the number of indexed packages currently loaded.
uint32_t upkeep_brew_index_count(const BrewSearchIndex *ptr);

/// Loads a JSON array of BrewPackage objects into the index. Returns count loaded.
uint32_t upkeep_brew_index_load_json(BrewSearchIndex *ptr, const char *json_utf8);

/// Zero-copy raw byte slice loader for Homebrew formula.json and cask.json arrays,
/// merging installed/pinned/outdated state from the local Homebrew prefix in parallel.
uint32_t upkeep_brew_index_load_api_bytes(
    BrewSearchIndex *ptr,
    const uint8_t *formulae_bytes,
    size_t formulae_len,
    const uint8_t *casks_bytes,
    size_t casks_len,
    const char *prefix_utf8
);

/// Loads Homebrew official formula.json and cask.json C strings into the index,
/// merging installed/pinned/outdated state from the local Homebrew prefix. Returns count loaded.
uint32_t upkeep_brew_index_load_api_json(
    BrewSearchIndex *ptr,
    const char *formulae_json_utf8,
    const char *casks_json_utf8,
    const char *prefix_utf8
);

/// Returns all installed packages from the merged API + local index as JSON (sorted by name).
char *upkeep_brew_index_installed_json(const BrewSearchIndex *ptr);

/// Searches the index with parallel nucleo fuzzy matching. Returns a newly allocated JSON string.
/// Filter mode: -1 = all, 0 = formulae only, 1 = casks only.
char *upkeep_brew_index_search_json(
    const BrewSearchIndex *ptr,
    const char *query_utf8,
    uint32_t limit,
    int32_t filter_mode
);

/// Zero-allocation parallel search: writes top matches into caller-allocated UpkeepMatch array.
/// Returns number of matches written.
uint32_t upkeep_brew_index_search_fast(
    const BrewSearchIndex *ptr,
    const char *query_utf8,
    int32_t filter_mode,
    UpkeepMatch *out_matches,
    uint32_t capacity
);

/// Single-pair nucleo fuzzy score (thread-local Matcher). Returns -1 when there is no match.
int32_t upkeep_fuzzy_score(const char *query_utf8, const char *candidate_utf8);

/// Phase 1 instant parallel scan of /Applications and ~/Applications (metadata + bundle ID only).
uint32_t upkeep_scan_applications_metadata(
    UpkeepAppRecord *out_apps,
    uint32_t capacity
);

/// Full parallel scan of /Applications and ~/Applications using Rayon + macOS getattrlistbulk.
uint32_t upkeep_scan_applications(
    UpkeepAppRecord *out_apps,
    uint32_t capacity
);

/// Computes APFS-accurate physical disk usage for a single file or directory path.
uint64_t upkeep_calculate_path_size(const char *path_utf8);

/// Parallel Uninstaller inspector: discovers ~/Library leftovers with APFS sizes
/// and matches Homebrew Caskroom tokens. Returns newly allocated JSON string.
char *upkeep_inspect_app_uninstall_json(
    const char *app_name_utf8,
    const char *bundle_id_utf8,
    const char *app_path_utf8,
    const char *brew_prefix_utf8
);

/// Parallel scan of Homebrew Cellar, Caskroom, and pinned kegs on disk.
/// Returns a newly allocated JSON array of installed packages.
char *upkeep_scan_brew_dirs_json(const char *prefix_utf8);

/// Strips ANSI escape codes from CLI output. Returns newly allocated UTF-8 string.
char *upkeep_strip_ansi(const char *raw_utf8);

/// SIMD-accelerated ASCII check.
bool upkeep_is_ascii(const char *raw_utf8, uint32_t len);

/// Parses `mo clean` / `mo clean --dry-run` output (Mole 1.73+) into JSON summary.
char *upkeep_parse_mole_clean_json(const char *raw_utf8, bool is_dry_run);

/// Frees any string returned by upkeep_* functions.
void upkeep_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* UPKEEP_CORE_H */
