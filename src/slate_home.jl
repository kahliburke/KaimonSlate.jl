"""
    SlateHome

KaimonSlate's OWN XDG homes — deliberately separate from Kaimon's config dir and from the Julia
depot, both of which are hazardous places to keep our state:

- Kaimon's `~/.config/kaimon/` is *its* config dir, not ours — our prefs don't belong there.
- a Julia depot scratchspace (`<depot>/scratchspaces/…`) can be **garbage-collected** by Julia,
  which would silently reclaim a user's staged local sites.

Three homes, each env-overridable, all under a `kaimonslate/` namespace:

| home       | default (`\$XDG_…` fallback shown)              | holds                                            |
|------------|------------------------------------------------|--------------------------------------------------|
| **config** | `\$XDG_CONFIG_HOME/kaimonslate` (`~/.config/…`) | prefs (`slate.json`), secrets, ledger-id cache   |
| **data**   | `\$XDG_DATA_HOME/kaimonslate` (`~/.local/share/…`) | ledger working checkout (durable, NOT a cache) |
| **cache**  | `\$XDG_CACHE_HOME/kaimonslate` (`~/.cache/…`)   | local site builds (`sites/<name>/`, regenerable) |

Resolution precedence, most-specific first, for each home:

1. `KAIMONSLATE_<HOME>_HOME`  — per-home override (`KAIMONSLATE_CONFIG_HOME`, `_DATA_HOME`, `_CACHE_HOME`)
2. `KAIMONSLATE_HOME/<sub>`   — single shortcut that sets all three (`config/`, `data/`, `cache/` subdirs)
3. `\$XDG_<TYPE>_HOME/kaimonslate` — standard XDG base dir
4. `~/.config` | `~/.local/share` | `~/.cache` `/kaimonslate` — XDG defaults when the var is unset

Every entry is a *function* (not a const) so it re-reads `ENV` — tests point the vars at a tempdir.
"""
module SlateHome

const _NS = "kaimonslate"

# ── Resolver ──────────────────────────────────────────────────────────────────────────────────────
# One helper drives all three homes; `home_sub` is the subdir under `KAIMONSLATE_HOME`, `xdg_var`/
# `xdg_default` the standard XDG base and its default relative to `homedir()`.
function _resolve(home_override::AbstractString, home_sub::AbstractString,
                  xdg_var::AbstractString, xdg_default::AbstractString)
    v = get(ENV, home_override, "")
    isempty(v) || return abspath(expanduser(v))
    h = get(ENV, "KAIMONSLATE_HOME", "")
    isempty(h) || return joinpath(abspath(expanduser(h)), home_sub)
    base = get(ENV, xdg_var, joinpath(homedir(), xdg_default))
    return joinpath(base, _NS)
end

"KaimonSlate's config home — prefs, secrets, the ledger-id cache."
config_home() = _resolve("KAIMONSLATE_CONFIG_HOME", "config", "XDG_CONFIG_HOME", ".config")

"KaimonSlate's data home — the durable ledger working checkout (NOT a cache; never GC'd)."
data_home() = _resolve("KAIMONSLATE_DATA_HOME", "data", "XDG_DATA_HOME", joinpath(".local", "share"))

"KaimonSlate's cache home — regenerable local site builds; safe to delete."
cache_home() = _resolve("KAIMONSLATE_CACHE_HOME", "cache", "XDG_CACHE_HOME", ".cache")

# ── Named locations under the homes ─────────────────────────────────────────────────────────────
"Path to the prefs file (moved off Kaimon's config dir)."
config_file() = joinpath(config_home(), "slate.json")

"Path to the (gitignored) secret store — referenced by `secretRef`, never in the ledger."
secrets_file() = joinpath(config_home(), "secrets.json")

"The durable ledger working checkout under the data home."
ledger_dir() = joinpath(data_home(), "ledger")

"""
Local site-build directory. `KAIMONSLATE_SITES_DIR` is the most-specific override (kept from the old
API and used by tests); otherwise it's `sites/` under the cache home.
"""
sites_dir() = get(ENV, "KAIMONSLATE_SITES_DIR", joinpath(cache_home(), "sites"))

"Durable per-cell declared-effect records (`EffectStore`), keyed by cell source digest."
effects_dir() = joinpath(cache_home(), "effects")

"`mkpath` each home that will be written to; returns the three paths."
function ensure_homes!()
    for d in (config_home(), data_home(), cache_home())
        try; mkpath(d); catch e; @warn "SlateHome: could not create home dir" dir = d exception = e; end
    end
    return (; config = config_home(), data = data_home(), cache = cache_home())
end

end # module SlateHome
