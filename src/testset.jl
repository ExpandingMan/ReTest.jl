module Testset

using Test: AbstractTestSet, Broken, DefaultTestSet, Error, Fail, Pass, Test,
            TestSetException, get_testset, get_testset_depth,
            parse_testset_args, pop_testset, push_testset

import Test: finish, record

import Random

using Printf: @sprintf

import InlineTest: @testset

# mostly copied from Test stdlib
# changed from Test: pass nothing as file in ip_has_file_and_func
#-----------------------------------------------------------------------

# (this has to be copied from Test, because `@__FILE__` is hardcoded)

# Backtrace utility functions
function ip_has_file_and_func(ip, file, funcs)
    return any(fr -> ((file === nothing || string(fr.file) == file) &&
                      fr.func in funcs),
               StackTraces.lookup(ip))
end

function scrub_backtrace(bt)
    do_test_ind = findfirst(ip -> ip_has_file_and_func(ip, nothing,
                                                       (:do_test, :do_test_throws)), bt)
    if do_test_ind !== nothing && length(bt) > do_test_ind
        bt = bt[do_test_ind + 1:end]
    end
    name_ind = findfirst(ip -> ip_has_file_and_func(ip, @__FILE__, (Symbol("macro expansion"),)), bt)
    if name_ind !== nothing && length(bt) != 0
        bt = bt[1:name_ind]
    end
    return bt
end

function scrub_exc_stack(stack)
    return Any[ (x[1], scrub_backtrace(x[2])) for x in stack ]
end

mutable struct Format
    stats::Bool
    desc_align::Int
    pass_width::Int
    fail_width::Int
    error_width::Int
    broken_width::Int
    total_width::Int
end

Format(stats, desc_align) = Format(stats, desc_align, 0, 0, 0,0 ,0)

mutable struct ReTestSet <: AbstractTestSet
    description::AbstractString
    results::Vector
    n_passed::Int
    anynonpass::Bool
    verbose::Bool
    timed::NamedTuple
    exception::Union{TestSetException,Nothing}
end

ReTestSet(desc; verbose = true) = ReTestSet(desc, [], 0, false, verbose,
                                             NamedTuple(), nothing)

# For a non-passed result, simply store the result
record(ts::ReTestSet, t::Union{Broken,Fail,Error}) = (push!(ts.results, t); t)
# For a passed result, do not store the result since it uses a lot of memory
record(ts::ReTestSet, t::Pass) = (ts.n_passed += 1; t)

# When a ReTestSet finishes, it records itself to its parent
# testset, if there is one. This allows for recursive printing of
# the results at the end of the tests
record(ts::ReTestSet, t::AbstractTestSet) = push!(ts.results, t)

function print_test_errors(ts::ReTestSet)
    for t in ts.results
        if isa(t, Error) || isa(t, Fail)
            printstyled(ts.description, ": ", color=:white)

            # don't print for interrupted tests
            if t isa Fail || t.test_type !== :test_interrupted
                show(t)
            end
            if t isa Fail # if not gets printed in the show method
                # Base.show_backtrace(stdout, scrub_backtrace(backtrace()))
            end
            println()
        elseif isa(t, ReTestSet)
            print_test_errors(t)
        end
    end
end

function print_test_results(ts::ReTestSet, fmt::Format, depth_pad=0)
    # Calculate the overall number for each type so each of
    # the test result types are aligned
    upd = false

    passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken = get_test_counts(ts)
    total_pass   = passes + c_passes
    total_fail   = fails  + c_fails
    total_error  = errors + c_errors
    total_broken = broken + c_broken
    dig_pass   = total_pass   > 0 ? ndigits(total_pass)   : 0
    dig_fail   = total_fail   > 0 ? ndigits(total_fail)   : 0
    dig_error  = total_error  > 0 ? ndigits(total_error)  : 0
    dig_broken = total_broken > 0 ? ndigits(total_broken) : 0
    total = total_pass + total_fail + total_error + total_broken
    nprinted = (total_pass > 0) + (total_fail > 0) + (total_error > 0) + (total_broken > 0)
    if nprinted <= 1
       total = 0
    end
    dig_total = total > 0 ? ndigits(total) : 0
    # For each category, take max of digits and header width if there are
    # tests of that type
    pass_width   = dig_pass   > 0 ? max(6,   dig_pass) : 0
    fail_width   = dig_fail   > 0 ? max(6,   dig_fail) : 0
    error_width  = dig_error  > 0 ? max(6,  dig_error) : 0
    broken_width = dig_broken > 0 ? max(6, dig_broken) : 0
    total_width  = dig_total  > 0 ? max(6,  dig_total) : 0

    if pass_width > fmt.pass_width
        upd = true
        fmt.pass_width = pass_width
    else
        pass_width = fmt.pass_width
    end
    if fail_width > fmt.fail_width
        upd = true
        fmt.fail_width = fail_width
    else
        fail_width = fmt.fail_width
    end
    if error_width > fmt.error_width
        upd = true
        fmt.error_width = error_width
    else
        error_width = fmt.error_width
    end
    if broken_width > fmt.broken_width
        upd = true
        fmt.broken_width = broken_width
    else
        broken_width = fmt.broken_width
    end
    if total_width > fmt.total_width
        upd = true
        fmt.total_width = total_width
    else
        total_width = fmt.total_width
    end

    # Calculate the alignment of the test result counts by
    # recursively walking the tree of test sets
    align = max(get_alignment(ts, 0), length("Test Summary:"))

    if align > fmt.desc_align
        upd = true
        fmt.desc_align = align
    else
        align = fmt.desc_align
    end

    # Print the outer test set header once
    if upd
        pad = nprinted == 0 ? "" : " "
        printstyled(rpad("Test Summary:", align, " "), " |", pad; bold=true, color=:white)
        if pass_width > 0
            printstyled(lpad("Pass", pass_width, " "), "  "; bold=true, color=:green)
        end
        if fail_width > 0
            printstyled(lpad("Fail", fail_width, " "), "  "; bold=true, color=Base.error_color())
        end
        if error_width > 0
            printstyled(lpad("Error", error_width, " "), "  "; bold=true, color=Base.error_color())
        end
        if broken_width > 0
            printstyled(lpad("Broken", broken_width, " "), "  "; bold=true, color=Base.warn_color())
        end
        if total_width > 0
            printstyled(lpad("Total", total_width, " "); bold=true, color=Base.info_color())
        end
        if fmt.stats
            # copied from Julia/test/runtests.jl
            printstyled("| Time (s) | GC (s) | GC % | Alloc (MB) | ΔRSS (MB)", color=:white)
        end
        println()
    end
    # Recursively print a summary at every level
    print_counts(ts, fmt, depth_pad, align, pass_width, fail_width, error_width, broken_width, total_width)
end

# Called at the end of a @testset, behaviour depends on whether
# this is a child of another testset, or the "root" testset
function finish(ts::ReTestSet, outchan)
    # If we are a nested test set, do not print a full summary
    # now - let the parent test set do the printing
    if get_testset_depth() != 0
        # Attach this test set to the parent test set
        parent_ts = get_testset()
        record(parent_ts, ts)
        return ts
    end
    passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken = get_test_counts(ts)
    total_pass   = passes + c_passes
    total_fail   = fails  + c_fails
    total_error  = errors + c_errors
    total_broken = broken + c_broken
    total = total_pass + total_fail + total_error + total_broken

    # Finally throw an error as we are the outermost test set
    if total != total_pass + total_broken
        # Get all the error/failures and bring them along for the ride
        efs = filter_errors(ts)
        ts.exception = TestSetException(total_pass, total_fail, total_error,
                                        total_broken, efs)
    end

    put!(outchan, ts)
    # return the testset so it is returned from the @testset macro
    ts
end

# Recursive function that finds the column that the result counts
# can begin at by taking into account the width of the descriptions
# and the amount of indentation. If a test set had no failures, and
# no failures in child test sets, there is no need to include those
# in calculating the alignment
function get_alignment(ts::ReTestSet, depth::Int)
    # The minimum width at this depth is
    ts_width = 2*depth + length(ts.description)
    # If all passing, no need to look at children
    !ts.anynonpass && return ts_width
    # Return the maximum of this width and the minimum width
    # for all children (if they exist)
    isempty(ts.results) && return ts_width
    child_widths = map(t->get_alignment(t, depth+1), ts.results)
    return max(ts_width, maximum(child_widths))
end
get_alignment(ts, depth::Int) = 0

# Recursive function that fetches backtraces for any and all errors
# or failures the testset and its children encountered
function filter_errors(ts::ReTestSet)
    efs = []
    for t in ts.results
        if isa(t, ReTestSet)
            append!(efs, filter_errors(t))
        elseif isa(t, Union{Fail, Error})
            append!(efs, [t])
        end
    end
    efs
end

# Recursive function that counts the number of test results of each
# type directly in the testset, and totals across the child testsets
function get_test_counts(ts::ReTestSet)
    passes, fails, errors, broken = ts.n_passed, 0, 0, 0
    c_passes, c_fails, c_errors, c_broken = 0, 0, 0, 0
    for t in ts.results
        isa(t, Fail)   && (fails  += 1)
        isa(t, Error)  && (errors += 1)
        isa(t, Broken) && (broken += 1)
        if isa(t, ReTestSet)
            np, nf, ne, nb, ncp, ncf, nce , ncb = get_test_counts(t)
            c_passes += np + ncp
            c_fails  += nf + ncf
            c_errors += ne + nce
            c_broken += nb + ncb
        end
    end
    ts.anynonpass = (fails + errors + c_fails + c_errors > 0)
    return passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken
end

# Recursive function that prints out the results at each level of
# the tree of test sets
function print_counts(ts::ReTestSet, fmt::Format, depth, align,
                      pass_width, fail_width, error_width, broken_width, total_width)
    # Count results by each type at this level, and recursively
    # through any child test sets
    passes, fails, errors, broken, c_passes, c_fails, c_errors, c_broken = get_test_counts(ts)
    subtotal = passes + fails + errors + broken + c_passes + c_fails + c_errors + c_broken
    # Print test set header, with an alignment that ensures all
    # the test results appear above each other
    print(rpad(string("  "^depth, ts.description), align, " "), " | ")

    np = passes + c_passes
    if np > 0
        printstyled(lpad(string(np), pass_width, " "), "  ", color=:green)
    elseif pass_width > 0
        # No passes at this level, but some at another level
        print(lpad(" ", pass_width), "  ")
    end

    nf = fails + c_fails
    if nf > 0
        printstyled(lpad(string(nf), fail_width, " "), "  ", color=Base.error_color())
    elseif fail_width > 0
        # No fails at this level, but some at another level
        print(lpad(" ", fail_width), "  ")
    end

    ne = errors + c_errors
    if ne > 0
        printstyled(lpad(string(ne), error_width, " "), "  ", color=Base.error_color())
    elseif error_width > 0
        # No errors at this level, but some at another level
        print(lpad(" ", error_width), "  ")
    end

    nb = broken + c_broken
    if nb > 0
        printstyled(lpad(string(nb), broken_width, " "), "  ", color=Base.warn_color())
    elseif broken_width > 0
        # None broken at this level, but some at another level
        print(lpad(" ", broken_width), "  ")
    end

    if np == 0 && nf == 0 && ne == 0 && nb == 0
        printstyled("No tests", color=Base.info_color())
    elseif ((np > 0) + (nf > 0) + (ne > 0) + (nb > 0)) > 1
        printstyled(lpad(string(subtotal), total_width, " "), color=Base.info_color())
    end

    if fmt.stats # copied from Julia/test/runtests.jl
        timed = ts.timed
        elapsed_align = textwidth("Time (s)")
        gc_align      = textwidth("GC (s)")
        percent_align = textwidth("GC %")
        alloc_align   = textwidth("Alloc (MB)")
        rss_align     = textwidth("ΔRSS (MB)")

        time_str = @sprintf("%7.2f", timed.time)
        printstyled("| ", lpad(time_str, elapsed_align, " "), " | ", color=:white)
        gc_str = @sprintf("%5.2f", timed.gcstats.total_time / 10^9)
        printstyled(lpad(gc_str, gc_align, " "), " | ", color=:white)

        # since there may be quite a few digits in the percentage,
        # the left-padding here is less to make sure everything fits
        percent_str = @sprintf("%4.1f",
                               100 * timed.gcstats.total_time / (10^9 * timed.time))
        printstyled(lpad(percent_str, percent_align, " "), " | ", color=:white)
        alloc_str = @sprintf("%5.2f", timed.bytes / 2^20)
        printstyled(lpad(alloc_str, alloc_align, " "), " | ", color=:white)
        rss_str = @sprintf("%5.2f", timed.rss / 2^20)
        printstyled(lpad(rss_str, rss_align, " "), color=:white)
    end
    println()

    # Only print results at lower levels if we had failures or if the user
    # wants.
    if (np + nb != subtotal) || (ts.verbose)
        for t in ts.results
            if isa(t, ReTestSet)
                print_counts(t, fmt, depth + 1, align,
                    pass_width, fail_width, error_width, broken_width, total_width)
            end
        end
    end
end

#-----------------------------------------------------------------------

default_rng() = isdefined(Random, :default_rng) ?
    Random.default_rng() :
    Random.GLOBAL_RNG

function get_testset_string(remove_last=false)
    testsets = get(task_local_storage(), :__BASETESTNEXT__, Test.AbstractTestSet[])
    join('/' * ts.description for ts in (remove_last ? testsets[1:end-1] : testsets))
end

# non-inline testset with regex filtering support
macro testset(isfinal::Bool, rx::Regex, desc::String, options, outchan, body)
    Testset.testset_beginend(isfinal, rx, desc, options, outchan,  body, __source__)
end

macro testset(isfinal::Bool, rx::Regex, desc::Union{String,Expr}, options, outchan,
              loopiter, loopvals, body)
    Testset.testset_forloop(isfinal, rx, desc, options, outchan, loopiter, loopvals, body, __source__)
end

"""
Generate the code for a `@testset` with a `begin`/`end` argument
"""
function testset_beginend(isfinal::Bool, rx::Regex, desc::String, options,
                          outchan, tests, source)
    # Generate a block of code that initializes a new testset, adds
    # it to the task local storage, evaluates the test(s), before
    # finally removing the testset and giving it a chance to take
    # action (such as reporting the results)
    ex = quote
        local current_str
        if $isfinal
            current_str = string(get_testset_string(), '/', $desc)
        end
        if !$isfinal || occursin($rx, current_str)
            local ret
            local ts = ReTestSet($desc; verbose=$(options.transient_verbose))
            push_testset(ts)
            # we reproduce the logic of guardseed, but this function
            # cannot be used as it changes slightly the semantic of @testset,
            # by wrapping the body in a function
            local RNG = default_rng()
            local oldrng = copy(RNG)
            local timed
            local rss
            try
                # RNG is re-seeded with its own seed to ease reproduce a failed test
                Random.seed!(RNG.seed)
                rss = Sys.maxrss()
                let
                    timed = @timed $(esc(tests))
                end
                rss = Sys.maxrss() - rss
            catch err
                err isa InterruptException && rethrow()
                # something in the test block threw an error. Count that as an
                # error in this test set
                record(ts, Error(:nontest_error, Expr(:tuple), err,
                                 Base.catch_stack(), $(QuoteNode(source))))
            finally
                copy!(RNG, oldrng)
                pop_testset()
                ret = finish(set_timed!(ts, timed, rss), $outchan)
            end
            ret
        end
    end
    # preserve outer location if possible
    if tests isa Expr && tests.head === :block &&
        !isempty(tests.args) && tests.args[1] isa LineNumberNode

        ex = Expr(:block, tests.args[1], ex)
    end
    return ex
end

"""
Generate the code for a `@testset` with a `for` loop argument
"""
function testset_forloop(isfinal::Bool, rx::Regex, desc::Union{String,Expr}, options, outchan,
                         loopiter, loopvals,
                         tests, source)

    # Pull out the loop variables. We might need them for generating the
    # description and we'll definitely need them for generating the
    # comprehension expression at the end
    loopvars = Expr[Expr(:(=), loopiter, loopvals)]
    blk = quote
        local current_str
        if $isfinal
            current_str = string(get_testset_string(!first_iteration), '/', $(esc(desc)))
        end
        if !$isfinal || occursin($rx, current_str)
            # Trick to handle `break` and `continue` in the test code before
            # they can be handled properly by `finally` lowering.
            if !first_iteration
                pop_testset()
                push!(arr, finish(set_timed!(ts, timed, rss), $outchan))
                # it's 1000 times faster to copy from tmprng rather than calling Random.seed!
                copy!(RNG, tmprng)
            end
            ts = ReTestSet($(esc(desc)); verbose=$(options.transient_verbose))
            push_testset(ts)
            first_iteration = false
            try
                rss = Sys.maxrss()
                let
                    timed = @timed $(esc(tests))
                end
                rss = Sys.maxrss() - rss
            catch err
                err isa InterruptException && rethrow()
                # Something in the test block threw an error. Count that as an
                # error in this test set
                record(ts, Error(:nontest_error, Expr(:tuple), err, Base.catch_stack(), $(QuoteNode(source))))
            end
        end
    end
    quote
        local arr = Vector{Any}()
        local first_iteration = true
        local ts
        local RNG = default_rng()
        local oldrng = copy(RNG)
        Random.seed!(RNG.seed)
        local tmprng = copy(RNG)
        local timed
        local rss
        try
            let
                $(Expr(:for, Expr(:block, [esc(v) for v in loopvars]...), blk))
            end
        finally
            # Handle `return` in test body
            if !first_iteration
                pop_testset()
                push!(arr, finish(set_timed!(ts, timed, rss), $outchan))
            end
            copy!(RNG, oldrng)
        end
        arr
    end
end

function set_timed!(ts, timed, rss)
    # on Julia < 1.5, @timed returns a Tuple; here we give the names as in
    # Julia 1.5+, but we filter out the `val` field, unused here
    ts.timed = (time = timed[2], bytes = timed[3],
                gctime = timed[4], gcstats = timed[5],
                rss = rss)
    ts
end

end # module
