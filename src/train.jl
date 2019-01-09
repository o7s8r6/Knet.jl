import Base: length, size, tail, iterate, eltype, IteratorSize, IteratorEltype, haslength, SizeUnknown, @propagate_inbounds, HasEltype

"Example: `progress!(train(f,repeat(data,10)))`"
train(pred, data::I; loss=nll, optimizer=Adam(), callback=nothing, params=nothing, kw...) where {I} = Train{I}(data,pred,loss,optimizer,callback,params,kw,Any)
train!(x...; o...) = for x in train(x...; o...); end

struct Train{I}; data::I; pred; loss; optimizer; callback; params; kw; eltype; end

length(c::Train) = length(c.data)
size(c::Train) = size(c.data)
eltype(c::Train) = (c.eltype === Any ? (c.eltype=typeof(@diff c.loss(c.pred,first(c.data)...;c.kw...))) : c.eltype)
IteratorSize(::Type{Train{I}}) where {I} = IteratorSize(I)
IteratorEltype(::Type{<:Train}) = Base.HasEltype()

@propagate_inbounds function iterate(m::Train, s...)
    next = iterate(m.data, s...)
    next === nothing && return nothing
    (args, s) = next
    y = @diff m.loss(m.pred, args...; m.kw...)
    m.callback !== nothing && !m.callback(y) && return nothing
    for x in (m.params === nothing ? Params(y) : m.params)
        if x.opt === nothing
            x.opt = deepcopy(m.optimizer)
        end
        update!(x, grad(y,x))
    end
    return (y,s)
end

# progress(minimize(f, repeat(data,10)))
# A stream (iterator) based implementation: minimize works like map
# taking a stream of args and generating a stream of func values
# except applying gradient based updates to params at each step

"Example: `minimize(f,repeat(data,10))`"
minimize(f,d::I,a=Adam(); params=nothing) where {I} = Minimize{I}(d,f,a,params,Any)
minimize!(x...; o...) = for x in minimize(x...; o...); end

struct Minimize{I}; data::I; func; algo; params; eltype; end

length(c::Minimize) = length(c.data)
size(c::Minimize) = size(c.data)
eltype(c::Minimize) = (c.eltype === Any ? typeof(@diff c.func(first(c.data)...)) : c.eltype)
IteratorSize(::Type{Minimize{I}}) where {I} = IteratorSize(I)
IteratorEltype(::Type{<:Minimize}) = Base.HasEltype()

@propagate_inbounds function iterate(m::Minimize, s...)
    next = iterate(m.data, s...)
    next === nothing && return nothing
    (args, s) = next
    y = @diff m.func(args...)
    for x in (m.params === nothing ? Params(y) : m.params)
        if x.opt === nothing
            x.opt = deepcopy(m.algo)
        end
        update!(x, grad(y,x))
    end
    return (y,s)
end

"""
    converge(iter, alpha=0.001)

Copy the numeric iterator until values stop decreasing.
Example: `progress!(converge(minimize(f,cycle(data))))`
"""
converge(iter::I, alpha=0.001) where {I} = Converge{I}(iter, alpha)
converge!(x...; o...) = for x in converge(x...; o...); end

struct Converge{I}; iter::I; alpha::Float64; end

length(c::Converge) = length(c.iter)
size(c::Converge) = size(c.iter)
eltype(c::Converge) = eltype(c.iter)
IteratorSize(::Type{Converge{I}}) where {I} = IteratorSize(I)
IteratorEltype(::Type{Converge{I}}) where {I} = IteratorEltype(I)

@propagate_inbounds function iterate(c::Converge, s=(0.0,Inf))
    avgp,avgx,state = s[1],s[2],tail(tail(s))
    next = iterate(c.iter, state...)
    next === nothing && return nothing
    (item, state) = next
    x = value(item)
    if avgx == Inf; avgx = x; end
    p = x - avgx
    avgx = c.alpha * x + (1-c.alpha) * avgx
    avgp = c.alpha * p + (1-c.alpha) * avgp
    avgp > 0.0 && return nothing
    (item, (avgp, avgx, state))
end


# TODO: move to AutoGrad
"Returns an iterator over Params on Tape."
struct Params; tape::AutoGrad.Tape; end

eltype(::Type{Params}) = Param
IteratorEltype(::Type{Params}) = HasEltype()
IteratorSize(::Type{Params}) = SizeUnknown()

@propagate_inbounds function iterate(p::Params, s::Int=1)
    next = iterate(p.tape.list, s)
    while next !== nothing
        (n,s) = next
        if isa(n.Value,Param)
            return (n.Value,s)
        end
        next = iterate(p.tape.list, s)
    end
    nothing
end


"""
    param(array; atype)
    param(dims...; init, atype)
    param0(dims...; atype)

The first form returns `Param(atype(array))` where `atype=identity` is the default.

The second form Returns a randomly initialized `Param(atype(init(dims...)))`.
By default, `init` is `xavier` and `atype` is `KnetArray{Float32}` if `gpu() >= 0`,
otherwise `Array{Float32}`. 

The third form `param0` is an alias for `param(dims...; init=zeros)`.
"""
param,param0

# TODO: Knet.Param <: AutoGrad.Tracked as a separate type?
param(x::Union{Array,KnetArray}; atype=identity) = Param(atype(x))
param(d...; init=xavier, atype=atype())=Param(atype(init(d...)))
param0(d...; atype=atype())=param(d...; init=zeros, atype=atype)
atype()=(gpu() >= 0 ? KnetArray{Float32} : Array{Float32})


### DEPRECATED:

"""
    train!(model, data; loss, optimizer, callback, o...)

Train a model with given data.

* `model`: A callable object. `model(x; o...)` should return a prediction. `params(model)`
   will automatically iterate over model parameters.
* `data`: An iterator. `for (x,y) in data` should iterate over input-output pairs.
* `loss=nll`: A loss function, called with `J = @diff loss(model,x,y; o...)`.
* `optimizer=Adam()`: An optimizer object that will be copied for each parameter and used by
  `[update!]`(@ref).
* `callback`: To facilitate reporting and termination, a callback function is called before
   every update with `callback(J)`. Training continues if the return value is true, terminates
   if it is false. By default training will end after one pass over the data.
* Other keyword arguments `(o...)` will be passed to `loss` and possibly by `loss` to `model`.
"""
train!

"""
Pre-defined callback function constructors:

* converge(): Trains until convergence
* updates(n): Stops after n updates
* epochs(data,n): Trains for n epochs, equivalent to updates(n*length(data))
"""
converge, updates, epochs

function converge(alpha::Number = 0.001)
    avgx = Inf
    avgp = 0.0
    # prog = Progress()
    function callback(x)
        x = value(x)
        if avgx == Inf; avgx = x; end
        p = x - avgx
        avgx = alpha * x + (1-alpha) * avgx
        avgp = alpha * p + (1-alpha) * avgp
        # display_progress!(prog, x)
        return avgp <= 0.0
    end
    return callback
end

function updates(n)
    # p = Progress(n)
    function callback(x)
        # display_progress!(p, value(x))
        n -= 1
        return n > 0
    end
end

epochs(d,n)=updates(n*length(d))


### DEAD CODE:

# function train!(model, data; loss=nll, optimizer=Adam(), callback=epochs(data,1), o...)
#     ps = params(model)
#     for param in ps
#         if param.opt === nothing
#             param.opt = deepcopy(optimizer)
#         end
#     end
#     while true
#         for (x,y) in data
#             J = @diff loss(model,x,y; o...)
#             if !callback(J)
#                 return
#             end
#             for param in ps
#                 g = grad(J,param)
#                 update!(value(param),g,param.opt)
#             end
#         end
#     end
# end

    ## This may be slightly faster but risky if active params change
    # if m.params === nothing
    #     m.params = params(y, m.algo)
    # end
    # for x in m.params
    #     update!(x, grad(y,x))
    # end

# function AutoGrad.params(y::AutoGrad.Tape, optimizer=nothing)
#     p = Param[]
#     for node in y.list
#         x = node.Value
#         if isa(x, Param)
#             if x.opt === nothing && optimizer !== nothing
#                 x.opt = deepcopy(optimizer)
#             end
#             push!(p, x)
#         end
#     end
#     return p
# end

# # Simpler and more flexible alternative to train!
# # Does not care where model ends loss begins or where params are
# # data may consist of tuples of any number of args
# # Epochs can be set by data iterator (convergence cannot)
# function minimize!(func, data, optimizer=Adam())
#     for args in data
#         y = @diff func(args...)
#         for node in y.list      # breaks abstraction
#             x = node.Value
#             if isa(x, Param)
#                 g = grad(y,x)
#                 if x.opt === nothing; x.opt = deepcopy(optimizer); end
#                 update!(x.value, g, x.opt)
#             end
#         end
#     end
# end

### DEAD CODE


### Issues:
# + What if we call train multiple times, and don't want to use the optimizers?
# x Do we want parameter initialization as well? init and opt init should happen once.
# - Recording losses with different loss functions.
# x What info does the callback need?
# - Are we doing anything other than pushing kwargs from train to Train?
# - What if we want convergence in trnloss or convergence in devloss? Return earlier (best) model?
# + How do we easily measure epochs?
# + ProgressMeter both in time mode and converge mode.
# + Printing loss with ProgressMeter seems difficult.
# + Frequency of progress updates and loss calculations?

# + Keyword argument problem:
# - optimizer, loss, model can all take keyword args; how do we specify them through train?
# + We can give a constructed optimizer and deepcopy it for each param.
# ? We don't call model directly, only through loss (because it may need model params for regularization).
# ? So we pass all unrecognized kwargs to loss and let it sort out.

# x What to pass to the callback:
# x model, data, loss, optimizer and (o...) are all available to the caller. No need to pass to callback.
# x The only things that are not available are J,x,y. I can't think of a use for x,y.
# x That leaves J. I considered passing value(J), however that prevents the callback from looking at gradients.
# + (e.g. for reporting the gradient norms), so I decided to pass back J as is.

# x We assume a model is just a callable object (https://docs.julialang.org/en/v1/manual/methods/#Function-like-objects-1)
# x model(x) will give us a prediction, and params(model) will iterate over the parameters.

# + 20190105: Do we even need to assume this? train! can simply look at the Tape to find the
# + parameters! In that case optimizers would need to be set elsewhere.

# x use HasLength after data
# x converge may not have length?
# + first efficiency of iterating y.list
# x separate Param in Knet?

# + write train(model,data) iterator style
# + fix update between display_progress and progress
# x progress should handle HasLength
# + use tape iter in train
# + write params tape as iterator
# - check regularization: 
#     do we need opt args?
#     regularizer as parametric fn?
#     regularizer as part of optimizer?
# - write docs
# x use throttle?

# + use cycle for repeat
# + use take for updates: take(cycle(data),n)
# + shuffling during repeats?
# x filter for params(tape) and converge?
# + make params an optional argument
