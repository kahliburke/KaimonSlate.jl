# Likely duplicate code, by embedding each function on its own and comparing every pair.
#
#   julia --project=. dev/dupes/dupes.jl [--threshold 0.90] [--min-lines 6] [--out docs/_dupes-report.md]
#
# One chunk per function, method or macro (JuliaSyntax for Julia, dev/dupes/chunk_js.mjs for the
# browser code), with comments and docstrings removed, so what is compared is the code. Each chunk
# is embedded by a local Ollama model and cached by content, so a second run embeds only what
# changed. Two scores per pair: the embeddings' cosine, which also finds the same job written
# twice, and the overlap of token 5-grams with names and literals replaced, which is high only for
# copy-paste. Pairs above the threshold are grouped into clusters, ranked by how much code they hold.
#
# Needs Ollama with the model (`ollama pull qwen3-embedding:4b`) and `npm --prefix dev install`.

using HTTP, JSON, SHA, Serialization, LinearAlgebra, Printf
const JS = Base.JuliaSyntax

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const MODEL = get(ENV, "DUPES_MODEL", "qwen3-embedding:4b")
const OLLAMA = get(ENV, "OLLAMA_HOST", "http://localhost:11434")
const CACHE = joinpath(@__DIR__, ".cache", "emb-" * replace(MODEL, r"[^A-Za-z0-9]" => "_") * ".jls")
const MAX_CHARS = 8000   # a longer function is embedded by its first part

function arg(name, default)
    i = findfirst(==(name), ARGS)
    return i === nothing ? default : ARGS[i + 1]
end
const THRESHOLD = parse(Float64, arg("--threshold", "0.90"))
const MIN_LINES = parse(Int, arg("--min-lines", "6"))
const OUT = joinpath(ROOT, arg("--out", "docs/_dupes-report.md"))

struct Chunk
    file::String; start::Int; stop::Int; name::String; lang::String
    code::String; norm::Vector{String}
end
codelines(c::Chunk) = count(l -> !isempty(strip(l)), split(c.code, '\n'))

# ── Julia ───────────────────────────────────────────────────────────────────────────────────────
const _JL_DEF = (JS.K"function", JS.K"macro")

function _jl_norm(code::AbstractString)
    out = String[]
    for t in JS.tokenize(code)
        k = JS.kind(t)
        (JS.is_whitespace(k) || k == JS.K"Comment" || k == JS.K"NewlineWs") && continue
        push!(out, k == JS.K"Identifier" ? "ID" : JS.is_literal(k) ? "LIT" :
                   k in (JS.K"String", JS.K"CmdString") ? "STR" : string(k))
    end
    return out
end

# The code between two byte offsets with its comments removed.
function _jl_strip(src::String, lo::Int, hi::Int)
    bytes = view(codeunits(src), lo:hi)
    io = IOBuffer()
    for t in JS.tokenize(String(copy(bytes)))
        JS.kind(t) == JS.K"Comment" && continue
        write(io, view(bytes, t.range))
    end
    return String(take!(io))
end
_line_at(src::String, b::Int) = count(==(UInt8('\n')), view(codeunits(src), 1:b)) + 1

function _jl_name(node)
    sig = JS.children(node)
    (sig === nothing || isempty(sig)) && return "<anon>"
    s = sig[1]
    while JS.kind(s) in (JS.K"where", JS.K"::", JS.K"call", JS.K"curly", JS.K"macrocall") && JS.children(s) !== nothing && !isempty(JS.children(s))
        s = JS.children(s)[1]
    end
    return string(JS.sourcetext(s))
end

function jl_chunks(file::String)
    src = read(file, String)
    tree = try
        JS.parseall(JS.SyntaxNode, src; filename = file, ignore_errors = true)
    catch e
        @warn "cannot parse" file exception = e
        return Chunk[]
    end
    out = Chunk[]
    function walk(n)
        k = JS.kind(n)
        short = k == JS.K"=" && JS.children(n) !== nothing && !isempty(JS.children(n)) &&
                JS.kind(JS.children(n)[1]) in (JS.K"call", JS.K"where")
        if k in _JL_DEF || short
            lo, hi = JS.first_byte(n), JS.last_byte(n)
            code = _jl_strip(src, lo, hi)
            push!(out, Chunk(relpath(file, ROOT), _line_at(src, lo), _line_at(src, hi),
                             _jl_name(n), "jl", code, _jl_norm(code)))
        end
        cs = JS.children(n)
        cs === nothing || foreach(walk, cs)
    end
    walk(tree)
    return out
end

# ── JavaScript ──────────────────────────────────────────────────────────────────────────────────
function js_chunks(files::Vector{String})
    isempty(files) && return Chunk[]
    script = joinpath(@__DIR__, "chunk_js.mjs")
    out = Chunk[]
    for line in eachline(Cmd(`node $script $files`; dir = joinpath(ROOT, "dev")))
        d = JSON.parse(line)
        push!(out, Chunk(relpath(d["file"], ROOT), d["start"], d["end"], d["name"], "js",
                         d["code"], split(d["norm"])))
    end
    return out
end

function source_files()
    jl, js = String[], String[]
    for dir in (joinpath(ROOT, "src"), joinpath(ROOT, "lib"))
        for (root, dirs, fs) in walkdir(dir)
            filter!(d -> !(d in ("node_modules", "build", "test", "docs")), dirs)
            for f in fs
                p = joinpath(root, f)
                endswith(f, ".jl") && push!(jl, p)
                (endswith(f, ".js") || endswith(f, ".mjs")) && !occursin(r"\.(bundle|min)\.m?js$", f) &&
                    filesize(p) < 1_500_000 && push!(js, p)
            end
        end
    end
    return jl, js
end

# ── Embeddings ──────────────────────────────────────────────────────────────────────────────────
function embed!(cache::Dict{String,Vector{Float32}}, chunks::Vector{Chunk})
    todo = unique([c.code for c in chunks if !haskey(cache, bytes2hex(sha1(c.code)))])
    isempty(todo) && return cache
    @info "embedding $(length(todo)) new chunks with $MODEL"
    mkpath(dirname(CACHE))
    t0 = time()
    for (i, batch) in enumerate(Iterators.partition(todo, 16))
        body = JSON.json(Dict("model" => MODEL, "input" => [first(c, MAX_CHARS) for c in batch]))
        r = HTTP.post(OLLAMA * "/api/embed", ["Content-Type" => "application/json"], body; read_idle_timeout = 600)
        embs = JSON.parse(String(r.body))["embeddings"]
        for (c, e) in zip(batch, embs)
            cache[bytes2hex(sha1(c))] = Float32.(e)
        end
        if i % 20 == 0
            n = min(i * 16, length(todo))
            @info @sprintf("  %d / %d  (%.0f s)", n, length(todo), time() - t0)
            serialize(CACHE, cache)
        end
    end
    serialize(CACHE, cache)
    return cache
end

# ── Scores ──────────────────────────────────────────────────────────────────────────────────────
shingles(toks, k = 5) = Set(UInt64[hash(view(toks, i:(i + k - 1))) for i in 1:(length(toks) - k + 1)])
function jaccard(a::Set, b::Set)
    (isempty(a) || isempty(b)) && return 0.0
    return length(intersect(a, b)) / length(union(a, b))
end
# One chunk inside the other (a closure in its function) is not a duplicate.
nested(a::Chunk, b::Chunk) = a.file == b.file && (a.start <= b.start <= b.stop <= a.stop || b.start <= a.start <= a.stop <= b.stop)

function pairs_above(X::Matrix{Float32}, chunks, threshold)
    n = size(X, 2)
    out = Tuple{Int,Int,Float32}[]
    for lo in 1:1024:n
        hi = min(n, lo + 1023)
        S = X[:, lo:hi]' * X
        for (r, i) in enumerate(lo:hi), j in (i + 1):n
            s = S[r, j]
            s >= threshold && !nested(chunks[i], chunks[j]) && push!(out, (i, j, s))
        end
    end
    return out
end

function clusters(n, prs)
    parent = collect(1:n)
    find(x) = (while parent[x] != x; parent[x] = parent[parent[x]]; x = parent[x]; end; x)
    for (i, j, _) in prs
        a, b = find(i), find(j)
        a == b || (parent[a] = b)
    end
    groups = Dict{Int,Vector{Int}}()
    for (i, j, _) in prs, x in (i, j)
        push!(get!(groups, find(x), Int[]), x)
    end
    return [unique(v) for v in values(groups)]
end

function main()
    jlfiles, jsfiles = source_files()
    chunks = vcat(reduce(vcat, (jl_chunks(f) for f in jlfiles); init = Chunk[]), js_chunks(jsfiles))
    filter!(c -> codelines(c) >= MIN_LINES, chunks)
    @info "$(length(chunks)) chunks of $MIN_LINES+ lines from $(length(jlfiles)) Julia and $(length(jsfiles)) JS files"
    mkpath(dirname(CACHE))
    cache = isfile(CACHE) ? deserialize(CACHE)::Dict{String,Vector{Float32}} : Dict{String,Vector{Float32}}()
    embed!(cache, chunks)
    X = reduce(hcat, (normalize(cache[bytes2hex(sha1(c.code))]) for c in chunks))
    prs = pairs_above(X, chunks, Float32(THRESHOLD))
    @info "$(length(prs)) pairs at cosine ≥ $THRESHOLD"
    sh = Dict{Int,Set{UInt64}}()
    shof(i) = get!(() -> shingles(chunks[i].norm), sh, i)
    best = Dict{Tuple{Int,Int},Tuple{Float32,Float64}}((i, j) => (s, jaccard(shof(i), shof(j))) for (i, j, s) in prs)
    cl = clusters(length(chunks), prs)
    weight(g) = sum(codelines(chunks[i]) for i in g) * (length(g) - 1)
    sort!(cl; by = g -> -weight(g))
    open(OUT, "w") do io
        println(io, "# Likely duplicates\n")
        println(io, "Model `$MODEL`, cosine ≥ $THRESHOLD, functions of $MIN_LINES+ code lines. ",
                    "$(length(chunks)) functions, $(length(prs)) pairs, $(length(cl)) clusters.\n")
        println(io, "`copy` marks a pair whose token 5-grams (names and literals replaced) overlap by 50% or more.\n")
        for (k, g) in enumerate(cl)
            sort!(g; by = i -> (chunks[i].file, chunks[i].start))
            sims = [best[(min(i, j), max(i, j))] for i in g for j in g if i < j && haskey(best, (min(i, j), max(i, j)))]
            top = maximum(first, sims); cp = maximum(last, sims)
            @printf(io, "## %d. %d functions, %d lines, cosine up to %.3f, token overlap up to %.0f%%%s\n\n",
                    k, length(g), sum(codelines(chunks[i]) for i in g), top, 100cp, cp >= 0.5 ? " (copy)" : "")
            for i in g
                c = chunks[i]
                println(io, "- `", c.file, ":", c.start, "-", c.stop, "` ", c.name, " (", codelines(c), " lines)")
            end
            println(io)
        end
    end
    @info "report: $OUT"
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
