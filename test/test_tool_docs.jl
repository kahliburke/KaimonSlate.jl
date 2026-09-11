# Every tool an agent can see must arrive with a description.
#
# This has now gone wrong three times (api, run_on, edit_cell) and been fixed instance by instance
# each time, which is why it keeps coming back. The failure is silent by construction: a tool with
# no description registers, dispatches and works — it is only invisible to the model deciding
# whether to call it, and the only symptom is an agent that never uses it.
#
# The mechanism is a source scan. KaimonGate recovers a closure's docstring by reading the file
# that defines it and scanning UP from the definition line, because a closure has no module-level
# binding for `Base.Docs.doc` to attach to. So anything between the docstring and the `function`
# line — even a comment — leaves the tool with nothing.
#
# ASSERT ON WHAT THE CLIENT WOULD RECEIVE, not on the source. Checking that a docstring exists in
# the file would pass while the recovery that actually feeds the wire returns empty, which is the
# whole failure. So this runs the real recovery function against the real tool objects.

using ReTest
using KaimonSlate

# The gate appends a timeout notice to some tools' descriptions. A tool whose description is ONLY
# that notice is bare, however long the result looks — three dbg_* tools once measured ~195 chars
# and carried nothing but this. A length threshold alone would have passed them.
const _TIMEOUT_NOTE = "This tool may run up to"

@testset "every tool has a description" begin
    KG = isdefined(Main, :KaimonGate) ? Main.KaimonGate : nothing
    if KG === nothing
        @info "KaimonGate not loaded (no gate in this process) — skipping the tool-description check"
        @test true
    else
        tools = KaimonSlate.create_tools(KG.GateTool)
        @test !isempty(tools)

        # `handler`, not `func` — reaching for a field that does not exist inside a `try` returns
        # "" for every tool and reads as a total failure, which is its own kind of wrong answer.
        @test hasfield(typeof(first(tools)), :handler)

        recovered = Dict(t.name => strip(String(try
                                                    KG._source_docstring(t.handler)
                                                catch e
                                                    error("docstring recovery threw for $(t.name): $e")
                                                end)) for t in tools)

        bare = sort([n for (n, d) in recovered if isempty(d)])
        @test isempty(bare)

        # A description that is only the generated suffix is bare too.
        suffix_only = sort([n for (n, d) in recovered
                            if !isempty(d) && startswith(d, _TIMEOUT_NOTE)])
        @test isempty(suffix_only)

        # Implausibly short means the scan found something that is not the docstring — a stray
        # string literal above the definition, say. Real ones are a sentence at minimum.
        stubby = sort([(n, length(d)) for (n, d) in recovered if 0 < length(d) < 40]; by = last)
        @test isempty(stubby)
    end
end
