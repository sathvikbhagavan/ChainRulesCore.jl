"""
    AbstractZero <: AbstractTangent

Supertype for zero-like tangents—i.e., tangents that act like zero when
added or multiplied to other values.
If an AD system encounters a propagator that takes as input only subtypes of `AbstractZero`,
then it can stop performing AD operations.
All propagators are linear functions, and thus the final result will be zero.

All `AbstractZero` subtypes are singleton types.
There are two of them: [`ZeroTangent()`](@ref) and [`NoTangent()`](@ref).
"""
abstract type AbstractZero <: AbstractTangent end
Base.iszero(::AbstractZero) = true

Base.iterate(x::AbstractZero) = (x, nothing)
Base.iterate(::AbstractZero, ::Any) = nothing

Base.first(x::AbstractZero) = x
Base.tail(x::AbstractZero) = x
Base.last(x::AbstractZero) = x

Base.Broadcast.broadcastable(x::AbstractZero) = Ref(x)
Base.Broadcast.broadcasted(::Type{T}) where {T<:AbstractZero} = T()

LinearAlgebra.norm(::AbstractZero) = 0

# Linear operators
Base.adjoint(z::AbstractZero) = z
Base.transpose(z::AbstractZero) = z
Base.:/(z::AbstractZero, ::Any) = z

Base.convert(::Type{T}, x::AbstractZero) where {T<:Number} = zero(T)
# (::Type{T})(::AbstractZero, ::AbstractZero...) where {T<:Number} = zero(T)

(::Type{Complex})(x::AbstractZero, y::Real) = Complex(false, y)
(::Type{Complex})(x::Real, y::AbstractZero) = Complex(x, false)

Base.getindex(z::AbstractZero, args...) = z
Base.getproperty(z::AbstractZero, name::Symbol) = z


Base.view(z::AbstractZero, ind...) = z
Base.sum(z::AbstractZero; dims=:) = z
Base.reshape(z::AbstractZero, size...) = z
Base.reverse(z::AbstractZero, args...; kwargs...) = z

(::Type{<:UniformScaling})(z::AbstractZero) = z

"""
    ZeroTangent() <: AbstractZero

The additive identity for tangents.
This is basically the same as `0`.
A derivative of `ZeroTangent()` does not propagate through the primal function.
"""
struct ZeroTangent <: AbstractZero end

Base.eltype(::Type{ZeroTangent}) = ZeroTangent

Base.zero(::AbstractTangent) = ZeroTangent()
Base.zero(::Type{<:AbstractTangent}) = ZeroTangent()

"""
    NoTangent() <: AbstractZero

This tangent indicates that the derivative does not exist.
It is the tangent type for primal types that are not differentiable,
such as integers or booleans (when they are not being used to represent
floating-point values).
The only valid way to perturb such values is to not change them at all.
As a consequence, `NoTangent` is functionally identical to `ZeroTangent()`,
but it provides additional semantic information.

Adding `NoTangent()` to a primal is generally wrong: gradient-based
methods cannot be used to optimize over discrete variables.
An optimization package making use of this might want to check for such a case.

!!! note
    This does not indicate that the derivative is not implemented,
    but rather that mathematically it is not defined.

This mostly shows up as the derivative with respect to dimension, index, or size
arguments.
```
    function rrule(fill, x, len::Int)
        y = fill(x, len)
        fill_pullback(ȳ) = (NoTangent(), @thunk(sum(Ȳ)), NoTangent())
        return y, fill_pullback
    end
```
"""
struct NoTangent <: AbstractZero end

"""
    zero_tangent(primal)

This returns an appropriate zero tangent suitable for accumulating tangents of the primal.
For mutable composites types this is a structural []`MutableTangent`](@ref)
For `Array`s, it is applied recursively for each element.
For immutable types, this is simply [`ZeroTangent()`](@ref) as accumulation is default out-of-place for contexts where mutation does not apply.
(Where mutation is not to be supported even for mutable types, then [`ZeroTangent()`](@ref) should be used for everything)

!!! warning Exprimental
    `zero_tangent`is an experimental feature, and is part of the mutation support featureset.
    While this notice remains it may have changes in behavour, and interface in any _minor_ version of ChainRulesCore.
    Exactly how it should be used (e.g. is it forward-mode only?)
"""
function zero_tangent end

zero_tangent(x::Number) = zero(x)

@generated function zero_tangent(primal)
    zfield_exprs = map(fieldnames(primal)) do fname
        fval = :(
            if isdefined(primal, $(QuoteNode(fname)))
                zero_tangent(getfield(primal, $(QuoteNode(fname))))
            else
                # This is going to be potentially bad, but that's what they get for not giving us a primal
                # This will never me mutated inplace, rather it will alway be replaced with an actual value first
                ZeroTangent()
            end
        )
        Expr(:kw, fname, fval)
    end
    
    return if has_mutable_tangent(primal)
        any_mask = map(fieldnames(primal), fieldtypes(primal)) do fname, ftype
            # If it is is unassigned, or if it doesn't have a concrete type, let it take any value for its tangent
            fdef = :(!isdefined(primal, $(QuoteNode(fname))) || !isconcretetype($ftype))
            Expr(:kw, fname, fdef)
        end
        :($MutableTangent{$primal}(
            $(Expr(:tuple, Expr(:parameters, any_mask...))),
            $(Expr(:tuple, Expr(:parameters, zfield_exprs...)))
        ))
    else
        :($Tangent{$primal}($(Expr(:parameters, zfield_exprs...))))
    end    
end

zero_tangent(primal::Tuple) = Tangent{typeof(primal)}(map(zero_tangent, primal)...)

function zero_tangent(x::Array{P,N}) where {P,N}
    if (isbitstype(P) || all(i -> isassigned(x, i), eachindex(x)))
        return map(zero_tangent, x)
    end

    # Now we need to handle nonfully assigned arrays
    # see discussion at https://github.com/JuliaDiff/ChainRulesCore.jl/pull/626#discussion_r1345235265
    y = Array{guess_zero_tangent_type(P),N}(undef, size(x)...)
    @inbounds for n in eachindex(y)
        if isassigned(x, n)
            y[n] = zero_tangent(x[n])
        end
    end
    return y
end

# Sad heauristic methods we need because of unassigned values
guess_zero_tangent_type(::Type{T}) where {T<:Number} = T
guess_zero_tangent_type(::Type{T}) where {T<:Integer} = typeof(float(zero(T)))
guess_zero_tangent_type(::Type{<:Array{T,N}}) where {T,N} = return Array{guess_zero_tangent_type(T),N}
guess_zero_tangent_type(T::Type)=  Any