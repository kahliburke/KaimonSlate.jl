# Reactive input widgets (`@bind`, interactivity Layer 3) — host-side value glue.
#
# The widgets themselves (`Slider`, `Toggle`, …), the `@bind` macro, value reconcile,
# and coercion all live in the shared `widgets.jl` — ONE implementation injected into
# both the in-process and gate-worker namespaces. What remains here is the host glue:
# applying a browser value change to a cell's `BindSpec` and the kernel's namespace.

export set_bind_value!

"""
    set_bind_value!(report, cell, name, value, kernel=InProcessKernel()) -> cell

Apply a browser value change for bound variable `name` (one of `cell.binds`): route
it through the kernel (`assign_bind!` coerces against the widget, updates the
per-notebook registry, and assigns the global), then mirror the coerced value into
the host-side `BindSpec`. No-op if the cell has no such bind.
"""
function set_bind_value!(report::Report, cell::Cell, name::Symbol, value,
                         kernel::Kernel = InProcessKernel())
    i = findfirst(b -> b.name == name, cell.binds)
    i === nothing && return cell
    spec = cell.binds[i]
    spec.value = assign_bind!(kernel, report, spec.name, value)
    cell.state = FRESH
    return cell
end

"Convenience: set the sole bind of a single-control cell (no-op unless exactly one)."
function set_bind_value!(report::Report, cell::Cell, value, kernel::Kernel = InProcessKernel())
    length(cell.binds) == 1 || return cell
    return set_bind_value!(report, cell, cell.binds[1].name, value, kernel)
end
