#%% md id=intro
# Gate smoke test

Minimal notebook to validate `GateKernel` end-to-end (eval, @bind, reactivity)
over the ZMQ worker — no heavy deps.

#%% code id=ctl
@bind k Slider(0:100)

#%% code id=calc
y = k^2

#%% code id=show
(; k, y, doubled = 2y)
