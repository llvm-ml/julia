# This file is a part of Julia. License is MIT: https://julialang.org/license

## client.jl - frontend handling command line options, environment setup,
##             and REPL

have_color = nothing
const default_color_warn = :yellow
const default_color_error = :light_red
const default_color_info = :cyan
const default_color_debug = :blue
const default_color_input = :normal
const default_color_answer = :normal
const color_normal = text_colors[:normal]

function repl_color(key, default)
    env_str = get(ENV, key, "")
    c = tryparse(Int, env_str)
    c_conv = something(c, Symbol(env_str))
    haskey(text_colors, c_conv) ? c_conv : default
end

error_color() = repl_color("JULIA_ERROR_COLOR", default_color_error)
warn_color()  = repl_color("JULIA_WARN_COLOR" , default_color_warn)
info_color()  = repl_color("JULIA_INFO_COLOR" , default_color_info)
debug_color()  = repl_color("JULIA_DEBUG_COLOR" , default_color_debug)

input_color()  = text_colors[repl_color("JULIA_INPUT_COLOR", default_color_input)]
answer_color() = text_colors[repl_color("JULIA_ANSWER_COLOR", default_color_answer)]

stackframe_lineinfo_color() = repl_color("JULIA_STACKFRAME_LINEINFO_COLOR", :bold)
stackframe_function_color() = repl_color("JULIA_STACKFRAME_FUNCTION_COLOR", :bold)

function repl_cmd(cmd, out)
    shell = shell_split(get(ENV, "JULIA_SHELL", get(ENV, "SHELL", "/bin/sh")))
    shell_name = Base.basename(shell[1])

    # Immediately expand all arguments, so that typing e.g. ~/bin/foo works.
    cmd.exec .= expanduser.(cmd.exec)

    if isempty(cmd.exec)
        throw(ArgumentError("no cmd to execute"))
    elseif cmd.exec[1] == "cd"
        new_oldpwd = pwd()
        if length(cmd.exec) > 2
            throw(ArgumentError("cd method only takes one argument"))
        elseif length(cmd.exec) == 2
            dir = cmd.exec[2]
            if dir == "-"
                if !haskey(ENV, "OLDPWD")
                    error("cd: OLDPWD not set")
                end
                dir = ENV["OLDPWD"]
            end
            cd(dir)
        else
            cd()
        end
        ENV["OLDPWD"] = new_oldpwd
        println(out, pwd())
    else
        @static if !Sys.iswindows()
            if shell_name == "fish"
                shell_escape_cmd = "begin; $(shell_escape_posixly(cmd)); and true; end"
            else
                shell_escape_cmd = "($(shell_escape_posixly(cmd))) && true"
            end
            cmd = `$shell -c $shell_escape_cmd`
        end
        try
            run(ignorestatus(cmd))
        catch
            # Windows doesn't shell out right now (complex issue), so Julia tries to run the program itself
            # Julia throws an exception if it can't find the program, but the stack trace isn't useful
            lasterr = current_exceptions()
            lasterr = ExceptionStack([(exception = e[1], backtrace = [] ) for e in lasterr])
            invokelatest(display_error, lasterr)
        end
    end
    nothing
end

# deprecated function--preserved for DocTests.jl
function ip_matches_func(ip, func::Symbol)
    for fr in StackTraces.lookup(ip)
        if fr === StackTraces.UNKNOWN || fr.from_c
            return false
        end
        fr.func === func && return true
    end
    return false
end

function scrub_repl_backtrace(bt)
    if bt !== nothing && !(bt isa Vector{Any}) # ignore our sentinel value types
        bt = bt isa Vector{StackFrame} ? copy(bt) : stacktrace(bt)
        # remove REPL-related frames from interactive printing
        eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval, bt)
        eval_ind === nothing || deleteat!(bt, eval_ind:length(bt))
    end
    return bt
end
scrub_repl_backtrace(stack::ExceptionStack) =
    ExceptionStack(Any[(;x.exception, backtrace = scrub_repl_backtrace(x.backtrace)) for x in stack])

istrivialerror(stack::ExceptionStack) =
    length(stack) == 1 && length(stack[1].backtrace) ≤ 1
    # frame 1 = top level; assumes already went through scrub_repl_backtrace

function display_error(io::IO, stack::ExceptionStack)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    show_exception_stack(IOContext(io, :limit => true), stack)
    println(io)
end
display_error(stack::ExceptionStack) = display_error(stderr, stack)

# these forms are depended on by packages outside Julia
function display_error(io::IO, er, bt)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    showerror(IOContext(io, :limit => true), er, bt, backtrace = bt!==nothing)
    println(io)
end
display_error(er, bt=nothing) = display_error(stderr, er, bt)

function eval_user_input(errio, @nospecialize(ast), show_value::Bool)
    errcount = 0
    lasterr = nothing
    have_color = get(stdout, :color, false)::Bool
    while true
        try
            if have_color
                print(color_normal)
            end
            if lasterr !== nothing
                lasterr = scrub_repl_backtrace(lasterr)
                istrivialerror(lasterr) || setglobal!(Base.MainInclude, :err, lasterr)
                invokelatest(display_error, errio, lasterr)
                errcount = 0
                lasterr = nothing
            else
                ast = Meta.lower(Main, ast)
                value = Core.eval(Main, ast)
                setglobal!(Base.MainInclude, :ans, value)
                if !(value === nothing) && show_value
                    if have_color
                        print(answer_color())
                    end
                    try
                        invokelatest(display, value)
                    catch
                        @error "Evaluation succeeded, but an error occurred while displaying the value" typeof(value)
                        rethrow()
                    end
                end
            end
            break
        catch
            if errcount > 0
                @error "SYSTEM: display_error(errio, lasterr) caused an error"
            end
            errcount += 1
            lasterr = scrub_repl_backtrace(current_exceptions())
            setglobal!(Base.MainInclude, :err, lasterr)
            if errcount > 2
                @error "It is likely that something important is broken, and Julia will not be able to continue normally" errcount
                break
            end
        end
    end
    isa(stdin, TTY) && println()
    nothing
end

function _parse_input_line_core(s::String, filename::String)
    ex = Meta.parseall(s, filename=filename)
    if ex isa Expr && ex.head === :toplevel
        if isempty(ex.args)
            return nothing
        end
        last = ex.args[end]
        if last isa Expr && (last.head === :error || last.head === :incomplete)
            # if a parse error happens in the middle of a multi-line input
            # return only the error, so that none of the input is evaluated.
            return last
        end
    end
    return ex
end

function parse_input_line(s::String; filename::String="none", depwarn=true)
    # For now, assume all parser warnings are depwarns
    ex = if depwarn
        _parse_input_line_core(s, filename)
    else
        with_logger(NullLogger()) do
            _parse_input_line_core(s, filename)
        end
    end
    return ex
end
parse_input_line(s::AbstractString) = parse_input_line(String(s))

# detect the reason which caused an :incomplete expression
# from the error message
# NOTE: the error messages are defined in src/julia-parser.scm
function fl_incomplete_tag(msg::AbstractString)
    occursin("string", msg) && return :string
    occursin("comment", msg) && return :comment
    occursin("requires end", msg) && return :block
    occursin("\"`\"", msg) && return :cmd
    occursin("character", msg) && return :char
    return :other
end

incomplete_tag(ex) = :none
function incomplete_tag(ex::Expr)
    if ex.head !== :incomplete
        return :none
    elseif isempty(ex.args)
        return :other
    elseif ex.args[1] isa String
        return fl_incomplete_tag(ex.args[1])
    else
        return incomplete_tag(ex.args[1])
    end
end
incomplete_tag(exc::Meta.ParseError) = incomplete_tag(exc.detail)

function exec_options(opts)
    quiet                 = (opts.quiet != 0)
    startup               = (opts.startupfile != 2)
    history_file          = (opts.historyfile != 0)
    color_set             = (opts.color != 0) # --color!=auto
    global have_color     = color_set ? (opts.color == 1) : nothing # --color=on
    global is_interactive = (opts.isinteractive != 0)

    # pre-process command line argument list
    arg_is_program = !isempty(ARGS)
    repl = !arg_is_program
    cmds = unsafe_load_commands(opts.commands)
    for (cmd, arg) in cmds
        if cmd == 'e'
            arg_is_program = false
            repl = false
        elseif cmd == 'E'
            arg_is_program = false
            repl = false
        elseif cmd == 'L'
            # nothing
        elseif cmd == 'B' # --bug-report
            # If we're doing a bug report, don't load anything else. We will
            # spawn a child in which to execute these options.
            let InteractiveUtils = load_InteractiveUtils()
                InteractiveUtils.report_bug(arg)
            end
            return nothing
        else
            @warn "Unexpected command -$cmd'$arg'"
        end
    end

    # remove filename from ARGS
    global PROGRAM_FILE = arg_is_program ? popfirst!(ARGS) : ""

    # Load Distributed module only if any of the Distributed options have been specified.
    distributed_mode = (opts.worker == 1) || (opts.nprocs > 0) || (opts.machine_file != C_NULL)
    if distributed_mode
        let Distributed = require(PkgId(UUID((0x8ba89e20_285c_5b6f, 0x9357_94700520ee1b)), "Distributed"))
            Core.eval(Main, :(const Distributed = $Distributed))
            Core.eval(Main, :(using .Distributed))
        end

        invokelatest(Main.Distributed.process_opts, opts)
    end

    interactiveinput = (repl || is_interactive::Bool) && isa(stdin, TTY)
    is_interactive::Bool |= interactiveinput

    # load ~/.julia/config/startup.jl file
    if startup
        try
            load_julia_startup()
        catch
            invokelatest(display_error, scrub_repl_backtrace(current_exceptions()))
            !(repl || is_interactive::Bool) && exit(1)
        end
    end

    # process cmds list
    for (cmd, arg) in cmds
        if cmd == 'e'
            Core.eval(Main, parse_input_line(arg))
        elseif cmd == 'E'
            invokelatest(show, Core.eval(Main, parse_input_line(arg)))
            println()
        elseif cmd == 'L'
            # load file immediately on all processors
            if !distributed_mode
                include(Main, arg)
            else
                # TODO: Move this logic to Distributed and use a callback
                @sync for p in invokelatest(Main.procs)
                    @async invokelatest(Main.remotecall_wait, include, p, Main, arg)
                end
            end
        end
    end

    # load file
    if arg_is_program
        # program
        if !is_interactive::Bool
            exit_on_sigint(true)
        end
        try
            if PROGRAM_FILE == "-"
                include_string(Main, read(stdin, String), "stdin")
            else
                include(Main, PROGRAM_FILE)
            end
        catch
            invokelatest(display_error, scrub_repl_backtrace(current_exceptions()))
            if !is_interactive::Bool
                exit(1)
            end
        end
    end
    if repl || is_interactive::Bool
        b = opts.banner
        auto = b == -1
        banner = b == 0 || (auto && !interactiveinput) ? :no  :
                 b == 1 || (auto && interactiveinput)  ? :yes :
                 :short # b == 2
        run_main_repl(interactiveinput, quiet, banner, history_file, color_set)
    end
    nothing
end

function _global_julia_startup_file()
    # If the user built us with a specific Base.SYSCONFDIR, check that location first for a startup.jl file
    # If it is not found, then continue on to the relative path based on Sys.BINDIR
    BINDIR = Sys.BINDIR
    SYSCONFDIR = Base.SYSCONFDIR
    if !isempty(SYSCONFDIR)
        p1 = abspath(BINDIR, SYSCONFDIR, "julia", "startup.jl")
        isfile(p1) && return p1
    end
    p2 = abspath(BINDIR, "..", "etc", "julia", "startup.jl")
    isfile(p2) && return p2
    return nothing
end

function _local_julia_startup_file()
    if !isempty(DEPOT_PATH)
        path = abspath(DEPOT_PATH[1], "config", "startup.jl")
        isfile(path) && return path
    end
    return nothing
end

function load_julia_startup()
    global_file = _global_julia_startup_file()
    (global_file !== nothing) && include(Main, global_file)
    local_file = _local_julia_startup_file()
    (local_file !== nothing) && include(Main, local_file)
    return nothing
end

const repl_hooks = []

"""
    atreplinit(f)

Register a one-argument function to be called before the REPL interface is initialized in
interactive sessions; this is useful to customize the interface. The argument of `f` is the
REPL object. This function should be called from within the `.julia/config/startup.jl`
initialization file.
"""
atreplinit(f::Function) = (pushfirst!(repl_hooks, f); nothing)

function __atreplinit(repl)
    for f in repl_hooks
        try
            f(repl)
        catch err
            showerror(stderr, err)
            println(stderr)
        end
    end
end
_atreplinit(repl) = invokelatest(__atreplinit, repl)

function load_InteractiveUtils(mod::Module=Main)
    # load interactive-only libraries
    if !isdefined(mod, :InteractiveUtils)
        try
            let InteractiveUtils = require(PkgId(UUID(0xb77e0a4c_d291_57a0_90e8_8db25a27a240), "InteractiveUtils"))
                Core.eval(mod, :(const InteractiveUtils = $InteractiveUtils))
                Core.eval(mod, :(using .InteractiveUtils))
                return InteractiveUtils
            end
        catch ex
            @warn "Failed to import InteractiveUtils into module $mod" exception=(ex, catch_backtrace())
        end
        return nothing
    end
    return getfield(mod, :InteractiveUtils)
end

global active_repl

# run the requested sort of evaluation loop on stdio
function run_main_repl(interactive::Bool, quiet::Bool, banner::Symbol, history_file::Bool, color_set::Bool)
    load_InteractiveUtils()

    if interactive && isassigned(REPL_MODULE_REF)
        invokelatest(REPL_MODULE_REF[]) do REPL
            term_env = get(ENV, "TERM", @static Sys.iswindows() ? "" : "dumb")
            term = REPL.Terminals.TTYTerminal(term_env, stdin, stdout, stderr)
            banner == :no || Base.banner(term, short=banner==:short)
            if term.term_type == "dumb"
                repl = REPL.BasicREPL(term)
                quiet || @warn "Terminal not fully functional"
            else
                repl = REPL.LineEditREPL(term, get(stdout, :color, false), true)
                repl.history_file = history_file
            end
            global active_repl = repl
            # Make sure any displays pushed in .julia/config/startup.jl ends up above the
            # REPLDisplay
            pushdisplay(REPL.REPLDisplay(repl))
            _atreplinit(repl)
            REPL.run_repl(repl, backend->(global active_repl_backend = backend))
        end
    else
        # otherwise provide a simple fallback
        if interactive && !quiet
            @warn "REPL provider not available: using basic fallback"
        end
        banner == :no || Base.banner(short=banner==:short)
        let input = stdin
            if isa(input, File) || isa(input, IOStream)
                # for files, we can slurp in the whole thing at once
                ex = parse_input_line(read(input, String))
                if Meta.isexpr(ex, :toplevel)
                    # if we get back a list of statements, eval them sequentially
                    # as if we had parsed them sequentially
                    for stmt in ex.args
                        eval_user_input(stderr, stmt, true)
                    end
                    body = ex.args
                else
                    eval_user_input(stderr, ex, true)
                end
            else
                while isopen(input) || !eof(input)
                    if interactive
                        print("julia> ")
                        flush(stdout)
                    end
                    try
                        line = ""
                        ex = nothing
                        while !eof(input)
                            line *= readline(input, keep=true)
                            ex = parse_input_line(line)
                            if !(isa(ex, Expr) && ex.head === :incomplete)
                                break
                            end
                        end
                        eval_user_input(stderr, ex, true)
                    catch err
                        isa(err, InterruptException) ? print("\n\n") : rethrow()
                    end
                end
            end
        end
    end
    nothing
end

# MainInclude exists to hide Main.include and eval from `names(Main)`.
baremodule MainInclude
using ..Base
# These definitions calls Base._include rather than Base.include to get
# one-frame stacktraces for the common case of using include(fname) in Main.
include(mapexpr::Function, fname::AbstractString) = Base._include(mapexpr, Main, fname)
function include(fname::AbstractString)
    isa(fname, String) || (fname = Base.convert(String, fname)::String)
    Base._include(identity, Main, fname)
end
eval(x) = Core.eval(Main, x)

"""
    ans

A variable referring to the last computed value, automatically imported to the interactive prompt.
"""
global ans = nothing

"""
    err

A variable referring to the last thrown errors, automatically imported to the interactive prompt.
The thrown errors are collected in a stack of exceptions.
"""
global err = nothing

# weakly exposes ans and err variables to Main
export ans, err

end

"""
    eval(expr)

Evaluate an expression in the global scope of the containing module.
Every `Module` (except those defined with `baremodule`) has its own 1-argument
definition of `eval`, which evaluates expressions in that module.
"""
MainInclude.eval

"""
    include([mapexpr::Function,] path::AbstractString)

Evaluate the contents of the input source file in the global scope of the containing module.
Every module (except those defined with `baremodule`) has its own
definition of `include`, which evaluates the file in that module.
Returns the result of the last evaluated expression of the input file. During including,
a task-local include path is set to the directory containing the file. Nested calls to
`include` will search relative to that path. This function is typically used to load source
interactively, or to combine files in packages that are broken into multiple source files.
The argument `path` is normalized using [`normpath`](@ref) which will resolve
relative path tokens such as `..` and convert `/` to the appropriate path separator.

The optional first argument `mapexpr` can be used to transform the included code before
it is evaluated: for each parsed expression `expr` in `path`, the `include` function
actually evaluates `mapexpr(expr)`.  If it is omitted, `mapexpr` defaults to [`identity`](@ref).

Use [`Base.include`](@ref) to evaluate a file into another module.

!!! compat "Julia 1.5"
    Julia 1.5 is required for passing the `mapexpr` argument.
"""
MainInclude.include

function _start()
    empty!(ARGS)
    append!(ARGS, Core.ARGS)
    # clear any postoutput hooks that were saved in the sysimage
    empty!(Base.postoutput_hooks)
    try
        exec_options(JLOptions())
    catch
        invokelatest(display_error, scrub_repl_backtrace(current_exceptions()))
        exit(1)
    end
    if is_interactive && get(stdout, :color, false)
        print(color_normal)
    end
end
