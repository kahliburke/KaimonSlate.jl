#%% md id=title title
# Edge Gauntlet — hostile outputs and awkward values

*A QA notebook: every cell here tries to break rendering, capture, or analysis. Everything
should degrade gracefully — truncated, paged, or shown as a clean error. Nothing should wedge
the notebook.*

#%% code id=deps
using DataFrames

#%% md id=sec_size
## Big things

#%% code id=bigmatrix
## 500×500 matrix — the text repr must clamp, not flood the browser.
bigm = randn(500, 500)

#%% code id=bigstring
## A 10 MB string value — overflow bar with full-result access, not a 10 MB DOM node.
bigs = "x"^10_000_000
"length: $(length(bigs))" * " | first 40: " * bigs[1:40]

#%% code id=bigstring_show
bigs

#%% code id=stdout_flood
## 20k lines of stdout — capture must truncate, not buffer forever.
for i in 1:20_000
    println("flood line $i")
end
"printed 20k lines"

#%% code id=bigtable
## 100k-row table — must page, never ship every row to the DOM.
slate_table(DataFrame(rand(100_000, 5), :auto); page_size = 15)

#%% md id=sec_values
## Awkward values

#%% code id=nan_chart
## NaN / ±Inf into an ECharts series — JSON has no Inf; the egress sanitizer must map
## non-finite → null (an ECharts gap), never a 500 on the state pull.
echart(:line, 1:10, [1.0, 2.0, NaN, 4.0, Inf, 6.0, -Inf, 8.0, 9.0, 10.0]; title = "NaN/Inf line")

#%% code id=missing_table
slate_table(DataFrame(a = [1, missing, 3], b = ["x", missing, "z"],
                      c = [missing, 2.5, NaN]))

#%% code id=circular
## A self-referential Dict — repr must not recurse forever.
d = Dict{String,Any}("k" => 1)
d["self"] = d
d

#%% code id=unicode_idents
## Unicode identifiers through dependency analysis.
αβ🚀 = 42
∑ₓ = sum
"α total: $(∑ₓ([αβ🚀, 1]))"

#%% code id=unicode_reader
"reader sees $(αβ🚀)"

#%% md id=sec_errors
## Errors that must render cleanly

#%% code id=deep_backtrace
## 200-deep recursion before the throw — the backtrace view has to cope.
deepboom(n) = n == 0 ? error("boom at the bottom") : deepboom(n - 1)
deepboom(200)

#%% code id=stackoverflow
## A caught StackOverflowError — enormous exception object, cell must survive.
selfcall() = selfcall()
try
    selfcall()
catch e
    "caught $(typeof(e))"
end

#%% code id=method_error
## MethodError with elaborate type params in the signature.
Dict{Tuple{Int,String},Vector{Float64}}() + 1

#%% md id=sec_trace
## Trace on a real loop

#%% code id=traced trace
acc = 0
for i in 1:5
    acc += i * i
end
acc
