# ── PyPI anywidget installer ──────────────────────────────────────────────────────────────────────────
# Host a *published* anywidget (an `anywidget.AnyWidget` subclass on PyPI) unchanged. SlateAFM takes NO
# Python dependency: this shells out to whatever `python3 -m pip` is on PATH to (1) install the package into
# a cached scratch env and (2) read three CLASS ATTRIBUTES off the widget — `_esm`, `_css`, and the default
# values of its `sync=True` traits. NO widget instantiation, no kernel, no comm. The extracted ESM + CSS are
# written into a served DEPLOY dir and handed to `afm(...)` like any other module URL. If no usable pip is
# found, `pypi_afm` errors with the manual fallbacks (a CDN URL or `ext_asset_url`) — the rest of SlateAFM
# never touches Python.

# Served under `/ext-assets/<_PYPI_KEY>/…`; a fetched widget lands in `<deploy>/served/<pkg__class>/`.
const _PYPI_KEY = "SlateAFMpypi"

"""
    SlateAFM.deploy_dir() -> String

The directory fetched PyPI widgets are installed + served from. Defaults to
`<depot>/slate_afm/pypi`; override with `ENV["SLATE_AFM_DEPLOY"]`. Created on first use.
"""
deploy_dir() = get(ENV, "SLATE_AFM_DEPLOY") do
    joinpath(first(DEPOT_PATH), "slate_afm", "pypi")
end
_served_root() = joinpath(deploy_dir(), "served")   # registered with provide_assets! (the /ext-assets root)
_envs_root()   = joinpath(deploy_dir(), "envs")     # pip --target scratch envs (NOT served)

# The introspection program, run once per package by the system Python. Reads _esm/_css/trait-defaults off
# the class and writes esm.js / css/widget.css / meta.json into `outdir`. argv: import-name, class, outdir.
const _INTROSPECT_PY = raw"""
import importlib, inspect, json, os, pathlib, sys
import_name, want_class, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import anywidget
except Exception as e:
    print("SLATE_AFM_ERR: could not import anywidget (%s)" % e, file=sys.stderr); sys.exit(2)
mod = importlib.import_module(import_name)
widgets = {n: o for n, o in vars(mod).items()
           if inspect.isclass(o) and issubclass(o, anywidget.AnyWidget) and o is not anywidget.AnyWidget}
if not widgets:
    print("SLATE_AFM_ERR: no anywidget.AnyWidget subclass exported by '%s'" % import_name, file=sys.stderr); sys.exit(3)
if want_class:
    if want_class not in widgets:
        print("SLATE_AFM_ERR: class '%s' not found. Available: %s" % (want_class, ", ".join(sorted(widgets))), file=sys.stderr); sys.exit(4)
    cname, cls = want_class, widgets[want_class]
elif len(widgets) == 1:
    cname, cls = next(iter(widgets.items()))
else:
    print("SLATE_AFM_ERR: package exports several widgets; pass class=. Available: %s" % ", ".join(sorted(widgets)), file=sys.stderr); sys.exit(5)
def resolve(v):
    if v is None: return None
    if isinstance(v, pathlib.Path): return v.read_text()
    s = str(v)
    try:
        p = pathlib.Path(s)
        if len(s) < 4096 and p.exists() and p.is_file(): return p.read_text()
    except Exception: pass
    return s
esm, css = resolve(getattr(cls, "_esm", None)), resolve(getattr(cls, "_css", None))
if not esm:
    print("SLATE_AFM_ERR: class '%s' has no _esm" % cname, file=sys.stderr); sys.exit(6)
defaults = {}
for tn, tr in cls.class_traits().items():
    if tr.metadata.get("sync"):
        try:
            d = tr.default(); json.dumps(d); defaults[tn] = d
        except Exception:
            pass
os.makedirs(outdir, exist_ok=True)
open(os.path.join(outdir, "esm.js"), "w").write(esm)
css_files = []
if css:
    os.makedirs(os.path.join(outdir, "css"), exist_ok=True)
    open(os.path.join(outdir, "css", "widget.css"), "w").write(css)
    css_files.append("css/widget.css")
json.dump({"class": cname, "css": css_files, "defaults": defaults,
           "version": getattr(mod, "__version__", "")},
          open(os.path.join(outdir, "meta.json"), "w"))
print("SLATE_AFM_OK " + cname)
"""

_sanitize(s::AbstractString) = replace(String(s), r"[^A-Za-z0-9._-]" => "_")

# Resolve the Python interpreter: `python=` arg, then ENV["SLATE_AFM_PYTHON"], then python3/python on PATH.
function _pypi_python(python::AbstractString)
    cand = !isempty(python) ? python : get(ENV, "SLATE_AFM_PYTHON", "")
    isempty(cand) || return cand
    for c in ("python3", "python")
        w = Sys.which(c)
        w === nothing || return w
    end
    error("pypi_afm: no `python3`/`pip` found on PATH. Install Python (it ships pip), pass " *
          "`python=\"/path/to/python\"`, or set ENV[\"SLATE_AFM_PYTHON\"]. Or skip the installer and give " *
          "`afm(...)` a module URL directly — a CDN URL, e.g. afm(\"https://esm.sh/…\"), or `ext_asset_url`.")
end

# Run a command, capturing merged stdout+stderr; return (exitcode, output).
function _run_capture(cmd::Cmd)
    buf = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = buf, stderr = buf))
    return (p.exitcode, String(take!(buf)))
end

# Ensure the package is pip-installed into a per-spec scratch env (cached). Returns the env dir.
function _ensure_env(python::AbstractString, pkgspec::AbstractString; force::Bool)
    envdir = joinpath(_envs_root(), _sanitize(pkgspec))
    marker = joinpath(envdir, ".slate_afm_ok")
    (!force && isfile(marker)) && return envdir
    mkpath(envdir)
    code, out = _run_capture(`$python -m pip install --target $envdir --upgrade --quiet $pkgspec`)
    code == 0 || error("pypi_afm: `pip install $pkgspec` failed (exit $code):\n" * last(out, 1200))
    # anywidget is needed to introspect; pip pulled it as a dep of the widget, but pull it explicitly in case
    # the widget declares it only as a peer.
    _run_capture(`$python -m pip install --target $envdir --quiet anywidget`)
    touch(marker)
    return envdir
end

# Install (if needed) + introspect a PyPI widget; returns (; sub, css_subs, defaults) with `sub`/`css_subs`
# the served subpaths under `_PYPI_KEY`. Cached by (pkg, class): a second call is a fast disk read.
function _resolve_pypi(pkg::AbstractString, class::AbstractString, import_as::AbstractString,
                       python::AbstractString, force::Bool)
    py = _pypi_python(python)
    importname = isempty(import_as) ? replace(match(r"^[A-Za-z0-9_.-]+", String(pkg)).match, "-" => "_") : import_as
    key = _sanitize(String(pkg) * (isempty(class) ? "" : "__" * class))
    outdir = joinpath(_served_root(), key)
    metaf = joinpath(outdir, "meta.json")
    if force || !isfile(metaf)
        mkpath(_served_root())
        envdir = _ensure_env(py, pkg; force = force)
        script = joinpath(envdir, "_slate_afm_introspect.py")
        write(script, _INTROSPECT_PY)
        code, out = _run_capture(addenv(`$py $script $importname $class $outdir`, "PYTHONPATH" => envdir))
        code == 0 || error("pypi_afm: introspecting $pkg failed (exit $code):\n" * last(strip(out), 800))
    end
    meta = JSON.parse(read(metaf, String))
    css_subs = String[key * "/" * String(c) for c in get(meta, "css", String[])]
    defaults = Dict{String,Any}(String(k) => v for (k, v) in get(meta, "defaults", Dict{String,Any}()))
    return (sub = key * "/esm.js", css_subs = css_subs, defaults = defaults, class = String(get(meta, "class", "")))
end

"""
    pypi_afm(pkg; class = "", import_as = "", css = String[], id = "", python = "", force = false, traits...)

Host a **published anywidget** from PyPI. Shells out to the system `python3 -m pip` (no Python dependency in
SlateAFM) to install `pkg` into a cached deploy env and read the widget's `_esm`/`_css`/trait-defaults, then
serves the module and returns a normal [`afm`](@ref) handle. `class` picks the `AnyWidget` subclass (needed
only when a package exports several); `import_as` overrides the import name when it differs from the
distribution name; `css` appends extra stylesheet URLs (e.g. a CDN css the widget assumes); `traits…`
override the widget's defaults; `force = true` re-installs/re-introspects. Errors with the manual fallbacks
if no pip is found — see [`deploy_dir`](@ref) for where things land.

```julia
@bind mol pypi_afm("ipymolstar"; class = "PDBeMolStar", molecule_id = "1cbs", spin = false)
```
"""
function pypi_afm(pkg::AbstractString; class::AbstractString = "", import_as::AbstractString = "",
                  css = String[], id::AbstractString = "", python::AbstractString = "",
                  force::Bool = false, traits...)
    spec = _resolve_pypi(pkg, class, import_as, python, force)
    provide_assets!(_PYPI_KEY, _served_root())   # (re)register the deploy root so it's served this session
    merged = copy(spec.defaults)
    for (k, v) in traits
        merged[String(k)] = v
    end
    csslist = String[ext_asset_url(_PYPI_KEY, c) for c in spec.css_subs]
    append!(csslist, css isa AbstractString ? [String(css)] : String[String(c) for c in css])
    return afm(ext_asset_url(_PYPI_KEY, spec.sub);
               id = id, css = csslist, (Symbol(k) => v for (k, v) in merged)...)
end
