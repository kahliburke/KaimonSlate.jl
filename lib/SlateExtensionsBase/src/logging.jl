# ── A logger whose behaviour is supplied as functions ─────────────────────────────────────────

"""
    HookLogger(inner, handle; min_level = nothing, shouldlog = nothing)

A logger that passes each record to `handle(inner, level, message, _module, group, id, file, line;
kwargs...)`, with `inner` as the logger it wraps. `min_level` is its fixed minimum level (`inner`'s
when `nothing`); `shouldlog(inner, level, _module, group, id)` filters before `handle` (`inner`'s
filter when `nothing`).

The functions are called in the latest world. That and the methods below living in this package are
the point: a package's code compiled into a sysimage runs in the world the image was built in, and a
custom compiler (GPUCompiler's, for one) asks the current logger for its level while inferring. A
logger type defined after that world, with its methods, is invisible from there; this one is part of
the image along with this package.
"""
struct HookLogger{L<:Base.CoreLogging.AbstractLogger} <: Base.CoreLogging.AbstractLogger
    inner::L
    handle::Any
    min_level::Union{Nothing,Base.CoreLogging.LogLevel}
    shouldlog::Any
end
HookLogger(inner::Base.CoreLogging.AbstractLogger, handle; min_level = nothing, shouldlog = nothing) =
    HookLogger(inner, handle, min_level, shouldlog)

Base.CoreLogging.min_enabled_level(l::HookLogger) =
    l.min_level === nothing ? Base.CoreLogging.min_enabled_level(l.inner) : l.min_level
Base.CoreLogging.catch_exceptions(l::HookLogger) = Base.CoreLogging.catch_exceptions(l.inner)
Base.CoreLogging.shouldlog(l::HookLogger, args...) =
    l.shouldlog === nothing ? Base.CoreLogging.shouldlog(l.inner, args...) : Base.invokelatest(l.shouldlog, l.inner, args...)
Base.CoreLogging.handle_message(l::HookLogger, args...; kwargs...) =
    (Base.invokelatest(l.handle, l.inner, args...; kwargs...); nothing)
