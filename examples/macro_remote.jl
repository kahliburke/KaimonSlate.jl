#%% md id=intro
# Macro-aware deps, remotely

Every binding below is **macro-made** — invisible to a plain parse, so the
graph edges only exist if ExpressionExplorer is alive in the worker doing
the expansion. Run this on a remote host to verify the provisioned env
carries EE.

#%% code id=ee_probe
ee_ok = isdefined(Main, :SlateWorker) && isdefined(Main.SlateWorker, :_EE_OK) ?
    Main.SlateWorker._EE_OK : missing
"worker ExpressionExplorer: $(ee_ok === true ? "✓ loaded" : ee_ok === false ? "✗ UNAVAILABLE" : "? (in-process kernel)")"

#%% code id=colors
@enum Fruit apple banana cherry

#%% code id=pick
# reads macro-defined enum instances — edge exists only via macro expansion
basket = [apple, cherry, cherry, banana, cherry]

#%% code id=tally
counts = Dict(f => count(==(f), basket) for f in instances(Fruit))

#%% code id=cfgdef
Base.@kwdef struct SimCfg
    trials::Int = 200
    seed::Int = 41
end

#%% code id=cfg
cfg = SimCfg(seed = 42)

#%% code id=defpair
macro defpair(name, val)
    sq = Symbol(name, :_sq)
    esc(quote
        $name = $val
        $sq = $val^2
    end)
end

#%% code id=usepair
@defpair width 7

#%% code id=area
# `width_sq` exists only through @defpair's expansion
area = width_sq * cfg.trials

#%% code id=summary
"basket=$(length(basket)) fruit, top=$(argmax(counts)), width²=$(width_sq), area=$(area), EE=$(ee_ok)"
