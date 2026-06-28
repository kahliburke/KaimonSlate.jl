#%% md id=intro
# 📦 Output limits — scroll, wrap, caps & full-result access

Exercises the large-output mitigations. Run each cell and check the noted behavior.
(Open with an up-to-date Slate — these are mostly server + front-end changes.)

#%% md id=h_wide
## 1 · Wide output scrolls horizontally (no wrap)

A wide matrix should scroll **horizontally** instead of wrapping into a scrambled mess.
Toggle **Settings → "Wrap text output"** to switch to wrapping.

#%% code id=wide_matrix
# A tridiagonal matrix — wide enough to overflow the cell width.
[i == j ? 2.0 : abs(i - j) == 1 ? -1.0 : 0.0 for i in 1:25, j in 1:25]

#%% md id=h_tall
## 2 · Tall output clamps with scroll + Expand/Collapse

A few hundred lines of stdout should clamp to ~30em with an in-place scroll and an
**⤢ Expand** toggle (Collapse returns you to the cell header). Markdown is never clamped.

#%% code id=tall_stdout
for i in 1:180
    println("row ", lpad(i, 3), " · ", round(rand(); digits = 4))
end

#%% md id=h_bigstdout
## 3 · Massive stdout is capped — full result still reachable

Printing ~400k characters: the page shows a **capped preview** with a *"truncated for display"*
notice, and an access bar offers **open ↗ / editor / download** for the full text (saved to a temp
file, never shipped whole).

#%% code id=big_stdout
for _ in 1:400_000
    print('x')
end

#%% md id=h_bigval
## 4 · Big return values stay bounded

A million-element vector: Julia's `:limit` display shows a compact summary (a few rows), so the page
never renders the whole thing.

#%% code id=big_array
rand(10^6)

#%% md id=h_bightml
## 5 · Oversized HTML output → notice + full result

A custom value whose `text/html` render is multi-MB: the cell shows a *"too large to render"* notice
(rendering it inline would freeze the tab) with the full result available via the access bar.

#%% code id=big_html
struct BigHTML end
Base.showable(::MIME"text/html", ::BigHTML) = true
Base.show(io::IO, ::MIME"text/html", ::BigHTML) = print(io, "<p>", repeat("x", 600_000), "</p>")
BigHTML()

#%% md id=h_normal
## 6 · Normal output is untouched

Small results render exactly as before — no clamp, no bar.

#%% code id=normal
[1, 2, 3] .^ 2
