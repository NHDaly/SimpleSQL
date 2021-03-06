module SimpleSQL
using Serialization  # for file-backed datastores.

# SQL query-style API
export @SQL, @CREATE, @INSERT, @SELECT, @WHERE, @GROUP
# julia function-style api.
export create_table, insert_into_values, select_from
# Disk i/o
export write_table_to_disk, read_table_from_disk

struct Table
    title::String
    headers
    cols
end
""" users = create_table("users", (:id, Int64), (:name, String)) """
create_table(title, key_pairs...) =
    create_table(title, collect((Symbol(s),t) for (s,t) in key_pairs))
function create_table(title, key_pairs::Vector{Tuple{Symbol, Type}})
    cols = Tuple((Vector{T}() for (s,T) in key_pairs))
    return Table(title, [k for (k,v) in key_pairs], cols)
end
function create_table(title, key_pairs::Vector{Tuple{Symbol, DataType}})
    cols = Tuple((Vector{T}() for (s,T) in key_pairs))
    return Table(title, [k for (k,v) in key_pairs], cols)
end

function write_table_to_disk(table, filename)
    if !isempty(filename)
        io = open(filename, "w")
        serialize(io, table)
        close(io)
    end
end
function read_table_from_disk(filename)
    if !isempty(filename)
        io = open(filename, "r")
        t = deserialize(io)
        close(io)
        return t
    end
end

tostring(x) = join([x], "")  # String(::Expr) fails for reasons..
function Base.show(io::IO, t::Table)
    numrows = length(t.cols) > 0 ? length(t.cols[1]) : 0
    println(io, "$(t.title)   $numrows rows")
    for (i, h) in enumerate(t.headers)
        println(io, "$h::$(eltype(t.cols[i]))")
    end
end

""" insert_into_values(users, (1, "nathan")) """
function insert_into_values(t, values)
    table = t.cols
    for i in 1:length(values)
        push!(table[i], values[i])
    end
end

# The main `SELECT` function. This is the interface, and all specializations for
# different types happen via specializations of _select_from_internal.
"""
    _select_from(users, :id, :(uppercase.(name)))
 Perform a SELECT query on t. Queries can be column names or expressions.
 """
function _select_from(t, columns...; callingmodule=Main)
    out_names, out_cols = [], []
    for c in columns
        r = _select_from_internal(t, c, callingmodule)
        push!(out_names, r.headers)
        push!(out_cols, r.cols)
    end
    Table("RESULTS", Tuple(Iterators.flatten(out_names)), Tuple(Iterators.flatten(out_cols)))
end
_select_from(t, columns::Tuple; callingmodule=Main) = _select_from(t, columns...; callingmodule=callingmodule)
_select_from(t, columns::Vector; callingmodule=Main) = _select_from(t, columns...; callingmodule=callingmodule)

# For a single symbol, just find the matching column name.
function _select_from_internal(t, col::Symbol, callingmodule)
    indices = _match_column_names(t, col)
    length(indices) >= 1 || error("Column $col does not exist.")
    Table("RESULTS", Tuple(t.headers[i] for i in indices), Tuple(t.cols[i] for i in indices))
end
_select_from_internal(t, c::String, callingmodule) = _select_from_internal(t, Symbol(c), callingmodule)
_select_from_internal(t, expr::QuoteNode, callingmodule) = _select_from_internal(t, expr.value, callingmodule)
# Use compiler dispatch to compare column names w/ :*
matches(a::Val{S}, b::Val{S}) where {S} = true
matches(a::Val{A}, b::Val{B}) where {A, B} = false
matches(a::Val{A}, b::Val{:*}) where {A} = true
matches(a::Val{:*}, b::Val{A}) where {A} = true
_match_column_names(t, col::Symbol) =
    Tuple(Iterators.flatten(findall(s -> matches(Val(s), Val(col)), t.headers)))

# For expressions, we evaluate the expression with the column name replaced with
# its value. This requires digging into the expression to find the column name,
# retrieving the column(s), and then evaluating the expr with the column(s) value(s).
function _select_from_internal(t, expr::Expr, callingmodule)
    col = _retrieve_col_name(t, expr)
    val_table = _select_from(t, col; callingmodule=callingmodule)
    val = val_table.cols
    return _eval_expr_internal(val, col, col.expr, callingmodule)
end
function _eval_expr_internal(val, col, expr::Expr, callingmodule)
    out_colname = tostring(expr)  # Before mutating expr.
    if col isa ColumnExprRef
        syms = [col.sym]
        vals = (val,)
    else
        syms = col.syms
        vals = val
    end
    # Interpolate the values into their corresponding symbol name.
    for (i,sym) in enumerate(syms)
        sym[] = permutedims(reshape(collect(Iterators.flatten(vals[i])), length(vals[i]),:))
    end
    r = Core.eval(callingmodule, expr)  # eval the expression in the calling module
    # Now turn the 3x1 Arrays back into a 3-el Vector
    if length(size(r)) == 2 && size(r)[end] == 1
        r = reshape(r, size(r)[1])
    elseif size(r) == ()
        r = [r]  # wrap scalar results as a 1-vector
    end
    Table("RESULTS", [out_colname], (r,))
end
# Convert :(sum(id)) to :id, :(sum(<placeholder>)) so that the column can be
#  retrieved and its value inserted into the expr.
# Note: returns the first match it finds.
# TODO: would be better to return _all_ matches so you can e.g. add columns
expr_to_col(table, _) = []
function expr_to_col(table, expr::Expr)
    outs = []
    for (i,arg) in enumerate(expr.args)
        if arg isa Union{Symbol,String}
            indices = _match_column_names(table, Symbol(arg))
            if !isempty(indices)
                push!(outs, (Symbol(arg), Ref(expr.args, i)))
            end
        end
        append!(outs, expr_to_col(table, arg))
    end
    return outs
end

struct SelectResult
    headers
    values::Matrix
end
import Base: ==
==(a::SelectResult, b::SelectResult) = (a.headers == b.headers && a.values == b.values)

function Base.show(io::IO, t::SelectResult)
    row_elts = []
    max_elt_sizes = zeros(Int, length(t.headers))
    for r in 1:size(t.values)[1]
        elts = [tostring(v) for v in t.values[r,:]]
        push!(row_elts, elts)
        max_elt_sizes .= max.(max_elt_sizes, length.(elts))
    end
    hstrs = [tostring(h) for h in t.headers]
    spaced_hstrs = [" "^(max(max_elt_sizes[i], length(h))-length(h))*h for (i,h) in enumerate(hstrs)]
    println(io, join(spaced_hstrs, " | ") *"\n"*
                join(["-"^(length(h)) for h in spaced_hstrs], "-|-"));
    for elts in row_elts
        println(io, join([" "^(max(0, length(spaced_hstrs[i])-length(s))) * s for (i,s) in enumerate(elts)], " | "))
    end
end

select_from(t, columns::Tuple; where=nothing, groupby=nothing, callingmodule=Main) =
    select_from(t, columns...; where=where, groupby=groupby, callingmodule=callingmodule)
select_from(t, columns::Vector; where=nothing, groupby=nothing, callingmodule=Main) =
    select_from(t, columns...; where=where, groupby=groupby, callingmodule=callingmodule)
function select_from(t, colexprs...; where=nothing, groupby=nothing, callingmodule=Main)
    if where == nothing && groupby == nothing
        out_table = _select_from(t, colexprs...; callingmodule=callingmodule)
        out_colnames = out_table.headers
        results = out_table.cols
    else
        if where != nothing
            # PARSE WHERE EXPRESSION
            wherecolexpr = _retrieve_col_name(t, where)
            val_table = _select_from(t, wherecolexpr; callingmodule=callingmodule)
            vals = val_table.cols
            # Get bitarray for whereexpr row-filter.
            rowfilter = _eval_expr_internal(vals, wherecolexpr, wherecolexpr.expr, callingmodule)
        end
        if groupby != nothing
            # PARSE GROUP BY EXPRESSION
            grouped_table = _select_from(t, groupby; callingmodule=callingmodule)
            if where != nothing
                grouped_table = Table(grouped_table.title, grouped_table.headers,
                     map(c->getindex(c, rowfilter.cols[1]), grouped_table.cols))
            end
            grouping_vals = grouped_table.cols
            @assert length(grouping_vals) == 1
            colors, counts = color_unique_vals(grouping_vals[1])
            num_colors = maximum(colors)
        end

        # Now get the actual values for the colexprs. This works as follows:
        #  1. Get each column based on the symbol, or the name in an expression.
        #  2. Apply `where` filter if present.
        #  3. Create new grouped columns based on `groupby` clause if present.
        #  4. Eval any expressions present in the resultant columns.
        results = []
        out_colnames = []
        for colexpr in colexprs
            col = _retrieve_col_name(t, colexpr)
            val_table = _select_from(t, col; callingmodule=callingmodule)
            # Now filter with where
            if where != nothing
                filtered_table = Table(val_table.title, val_table.headers,
                     map(c->getindex(c, rowfilter.cols[1]), val_table.cols))
                #filtered_table = map(c->getindex(c, rowfilter.cols[1]), val)
            else
                filtered_table = val_table
            end
            # Then finally eval the expressions
            if groupby != nothing
                inner_results, inner_colnames = _select_from__group_by_internal(t, col, filtered_table, colors, counts, num_colors, callingmodule)
            else
                filtered = filtered_table.cols
                if isa(col, Union{ColumnExprRef, MultiColumnExprRef})
                    t = _eval_expr_internal(filtered, col, colexpr, callingmodule)
                    inner_colnames, inner_results = t.headers, t.cols
                else
                    inner_colnames, inner_results = filtered_table.headers, filtered
                end
            end
            push!(results, inner_results...)
            push!(out_colnames, inner_colnames...)
        end
    end
    # Trim all columns to the same length and return results as a Matrix.
    minlen = minimum(length.(results))
    return SelectResult(out_colnames, hcat_no_promote(minlen, results))
end
function hcat_no_promote(minlen, results)
    eltypes = unique([eltype(r) for r in results])
    results = collect(r[end-minlen+1:end] for r in results)
    if length(eltypes) == 1
        return hcat(results...)
    end
    out = Matrix{Any}(undef, minlen, length(results))
    for (i,r) in enumerate(results)
        r = [r...]
        out[:,i] .= r
    end
    return out
end

# Types for dispatching to handle columns as expression.
struct Column
    name::Symbol
end
struct ColumnExprRef
    name::Symbol
    sym
    expr::Expr
end
struct MultiColumnExprRef
    names::Array{Symbol,1}
    syms::Array
    expr::Expr
end
_retrieve_col_name(t, col::Symbol) = Column(col)
function _retrieve_col_name(t, expr::Expr)
     colsyms = expr_to_col(t, expr)
     if length(colsyms) == 1
         return ColumnExprRef(colsyms[1]..., expr)
     end
     return MultiColumnExprRef(getindex.(colsyms, 1), getindex.(colsyms, 2), expr)
 end

_select_from(t, col::Column; callingmodule=Main) = _select_from(t, col.name; callingmodule=callingmodule)
_select_from(t, col::ColumnExprRef; callingmodule=Main) = _select_from(t, col.name; callingmodule=callingmodule)
_select_from(t, col::MultiColumnExprRef; callingmodule=Main) = _select_from(t, col.names...; callingmodule=callingmodule)

# -- Groupby implementation
# Rename each unique item to a unique number, and get counts.
# Eg: convert (5,7,7,2,7) -> (1,2,2,3,2) and [1,3,1]
function color_unique_vals(col::Array{T,1}) where T
    seen = Dict{T, Int64}()
    cur = 1
    out = Array{Int64, 1}(undef, length(col))
    counts = []
    for (i,v) in enumerate(col)
        if !(v in keys(seen))
            seen[v] = cur
            push!(counts, 0)
            cur += 1
        end
        out[i] = seen[v]
        counts[seen[v]] += 1
    end
    out, counts
end

function _select_from__group_by_internal(t, colexpr, vals_table, colors, counts, num_colors, callingmodule)
    vals = vals_table.cols
    results = []
    out_colnames = _colnames_from_table(vals_table, colexpr)
    if (colexpr isa MultiColumnExprRef)
        vals = (collect(zip(vals...)),)
    end
    for v in vals
        splits = [Vector{eltype(v)}(undef, c) for c in counts]
        for i in 1:num_colors
            splits[i] .= v[colors.==i]
        end

        row_results = []
        for val in splits
            if (colexpr isa MultiColumnExprRef)
                val = [val[1]...]
            end
            push!(row_results, _get_val_from_split(val, colexpr, callingmodule)...)
        end
        push!(results, row_results)
    end
    return results, out_colnames
end

_colnames_from_table(t, colexpr::Column) = t.headers
_colnames_from_table(t, colexpr::ColumnExprRef) = [tostring(colexpr.expr)]
_colnames_from_table(t, colexpr::MultiColumnExprRef) = [tostring(colexpr.expr)]

function _get_val_from_split(v, colexpr::Column, callingmodule)
    return [v[1]]
end
function _get_val_from_split(v, colexpr::ColumnExprRef, callingmodule)
    out_t = _eval_expr_internal(v, colexpr, colexpr.expr, callingmodule)
    return out_t.cols[1]
end
function _get_val_from_split(v, colexpr::MultiColumnExprRef, callingmodule)
    out_t = _eval_expr_internal(v, colexpr, colexpr.expr, callingmodule)
    return out_t.cols[1]
end


# ----------------------- Now start the SQL interpreter part --------------

macro CREATE(expr)
    @assert(expr.head == :macrocall)
    @assert(expr.args[1] == Symbol("@TABLE"))
    # args[2] is @TABLE's LineNumberNode
    table = expr.args[3]
    name = String(table)
    colpairs = eval(expr.args[4])
    # Escape expr so table name doesn't become a weird macro-local variable.
    esc(quote
        $table = create_table($name, $(colpairs...))
    end)
end

macro INSERT(expr)
    @assert(expr.head == :macrocall)
    @assert(expr.args[1] == Symbol("@INTO"))
    # args[2] is @TABLE's LineNumberNode
    table = expr.args[3]
    values = expr.args[4]
    @assert(values.args[1] == Symbol("@VALUES"))
    vals = eval(values.args[3])
    quote
        insert_into_values($(esc(table)), $vals)
    end
end

quote_column_syms(colexpr) = colexpr
function quote_column_syms(colexpr::Symbol)
    QuoteNode(colexpr)
end
function quote_column_syms(colexpr::Expr)
    if colexpr.head == :tuple
        for (i,v) in enumerate(colexpr.args)  # re-quote bare symbols (for @SELECT id, aisle @FROM t)
            if v isa Symbol
                colexpr.args[i] = QuoteNode(v)
            elseif v isa Expr && v.head != :quote
                colexpr.args[i] = Expr(:quote, v)
            end
        end
    elseif colexpr.head != :quote
        colexpr = Expr(:quote, colexpr)
    end
    colexpr
end
function macro_select(colexpr, extraexpr::Expr, callingmodule)
    parsed_exprs = parse_macro_block(colexpr, extraexpr)
    colexpr, fromexpr, keyargs = parsed_exprs[1], parsed_exprs[2], parsed_exprs[3:end]
    colexpr = quote_column_syms(colexpr)
    @assert(fromexpr.args[1] == Symbol("@FROM"))
    return quote
        select_from($(esc(fromexpr.args[3])), $(esc(colexpr)); $(keyargs...), callingmodule=$callingmodule)
    end
end
macro SELECT(colexpr, fromexpr::Expr)
    return macro_select(colexpr, fromexpr, __module__)
end

# Handle from start of @-section to next @-section
function parse_macro_block(expr)
    #return expr
    return _macro_block(Val(expr.args[1]), expr)
end
function parse_macro_block(expr, extraexpr)
    #res = expr
    if expr isa Union{Symbol, QuoteNode} || expr.head == :tuple
        res = expr
    else
        res = _macro_block(Val(expr.args[1]), expr)
    end
    if length(extraexpr.args) > 3
        nextexpr = extraexpr.args[4]
        deleteat!(extraexpr.args, 4)
        return res, parse_macro_block(extraexpr, nextexpr)...
    end
    return res, _macro_block(Val(extraexpr.args[1]), extraexpr)
end


function _macro_block(::Val{Symbol("@GROUP")}, expr)
    @assert expr.args[3].args[1] == Symbol("@BY")
    groupcolexpr = quote_column_syms(expr.args[3].args[3])
    esc(:(groupby=$groupcolexpr))
end
function _macro_block(::Val{Symbol("@WHERE")}, expr)
    whereexpr = quote_column_syms(expr.args[3])
    esc(:(where=$whereexpr))
end
function _macro_block(::Val{S}, expr) where S
    expr
end


"""
        @SQL begin
            @SELECT ...
            @FROM ...
        end
    Macro to create multiline SQL statements. Note that each internal macro must
    have at least one argument on the same line (e.g. Can't do `@SELECT
                                                                  id`).
 """
macro SQL(expr)
    @assert expr.head == :block
    # Squash everything into a recursive expr, to match how it would be on a single line.
    inside_expr = expr.args[2]
    while length(expr.args) > 2
        push!(inside_expr.args, expr.args[4])
        inside_expr = inside_expr.args[end]
        deleteat!(expr.args, (3,4))
    end
    # Return the @SELECT expression.
    esc(expr.args[2])
end

end
