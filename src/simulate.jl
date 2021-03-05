import StatsBase

# function simulate(rng::AbstractRNG, cm::ConditionalModel{A,B,M,Argvals,EmptyNTtype}, N::Int) where {A,B,M,Argvals}
#     m = Model(cm)
#     cm0 = setReturn(m, nothing)(argvals(cm))
#     info = StructArray(simulate(rng, cm0, N))
#     vals = [predict(cm, pars) for pars in info]
#     return StructArray{Noted}((vals, info))
# end

# function simulate(cm::ConditionalModel{A,B,M,Argvals,EmptyNTtype}, N::Int) where {A,B,M,Argvals} 
#     return simulate(GLOBAL_RNG, cm, N)
# end


# function simulate(rng::AbstractRNG, cm::ConditionalModel{A,B,M,Argvals,EmptyNTtype}) where {A,B,M,Argvals}
#     m = Model(cm)
#     cm0 = setReturn(m, nothing)(argvals(cm))
#     info = simulate(rng, cm0)
#     val = predict(cm, info)
#     return Noted(val, info)
# end

# function simulate(cm::ConditionalModel{A,B,M,Argvals,EmptyNTtype}) where {A,B,M,Argvals}
#     return simulate(GLOBAL_RNG, cm)
# end

using GeneralizedGenerated
using Random: GLOBAL_RNG
using NestedTuples
using SampleChains

EmptyNTtype = NamedTuple{(),Tuple{}} where T<:Tuple
export simulate

function simulate(rng::AbstractRNG, d::ConditionalModel, N::Int; trace_assignments=false)
    x = simulate(rng, d)
    T = typeof(x)
    ta = TupleVector(undef, x, N)
    @inbounds ta[1] = x

    for j in 2:N
        @inbounds ta[j] = simulate(rng, d; trace_assignments)
    end

    return ta
end

simulate(d::ConditionalModel, N::Int; trace_assignments=false) = simulate(GLOBAL_RNG, d, N; trace_assignments)

@inline function simulate(rng::AbstractRNG, c::ConditionalModel; trace_assignments=false)
    m = Model(c)
    return _simulate(getmoduletypencoding(m), m, argvals(c), Val(trace_assignments))(rng)
end

@inline function simulate(m::ConditionalModel; trace_assignments=false) 
    simulate(GLOBAL_RNG, m; trace_assignments)
end

@inline function simulate(rng::AbstractRNG, m::Model; trace_assignments=false)
    return _simulate(getmoduletypencoding(m), m, NamedTuple())(rng)
end

simulate(m::Model; trace_assignments=false) = simulate(GLOBAL_RNG, m; trace_assignments)


sourceSimulate(m::Model; trace_assignments=false) = sourceSimulate(trace_assignments)(m)
sourceSimulate(jd::ConditionalModel; trace_assignments=false) = sourceSimulate(jd.model; trace_assignments)

export sourceSimulate
function sourceSimulate(trace_assignments=false) 
    ta = trace_assignments
    function(_m::Model)
        pars = sort(sampled(_m))
        
        tracekeys = sort(trace_assignments ? parameters(_m) : sampled(_m))
        _traceName = Dict((k => Symbol(:_trace_, k) for k in tracekeys))

        function proc(_m, st::Assign)
            q = @q begin $(st.x) = $(st.rhs) end
            if trace_assignments
                _traceName[st.x] = Symbol(:_trace_, st.x)
                push!(q.args, :($(_traceName[st.x]) = $(st.x)))
            end
            q
        end
        
        proc(_m, st::Sample)  = @q begin
            $(_traceName[st.x]) = simulate(_rng, $(st.rhs); trace_assignments=$ta)
            $(st.x) = value($(_traceName[st.x]))
        end

        proc(_m, st::Return)  = :(_value = $(st.rhs))
        proc(_m, st::LineNumber) = nothing

        _traces = map(x -> Expr(:(=), x,_traceName[x]), tracekeys) 

        wrap(kernel) = @q begin
            _rng -> begin
                _value = nothing
                $kernel
                _trace = $(Expr(:tuple, _traces...))
                return (value = _value, trace = _trace)
            end
        end

        buildSource(_m, proc, wrap) |> MacroTools.flatten
    end
end

# simulate(rng::AbstractRNG, d::Distribution; trace_assignments=false) = rand(rng, d)

# simulate(rng::AbstractRNG, d::iid{Int}; trace_assignments=false) = [simulate(rng, d.dist; trace_assignments) for j in 1:d.size]

trace(x::NamedTuple) = x.trace
trace(x) = x

using MeasureTheory: AbstractMeasure

simulate(μ::AbstractMeasure; trace_assignments=false) = simulate(Random.GLOBAL_RNG, μ; trace_assignments)

simulate(rng::AbstractRNG, μ::AbstractMeasure; trace_assignments=false) = rand(rng, sampletype(μ),  μ)

@gg M function _simulate(_::Type{M}, _m::Model, _args, trace_assignments::Val{V}) where {V, M <: TypeLevel{Module}}
    trace_assignments = V
    Expr(:let,
        Expr(:(=), :M, from_type(M)),
        type2model(_m) |> sourceSimulate(trace_assignments) |> loadvals(_args, NamedTuple()))
end

@gg M function _simulate(_::Type{M}, _m::Model, _args::NamedTuple{()}, trace_assignments::Val{V}) where {V, M <: TypeLevel{Module}}
    trace_assignments = V
    Expr(:let,
        Expr(:(=), :M, from_type(M)),
        type2model(_m) |> sourceSimulate(trace_assignments))
end