# This file is a part of Julia. License is MIT: https://julialang.org/license

## Code for searching and viewing documentation

using Markdown

using Base.Docs: catdoc, modules, DocStr, Binding, MultiDoc, keywords, isfield, namify, bindingexpr,
    defined, resolve, getdoc, meta, aliasof, signature

import Base.Docs: doc, formatdoc, parsedoc, apropos

using Base: with_output_color, mapany

import REPL

using InteractiveUtils: subtypes

using Unicode: normalize

## Help mode ##

# This is split into helpmode and _helpmode to easier unittest _helpmode
helpmode(io::IO, line::AbstractString, mod::Module=Main) = :($REPL.insert_hlines($io, $(REPL._helpmode(io, line, mod))))
helpmode(line::AbstractString, mod::Module=Main) = helpmode(stdout, line, mod)

const extended_help_on = Ref{Any}(nothing)

function _helpmode(io::IO, line::AbstractString, mod::Module=Main)
    line = strip(line)
    ternary_operator_help = (line == "?" || line == "?:")
    if startswith(line, '?') && !ternary_operator_help
        line = line[2:end]
        extended_help_on[] = line
        brief = false
    else
        extended_help_on[] = nothing
        brief = true
    end
    # interpret anything starting with # or #= as asking for help on comments
    if startswith(line, "#")
        if startswith(line, "#=")
            line = "#="
        else
            line = "#"
        end
    end
    x = Meta.parse(line, raise = false, depwarn = false)
    assym = Symbol(line)
    expr =
        if haskey(keywords, Symbol(line)) || Base.isoperator(assym) || isexpr(x, :error) ||
            isexpr(x, :invalid) || isexpr(x, :incomplete)
            # Docs for keywords must be treated separately since trying to parse a single
            # keyword such as `function` would throw a parse error due to the missing `end`.
            assym
        elseif isexpr(x, (:using, :import))
            (x::Expr).head
        else
            # Retrieving docs for macros requires us to make a distinction between the text
            # `@macroname` and `@macroname()`. These both parse the same, but are used by
            # the docsystem to return different results. The first returns all documentation
            # for `@macroname`, while the second returns *only* the docs for the 0-arg
            # definition if it exists.
            (isexpr(x, :macrocall, 1) && !endswith(line, "()")) ? quot(x) : x
        end
    # the following must call repl(io, expr) via the @repl macro
    # so that the resulting expressions are evaluated in the Base.Docs namespace
    :($REPL.@repl $io $expr $brief $mod)
end
_helpmode(line::AbstractString, mod::Module=Main) = _helpmode(stdout, line, mod)

# Print vertical lines along each docstring if there are multiple docs
function insert_hlines(io::IO, docs)
    if !isa(docs, Markdown.MD) || !haskey(docs.meta, :results) || isempty(docs.meta[:results])
        return docs
    end
    docs = docs::Markdown.MD
    v = Any[]
    for (n, doc) in enumerate(docs.content)
        push!(v, doc)
        n == length(docs.content) || push!(v, Markdown.HorizontalRule())
    end
    return Markdown.MD(v)
end

function formatdoc(d::DocStr)
    buffer = IOBuffer()
    for part in d.text
        formatdoc(buffer, d, part)
    end
    Markdown.MD(Any[Markdown.parse(seekstart(buffer))])
end
@noinline formatdoc(buffer, d, part) = print(buffer, part)

function parsedoc(d::DocStr)
    if d.object === nothing
        md = formatdoc(d)
        md.meta[:module] = d.data[:module]
        md.meta[:path]   = d.data[:path]
        d.object = md
    end
    d.object
end

## Trimming long help ("# Extended help")

struct Message  # For direct messages to the terminal
    msg    # AbstractString
    fmt    # keywords to `printstyled`
end
Message(msg) = Message(msg, ())

function Markdown.term(io::IO, msg::Message, columns)
    printstyled(io, msg.msg; msg.fmt...)
end

trimdocs(doc, brief::Bool) = doc

function trimdocs(md::Markdown.MD, brief::Bool)
    brief || return md
    md, trimmed = _trimdocs(md, brief)
    if trimmed
        line = extended_help_on[]
        line = isa(line, AbstractString) ? line : ""
        push!(md.content, Message("Extended help is available with `??$line`", (color=Base.info_color(), bold=true)))
    end
    return md
end

function _trimdocs(md::Markdown.MD, brief::Bool)
    content, trimmed = [], false
    for c in md.content
        if isa(c, Markdown.Header{1}) && isa(c.text, AbstractArray) && !isempty(c.text)
            item = c.text[1]
            if isa(item, AbstractString) &&
                lowercase(item) ∈ ("extended help",
                                   "extended documentation",
                                   "extended docs")
                trimmed = true
                break
            end
        end
        c, trm = _trimdocs(c, brief)
        trimmed |= trm
        push!(content, c)
    end
    return Markdown.MD(content, md.meta), trimmed
end

_trimdocs(md, brief::Bool) = md, false

"""
    Docs.doc(binding, sig)

Return all documentation that matches both `binding` and `sig`.

If `getdoc` returns a non-`nothing` result on the value of the binding, then a
dynamic docstring is returned instead of one based on the binding itself.
"""
function doc(binding::Binding, sig::Type = Union{})
    if defined(binding)
        result = getdoc(resolve(binding), sig)
        result === nothing || return result
    end
    results, groups = DocStr[], MultiDoc[]
    # Lookup `binding` and `sig` for matches in all modules of the docsystem.
    for mod in modules
        dict = meta(mod)
        if haskey(dict, binding)
            multidoc = dict[binding]
            push!(groups, multidoc)
            for msig in multidoc.order
                sig <: msig && push!(results, multidoc.docs[msig])
            end
        end
    end
    if isempty(groups)
        # When no `MultiDoc`s are found that match `binding` then we check whether `binding`
        # is an alias of some other `Binding`. When it is we then re-run `doc` with that
        # `Binding`, otherwise if it's not an alias then we generate a summary for the
        # `binding` and display that to the user instead.
        alias = aliasof(binding)
        alias == binding ? summarize(alias, sig) : doc(alias, sig)
    else
        # There was at least one match for `binding` while searching. If there weren't any
        # matches for `sig` then we concatenate *all* the docs from the matching `Binding`s.
        if isempty(results)
            for group in groups, each in group.order
                push!(results, group.docs[each])
            end
        end
        # Get parsed docs and concatenate them.
        md = catdoc(mapany(parsedoc, results)...)
        # Save metadata in the generated markdown.
        if isa(md, Markdown.MD)
            md.meta[:results] = results
            md.meta[:binding] = binding
            md.meta[:typesig] = sig
        end
        return md
    end
end

# Some additional convenience `doc` methods that take objects rather than `Binding`s.
doc(obj::UnionAll) = doc(Base.unwrap_unionall(obj))
doc(object, sig::Type = Union{}) = doc(aliasof(object, typeof(object)), sig)
doc(object, sig...)              = doc(object, Tuple{sig...})

function lookup_doc(ex)
    if isa(ex, Expr) && ex.head !== :(.) && Base.isoperator(ex.head)
        # handle syntactic operators, e.g. +=, ::, .=
        ex = ex.head
    end
    if haskey(keywords, ex)
        return parsedoc(keywords[ex])
    elseif Meta.isexpr(ex, :incomplete)
        return :($(Markdown.md"No documentation found."))
    elseif !isa(ex, Expr) && !isa(ex, Symbol)
        return :($(doc)($(typeof)($(esc(ex)))))
    end
    if isa(ex, Symbol) && Base.isoperator(ex)
        str = string(ex)
        isdotted = startswith(str, ".")
        if endswith(str, "=") && Base.operator_precedence(ex) == Base.prec_assignment && ex !== :(:=)
            op = chop(str)
            eq = isdotted ? ".=" : "="
            return Markdown.parse("`x $op= y` is a synonym for `x $eq x $op y`")
        elseif isdotted && ex !== :(..)
            op = str[2:end]
            return Markdown.parse("`x $ex y` is akin to `broadcast($op, x, y)`. See [`broadcast`](@ref).")
        end
    end
    binding = esc(bindingexpr(namify(ex)))
    if isexpr(ex, :call) || isexpr(ex, :macrocall)
        sig = esc(signature(ex))
        :($(doc)($binding, $sig))
    else
        :($(doc)($binding))
    end
end

# Object Summaries.
# =================

function summarize(binding::Binding, sig)
    io = IOBuffer()
    if defined(binding)
        binding_res = resolve(binding)
        !isa(binding_res, Module) && println(io, "No documentation found.\n")
        summarize(io, binding_res, binding)
    else
        println(io, "No documentation found.\n")
        quot = any(isspace, sprint(print, binding)) ? "'" : ""
        println(io, "Binding ", quot, "`", binding, "`", quot, " does not exist.")
    end
    md = Markdown.parse(seekstart(io))
    # Save metadata in the generated markdown.
    md.meta[:results] = DocStr[]
    md.meta[:binding] = binding
    md.meta[:typesig] = sig
    return md
end

function summarize(io::IO, λ::Function, binding::Binding)
    kind = startswith(string(binding.var), '@') ? "macro" : "`Function`"
    println(io, "`", binding, "` is a ", kind, ".")
    println(io, "```\n", methods(λ), "\n```")
end

function summarize(io::IO, TT::Type, binding::Binding)
    println(io, "# Summary")
    T = Base.unwrap_unionall(TT)
    if T isa DataType
        println(io, "```")
        print(io,
            Base.isabstracttype(T) ? "abstract type " :
            Base.ismutabletype(T)  ? "mutable struct " :
            Base.isstructtype(T) ? "struct " :
            "primitive type ")
        supert = supertype(T)
        println(io, T)
        println(io, "```")
        if !Base.isabstracttype(T) && T.name !== Tuple.name && !isempty(fieldnames(T))
            println(io, "# Fields")
            println(io, "```")
            pad = maximum(length(string(f)) for f in fieldnames(T))
            for (f, t) in zip(fieldnames(T), fieldtypes(T))
                println(io, rpad(f, pad), " :: ", t)
            end
            println(io, "```")
        end
        subt = subtypes(TT)
        if !isempty(subt)
            println(io, "# Subtypes")
            println(io, "```")
            for t in subt
                println(io, Base.unwrap_unionall(t))
            end
            println(io, "```")
        end
        if supert != Any
            println(io, "# Supertype Hierarchy")
            println(io, "```")
            Base.show_supertypes(io, T)
            println(io)
            println(io, "```")
        end
    elseif T isa Union
        println(io, "`", binding, "` is of type `", typeof(TT), "`.\n")
        println(io, "# Union Composed of Types")
        for T1 in Base.uniontypes(T)
            println(io, " - `", Base.rewrap_unionall(T1, TT), "`")
        end
    else # unreachable?
        println(io, "`", binding, "` is of type `", typeof(TT), "`.\n")
    end
end

function find_readme(m::Module)::Union{String, Nothing}
    mpath = pathof(m)
    isnothing(mpath) && return nothing
    !isfile(mpath) && return nothing # modules in sysimage, where src files are omitted
    path = dirname(mpath)
    top_path = pkgdir(m)
    while true
        for file in readdir(path; join=true, sort=true)
            isfile(file) && (basename(lowercase(file)) in ["readme.md", "readme"]) || continue
            return file
        end
        path == top_path && break # go no further than pkgdir
        path = dirname(path) # work up through nested modules
    end
    return nothing
end
function summarize(io::IO, m::Module, binding::Binding; nlines::Int = 200)
    readme_path = find_readme(m)
    if isnothing(readme_path)
        println(io, "No docstring or readme file found for module `$m`.\n")
    else
        println(io, "No docstring found for module `$m`.")
    end
    exports = filter!(!=(nameof(m)), names(m))
    if isempty(exports)
        println(io, "Module does not export any names.")
    else
        println(io, "# Exported names")
        print(io, "  `")
        join(io, exports, "`, `")
        println(io, "`\n")
    end
    if !isnothing(readme_path)
        readme_lines = readlines(readme_path)
        isempty(readme_lines) && return  # don't say we are going to print empty file
        println(io, "# Displaying contents of readme found at `$(readme_path)`")
        for line in first(readme_lines, nlines)
            println(io, line)
        end
        length(readme_lines) > nlines && println(io, "\n[output truncated to first $nlines lines]")
    end
end

function summarize(io::IO, @nospecialize(T), binding::Binding)
    T = typeof(T)
    println(io, "`", binding, "` is of type `", T, "`.\n")
    summarize(io, T, binding)
end

# repl search and completions for help


quote_spaces(x) = any(isspace, x) ? "'" * x * "'" : x

function repl_search(io::IO, s::Union{Symbol,String}, mod::Module)
    pre = "search:"
    print(io, pre)
    printmatches(io, s, map(quote_spaces, doc_completions(s, mod)), cols = _displaysize(io)[2] - length(pre))
    println(io, "\n")
end

# TODO: document where this is used
repl_search(s, mod::Module) = repl_search(stdout, s, mod)

function repl_corrections(io::IO, s, mod::Module)
    print(io, "Couldn't find ")
    quot = any(isspace, s) ? "'" : ""
    print(io, quot)
    printstyled(io, s, color=:cyan)
    print(io, quot, '\n')
    print_correction(io, s, mod)
end
repl_corrections(s) = repl_corrections(stdout, s)

# inverse of latex_symbols Dict, lazily created as needed
const symbols_latex = Dict{String,String}()
function symbol_latex(s::String)
    if isempty(symbols_latex) && isassigned(Base.REPL_MODULE_REF)
        for (k,v) in Iterators.flatten((REPLCompletions.latex_symbols,
                                        REPLCompletions.emoji_symbols))
            symbols_latex[v] = k
        end

        # Overwrite with canonical mapping when a symbol has several completions (#39148)
        merge!(symbols_latex, REPLCompletions.symbols_latex_canonical)
    end

    return get(symbols_latex, s, "")
end
function repl_latex(io::IO, s0::String)
    # This has rampant `Core.Box` problems (#15276). Use the tricks of
    # https://docs.julialang.org/en/v1/manual/performance-tips/#man-performance-captured
    # We're changing some of the values so the `let` trick isn't applicable.
    s::String = s0
    latex::String = symbol_latex(s)
    if isempty(latex)
        # Decompose NFC-normalized identifier to match tab-completion
        # input if the first search came up empty.
        s = normalize(s, :NFD)
        latex = symbol_latex(s)
    end
    if !isempty(latex)
        print(io, "\"")
        printstyled(io, s, color=:cyan)
        print(io, "\" can be typed by ")
        printstyled(io, latex, "<tab>", color=:cyan)
        println(io, '\n')
    elseif any(c -> haskey(symbols_latex, string(c)), s)
        print(io, "\"")
        printstyled(io, s, color=:cyan)
        print(io, "\" can be typed by ")
        state::Char = '\0'
        with_output_color(:cyan, io) do io
            for c in s
                cstr = string(c)
                if haskey(symbols_latex, cstr)
                    latex = symbols_latex[cstr]
                    if length(latex) == 3 && latex[2] in ('^','_')
                        # coalesce runs of sub/superscripts
                        if state != latex[2]
                            '\0' != state && print(io, "<tab>")
                            print(io, latex[1:2])
                            state = latex[2]
                        end
                        print(io, latex[3])
                    else
                        if '\0' != state
                            print(io, "<tab>")
                            state = '\0'
                        end
                        print(io, latex, "<tab>")
                    end
                else
                    if '\0' != state
                        print(io, "<tab>")
                        state = '\0'
                    end
                    print(io, c)
                end
            end
            '\0' != state && print(io, "<tab>")
        end
        println(io, '\n')
    end
end
repl_latex(s::String) = repl_latex(stdout, s)

macro repl(ex, brief::Bool=false, mod::Module=Main) repl(ex; brief, mod) end
macro repl(io, ex, brief, mod) repl(io, ex; brief, mod) end

function repl(io::IO, s::Symbol; brief::Bool=true, mod::Module=Main)
    str = string(s)
    quote
        repl_latex($io, $str)
        repl_search($io, $str, $mod)
        $(if !isdefined(mod, s) && !haskey(keywords, s) && !Base.isoperator(s)
               :(repl_corrections($io, $str, $mod))
          end)
        $(_repl(s, brief))
    end
end
isregex(x) = isexpr(x, :macrocall, 3) && x.args[1] === Symbol("@r_str") && !isempty(x.args[3])

repl(io::IO, ex::Expr; brief::Bool=true, mod::Module=Main) = isregex(ex) ? :(apropos($io, $ex)) : _repl(ex, brief)
repl(io::IO, str::AbstractString; brief::Bool=true, mod::Module=Main) = :(apropos($io, $str))
repl(io::IO, other; brief::Bool=true, mod::Module=Main) = esc(:(@doc $other))
#repl(io::IO, other) = lookup_doc(other) # TODO

repl(x; brief::Bool=true, mod::Module=Main) = repl(stdout, x; brief, mod)

function _repl(x, brief::Bool=true)
    if isexpr(x, :call)
        x = x::Expr
        # determine the types of the values
        kwargs = nothing
        pargs = Any[]
        for arg in x.args[2:end]
            if isexpr(arg, :parameters)
                kwargs = mapany(arg.args) do kwarg
                    if kwarg isa Symbol
                        kwarg = :($kwarg::Any)
                    elseif isexpr(kwarg, :kw)
                        lhs = kwarg.args[1]
                        rhs = kwarg.args[2]
                        if lhs isa Symbol
                            if rhs isa Symbol
                                kwarg.args[1] = :($lhs::(@isdefined($rhs) ? typeof($rhs) : Any))
                            else
                                kwarg.args[1] = :($lhs::typeof($rhs))
                            end
                        end
                    end
                    kwarg
                end
            elseif isexpr(arg, :kw)
                if kwargs === nothing
                    kwargs = Any[]
                end
                lhs = arg.args[1]
                rhs = arg.args[2]
                if lhs isa Symbol
                    if rhs isa Symbol
                        arg.args[1] = :($lhs::(@isdefined($rhs) ? typeof($rhs) : Any))
                    else
                        arg.args[1] = :($lhs::typeof($rhs))
                    end
                end
                push!(kwargs, arg)
            else
                if arg isa Symbol
                    arg = :($arg::(@isdefined($arg) ? typeof($arg) : Any))
                elseif !isexpr(arg, :(::))
                    arg = :(::typeof($arg))
                end
                push!(pargs, arg)
            end
        end
        if kwargs === nothing
            x.args = Any[x.args[1], pargs...]
        else
            x.args = Any[x.args[1], Expr(:parameters, kwargs...), pargs...]
        end
    end
    #docs = lookup_doc(x) # TODO
    docs = esc(:(@doc $x))
    docs = if isfield(x)
        quote
            if isa($(esc(x.args[1])), DataType)
                fielddoc($(esc(x.args[1])), $(esc(x.args[2])))
            else
                $docs
            end
        end
    else
        docs
    end
    :(REPL.trimdocs($docs, $brief))
end

"""
    fielddoc(binding, field)

Return documentation for a particular `field` of a type if it exists.
"""
function fielddoc(binding::Binding, field::Symbol)
    for mod in modules
        dict = meta(mod)
        if haskey(dict, binding)
            multidoc = dict[binding]
            if haskey(multidoc.docs, Union{})
                fields = multidoc.docs[Union{}].data[:fields]
                if haskey(fields, field)
                    doc = fields[field]
                    return isa(doc, Markdown.MD) ? doc : Markdown.parse(doc)
                end
            end
        end
    end
    fields = join(["`$f`" for f in fieldnames(resolve(binding))], ", ", ", and ")
    fields = isempty(fields) ? "no fields" : "fields $fields"
    Markdown.parse("`$(resolve(binding))` has $fields.")
end

# As with the additional `doc` methods, this converts an object to a `Binding` first.
fielddoc(object, field::Symbol) = fielddoc(aliasof(object, typeof(object)), field)


# Search & Rescue
# Utilities for correcting user mistakes and (eventually)
# doing full documentation searches from the repl.

# Fuzzy Search Algorithm

function matchinds(needle, haystack; acronym::Bool = false)
    chars = collect(needle)
    is = Int[]
    lastc = '\0'
    for (i, char) in enumerate(haystack)
        while !isempty(chars) && isspace(first(chars))
            popfirst!(chars) # skip spaces
        end
        isempty(chars) && break
        if lowercase(char) == lowercase(chars[1]) &&
           (!acronym || !isletter(lastc))
            push!(is, i)
            popfirst!(chars)
        end
        lastc = char
    end
    return is
end

longer(x, y) = length(x) ≥ length(y) ? (x, true) : (y, false)

bestmatch(needle, haystack) =
    longer(matchinds(needle, haystack, acronym = true),
           matchinds(needle, haystack))

avgdistance(xs) =
    isempty(xs) ? 0 :
    (xs[end] - xs[1] - length(xs)+1)/length(xs)

function fuzzyscore(needle, haystack)
    score = 0.
    is, acro = bestmatch(needle, haystack)
    score += (acro ? 2 : 1)*length(is) # Matched characters
    score -= 2(length(needle)-length(is)) # Missing characters
    !acro && (score -= avgdistance(is)/10) # Contiguous
    !isempty(is) && (score -= sum(is)/length(is)/100) # Closer to beginning
    return score
end

function fuzzysort(search::String, candidates::Vector{String})
    scores = map(cand -> (fuzzyscore(search, cand), -Float64(levenshtein(search, cand))), candidates)
    candidates[sortperm(scores)] |> reverse
end

# Levenshtein Distance

function levenshtein(s1, s2)
    a, b = collect(s1), collect(s2)
    m = length(a)
    n = length(b)
    d = Matrix{Int}(undef, m+1, n+1)

    d[1:m+1, 1] = 0:m
    d[1, 1:n+1] = 0:n

    for i = 1:m, j = 1:n
        d[i+1,j+1] = min(d[i  , j+1] + 1,
                         d[i+1, j  ] + 1,
                         d[i  , j  ] + (a[i] != b[j]))
    end

    return d[m+1, n+1]
end

function levsort(search::String, candidates::Vector{String})
    scores = map(cand -> (Float64(levenshtein(search, cand)), -fuzzyscore(search, cand)), candidates)
    candidates = candidates[sortperm(scores)]
    i = 0
    for outer i = 1:length(candidates)
        levenshtein(search, candidates[i]) > 3 && break
    end
    return candidates[1:i]
end

# Result printing

function printmatch(io::IO, word, match)
    is, _ = bestmatch(word, match)
    for (i, char) = enumerate(match)
        if i in is
            printstyled(io, char, bold=true)
        else
            print(io, char)
        end
    end
end

function printmatches(io::IO, word, matches; cols::Int = _displaysize(io)[2])
    total = 0
    for match in matches
        total + length(match) + 1 > cols && break
        fuzzyscore(word, match) < 0 && break
        print(io, " ")
        printmatch(io, word, match)
        total += length(match) + 1
    end
end

printmatches(args...; cols::Int = _displaysize(stdout)[2]) = printmatches(stdout, args..., cols = cols)

function print_joined_cols(io::IO, ss::Vector{String}, delim = "", last = delim; cols::Int = _displaysize(io)[2])
    i = 0
    total = 0
    for outer i = 1:length(ss)
        total += length(ss[i])
        total + max(i-2,0)*length(delim) + (i>1 ? 1 : 0)*length(last) > cols && (i-=1; break)
    end
    join(io, ss[1:i], delim, last)
end

print_joined_cols(args...; cols::Int = _displaysize(stdout)[2]) = print_joined_cols(stdout, args...; cols=cols)

function print_correction(io::IO, word::String, mod::Module)
    cors = map(quote_spaces, levsort(word, accessible(mod)))
    pre = "Perhaps you meant "
    print(io, pre)
    print_joined_cols(io, cors, ", ", " or "; cols = _displaysize(io)[2] - length(pre))
    println(io)
    return
end

# TODO: document where this is used
print_correction(word, mod::Module) = print_correction(stdout, word, mod)

# Completion data


moduleusings(mod) = ccall(:jl_module_usings, Any, (Any,), mod)

filtervalid(names) = filter(x->!occursin(r"#", x), map(string, names))

accessible(mod::Module) =
    Symbol[filter!(s -> !Base.isdeprecated(mod, s), names(mod, all=true, imported=true));
           map(names, moduleusings(mod))...;
           collect(keys(Base.Docs.keywords))] |> unique |> filtervalid

function doc_completions(name, mod::Module=Main)
    res = fuzzysort(name, accessible(mod))

    # to insert an entry like `raw""` for `"@raw_str"` in `res`
    ms = match.(r"^@(.*?)_str$", res)
    idxs = findall(!isnothing, ms)

    # avoid messing up the order while inserting
    for i in reverse(idxs)
        c = only((ms[i]::AbstractMatch).captures)
        insert!(res, i, "$(c)\"\"")
    end
    res
end
doc_completions(name::Symbol) = doc_completions(string(name), mod)


# Searching and apropos

# Docsearch simply returns true or false if an object contains the given needle
docsearch(haystack::AbstractString, needle) = occursin(needle, haystack)
docsearch(haystack::Symbol, needle) = docsearch(string(haystack), needle)
docsearch(::Nothing, needle) = false
function docsearch(haystack::Array, needle)
    for elt in haystack
        docsearch(elt, needle) && return true
    end
    false
end
function docsearch(haystack, needle)
    @warn "Unable to search documentation of type $(typeof(haystack))" maxlog=1
    false
end

## Searching specific documentation objects
function docsearch(haystack::MultiDoc, needle)
    for v in values(haystack.docs)
        docsearch(v, needle) && return true
    end
    false
end

function docsearch(haystack::DocStr, needle)
    docsearch(parsedoc(haystack), needle) && return true
    if haskey(haystack.data, :fields)
        for doc in values(haystack.data[:fields])
            docsearch(doc, needle) && return true
        end
    end
    false
end

## doc search

## Markdown search simply strips all markup and searches plain text version
docsearch(haystack::Markdown.MD, needle) = docsearch(stripmd(haystack.content), needle)

"""
    stripmd(x)

Strip all Markdown markup from x, leaving the result in plain text. Used
internally by apropos to make docstrings containing more than one markdown
element searchable.
"""
stripmd(@nospecialize x) = string(x) # for random objects interpolated into the docstring
stripmd(x::AbstractString) = x  # base case
stripmd(x::Nothing) = " "
stripmd(x::Vector) = string(map(stripmd, x)...)

stripmd(x::Markdown.BlockQuote) = "$(stripmd(x.content))"
stripmd(x::Markdown.Admonition) = "$(stripmd(x.content))"
stripmd(x::Markdown.Bold) = "$(stripmd(x.text))"
stripmd(x::Markdown.Code) = "$(stripmd(x.code))"
stripmd(x::Markdown.Header) = stripmd(x.text)
stripmd(x::Markdown.HorizontalRule) = " "
stripmd(x::Markdown.Image) = "$(stripmd(x.alt)) $(x.url)"
stripmd(x::Markdown.Italic) = "$(stripmd(x.text))"
stripmd(x::Markdown.LaTeX) = "$(x.formula)"
stripmd(x::Markdown.LineBreak) = " "
stripmd(x::Markdown.Link) = "$(stripmd(x.text)) $(x.url)"
stripmd(x::Markdown.List) = join(map(stripmd, x.items), " ")
stripmd(x::Markdown.MD) = join(map(stripmd, x.content), " ")
stripmd(x::Markdown.Paragraph) = stripmd(x.content)
stripmd(x::Markdown.Footnote) = "$(stripmd(x.id)) $(stripmd(x.text))"
stripmd(x::Markdown.Table) =
    join([join(map(stripmd, r), " ") for r in x.rows], " ")

"""
    apropos([io::IO=stdout], pattern::Union{AbstractString,Regex})

Search available docstrings for entries containing `pattern`.

When `pattern` is a string, case is ignored. Results are printed to `io`.

`apropos` can be called from the help mode in the REPL by wrapping the query in double quotes:
```
help?> "pattern"
```
"""
apropos(string) = apropos(stdout, string)
apropos(io::IO, string) = apropos(io, Regex("\\Q$string", "i"))

function apropos(io::IO, needle::Regex)
    for mod in modules
        # Module doc might be in README.md instead of the META dict
        docsearch(doc(mod), needle) && println(io, mod)
        for (k, v) in meta(mod)
            docsearch(v, needle) && println(io, k)
        end
    end
end
