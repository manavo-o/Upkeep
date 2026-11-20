#ifndef SPOTLIGHT_CORE_H
#define SPOTLIGHT_CORE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BrewSearchIndex BrewSearchIndex;

typedef struct {
    uint32_t index;
    uint32_t score;
} SpotlightMatch;

typedef struct {
    char name[256];
    char bundle_id[256];
    char path[1024];
    uint64_t app_size_bytes;
} SpotlightAppRecord;

/// Creates a new in-memory nucleo fuzzy search index for Homebrew packages.
BrewSearchIndex *spotlight_brew_index_new(void);

/// Frees a BrewSearchIndex instance.
void spotlight_brew_index_free(BrewSearchIndex *ptr);

/// Loads a JSON array of BrewPackage objects into the index. Returns count loaded.
uint32_t spotlight_brew_index_load_json(BrewSearchIndex *ptr, const char *json_utf8);

/// Loads Homebrew official formula.json and cask.json arrays directly into the index,
/// merging installed/pinned state from the local Homebrew prefix. Returns count loaded.
uint32_t spotlight_brew_index_load_api_json(
    BrewSearchIndex *ptr,
    const char *formulae_json_utf8,
    const char *casks_json_utf8,
    const char *prefix_utf8
);

/// Searches the index with parallel nucleo fuzzy matching. Returns a newly allocated JSON string.
/// Filter mode: -1 = all, 0 = formulae only, 1 = casks only.
char *spotlight_brew_index_search_json(
    const BrewSearchIndex *ptr,
    const char *query_utf8,
    uint32_t limit,
    int32_t filter_mode
);

/// Zero-allocation parallel search: writes top matches into caller-allocated SpotlightMatch array.
/// Returns number of matches written.
uint32_t spotlight_brew_index_search_fast(
    const BrewSearchIndex *ptr,
    const char *query_utf8,
    int32_t filter_mode,
    SpotlightMatch *out_matches,
    uint32_t capacity
);

/// Single-pair nucleo fuzzy score. Returns -1 when there is no match.
int32_t spotlight_fuzzy_score(const char *query_utf8, const char *candidate_utf8);

/// Parallel scan of /Applications and ~/Applications using Rayon.
/// Writes up to capacity records into out_apps with APFS-accurate sizes and Info.plist bundle IDs.
/// Returns total number of applications written.
uint32_t spotlight_scan_applications(
    SpotlightAppRecord *out_apps,
    uint32_t capacity
);

/// Parallel scan of Homebrew Cellar, Caskroom, pinned kegs, and INSTALL_RECEIPT.json on disk.
/// Returns a newly allocated JSON array of installed packages.
char *spotlight_scan_brew_dirs_json(const char *prefix_utf8);

/// Strips ANSI escape codes from CLI output. Returns newly allocated UTF-8 string.
char *spotlight_strip_ansi(const char *raw_utf8);

/// SIMD-accelerated ASCII check.
bool spotlight_is_ascii(const char *raw_utf8, uint32_t len);

/// Parses `mo clean` / `mo clean --dry-run` output (Mole 1.73+) into JSON summary.
char *spotlight_parse_mole_clean_json(const char *raw_utf8, bool is_dry_run);

/// Frees any string returned by spotlight_* functions.
void spotlight_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* SPOTLIGHT_CORE_H */
