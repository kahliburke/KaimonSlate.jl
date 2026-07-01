# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Static export (HTML / print-to-PDF) ──────────────────────────────────────
# A self-contained HTML document of the notebook: markdown rendered, code shown,
# outputs embedded (images as base64), client-rendered ECharts frozen to their latest
# snapshot PNG, interactive tables flattened to static HTML. KaTeX from a CDN typesets
# math. No server, no scripts to boot — openable offline and printable to PDF.
# Theme palettes (`:root` vars) + syntax-highlight colours for the two export themes. `dark` matches
# the live UI; `light` is publication-style (matches the PDF's light default). The structural CSS below
# is theme-agnostic (all colours flow through the vars / `.hl-*` rules).
const _EXPORT_THEMES = Dict(
    "dark" => (root = "--bg:#0d1120;--bg2:#141828;--bg3:#1a1e2e;--border:#2a2e40;--text:#d4d8e8;--dim:#6a7090;--accent:#569cd6;--green:#56d364;--red:#e57575;--gold:#ffd700;--titlefg:#ffffff;",
               hl = ".hl-kw{color:#c586c0;} .exp-src .hl-com{color:#6a9955;font-style:italic;} .exp-src .hl-num{color:#b5cea8;} .exp-src .hl-str{color:#ce9178;} .exp-src .hl-macro{color:#569cd6;} .exp-src .hl-op{color:#56b6c2;} .exp-src .hl-fn{color:#dcdcaa;} .exp-src .hl-type{color:#4ec9b0;} .exp-src .hl-sym{color:#d19a66;}"),
    "light" => (root = "--bg:#ffffff;--bg2:#f6f7f9;--bg3:#eceef2;--border:#d8dce4;--text:#1f2430;--dim:#68708a;--accent:#2660a4;--green:#1a7f37;--red:#b4232a;--gold:#8a6d00;--titlefg:#0b0e16;",
                hl = ".hl-kw{color:#af00db;} .exp-src .hl-com{color:#008000;font-style:italic;} .exp-src .hl-num{color:#098658;} .exp-src .hl-str{color:#a31515;} .exp-src .hl-macro{color:#0000ff;} .exp-src .hl-op{color:#0451a5;} .exp-src .hl-fn{color:#795e26;} .exp-src .hl-type{color:#267f99;} .exp-src .hl-sym{color:#b26900;}"))

# Code-listing font size, mirroring the PDF's `code` option.
_export_code_size(code) = get(Dict("normal" => ".82rem", "small" => ".76rem", "smaller" => ".70rem", "tiny" => ".64rem"), String(code), ".82rem")

function _export_css(theme::AbstractString = "dark", code::AbstractString = "normal")
    t = get(_EXPORT_THEMES, lowercase(String(theme)), _EXPORT_THEMES["dark"])
    return """
:root{$(t.root)}
*{box-sizing:border-box;} body{background:var(--bg);color:var(--text);margin:0;
  font-family:'Segoe UI',system-ui,sans-serif;line-height:1.6;}
.export{max-width:900px;margin:0 auto;padding:36px 24px 80px;}
.exp-title{color:var(--titlefg);font-size:1.9rem;margin:0 0 2px;}
.exp-titleblock{text-align:center;padding:8px 0 4px;}
.exp-subtitle{color:var(--text);font-size:1.2rem;margin-top:4px;}
.exp-byline{color:var(--dim);font-size:.86rem;margin-top:8px;}
.exp-abstract{max-width:680px;margin:16px auto 0;text-align:left;font-size:.92rem;font-style:italic;
  color:var(--text);border-top:1px solid var(--border);border-bottom:1px solid var(--border);padding:12px 0;}
.exp-abslabel{display:block;font-style:normal;font-size:.7rem;text-transform:uppercase;letter-spacing:.09em;
  font-weight:700;color:var(--accent);margin-bottom:5px;text-align:left;}
.exp-md{margin:14px 0;} .exp-md h1{font-size:1.6rem;border-bottom:1px solid var(--border);padding-bottom:.2em;}
.exp-figcap{margin:2px 24px 16px;font-size:.85rem;color:var(--dim);line-height:1.5;}
.exp-figcap b{color:var(--text);}.exp-figcap p{display:inline;margin:0;}
.exp-chart{margin:14px 0;}
.exp-refs{margin-top:28px;border-top:1px solid var(--border);padding-top:8px;font-size:.9rem;}
.exp-refs h2{font-size:1.1rem;}
.exp-run{text-align:center;margin:10px 0 4px;}
#exp-run-btn{background:var(--accent);color:#fff;border:none;border-radius:6px;padding:8px 16px;
  font-size:.92rem;cursor:pointer;font-family:inherit;}
#exp-run-btn:hover{filter:brightness(1.1);}
#exp-run-bg{display:none;position:fixed;inset:0;background:#000a;align-items:center;justify-content:center;z-index:50;}
.exp-run-modal{background:var(--bg2);border:1px solid var(--border);border-radius:12px;max-width:640px;
  width:92%;padding:22px 26px;color:var(--text);}
.exp-run-modal h2{margin:0 0 8px;font-size:1.2rem;color:var(--titlefg);}
.exp-run-modal a{color:var(--accent);}
.exp-run-cmd{background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:10px 12px;overflow-x:auto;}
.exp-run-cmd code{font-family:'Cascadia Code','Fira Code',monospace;font-size:.8rem;white-space:pre-wrap;word-break:break-all;color:var(--text);}
.exp-run-row{display:flex;gap:8px;justify-content:flex-end;margin-top:14px;}
.exp-run-row button{background:var(--bg3);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:6px 14px;cursor:pointer;font-family:inherit;}
.exp-md table,.exp-table{border-collapse:collapse;margin:8px 0;font-size:.84rem;}
.exp-md td,.exp-md th,.exp-table td,.exp-table th{border:1px solid var(--border);padding:4px 10px;text-align:left;}
.exp-table th{background:var(--bg3);color:var(--dim);} .exp-table td{font-variant-numeric:tabular-nums;}
.exp-md code{background:var(--bg3);padding:1px 5px;border-radius:4px;}
.exp-code{margin:14px 0;border:1px solid var(--border);border-radius:8px;background:var(--bg2);overflow:hidden;}
.exp-src{margin:0;padding:10px 14px;background:var(--bg3);border-bottom:1px solid var(--border);overflow-x:auto;}
.exp-src code{font-family:'Cascadia Code','Fira Code',monospace;font-size:$(_export_code_size(code));color:var(--text);white-space:pre;}
.exp-src $(t.hl)
.exp-out{font-size:.86rem;} .exp-out .out,.exp-out .val,.exp-out .err{padding:8px 14px;}
.exp-out .out{color:var(--dim);} .exp-out .val{color:var(--green);} .exp-out .err{color:var(--red);}
.exp-out pre{margin:0;white-space:pre-wrap;} .exp-out .dispwrap,.disp.img{padding:10px 14px;}
.disp.img img{max-width:100%;height:auto;border-radius:4px;display:block;}
.disp.latex{padding:6px 14px;overflow-x:auto;} .katex{font-size:1.1em;}
@media print{ body{-webkit-print-color-adjust:exact;print-color-adjust:exact;} .exp-code{break-inside:avoid;} }
"""
end

function _export_table_html(spec)
    cols = get(spec, "columns", Any[])
    rows = get(spec, "rows", Any[])
    io = IOBuffer()
    print(io, "<table class=\"exp-table\"><thead><tr>")
    for c in cols
        nm = c isa AbstractDict ? get(c, "name", "") : c
        print(io, "<th>", _esc(string(nm)), "</th>")
    end
    print(io, "</tr></thead><tbody>")
    for r in rows
        print(io, "<tr>")
        for v in r
            print(io, "<td>", v === nothing ? "" : _esc(string(v)), "</td>")
        end
        print(io, "</tr>")
    end
    print(io, "</tbody></table>")
    return String(take!(io))
end

# Server-side Julia syntax highlighting for the SELF-CONTAINED export: tokenize with the
# `JuliaSyntax` bundled in Base (no dependency, no JS, works offline) and wrap each interesting
# token in a `<span class="hl-…">`; whitespace/punctuation pass through as escaped text. A macro
# call (`@name`) colours both the `@` and the following name. Any tokenizer hiccup falls back to
# plain escaped source, so a syntactically-incomplete cell still exports.
function _highlight_julia(code::AbstractString)
    isempty(code) && return ""
    try
        JS = Base.JuliaSyntax
        cu = codeunits(code)                 # token ranges are BYTE ranges (char-aligned), so slice
        toks = collect(JS.tokenize(code))    # bytes — `code[range]` throws when a token follows a
        kinds = [string(JS.kind(t)) for t in toks]   # multibyte char like λ/π/θ (mid-char index).
        n = length(toks)
        io = IOBuffer()
        prev_at = false                       # last token was `@` → this one is the macro name
        prev_sym = false                      # last token was a quote-colon → this one completes `:name`
        for i in 1:n
            t = toks[i]; txt = String(cu[t.range]); k = JS.kind(t); ks = kinds[i]
            nextk = i < n ? kinds[i+1] : ""   # IMMEDIATE next (no skip) — call/symbol have no space
            # `*` `^` `'` `/` `<` … tokenize as identifiers, not operator kinds — catch them too.
            is_op_id = ks == "Identifier" && Base.isoperator(Symbol(txt))
            cls = JS.is_keyword(k) ? "kw" :
                  ks == "Comment" ? "com" :
                  (prev_at || ks == "@") ? "macro" :
                  prev_sym ? "sym" :
                  (ks == ":" && nextk == "Identifier") ? "sym" :        # :gray  :cyan  :dash
                  JS.is_number(k) ? "num" :
                  (occursin("String", ks) || occursin("Char", ks) || ks in ("\"", "`")) ? "str" :
                  (ks == "Identifier" && !is_op_id && nextk == "(") ? "fn" :   # f(…)  lines!(…)
                  (is_op_id || JS.is_operator(k)) ? "op" :
                  (ks == "Identifier" && !isempty(txt) && isuppercase(first(txt))) ? "type" : ""
            prev_at = (ks == "@")
            prev_sym = (cls == "sym" && ks == ":")
            isempty(cls) ? print(io, _esc(txt)) :
                print(io, "<span class=\"hl-", cls, "\">", _esc(txt), "</span>")
        end
        return String(take!(io))
    catch
        return _esc(code)
    end
end

function export_html(nb::LiveNotebook; include_source::Bool = true,
                     theme::AbstractString = "dark", code::AbstractString = "normal",
                     outputs::AbstractString = "all", og_image::AbstractString = "", runnable::Bool = false)
    show_source = include_source && lowercase(String(code)) != "hidden"   # `code=hidden` ⇒ outputs only
    lock(nb.lock) do
        fm0 = report_frontmatter(nb.report)
        title = _esc(fm0.title)
        # Open Graph / Twitter card metadata: once this page is HOSTED at a URL, a link pasted into
        # Slack / Discourse / iMessage / etc. unfurls into a rich card (title + description + image). Inert
        # on a downloaded file (no URL to fetch), harmless — lights up when published. `og_image` is a URL
        # or a path relative to the page (the site builder writes an `og-image.png` next to index.html).
        desc = _esc(_first_words(isempty(strip(fm0.abstract)) ? fm0.byline : fm0.abstract, 40))
        img = isempty(strip(og_image)) ? "" :
            "<meta property=\"og:image\" content=\"$(_esc(og_image))\"/><meta name=\"twitter:image\" content=\"$(_esc(og_image))\"/>"
        io = IOBuffer()
        print(io, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"/>",
              "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"/><title>", title, "</title>",
              "<meta property=\"og:type\" content=\"article\"/><meta property=\"og:title\" content=\"", title, "\"/>",
              (isempty(desc) ? "" : "<meta property=\"og:description\" content=\"$desc\"/><meta name=\"description\" content=\"$desc\"/>"),
              img,
              "<meta name=\"twitter:card\" content=\"", isempty(img) ? "summary" : "summary_large_image", "\"/><meta name=\"generator\" content=\"Kaimon Slate\"/>",
              "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css\"/>",
              "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js\"></script>",
              "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js\"></script>",
              # ECharts renders CLIENT-SIDE from the embedded specs below (real charts with data), instead
              # of freezing to a server snapshot that headless exports can't capture.
              "<script src=\"https://cdn.jsdelivr.net/npm/echarts@5.5.1/dist/echarts.min.js\"></script>",
              "<style>", _export_css(theme, code), "</style></head><body><article class=\"export\">")
        charts = Tuple{String,String}[]   # (dom id, option JSON) collected across cells → rendered at the end
        # Role-tagged metadata → a title block at the top; the hoisted cells are dropped from the
        # body (mirrors the PDF/Typst export).
        fm = fm0
        figidx = figure_index(nb.report)
        # Rewrite `[@cite]` → its in-text form (per bibstyle) and `[@fig:label]` → "Figure N" so the
        # static page reads like the live view / PDF instead of showing raw markers.
        citectx = _md_cite_ctx(nb)
        citekeys = citectx === nothing ? Set{String}() : citectx.citekeys
        citemit = citectx === nothing ? _cite_literal : citectx.emit
        rw(s) = _rewrite_citations(s, citekeys; emit = citemit, figrefs = figidx.labels, figemit = _fig_text)
        print(io, "<header class=\"exp-titleblock\"><h1 class=\"exp-title\">",
              _esc(fm.title), "</h1>")
        isempty(strip(fm.subtitle)) || print(io, "<div class=\"exp-subtitle\">", _esc(fm.subtitle), "</div>")
        isempty(strip(fm.byline)) || print(io, "<div class=\"exp-byline\">", _esc(fm.byline), "</div>")
        if !isempty(strip(fm.abstract))
            print(io, "<div class=\"exp-abstract\"><span class=\"exp-abslabel\">Abstract</span>",
                  markdown_html(rw(fm.abstract), CellOutput[]), "</div>")
        end
        runnable && print(io, "<div class=\"exp-run\"><button id=\"exp-run-btn\">▶ Run this notebook live</button></div>")
        print(io, "</header>")
        for c in nb.report.cells
            # A collapsed (folded ▸) cell is tucked away entirely in the notebook — omit it from
            # the export too (both code and output), for markdown and code alike.
            (:collapsed in c.flags) && continue
            c.id in fm.skip && continue              # hoisted into the title block above
            (:bibliography in c.flags) && continue   # raw BibTeX isn't shown (HTML has no CSL engine yet)
            if c.kind == MARKDOWN
                mdsrc = rw(c.id == fm.titlecell ? _strip_leading_h1(c.source) : c.source)   # citations/refs + hoisted H1
                if haskey(figidx.numbers, c.id)     # caption cell → numbered "Figure N." block
                    print(io, "<figcaption class=\"exp-figcap\" id=\"fig-", _esc(c.id), "\"><b>Figure ",
                          figidx.numbers[c.id], ".</b> ", markdown_html(mdsrc, c.interp), "</figcaption>")
                else
                    print(io, "<section class=\"exp-md\">", markdown_html(mdsrc, c.interp), "</section>")
                end
            else
                print(io, "<section class=\"exp-code\">")
                # Show source only when the NOTEBOOK shows it: respect the global `?source=0` toggle,
                # the per-cell `hidecode` (🙈) flag, AND `@bind` cells (which render their widget,
                # not the code editor, in the browser) — so the export matches what's on screen.
                (show_source && !(:hidecode in c.flags) && isempty(c.binds) && !isempty(strip(c.source))) &&
                    print(io, "<pre class=\"exp-src\"><code>", _highlight_julia(c.source), "</code></pre>")
                if _outputs_any(outputs)
                    # `figures`: only rich display (images/html/latex) — drop scalar text / stdout / errors.
                    o = c.output
                    if _outputs_text_ok(outputs)
                        print(io, "<div class=\"exp-out\">", output_html(c), "</div>")
                    elseif o !== nothing && !isempty(o.display)
                        print(io, "<div class=\"exp-out\"><div class=\"dispwrap\">", ReportRender._render_chunks(o.display), "</div></div>")
                    end
                    for (si, spec) in enumerate(_echarts_specs(c))   # embed each chart's spec → client renders it
                        did = string("chart-", c.id, "-", si)
                        print(io, "<div class=\"exp-chart\" id=\"", did, "\" style=\"width:100%;height:340px\"></div>")
                        push!(charts, (did, JSON.json(spec)))
                    end
                    for spec in _table_specs(c)
                        print(io, _export_table_html(spec))
                    end
                end
                print(io, "</section>")
            end
        end
        # References — rendered from the bibliography cells (the raw BibTeX cell itself is skipped above).
        refs = _md_references(citectx)
        isempty(strip(refs)) || print(io, "<section class=\"exp-md exp-refs\">", markdown_html(refs, CellOutput[]), "</section>")
        print(io, "</article>")
        # "Run this live" overlay: a one-liner (built from the page's own URL so it works wherever the
        # site is hosted) + download links for the launch script and the reproducible bundle.
        if runnable
            print(io, "<div id=\"exp-run-bg\"><div class=\"exp-run-modal\">",
                  "<h2>Run this notebook live</h2>",
                  "<p>Get the full interactive notebook (with the AI agent) on your machine. Needs ",
                  "<a href=\"https://julialang.org/downloads/\" target=\"_blank\" rel=\"noopener\">Julia 1.10+</a>. ",
                  "The script installs Kaimon + KaimonSlate, downloads this notebook's reproducible bundle, and launches it.</p>",
                  "<p><b>One-liner</b> — paste into a terminal:</p>",
                  "<pre class=\"exp-run-cmd\"><code id=\"exp-run-oneliner\"></code></pre>",
                  "<p><b>Or</b> <a id=\"exp-run-dl\" download=\"", _SITE_RUNJL, "\">download run.jl</a> to inspect first, then <code>julia run.jl</code>. ",
                  "Just the env? <a id=\"exp-run-bundle\" download=\"", _SITE_BUNDLE, "\">download the bundle</a>.</p>",
                  "<div class=\"exp-run-row\"><button id=\"exp-run-copy\">Copy one-liner</button><button id=\"exp-run-close\">Close</button></div>",
                  "</div></div>")
        end
        # ECharts: render each embedded spec client-side (real, interactive charts with data). The specs
        # are emitted as a JS array; a resize handler keeps them responsive.
        print(io, "<script>")
        if !isempty(charts)
            echtheme = theme == "dark" ? "'dark'" : "null"   # echarts.init(el, theme) — dark palette or default
            print(io, "var _slateCharts=[", join(("['" * id * "'," * opt * "]" for (id, opt) in charts), ","), "];",
                  "function _slateRenderCharts(){if(!window.echarts)return;_slateCharts.forEach(function(c){",
                  "var el=document.getElementById(c[0]);if(!el)return;var ch=echarts.init(el,", echtheme, ");",
                  "ch.setOption(c[1]);window.addEventListener('resize',function(){ch.resize();});});}",
                  "if(window.echarts)_slateRenderCharts();else window.addEventListener('load',_slateRenderCharts);")
        end
        if runnable
            # Build the one-liner + download links from THIS page's URL, so it works on any host.
            print(io, "(function(){var base=location.href.replace(/[^/]*(\\?.*)?(#.*)?\$/,'');",
                  "var runjl=base+", JSON.json(_SITE_RUNJL), ";var bundle=base+", JSON.json(_SITE_BUNDLE), ";",
                  "var cmd=\"julia -e 'using Downloads; include(Downloads.download(\\\"\"+runjl+\"\\\"))'\";",
                  "var q=function(id){return document.getElementById(id);};",
                  "if(q('exp-run-oneliner'))q('exp-run-oneliner').textContent=cmd;",
                  "if(q('exp-run-dl'))q('exp-run-dl').href=runjl;if(q('exp-run-bundle'))q('exp-run-bundle').href=bundle;",
                  "var bg=q('exp-run-bg');var show=function(v){if(bg)bg.style.display=v?'flex':'none';};",
                  "if(q('exp-run-btn'))q('exp-run-btn').onclick=function(){show(true);};",
                  "if(q('exp-run-close'))q('exp-run-close').onclick=function(){show(false);};",
                  "if(bg)bg.onclick=function(e){if(e.target===bg)show(false);};",
                  "if(q('exp-run-copy'))q('exp-run-copy').onclick=function(){navigator.clipboard&&navigator.clipboard.writeText(cmd);this.textContent='Copied ✓';};",
                  "})();")
        end
        print(io, "window.addEventListener('load',function(){",
              "if(window.renderMathInElement)renderMathInElement(document.body,{delimiters:[",
              "{left:'\$\$',right:'\$\$',display:true},{left:'\\\\[',right:'\\\\]',display:true},",
              "{left:'\$',right:'\$',display:false},{left:'\\\\(',right:'\\\\)',display:false}],",
              # don't math-render code listings / table cells (a literal $x$ in code)
              "ignoredClasses:['exp-src','exp-table'],throwOnError:false});});",
              "</script></body></html>")
        return String(take!(io))
    end
end

# ── Site publishing (a hosted web page: index.html + og-image.png) ────────────────────────────
# The FIRST figure in the notebook as PNG bytes (a display raster or a client-rendered chart's
# snapshot), or `nothing` if there is none / none captured.
function _first_figure_png(nb::LiveNotebook)
    for c in nb.report.cells
        c.kind == CODE || continue
        (:collapsed in c.flags) && continue
        img = cell_image(nb, c.id)
        img === nothing || return img
    end
    return nothing
end

# A generated OG title-card PNG (~1200×630) from the document metadata, rendered via the Typst binary
# (already a dependency for PDF export). `nothing` if Typst is unavailable or compilation fails.
function _title_card_png(nb::LiveNotebook)
    fm = report_frontmatter(nb.report)
    isempty(strip(fm.title)) && return nothing
    dir = mktempdir()
    try
        line(kind, s) = isempty(strip(s)) ? "" : kind * "[#" * s * "]\n"
        typ = string(
            "#set page(width: 1200pt, height: 630pt, margin: 72pt, fill: rgb(\"#0d1120\"))\n",
            "#set text(fill: rgb(\"#d4d8e8\"), font: (\"Libertinus Serif\", \"New Computer Modern\", \"DejaVu Serif\"))\n",
            "#align(center + horizon)[\n",
            "  #text(size: 52pt, weight: \"bold\", fill: white)[#", _typ_str(fm.title), "]\n",
            isempty(strip(fm.subtitle)) ? "" : "  #v(14pt)\n  #text(size: 28pt, fill: rgb(\"#9aa0c0\"))[#" * _typ_str(fm.subtitle) * "]\n",
            isempty(strip(fm.byline)) ? "" : "  #v(20pt)\n  #text(size: 20pt, fill: rgb(\"#6a7090\"))[#" * _typ_str(fm.byline) * "]\n",
            "  #v(28pt)\n  #line(length: 40%, stroke: 1pt + rgb(\"#2a2e40\"))\n",
            "  #v(10pt)\n  #text(size: 16pt, fill: rgb(\"#569cd6\"))[Kaimon Slate]\n",
            "]\n")
        write(joinpath(dir, "card.typ"), typ)
        png = joinpath(dir, "card.png")
        _typst_compile(joinpath(dir, "card.typ"), png)
        return isfile(png) ? read(png) : nothing
    catch
        return nothing
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
    og_image(nb) -> Vector{UInt8} | nothing

The social-preview image for the notebook: its first figure, else a generated title card, else
`nothing`. Used as the `og:image` for a published page.
"""
function og_image(nb::LiveNotebook)
    fig = _first_figure_png(nb)
    fig === nothing || return fig          # a real figure short-circuits the (slow) title-card render
    return _title_card_png(nb)
end

# A published site can carry a runnable bundle so a viewer can run the notebook LIVE on their machine.
# These are the fixed filenames the site, `run.jl`, and the page overlay all agree on.
const _SITE_BUNDLE = "notebook.standalone.jl"   # the reproducible env (export_standalone)
const _SITE_RUNJL = "run.jl"                     # the generated bootstrap script

# The `run.jl` bootstrap: install the packages, download the notebook's reproducible bundle from
# `bundle_url`, expand it, and (agent=true) set up the full Kaimon/agent experience. Discrete step
# functions so it can be extended (auto-launch, Julia bootstrap). Idempotent.
function _run_script(bundle_url::AbstractString; agent::Bool = true)
    KAIMON = "https://github.com/kahliburke/Kaimon.jl"
    SLATE = "https://github.com/kahliburke/KaimonSlate.jl"
    installs = agent ?
        "    Pkg.add(url = \"$KAIMON\")   # gate workers + the AI agent\n    Pkg.add(url = \"$SLATE\")  # auto-registers as a Kaimon extension on load" :
        "    Pkg.add(url = \"$SLATE\")"
    launch = agent ? """
        println(""\"
        ✓ Installed. Notebook bundle saved to: \$nb

        To run it with the FULL experience (per-notebook workers + AI agent):
          1. Start Kaimon the way you normally do — it auto-starts the Slate server at
             http://127.0.0.1:8765 and loads the `slate` tools.
          2. Open that URL, then open the notebook file — or just ask the agent:
                slate.open \$nb
             Slate reconstructs the notebook's exact environment from the bundle on open.

        For a quick look WITHOUT the agent, run instead:
          julia -e 'using KaimonSlate; KaimonSlate.serve_notebook(raw"\$nb")'
        ""\")""" : """
        println("✓ Installed. Serving at http://127.0.0.1:8765 — the env reconstructs on open…")
        @eval using KaimonSlate
        Base.invokelatest(getfield(KaimonSlate, :serve_notebook), nb)"""
    return """
    #!/usr/bin/env julia
    # ── Run this Kaimon Slate notebook live on your machine ──────────────────────────────────────
    # Auto-generated. Installs the packages, downloads this notebook's reproducible bundle, and gets
    # you running — Slate reconstructs the exact environment from the bundle when the notebook opens.
    # Re-runnable (idempotent). Prerequisite: Julia 1.10+ (juliaup / https://julialang.org/downloads).$(agent ? " For the agent: a logged-in `claude` CLI and/or Ollama (optional)." : "")
    #
    # Steps are separate functions so this is easy to extend or audit.
    using Pkg, Downloads

    # The bundle lives next to this script on the published site; override to self-host.
    const BUNDLE_URL = get(() -> "$bundle_url", ENV, "SLATE_BUNDLE_URL")

    function ensure_julia()
        VERSION >= v"1.10" || error("Julia 1.10+ required (found \$VERSION). See https://julialang.org/downloads")
    end

    function install_packages()
        @info "Installing packages (first run compiles — this can take a few minutes)…"
    $installs
    end

    function fetch_bundle()
        @info "Downloading the notebook bundle" BUNDLE_URL
        nb = joinpath(pwd(), $(JSON.json(_SITE_BUNDLE)))
        Downloads.download(BUNDLE_URL, nb)
        return nb
    end

    function main()
        ensure_julia()
        install_packages()
        nb = fetch_bundle()
    $launch
    end

    main()
    """
end

# Materialise the site into `dir`: index.html (wired to the og-image sidecar) + og-image.png +
# .nojekyll, and — when `bundle` — the reproducible `notebook.standalone.jl` + a `run.jl` bootstrap so
# the page can offer "Run this live". `base_url` (the eventual site URL) is baked into run.jl so it can
# fetch the bundle; `agent` picks the full-Kaimon vs standalone bootstrap. Shared by export_site +
# publish_site.
function _build_site_dir!(dir::AbstractString, nb::LiveNotebook; bundle::Bool = false,
                          base_url::AbstractString = "", agent::Bool = true, kwargs...)
    img = og_image(nb)
    ogpath = ""
    if img !== nothing
        write(joinpath(dir, "og-image.png"), img); ogpath = "og-image.png"
    end
    if bundle
        write(joinpath(dir, _SITE_BUNDLE), export_standalone(nb))
        burl = isempty(strip(base_url)) ? _SITE_BUNDLE : rstrip(String(base_url), '/') * "/" * _SITE_BUNDLE
        write(joinpath(dir, _SITE_RUNJL), _run_script(burl; agent = agent))
    end
    write(joinpath(dir, "index.html"), export_html(nb; og_image = ogpath, runnable = bundle, kwargs...))
    write(joinpath(dir, ".nojekyll"), "")   # GitHub Pages: serve files verbatim (no Jekyll processing)
    return dir
end

"""
    export_site(nb; kwargs...) -> Vector{UInt8}

Build a self-contained, publishable website for the notebook — `index.html` (the HTML export, wired
to an `og-image.png` sidecar so a shared link unfurls with a preview) plus that image — as a
gzip-compressed tarball. Unpack it into a `gh-pages` branch / any static host. HTML options
(`theme`, `code`, `outputs`, `include_source`) pass through to the page.
"""
function export_site(nb::LiveNotebook; kwargs...)
    dir = mktempdir()
    try
        _build_site_dir!(dir, nb; kwargs...)
        tarball = Tar.create(dir)
        try
            return transcode(GzipCompressor, read(tarball))
        finally
            rm(tarball; force = true)
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

# Run a git/gh command in `dir`, returning (ok, combined_output). Never throws.
function _git_run(dir::AbstractString, args::Cmd)
    out = IOBuffer()
    ok = try
        run(pipeline(setenv(args, dir = dir); stdout = out, stderr = out)); true
    catch
        false
    end
    return (ok, String(take!(out)))
end

_gh_ok(cmd::Cmd) = success(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))

"""
    publish_preflight(repo) -> NamedTuple

Inspect (read-only, no mutation) what publishing to `repo` would do, so the UI can warn before
acting: whether `gh` is available, the repo exists, its visibility, and whether it already has a
`gh-pages` branch / live Pages site that a publish would overwrite.
"""
function publish_preflight(repo::AbstractString)
    gh = Sys.which("gh")
    gh === nothing && return (; gh = false, valid = false, exists = false)
    occursin(r"^[\w.-]+/[\w.-]+$", repo) || return (; gh = true, valid = false, exists = false)
    _gh_ok(`$gh repo view $repo`) || return (; gh = true, valid = true, exists = false)
    vis = try; strip(read(pipeline(`$gh repo view $repo --json visibility -q .visibility`; stderr = devnull), String)); catch; ""; end
    pageurl = try; strip(read(pipeline(`$gh api repos/$repo/pages -q .html_url`; stderr = devnull), String)); catch; ""; end
    return (; gh = true, valid = true, exists = true, visibility = vis,
            hasGhPages = _gh_ok(`$gh api repos/$repo/branches/gh-pages`), pagesUrl = pageurl)
end

"""
    publish_site(nb, repo; private=false, create=true, kwargs...) -> (; url, repo, created, pagesEnabled, pagesError)

Publish the notebook as a GitHub Pages site to `repo` (`"owner/name"`), using the user's installed +
authenticated `gh` CLI. If the repo is missing and `create` is set, it's created with the requested
visibility (`private`); the built site is force-pushed to `gh-pages`, Pages is enabled, and the URL
returned. An EXISTING repo's visibility is left untouched. Idempotent — re-runs just update the branch.
Requires `gh` on PATH and `gh auth login`. (Pages needs a PUBLIC repo on the free plan.)
"""
function publish_site(nb::LiveNotebook, repo::AbstractString; private::Bool = false, create::Bool = true, kwargs...)
    gh = Sys.which("gh")
    gh === nothing && error("`gh` CLI not found on PATH. Install it and run `gh auth login`, then retry.")
    occursin(r"^[\w.-]+/[\w.-]+$", repo) || error("repo must be \"owner/name\" (got \"$repo\")")
    owner, name = split(repo, "/")
    token = strip(read(`$gh auth token`, String))                 # push auth without touching git config
    isempty(token) && error("`gh auth token` returned nothing — run `gh auth login` first.")

    dir = mktempdir()
    try
        # Bake the eventual Pages URL into run.jl so its bundle fetch is self-contained.
        _build_site_dir!(dir, nb; base_url = "https://$owner.github.io/$name/", kwargs...)
        # Fresh single-commit history on gh-pages (the site is a build artifact, not tracked source).
        for cmd in (`git init -q -b gh-pages`, `git add -A`,
                    `git -c user.email=slate@kaimon -c user.name=KaimonSlate commit -q -m "Publish notebook site"`)
            ok, log = _git_run(dir, cmd); ok || error("git failed: $log")
        end
        # Create the repo only when missing AND `create` is set; never change an existing repo's visibility.
        created = false
        if !_gh_ok(`$gh repo view $repo`)
            create || error("Repo $repo doesn't exist. Enable “create repo if missing”, or create it first.")
            vis = private ? "--private" : "--public"
            ok, log = _git_run(dir, `$gh repo create $repo $vis`)
            ok || error("gh repo create failed: $log")
            created = true
        end
        pushurl = "https://x-access-token:$token@github.com/$repo.git"
        ok, log = _git_run(dir, `git push --force $pushurl gh-pages`)
        ok || error("git push failed: $(replace(log, token => "***"))")
        # Enable Pages from gh-pages/. The `-f` values carry `[]`, which must reach gh as literal args,
        # so interpolate them as variables (no shell parsing). Already-enabled (409) counts as success;
        # a plan/visibility rejection (422 — Pages needs a PUBLIC repo on the free plan) is surfaced.
        srcbranch = "source[branch]=gh-pages"; srcpath = "source[path]=/"; pagesep = "repos/$repo/pages"
        already = _gh_ok(`$gh api $pagesep`)
        pok, plog = already ? (true, "") : _git_run(dir, `$gh api -X POST $pagesep -f $srcbranch -f $srcpath`)
        already_enabled = occursin("already enabled", plog)      # 409 — Pages was set up already; that's success
        pok = pok || already_enabled
        pagesError = pok ? "" : (occursin("does not support GitHub Pages", plog) ?
            "GitHub Pages isn't available for this repo — private Pages needs GitHub Pro/Team; on a free plan the repo must be PUBLIC." :
            strip(replace(plog, r"\s+" => " ")))
        return (; url = "https://$owner.github.io/$name/", repo = String(repo), created,
                pagesEnabled = pok, pagesError)
    finally
        rm(dir; recursive = true, force = true)
    end
end

# First ~`n` words of `text` as a plain one-liner (markdown punctuation stripped) — for the OG/meta
# description. Adds an ellipsis when truncated.
function _first_words(text, n::Int)
    s = replace(strip(String(text)), r"[#*_`>\[\]]" => "", r"\s+" => " ")
    w = split(s)
    isempty(w) && return ""
    return join(w[1:min(n, length(w))], " ") * (length(w) > n ? "…" : "")
end

# A GitHub-flavored markdown table from a `slate_table`/`slate_query` spec (server-paged tables carry
# only the loaded rows). `|` in a cell is escaped so it doesn't break the column layout.
function _md_table(spec)
    cols = get(spec, "columns", Any[]); rows = get(spec, "rows", Any[])
    names = String[c isa AbstractDict ? string(get(c, "name", "")) : string(c) for c in cols]
    isempty(names) && return ""
    io = IOBuffer()
    println(io, "| ", join(names, " | "), " |")
    println(io, "| ", join(fill("---", length(names)), " | "), " |")
    for r in rows
        println(io, "| ", join((v === nothing ? "" : replace(string(v), "|" => "\\|") for v in r), " | "), " |")
    end
    return String(take!(io))
end

# Markdown citation context: `citekeys`, a plain-text `emit` that renders each `[@key]` in the
# notebook's bibstyle (numeric `[2]` / author-date `(Knuth, 1984)`, honouring a `, p. 7` locator), and
# the data for a References section. `nothing` when the notebook has no bibliography.
function _md_cite_ctx(nb::LiveNotebook)
    bi = bibliography_index(nb.report, dirname(abspath(nb.path)))
    isempty(bi) && return nothing
    numeric = _is_numeric_style(get(nb.report.meta, "bibstyle", "ieee"))
    citekeys = Set(e.key for e in bi)
    numbers = citation_numbers(nb.report, citekeys)         # first-citation order (numeric labels + ordering)
    label = Dict{String,String}(e.key => (numeric ? string(get(numbers, e.key, 0)) : _author_year_label(e.author, e.year)) for e in bi)
    emit = (key, sup, _form) -> begin
        lab = get(label, String(key), String(key))
        inner = isempty(strip(sup)) ? lab : string(lab, ", ", strip(sup))
        numeric ? string("[", inner, "]") : string("(", inner, ")")
    end
    return (; citekeys, emit, bi, numeric, numbers, cited = cited_citation_keys(nb.report))
end

# The "## References" section for markdown export. Numeric styles list cited entries in citation order
# (`N. Author. Title. Year.`); author-date lists all entries alphabetically (`Author (Year). Title.`).
function _md_references(ctx)
    ctx === nothing && return ""
    io = IOBuffer(); println(io, "## References\n")
    if ctx.numeric
        cited = [e for e in ctx.bi if haskey(ctx.numbers, e.key)]
        sort!(cited; by = e -> ctx.numbers[e.key])
        for e in cited
            parts = filter(!isempty, [strip(e.author), strip(e.title), strip(e.year)])
            println(io, ctx.numbers[e.key], ". ", join(parts, ". "), ".")
        end
    else
        for e in sort(ctx.bi; by = e -> lowercase(_author_year_label(e.author, e.year)))
            yr = isempty(strip(e.year)) ? "" : string(" (", strip(e.year), ")")
            head = isempty(strip(e.author)) ? strip(e.title) : string(strip(e.author), yr, ". ", strip(e.title))
            println(io, "- ", head, ".")
        end
    end
    return String(take!(io))
end

"""
    export_markdown(nb; include_source=true, outputs="all") -> String

Serialize the notebook to GitHub-flavored Markdown for copy-paste (Discourse / Slack / GitHub /
Obsidian / docs). Prose rides verbatim; `[@cite]` and `[@fig:label]` render to their in-text form
(per the notebook's bibstyle) with a trailing References section; code cells become fenced ```julia
blocks; text outputs are fenced; figures / frozen charts embed as `![Figure N](data:image/…;base64,…)`;
tables become GFM tables. Data-URI images are self-contained but not every host renders them (GitHub
strips them) — for those, upload the standalone `.jl` (+ a PNG/SVG) alongside.
"""
function export_markdown(nb::LiveNotebook; include_source::Bool = true, outputs::AbstractString = "all")
    texts = _outputs_text_ok(outputs); anyout = _outputs_any(outputs)
    lock(nb.lock) do
        fm = report_frontmatter(nb.report)
        figidx = figure_index(nb.report)
        citectx = _md_cite_ctx(nb)
        citekeys = citectx === nothing ? Set{String}() : citectx.citekeys
        citemit = citectx === nothing ? _cite_literal : citectx.emit
        # figure cell id → its bound caption's number (for image alt text)
        fignum_of = Dict{String,Int}()
        for (capid, figid) in figidx.capfor
            (isempty(figid) || !haskey(figidx.numbers, capid)) && continue
            get!(fignum_of, figid, figidx.numbers[capid])
        end
        # Rewrite `[@cite]`/`[@fig:label]` in a prose block to their markdown in-text form.
        rw(s) = _rewrite_citations(s, citekeys; emit = citemit, figrefs = figidx.labels, figemit = _fig_text)
        io = IOBuffer()
        isempty(strip(fm.title)) || println(io, "# ", fm.title, "\n")
        isempty(strip(fm.subtitle)) || println(io, "### ", fm.subtitle, "\n")
        isempty(strip(fm.byline)) || println(io, "*", fm.byline, "*\n")
        isempty(strip(fm.abstract)) ||
            println(io, "> **Abstract.** ", replace(strip(rw(fm.abstract)), "\n" => "\n> "), "\n")
        for c in nb.report.cells
            (:collapsed in c.flags) && continue
            c.id in fm.skip && continue
            if :bibliography in c.flags        # rendered as the References section below, not raw BibTeX
                continue
            end
            if c.kind == MARKDOWN
                s = strip(rw(c.id == fm.titlecell ? _strip_leading_h1(c.source) : c.source))
                isempty(s) && continue
                haskey(figidx.numbers, c.id) ? println(io, "**Figure ", figidx.numbers[c.id], ".** ", s, "\n") :
                                               println(io, s, "\n")
                continue
            end
            if include_source && !(:hidecode in c.flags) && isempty(c.binds) && !isempty(strip(c.source))
                println(io, "```julia\n", rstrip(c.source), "\n```\n")
            end
            o = c.output
            (o === nothing || !anyout) && continue
            texts && o.exception !== nothing && println(io, "```\n", rstrip(o.exception), "\n```\n")
            texts && !isempty(strip(o.stdout)) && println(io, "```\n", rstrip(o.stdout), "\n```\n")
            alt = haskey(fignum_of, c.id) ? string("Figure ", fignum_of[c.id]) : "figure"   # meaningful alt when a data-URI won't render
            imgs = 0
            for ch in o.display
                if startswith(ch.mime, "image/")
                    println(io, "![", alt, "](data:", ch.mime, ";base64,", Base64.base64encode(ch.data), ")\n"); imgs += 1
                elseif ch.mime == "text/latex"
                    println(io, "\$\$", strip(String(copy(ch.data))), "\$\$\n")
                end
            end
            (texts && imgs == 0 && isempty(o.display) && !isempty(strip(o.value_repr))) &&
                println(io, "```\n", rstrip(o.value_repr), "\n```\n")
            if !isempty(_echarts_specs(c))
                png = _snapshot(nb.id, c.id)
                png === nothing ? println(io, "*[chart — open in a browser and re-export to capture]*\n") :
                    println(io, "![", alt, "](data:image/png;base64,", Base64.base64encode(png), ")\n")
            end
            for spec in _table_specs(c)
                t = _md_table(spec); isempty(t) || println(io, t, "")
            end
        end
        refs = _md_references(citectx)
        isempty(strip(refs)) || print(io, refs)
        return strip(String(take!(io))) * "\n"
    end
end

# The notebook-priming system prompt, set once at `agent_open` (the `system_prompt`
# arg → `claude --append-system-prompt`). It makes the agent a *live notebook
# operator* — driving the reactive notebook one cell at a time through the `slate.*`
# tools and reading each result — instead of a blind file-author that composes
# everything in its head and dumps one big Edit.
# DAG-scoped context for a per-cell ✨ turn: the target cell + its upstream dependency
# cone (what it reads, transitively, with sources) + downstream impact. Lets the agent
# work focused — edit this cell, branch upstream only when the cause is a precursor — and
# it knows WHERE the precursors are instead of grepping.
# Inline-reference expansion: a user can mention a cell by `@id` in chat (the UI offers
# autocomplete on `@`). For each @token that resolves to a real cell id, append that cell's
# source + current result, so the agent has the referenced cells in hand without surveying
# the whole notebook. Returns "" when nothing resolves.
function _mention_context(nb::LiveNotebook, text::AbstractString)
    byid = Dict(c.id => c for c in nb.report.cells)
    refs = String[]
    for m in eachmatch(r"@([A-Za-z0-9_]+)", String(text))
        id = String(m.captures[1])
        (haskey(byid, id) && !(id in refs)) && push!(refs, id)
    end
    isempty(refs) && return ""
    io = IOBuffer()
    print(io, "══ REFERENCED CELLS — the user mentioned these by @id; here is each one's source and current result. ══")
    for id in refs
        c = byid[id]
        kind = c.kind == MARKDOWN ? "md" : "code"
        print(io, "\n\n--- @", id, " [", kind, "] ---\n", rstrip(c.source))
        c.kind == CODE && print(io, "\n→ ", replace(_cell_result_text(c), "\n" => "\n  "))
    end
    return String(take!(io))
end

function _cell_context(nb::LiveNotebook, id::AbstractString)
    cells = nb.report.cells
    i = findfirst(c -> c.id == id, cells)
    i === nothing && return ""
    byid = Dict(c.id => c for c in cells)
    up = Set{String}(); frontier = String[id]
    while !isempty(frontier)
        c = get(byid, pop!(frontier), nothing); c === nothing && continue
        for d in c.deps
            (d == id || d in up) && continue
            push!(up, d); push!(frontier, d)
        end
    end
    down = setdiff(dependents_of(nb.report, Set([id])), Set([id]))
    io = IOBuffer()
    println(io, "══ SCOPED TURN — the user clicked ✨ on cell `", id, "`. This cell is your ENTIRE focus. ══")
    println(io, "- Answer about / modify ONLY cell `", id, "` (and, if a fix truly requires it, the upstream",
            " cells listed below that it reads from).")
    println(io, "- Do NOT review, critique, or touch any OTHER cell. Do NOT call `slate_read` to survey the",
            " whole notebook — this cell's source, output, its upstream dependency cone, and its downstream",
            " impact are ALL given below. Only read another cell if you genuinely need one not shown here.")
    println(io, "- If the request can't be satisfied within this cell + its precursors, say so briefly instead",
            " of widening scope. `slate_view(\"", id, "\")` shows this cell's figure if it has one.")
    tc = cells[i]
    println(io, "\n--- cell `", id, "` source ---\n", tc.source)
    o = tc.output
    if o !== nothing
        o.exception !== nothing ? println(io, "→ ERROR: ", first(split(o.exception, "\n"))) :
            (isempty(o.value_repr) || println(io, "→ ", o.value_repr))
    end
    upcells = [c for c in cells if c.id in up]
    if !isempty(upcells)
        println(io, "\n--- upstream cells it depends on (define what it reads) ---")
        for c in upcells
            println(io, "[`", c.id, "`] ", replace(strip(first(split(c.source, "\n"))), r"\s+" => " "))
        end
    end
    isempty(down) || println(io, "\n--- changing it re-runs downstream: ", join(sort(collect(down)), ", "))
    return String(take!(io))
end

# ── Canonical Slate notebook-API reference (SINGLE SOURCE OF TRUTH) ───────────
# The Slate notebook-API docs (echart, @bind, animate, reactive, slate_table, cell tags, …) are the
# SINGLE SOURCE OF TRUTH in `slate_api.jl`: `slate_api_reference()` (the `slate.api` tool + full
# reference), `slate_api_records()` (fed to semantic search), and `_SLATE_CHEATSHEET` (inlined in the
# agent prompt below) all come from the one registry there, so they can never drift.

function _agent_system_prompt(nb::LiveNotebook)
    # Match the user's UI theme for plots (sent from the browser on chat → nb.report.meta["ui_dark"]).
    dark = get(nb.report.meta, "ui_dark", nothing)
    themehint = dark === true  ? "The UI is DARK — `using CairoMakie; set_theme!(theme_dark())`, then return the figure." :
                dark === false ? "The UI is LIGHT — `using CairoMakie` with the default light theme (do NOT call `theme_dark()`); return the figure." :
                                 "Match the notebook UI theme — `using CairoMakie` and call `set_theme!(theme_dark())` only if the UI is dark; return the figure."
    return """
    You are an agent that BUILDS AND EDITS a live, reactive Julia notebook with the user, in real
    time. This notebook is id "$(nb.id)" (file: $(abspath(nb.path))). The full `mcp__kaimon__slate_*`
    toolset drives it — their schemas describe each; every slate tool takes `notebook="$(nb.id)"`.

    Change the notebook's CELLS through the slate tools (slate_add_cell / slate_edit_cell / slate_run /
    slate_delete_cell / slate_rename_cell), not by hand-editing the .jl — that fights the running engine.

    ITERATING ON THE PACKAGE'S OWN CODE: the notebook's worker is a LIVE Julia session in this project's
    env with Revise active — it IS your REPL and test harness, so you don't need a separate session.
      1. Edit the package's `src/` with your file tools (function bodies, struct changes, and new files
         are all hot-reloaded). Add a dependency with the `pkg_add` tool.
      2. Re-run the cell(s) that exercise the change (slate_run) to see new results live; if nothing
         exercises it yet, add a small cell that calls it.
    Use the wider Kaimon tools (search_code, goto_definition, run_tests, pkg_add, …) to navigate and
    manage the project. (If a change genuinely doesn't take, ↻ Restart worker.)

    ORIENT: `slate_read(notebook="$(nb.id)")` maps the notebook — a compact OUTLINE (each cell's id,
    kind, what it DEFINES, a one-line result) plus a STATE TOKEN. It is NOT the full notebook; read the
    full source+output of specific cells with `slate_read(cells="id1,id2")`. After edits, catch up with
    `slate_read(delta_since=<token>)` (only what changed). add/edit/run also return the affected cell,
    so you often need not re-read at all. Don't dump the whole notebook — outline, then drill in.

    WORK INCREMENTALLY: add or edit ONE cell at a time and look at the result it returns; fix errors
    before moving on; pick the next step from what you saw. Cells are REACTIVE — a cell re-runs when an
    upstream value it reads changes, so define once and read elsewhere. Give cells meaningful ids (the
    `id` arg on add, or slate_rename_cell) so the notebook reads well.

    The SLATE HELPERS below (echart, @bind, animate, playhead, reactive/@onclick, slate_table, cell
    tags) are Slate-specific — use them for charts / widgets / animation / tables / live updates. The
    cheatsheet below is the quick reference; `slate_api()` returns the FULL per-helper reference, and
    `slate_search_docs("…")` now finds these helpers too (they're indexed under module "Slate")
    alongside the notebook's PACKAGE docs (`slate_index_docs` adds more packages).

    $(_SLATE_CHEATSHEET)

    For STATIC/scientific figures use **CairoMakie**. $(themehint) NEVER GLMakie/WGLMakie (no GPU
    window), and don't use Makie `SliderGrid`/`@lift`/`Observable` — use the @bind reactivity above
    (Makie interactivity renders dead/static under CairoMakie).

    SCOPED TURNS: if a turn begins with a "SCOPED TURN — the user clicked ✨ on cell `…`" block, that
    cell is your whole focus; stay on it (and the upstream cells it lists), don't survey the rest, and
    don't slate_read the whole notebook — the context is already in the block.

    Be concise in chat; lead with the action.
    """
end

# Ensure an agent is bound to this notebook, spawning one (keyed `slate-<id>`,
# cwd = the notebook's directory) on first use and registering its event route.
# The agent inherits the host's MCP config (Kaimon included), so it can also call
# `slate.*`/`ex` — no explicit `mcp_config` needed (passing one with --strict would
# instead cut it off from the live Kaimon). Cell editing goes through the file.
# Ensure a crew member's agent is bound to this notebook, spawning one on first use.
# `crew` is a crew label ("" = the default/solo agent — id stays `slate-<id>` for
# back-compat so a re-adopted agent matches across an extension restart). Multiple
# crew agents share one notebook; `_AGENT_ROUTES` already maps each id → this nb.
# `model` ("" = service default = sonnet) binds at spawn only — an already-running
# crew agent keeps its model until reaped (the UI kills it on a model-setting change).
# The agent's working dir = the notebook's PROJECT ROOT (the dir holding the active Project.toml),
# NOT the notebook file's own directory. The `lab` preset runs Claude Code in `acceptEdits` mode,
# which only auto-accepts edits inside the workspace (cwd); rooting at the project lets the agent
# co-edit the notebook's module code under `src/` — for a notebook in `…/notebooks/foo.jl`, `src/`
# would otherwise be `../src`, outside the workspace, and an unattended agent can't get approval.
# Falls back to the notebook's own directory when there is no enclosing project (detached).
function _agent_cwd(path::AbstractString)
    d = dirname(abspath(path))
    proj = Base.current_project(d)
    return proj === nothing ? d : dirname(proj)
end
function _ensure_agent!(nb::LiveNotebook; crew::AbstractString = "", model::AbstractString = "",
                        permission::AbstractString = "")
    label = String(crew)
    existing = get(nb.agents, label, "")
    if !isempty(existing)
        # Reuse the bound agent ONLY if it's still alive. A dead session — its `claude` exited, or
        # Kaimon's agent service restarted under us — must not be sent into (that's the "endpoint not
        # available" / silent failure); close + forget it here so we spawn a fresh one below and chat
        # self-heals. If we can't even check the status (service hiccup), assume it's gone and respawn.
        alive = try
            String(get(_agent_call(:agent_status, Dict{String,Any}("agent_id" => existing)), "status", "")) != "dead"
        catch
            false
        end
        alive && return existing
        try; _agent_call(:agent_close, Dict{String,Any}("agent_id" => existing)); catch; end   # free the id
        lock(_AGENT_LOCK) do
            delete!(_AGENT_ROUTES, existing); delete!(_AGENT_CREW, existing); delete!(nb.agents, label)
        end
    end
    aid = isempty(label) ? "slate-$(nb.id)" : "slate-$(nb.id)-$(label)"
    open_args = Dict{String,Any}(
            "cwd" => _agent_cwd(nb.path),
            "id"  => aid,
            # Kaimon M4 permission preset. "lab" (the default) allows the agent the Kaimon
            # MCP tools (slate.*/ex/qdrant) + file edits — enough to drive + introspect the
            # notebook, without arbitrary shell/web. Runs unattended (no prompt to stall a
            # headless agent); the agent_* recursion guard is always applied. The user can
            # pick another preset in Settings ("auto"/"default"/"bypass"); it binds at spawn,
            # so a change reaps the agent (chat-kill) and the next turn respawns on it.
            "permission" => (isempty(permission) ? "lab" : String(permission)),
            "system_prompt" => _agent_system_prompt(nb))
    isempty(model) || (open_args["model"] = model)   # omit → Kaimon's default (sonnet)
    res = try
        _agent_call(:agent_open, open_args)
    catch e
        # Agent already running (e.g. it outlived an extension restart — agents are
        # Kaimon-owned) → re-adopt it rather than failing the chat.
        occursin("in use", lowercase(sprint(showerror, e))) || rethrow()
        Dict("agent_id" => aid)
    end
    aid = String(get(res, "agent_id", aid))
    isempty(aid) && error("agent_open returned no id")
    lock(_AGENT_LOCK) do
        _AGENT_ROUTES[aid] = nb
        _AGENT_CREW[aid] = label
        nb.agents[label] = aid
    end
    isempty(label) && (nb.agent_id = aid)   # keep the back-compat alias in sync
    return aid
end

# Close + deregister a notebook's crew agents (best effort). `keep_log=true` preserves
# the replay transcript (hard-kill: agents gone, but the conversation stays visible and
# a fresh agent continues it); `false` wipes it (notebook close — nothing left to show).
function _reap_agents!(nb::LiveNotebook; keep_log::Bool = false)
    aids = lock(_AGENT_LOCK) do
        ids = collect(values(nb.agents))
        for aid in ids
            delete!(_AGENT_ROUTES, aid); delete!(_AGENT_CREW, aid)
        end
        empty!(nb.agents)
        keep_log || delete!(_AGENT_LOG, nb.id)
        ids
    end
    nb.agent_id = ""
    if _agent_available()
        for aid in aids
            try; _agent_call(:agent_close, Dict{String,Any}("agent_id" => aid)); catch; end
        end
    end
    return nothing
end
_close_agent!(nb::LiveNotebook) = _reap_agents!(nb; keep_log = false)   # on notebook close

# Last turn-start time per notebook id — so a `result`'s delayed busy-clear can't clobber the
# busy flag of a NEWER turn that started inside its window (which would mislabel that turn's edits).
const _AGENT_TURN = Dict{String,Float64}()

"""
    relay_agent_event(channel, data)

Gate-bus callback for an `agent:<id>` event: forward the raw `{kind,turn,data}`
JSON onto the bound notebook's SSE, prefixed `agent:` so the SPA's live-event
handler routes it to the chat pane. `data` already rides the bus as a JSON string.
"""
function relay_agent_event(channel::AbstractString, data)
    startswith(channel, "agent:") || return
    aid = String(channel)[length("agent:")+1:end]
    nb, crew = lock(_AGENT_LOCK) do
        get(_AGENT_ROUTES, aid, nothing), get(_AGENT_CREW, aid, "")
    end
    nb === nothing && return
    s = data isa AbstractString ? String(data) : String(JSON.json(data))
    env = try; JSON.parse(s); catch; nothing; end
    kind = env === nothing ? "" : get(env, "kind", "")
    # Tag the envelope with the speaking crew member so the SPA can lane multiple
    # agents (and replay stays attributed). Re-serialize only when we parsed cleanly.
    if env !== nothing
        env["crew"] = crew
        s = JSON.json(env)
    end
    # Mark the agent busy across a turn so the file-watcher attributes the edits it
    # makes to "agent" (not "external"). Clear shortly AFTER the turn ends, so the
    # watcher tick that picks up the agent's final save is still inside the window.
    if kind == "turn_started"
        _AGENT_TURN[nb.id] = time()
        nb.agent_busy = true
    elseif kind == "result"
        # Keep attributing edits to the agent for a bit after the turn ends — the final file-write
        # often syncs a couple seconds late (watcher latency). Clear only if NO newer turn started
        # meanwhile (else a stale timer would wrongly un-busy the new turn → edits mislabeled).
        t = time()
        @async (sleep(8.0); get(_AGENT_TURN, nb.id, 0.0) <= t && (nb.agent_busy = false))
    end
    # Always push live (token + tool-input deltas stream to the pane). Buffer for
    # reload-replay, but SKIP the liveness chunks (`data.delta == true` and
    # `tool_input_delta`) — the authoritative copies (the `delta:false` block, the
    # `tool_result`) are buffered, so replay stays clean and the cap isn't burned.
    _broadcast(nb, "agent:" * s)
    is_delta = kind == "tool_input_delta" ||
        (env !== nothing && (d = get(env, "data", nothing); d isa AbstractDict && get(d, "delta", false) === true))
    if !is_delta
        compact = false; bufcopy = String[]
        lock(_AGENT_LOCK) do
            buf = get!(_AGENT_LOG, nb.id, String[])
            push!(buf, s)
            length(buf) > _AGENT_LOG_CAP && (popfirst!(buf); compact = true; bufcopy = copy(buf))
        end
        # Mirror to disk (outside the lock): append the new line, or compact the file to
        # the capped buffer once we start dropping the oldest (bounds the file to the cap).
        compact ? _rewrite_chat_log(nb, bufcopy) : _append_chat_log(nb, s)
    end
    return nothing
end

