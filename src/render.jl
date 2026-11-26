"""
    ReportRender

The **renderer** half of the engine/renderer split (§15.1): turns an evaluated
`Report` into a self-contained HTML artifact. Runs CLI-side, where the heavier
template deps already live (`OteraEngine`, `CommonMark`). It only consumes the
engine's `Report`/`Cell` data — no live module needed.

Escaping is correct by construction: one OteraEngine template with
`autoescape=true` HTML-escapes all code/stdout/value text automatically;
CommonMark-rendered markdown (already safe HTML) is injected via the `|> safe`
filter. No hand-escaping (§8).
"""
module ReportRender

using OteraEngine, CommonMark
using ..ReportEngine
import Base64

include(joinpath(@__DIR__, "expanduser_fix.jl"))   # `~` in a backtrace path (`_linkify_trace`)
include(joinpath(@__DIR__, "block_kinds.jl"))      # the block kinds of markdown (`_md_blocks`)

export render_html, render_report_file, output_html, markdown_html

const _TEMPLATE = joinpath(@__DIR__, "templates", "report.html.tmpl")

_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

# ── ANSI colour → spans ──────────────────────────────────────────────────────
# Captured output is cooked by `ReportEngine.cook_terminal` before it gets here, which replays and
# consumes every cursor/erase sequence and leaves SGR (`\e[…m`) as the ONLY escape family in the
# text. So this is the whole of the ANSI handling the page needs — and anything the cooker doesn't
# model can't reach us as visible garbage. The attribute model is the cooker's (`_tc_sgr`/`TAttr`),
# shared rather than reimplemented so the two can't drift.

# xterm-256 palette entry → "#rrggbb". 16–231 is a 6×6×6 cube, 232–255 a grey ramp. 0–15 are
# themeable and handled by class instead, so they never reach here.
function _xterm_rgb(n::Integer)
    if n >= 232
        v = 8 + (n - 232) * 10
        return string("#", lpad(string(v; base = 16), 2, '0')^3)
    end
    lvl = (0, 95, 135, 175, 215, 255)
    i = n - 16
    r, g, b = lvl[(i ÷ 36) + 1], lvl[((i % 36) ÷ 6) + 1], lvl[(i % 6) + 1]
    return string("#", join(lpad(string(c; base = 16), 2, '0') for c in (r, g, b)))
end

# A colour field (see `TAttr`): -1 default, 0..15 themed palette, 16..255 xterm palette, ≥256 a
# packed 24-bit colour. Returns (class, css-colour) — exactly one of the two is non-empty.
function _ansi_color(v::Integer, which::AbstractString)
    v < 0   && return ("", "")
    v < 16  && return (string("ansi-", which, "-", v), "")
    v < 256 && return ("", _xterm_rgb(v))
    rgb = v - 256
    return ("", string("#", lpad(string(rgb; base = 16), 6, '0')))
end

function _ansi_attrs(a)
    RE = ReportEngine
    classes = String[]
    styles = String[]
    for (bit, name) in ((RE.TC_BOLD, "bold"), (RE.TC_DIM, "dim"), (RE.TC_ITALIC, "italic"),
                        (RE.TC_UNDERLINE, "underline"), (RE.TC_REVERSE, "reverse"),
                        (RE.TC_STRIKE, "strike"))
        (a.flags & bit) != 0 && push!(classes, "ansi-" * name)
    end
    for (v, which, prop) in ((a.fg, "fg", "color"), (a.bg, "bg", "background-color"))
        cls, css = _ansi_color(v, which)
        isempty(cls) || push!(classes, cls)
        isempty(css) || push!(styles, string(prop, ":", css))
    end
    return (join(classes, ' '), join(styles, ';'))
end

"""
Cooked text → HTML, turning SGR runs into spans. `inner` escapes each plain run (and, for a
backtrace, linkifies it), so escaping stays correct by construction.
"""
function _ansi_html(text::AbstractString, inner::Function = _esc)
    s = String(text)
    occursin('\e', s) || return inner(s)          # the common case: no colour, no work
    # Cooked text has only SGR in it, but output stored before cooking existed — or produced by a
    # remote worker on an older build — has not been through the cooker at all. Dropping the rest
    # here rather than trusting the contract costs one pass over text that already contains an ESC.
    s = ReportEngine.keep_sgr_only(s)
    io = IOBuffer()
    attr = ReportEngine._TC_PLAIN
    pos = firstindex(s)
    for m in eachmatch(r"\e\[[0-9;:]*m", s)
        m.offset > pos && _ansi_run(io, SubString(s, pos, prevind(s, m.offset)), attr, inner)
        attr = ReportEngine._tc_sgr(attr, SubString(m.match, 3, lastindex(m.match) - 1))
        pos = m.offset + ncodeunits(m.match)
    end
    pos <= ncodeunits(s) && _ansi_run(io, SubString(s, pos, lastindex(s)), attr, inner)
    return String(take!(io))
end

function _ansi_run(io::IO, run::AbstractString, attr, inner::Function)
    isempty(run) && return nothing
    cls, style = _ansi_attrs(attr)
    if isempty(cls) && isempty(style)
        print(io, inner(run))
    else
        print(io, "<span",
              isempty(cls) ? "" : string(" class=\"", cls, "\""),
              isempty(style) ? "" : string(" style=\"", style, "\""), ">", inner(run), "</span>")
    end
    return nothing
end

"""
Markdown source → HTML (live notebook + md cells). `interps` are the captured
outputs of the cell's `{{ expr }}` blocks, spliced in document order. `prose` is applied to each
markdown value spliced in, as the caller already applied it to the source (the live view's citation
links, say), so spliced prose gets the same treatment as written prose. `caption` is the figure number
of a cell with the `caption` tag: each of its blocks is then a caption (`_md_blocks`).
"""
markdown_html(src::AbstractString; kw...) = _md_html(src, CellOutput[]; kw...)
markdown_html(src::AbstractString, interps; kw...) = _md_html(src, interps; kw...)

"""
    output_html(cell) -> String

The output fragment for a code cell (stdout / value / rich display / error),
escaped and embedded. Used by the live notebook server to update a cell in place.
"""
function output_html(cell::Cell)
    # A web cell renders like a code cell — its `@web(...)` evaluates to a `WebPage`, captured as an
    # HTML display chunk — so the same output pipeline (display/stdout/error) applies.
    evaluates(cell.kind) || return ""
    o = cell.output
    o === nothing && return ""
    io = IOBuffer()
    isempty(o.stdout) || print(io, "<div class=\"out\"><pre>", _ansi_html(o.stdout), "</pre></div>")
    # Captured stderr / `@warn` output — a distinct warnings block (not an error: the cell may
    # still have succeeded). VS Code source links in any `@ file:line` notices are made clickable.
    isempty(o.stderr) || print(io, "<div class=\"warn\"><pre>", _ansi_html(o.stderr, _linkify_trace), "</pre></div>")
    if isempty(o.display) && !isempty(o.value_repr)
        # Same treatment as stdout. The capture layer renders a value repr without colour, but a
        # package whose `show` colours unconditionally — ignoring the stream's `:color` — reaches
        # here anyway, and `_esc` would print its escape codes.
        print(io, "<div class=\"val\"><pre>", _ansi_html(o.value_repr), "</pre></div>")
    end
    isempty(o.display) || print(io, "<div class=\"dispwrap\">", _render_chunks(o.display), "</div>")
    if o.exception !== nothing
        # The message is syntax-coloured (error type, `backticked` names, Suggestion line); the
        # backtrace is dimmed. The message (`errjump`) jumps to the error's ORIGIN — the deepest
        # in-notebook frame (closest to where it actually fired, possibly another cell); the
        # backtrace's `cell:<id>:N` frames (`cellref`) each jump to their own cell (errors.js).
        org = _error_origin(o)
        # Both of these renderers style the text THEMSELVES, so colour arriving in it (from a
        # package whose `showerror` colours unconditionally) is redundant and would interleave with
        # their markup. Dropped rather than converted to spans, unlike stdout.
        exc = ReportEngine.strip_ansi(o.exception)
        print(io, "<div class=\"err\"><pre>")
        if org === nothing
            print(io, _render_exc_html(exc))
        else
            cid, ln = org
            print(io, "<span class=\"err-msg errjump\"",
                  (isempty(cid) ? "" : " data-cid=\"" * cid * "\""), " data-line=\"", ln,
                  "\" title=\"jump to the error origin (line ", ln, isempty(cid) ? "" : " in cell " * cid, ")\">",
                  _render_exc_html(exc), "</span>")
        end
        (o.backtrace === nothing || isempty(o.backtrace)) ||
            print(io, "<span class=\"err-bt\">\n",
                  _linkify_trace(ReportEngine.strip_ansi(o.backtrace)), "</span>")
        print(io, "</pre></div>")
    end
    return String(take!(io))
end

# Colour an already-escaped line's `` `backticked` `` names (identifiers/types Julia quotes in its
# error text) — the backticks drop, the content gets the `err-id` accent.
_color_ticks(s::AbstractString) =
    replace(s, r"`[^`]*`" => m -> "<span class=\"err-id\">" * chop(m; head = 1, tail = 1) * "</span>")

# Render an exception message as coloured HTML: the leading error TYPE (`UndefVarError`, `MethodError`,
# …) is set apart, `Suggestion:` lines are dimmed, and quoted names are accented. Everything is escaped.
function _render_exc_html(exc::AbstractString)
    io = IOBuffer()
    for (i, raw) in enumerate(split(exc, '\n'))
        i > 1 && print(io, '\n')
        m = i == 1 ? match(r"^([A-Za-z_][A-Za-z0-9_]*)([:(].*)$", raw) : nothing
        if startswith(lstrip(raw), "Suggestion:")
            print(io, "<span class=\"err-suggest\">", _color_ticks(_esc(raw)), "</span>")
        elseif m !== nothing
            print(io, "<span class=\"err-type\">", _esc(m.captures[1]), "</span>", _color_ticks(_esc(m.captures[2])))
        else
            print(io, _color_ticks(_esc(raw)))
        end
    end
    return String(take!(io))
end

# The source line in THIS cell where an error occurred — used to tint + jump to the offending line.
# Frames now read `cell:<id>:N` (the eval `filename`), so we take the first frame belonging to THIS
# cell (`cellid`); if the error is purely inside another cell's code the call site here still names
# this cell. Falls back to any `cell:…:N` / legacy `string:N` when `cellid` is unknown. `nothing`
# when the error has no in-cell location (surfaced deep inside a package).
# A cell is evaluated under the pseudo-filename `cell:<id>`, and Windows' stacktrace printer
# takes that for a path and prints it normalised: a frame for a function DEFINED in another
# cell reads `cell:\a:1`. The cell-ref regexes below would miss it, so those frames would lose
# their jump-to-source link, and the link text would show the separator. Undo it once, here.
_unmangle_cellrefs(s::AbstractString) = replace(s, r"\bcell:[\\/]+" => "cell:")

function _cell_error_line(o::CellOutput, cellid::AbstractString = "")
    for s0 in (o.backtrace, o.exception)
        s0 === nothing && continue
        s = _unmangle_cellrefs(s0)
        for m in eachmatch(r"\bcell:([\w\-]+):(\d+)", s)
            (isempty(cellid) || m.captures[1] == cellid) && return parse(Int, m.captures[2])
        end
        m = match(r"\bstring:(\d+)", s)        # legacy / interpolation eval filename
        m === nothing || return parse(Int, m.captures[1])
    end
    return nothing
end

# Where the error actually fired, as close to the source as the notebook can show: the TOPMOST
# (innermost) `cell:<id>:N` frame — the deepest in-notebook location. For an error inside another
# cell's function that's the defining cell; for one that surfaced in package code it's the cell that
# called in (the nearest editable edge). Returns `(cellid, line)`, `("", line)` for a legacy
# `string:N` frame (no cell), or `nothing`. Used for the error-message jump target.
function _error_origin(o::CellOutput)
    for s0 in (o.backtrace, o.exception)
        s0 === nothing && continue
        s = _unmangle_cellrefs(s0)
        m = match(r"\bcell:([\w\-]+):(\d+)", s)
        m === nothing || return (String(m.captures[1]), parse(Int, m.captures[2]))
        m = match(r"\bstring:(\d+)", s)
        m === nothing || return ("", parse(Int, m.captures[1]))
    end
    return nothing
end

# Make source locations in a backtrace clickable: `path.jl:line` → open in VS Code; `string:N`
# (our cell eval `filename`) → jump to that line IN THIS CELL (errors.js wires `.cellref`).
function _linkify_trace(bt0::AbstractString)
    bt = _unmangle_cellrefs(bt0)
    # `~/…` and `/…` are the unix forms; `C:\…` (or `C:/…`) is what a Windows backtrace carries,
    # and without it no source frame is clickable there.
    #
    # `+` and `@` are ordinary in a path (a git worktree, a versioned directory). Leaving them out
    # does not fail to match — it matches a SHORTER tail that is not a real file, so the frame
    # silently stops being clickable for everyone whose checkout contains one.
    s = replace(_esc(bt), r"((?:~|/|[A-Za-z]:[\\/])[\w./\\ +@\-]*\.jl):(\d+)" => function (m)
        p = match(r"^(.*\.jl):(\d+)$", m)
        p === nothing && return m
        path, line = String(p.captures[1]), String(p.captures[2])
        ap = expanduser(path)
        isabspath(ap) && isfile(ap) || return m   # skip Base's relative ./foo.jl etc. — only real files
        # vscode://file wants an absolute path with forward slashes; a Windows one needs its
        # separators flipped and the leading slash added (`vscode://file/C:/…`).
        uri = replace(ap, '\\' => '/')
        startswith(uri, "/") || (uri = "/" * uri)
        "<a class=\"srcref\" href=\"vscode://file" * uri * ":" * line * "\" title=\"open in VS Code\">" * m * "</a>"
    end)
    # `cell:<id>:N` → jump to line N IN CELL <id> (cross-cell: the frame names its own source cell).
    s = replace(s, r"\bcell:([\w\-]+):(\d+)\b" => function (m)
        p = match(r"\bcell:([\w\-]+):(\d+)\b", m)
        cid, ln = String(p.captures[1]), String(p.captures[2])
        "<a class=\"cellref\" data-cid=\"" * cid * "\" data-line=\"" * ln *
            "\" title=\"jump to line " * ln * " in cell " * cid * "\">" * m * "</a>"
    end)
    # Legacy / interpolation `string:N` → jump to that line in THIS cell (no cell id in the frame).
    return replace(s, r"\bstring:(\d+)\b" => function (m)
        ln = String(match(r"\d+", m).match)
        "<a class=\"cellref\" data-line=\"" * ln * "\" title=\"jump to line " * ln * " in this cell\">" * m * "</a>"
    end)
end

# Markdown → HTML with the table extension (GFM tables) and LaTeX math.
#
# Math is handled OUTSIDE CommonMark: `$…$` / `$$…$$` spans are stashed behind
# plain-text placeholders before parsing and restored (HTML-escaped) afterward,
# then typeset client-side by KaTeX. CommonMark's own math rule mangles LaTeX (it
# eats backslash-escapes like `\,`), so we keep the TeX byte-for-byte and let the
# browser render it. Placeholders are bare alphanumerics so markdown leaves them
# untouched; the restored span keeps its `$`/`$$` delimiters for KaTeX.
#
# Every renderer that reads markdown math (this one, doc bundles, Typst) splits the source with
# `_md_segments`, so they agree on what is math. A bare `$…$` follows Pandoc's rule: the opening `$`
# is not escaped and not followed by whitespace, the closing one is not preceded by whitespace and not
# followed by a digit. Prose amounts ("$5 and $10", "$100k–$750k") stay prose. `\[…\]` and `\(…\)`
# need no such rule: they do not occur by accident in prose.
#
# Documenter's spellings are math too, as in Julia's own markdown: a ```math fence for display, and a
# span in exactly two backticks inline. A span in one, three or more backticks is still code.
const _MD_SCAN = Regex(join((
    raw"(?<dmath>^[ ]{0,3}(?<mfence>`{3,}|~{3,})math[ \t]*\n.*?^[ ]{0,3}\k<mfence>[`~]*[ \t]*$|(?<!`)``(?!`)[^`]+?(?<!`)``(?!`))",
    # code, literal: a fenced block (to its closing fence or the end), or an inline span
    raw"(?<code>^[ ]{0,3}(?<fence>`{3,}|~{3,})[^\n]*\n.*?(?:^[ ]{0,3}\k<fence>[`~]*[ \t]*$|\z)|(?<ticks>`+).+?(?<!`)\k<ticks>(?!`))",
    # math; display forms first so a `$…$` cannot split a `$$…$$`
    raw"(?<math>\\\[.+?\\\]|\$\$.+?\$\$|\\\(.+?\\\)|(?<!\\)\$(?!\s)[^\$\n]+?(?<!\s)\$(?!\d))",
    # a dollar that is prose, escaped or not
    raw"(?<dollar>\\?\$)"), "|"), "ms")

"""
    _md_segments(s) -> Vector{Pair{Symbol,String}}

Markdown split into `:code` (fenced blocks and inline spans), `:math` (a span in any of Slate's four
delimiters or Documenter's two, delimiters included), `:dollar` (a `\$` or `\\\$` that is prose) and
`:text`.
"""
function _md_segments(s::AbstractString)
    s = String(s)
    out = Pair{Symbol,String}[]; i = 1
    for m in eachmatch(_MD_SCAN, s)
        m.offset > i && push!(out, :text => s[i:prevind(s, m.offset)])
        kind = m[:code] !== nothing ? :code : (m[:math] !== nothing || m[:dmath] !== nothing) ? :math : :dollar
        push!(out, kind => String(m.match))
        i = m.offset + ncodeunits(m.match)
    end
    i <= ncodeunits(s) && push!(out, :text => s[i:end])
    return out
end

"The TeX inside a `:math` segment, and whether it is display math."
function _math_parts(m::AbstractString)
    f = match(r"^[ ]{0,3}[`~]{3,}math[ \t]*\n(.*?)\n?[ ]{0,3}[`~]{3,}[ \t]*$"s, m)
    f === nothing || return (String(f.captures[1]), true)
    startswith(m, "``") && return (chop(m; head = 2, tail = 2), false)
    (startswith(m, "\$\$") || startswith(m, "\\[")) && return (chop(m; head = 2, tail = 2), true)
    startswith(m, "\\(") && return (chop(m; head = 2, tail = 2), false)
    return (chop(m; head = 1, tail = 1), false)
end

"A `:math` segment in delimiters KaTeX is configured for: Documenter's two spellings become dollars."
function _katex_math(t::AbstractString)
    s = lstrip(t)
    (startswith(s, "``") || startswith(s, "~~~")) || return String(t)
    tex, display = _math_parts(t)
    return display ? string("\$\$", tex, "\$\$") : string("\$", tex, "\$")
end

_math_token(i::Int) = "xslatemathx" * string(i; pad = 5) * "x"
const _DOLLAR_TOKEN = "xslatedollarx"

# A prose `$` goes out in an element of its own: KaTeX's auto-render pairs delimiters only within one
# text node, so it cannot join two prose dollars into a formula. Inside a tag (an attribute value of
# raw HTML) it is written bare.
function _restore_dollars(html::AbstractString)
    occursin(_DOLLAR_TOKEN, html) || return String(html)
    html = replace(html, r"<[^<>]*>" => t -> replace(t, _DOLLAR_TOKEN => "\$"))
    return replace(html, _DOLLAR_TOKEN => "<span class=\"dollar\">\$</span>")
end

# A string value's text/plain repr is quoted (`"c"`), but inside `{{ }}` interpolation — a
# presentation context, like Julia's `$(…)` — we want the bare content (`c`). Lives in widgets.jl
# because a REPLAYED interpolation is rendered in the worker, where this module does not exist, and
# the two must produce identical text or moving the control would visibly restyle the prose.
const _interp_scalar = ReportEngine._interp_scalar

# The text an interpolation contributes to an ATTRIBUTE — its scalar value, with no markup around it.
# `""` for one that renders something (a chart, a table, an image): those are not attribute material,
# and leaving the token in place is better than writing a `<div>` into a `src=`, since an unresolved
# token is visibly wrong rather than quietly malformed.
function _attr_interp_text(o)
    o === nothing && return ""
    o.exception === nothing || return ""
    isempty(o.display) && isempty(o.echarts) && isempty(o.tables) || return ""
    return _interp_scalar(o.value_repr)
end

# Add attributes to a tag, before its `>` and any XHTML-style `/`.
function _tag_add_attrs(tag::AbstractString, extra::AbstractString)
    body = rstrip(tag[firstindex(tag):prevind(tag, lastindex(tag))])
    endswith(body, "/") && (body = rstrip(body[firstindex(body):prevind(body, lastindex(body))]))
    return string(body, extra, ">")
end

const _ATTR_PAIR = r"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*\"([^\"]*)\""

# The slot marker a recorded template holds in place of an interpolation. NOT the interpolation token:
# the substitution below is a blanket string replace over the whole document, and it would rewrite the
# template we just stored — putting a `<span>` inside the very attribute this exists to keep clean.
_slot_token(i::Int) = "xslottokx" * string(i; pad = 5) * "x"

# Substitute the interpolations that landed inside a tag, and only those. Scans tag by tag rather than
# with a regex over the whole document: an attribute value can contain `>` and a `<` can appear in
# prose, so a pattern for "inside a tag" is exactly the thing that goes wrong on real input.
#
# A tag whose attribute was BUILT from an interpolation also gets a slot number and, per attribute, the
# template it was built from (`data-islot` / `data-itmpl-<attr>`). The value is embedded in the middle
# of the attribute — `frame_` + `07` + `.png` — so a replayed position cannot simply assign the
# swept string; the export resolves the template per position and ships the finished attribute. This is
# where that template is recorded, because this is the only place that still knows which token went
# where. Kept verbatim from the rendered HTML (already entity-escaped by CommonMark), so re-escaping it
# here would double it.
function _sub_attr_interps(html::AbstractString, interps)
    isempty(interps) && return html
    ('<' in html) || return html
    out = IOBuffer(); i = firstindex(html); n = lastindex(html); slot = 0
    while i <= n
        if html[i] != '<'
            print(out, html[i]); i = nextind(html, i); continue
        end
        j = findnext('>', html, i)
        if j === nothing                                   # unterminated `<` — emit the rest verbatim
            print(out, html[i:n]); break
        end
        tag = html[i:j]
        if occursin("xslateinterpx", tag)
            tmpl = IOBuffer()
            for m in eachmatch(_ATTR_PAIR, tag)
                occursin("xslateinterpx", m.captures[2]) || continue
                v = String(m.captures[2])
                for k in eachindex(interps)
                    v = replace(v, ReportEngine._interp_token(k) => _slot_token(k))
                end
                print(tmpl, " data-itmpl-", lowercase(m.captures[1]), "=\"", v, "\"")
            end
            for k in eachindex(interps)
                tok = ReportEngine._interp_token(k)
                occursin(tok, tag) || continue
                tag = replace(tag, tok => _esc(_attr_interp_text(interps[k])))
            end
            t = String(take!(tmpl))
            if !isempty(t)
                tag = _tag_add_attrs(tag, string(" data-islot=\"", slot, "\"", t))
                slot += 1
            end
        end
        print(out, tag); i = nextind(html, j)
    end
    return String(take!(out))
end

# Nothing to splice: the interpolation produced no output at all. `nothing` reprs as `"nothing"`, which
# is what an unclaimed fence renderer returns, so it counts as empty here too — a `{{ }}` that genuinely
# evaluates to `nothing` already rendered as blank prose before this existed.
# Does this fragment open with a block-level tag? Decides whether it may sit inside a `<p>`.
_is_block_frag(f::AbstractString) =
    startswith(f, "<pre") || startswith(f, "<div") || startswith(f, "<figure") || startswith(f, "<table")

_is_empty_output(o) =
    o.exception === nothing && isempty(o.display) && isempty(o.echarts) && isempty(o.tables) &&
    (isempty(o.value_repr) || o.value_repr == "nothing")

# The text of an output whose only rich form is markdown, or `nothing`.
function _markdown_output(o)
    (o === nothing || o.exception !== nothing || length(o.display) != 1) && return nothing
    ch = only(o.display)
    return ch.mime == "text/markdown" ? String(copy(ch.data)) : nothing
end

# True when the output `o` draws a figure: a picture, an HTML display, a component, or a chart. The
# MIME types of its chunks decide, as `_render_chunks` draws them. A `Markdown.MD` value (its HTML,
# then its markdown form) is prose, and so is math.
function _is_figure_value(o)
    o.exception === nothing || return false
    isempty(o.display) && return !isempty(o.echarts)
    return any(pairs(o.display)) do (i, ch)
        startswith(ch.mime, "image/") || ch.mime in _FIGURE_CHUNK_MIMES ||
            (ch.mime == "text/html" && !_is_md_value_html(o.display, i))
    end
end
const _FIGURE_CHUNK_MIMES = ("application/vnd.kaimonslate.component+json", "application/vnd.kaimonslate.html+html")

# The markdown template with each markdown-valued `{{ expr }}` capture's text in place (passed through
# `prose`); the other interpolations stay as tokens. Returns `(template, exprs)`.
function _md_spliced(src::AbstractString, interps = CellOutput[]; prose = identity)
    tmpl, exprs = ReportEngine._md_template(src)
    for i in 1:length(exprs)
        md = _markdown_output(i <= length(interps) ? interps[i] : nothing)
        md === nothing || (tmpl = replace(tmpl, ReportEngine._interp_token(i) => prose(md)))
    end
    return tmpl, exprs
end

# Render markdown, splicing each `{{ expr }}` capture in. A markdown value is prose: its text goes
# into the source before parsing, so its headings, lists, tables and links are the cell's own.
# Other self-contained outputs (image / HTML / LaTeX / scalar) embed directly; echarts & interactive
# tables emit a host placeholder (`.ichart`/`.itable` keyed by index) that the SPA hydrates from the
# cell's collected `echarts`/`tables` — same order as here.
function _md_html(src::AbstractString, interps = CellOutput[]; prose = identity, caption = nothing)
    tmpl, exprs = _md_spliced(src, interps; prose)
    frags = String[]; ec = 0; tc = 0
    for i in 1:length(exprs)
        o = i <= length(interps) ? interps[i] : nothing
        # A desugared ```lang fence whose language no extension claimed (or whose renderer declined)
        # comes back empty — emit the code block CommonMark would have, so an unclaimed fence is
        # indistinguishable from one that was never rewritten. Checked before the empty-output cases
        # below, which would otherwise swallow the block entirely.
        fence = ReportEngine._fence_call(exprs[i])
        if _markdown_output(o) !== nothing
            push!(frags, "")                                        # already spliced into the source
        elseif fence !== nothing && (o === nothing || _is_empty_output(o))
            push!(frags, "<pre><code class=\"language-" * _esc(fence.lang) * "\">" *
                         _esc(fence.body) * "</code></pre>")
        elseif o === nothing
            push!(frags, "")
        elseif o.exception !== nothing
            push!(frags, "<span class=\"interr\">⟨" * _esc(o.exception) * "⟩</span>")
        elseif !isempty(o.display)
            push!(frags, _render_chunks(o.display))
        elseif !isempty(o.echarts)
            push!(frags, "<div class=\"ichart\" data-i=\"$ec\"></div>"); ec += 1
        elseif !isempty(o.tables)
            push!(frags, "<div class=\"itable\" data-i=\"$tc\"></div>"); tc += 1
        elseif !isempty(o.value_repr)
            # Indexed like the `.ichart`/`.itable` placeholders above, and for the same reason: a
            # replayed position ships one string per interpolation, and this is what it writes into.
            push!(frags, "<span class=\"ival\" data-i=\"" * string(i - 1) * "\">" *
                         _esc(_interp_scalar(o.value_repr)) * "</span>")
        else
            push!(frags, "")
        end
    end
    # math and prose dollars → placeholders (math kept byte-for-byte for KaTeX). The LaTeX-bracket
    # spellings are stashed too, even though KaTeX is configured for them: CommonMark reads `\(` / `\[`
    # as escaped punctuation and drops the backslash, leaving KaTeX no delimiter to match.
    math = String[]
    b = IOBuffer()
    for (kind, t) in _md_segments(tmpl)
        if kind === :math
            push!(math, _katex_math(t)); print(b, _math_token(length(math)))
        elseif kind === :dollar
            print(b, _DOLLAR_TOKEN)
        else
            print(b, t)
        end
    end
    # Each block of a kind gets its `<slate-…>` element (block_kinds.jl). The markdown values are in
    # the source already, so this one call covers them. A `{{ }}` value alone in its paragraph is a
    # figure when it draws a picture, a chart or a component (`_is_figure_value`).
    isfig(i) = i <= length(interps) && _is_figure_value(interps[i])
    s = _md_kinds(_quote_fence_values(String(take!(b))); caption, figure = isfig)
    ast = _md_parser()(s)
    _style_groups!(ast)
    html = CommonMark.html(ast)
    for (i, m) in enumerate(math)
        tex = m
        for j in 1:length(exprs)                                    # interpolations inside math → raw TeX
            tok = ReportEngine._interp_token(j)
            occursin(tok, tex) && (tex = replace(tex, tok => _math_value(j <= length(interps) ? interps[j] : nothing)))
        end
        html = replace(html, _math_token(i) => _esc(tex))           # raw TeX, escaped; KaTeX reads the text node
    end
    html = _restore_dollars(html)
    # An interpolation that landed inside a TAG is part of an attribute, not prose — `![alt]({{ … }})`
    # is the ordinary case, and a title= or a width= are others. The fragment for a scalar is a
    # `<span>`, and writing that into an attribute value breaks the tag, so those positions take the
    # bare text instead. Done before the substitution below, which is a blanket string replace and
    # cannot tell the two contexts apart.
    html = _sub_attr_interps(html, interps)
    for (i, f) in enumerate(frags)
        tok = ReportEngine._interp_token(i)
        # A BLOCK-level fragment (a fence's code block, a rich display, a chart/table host) standing
        # alone in its own paragraph: drop the `<p>` CommonMark wrapped the bare token in, since a `<p>`
        # cannot legally contain a `<pre>`/`<div>` and the browser's repair splits it into stray empties.
        # An inline fragment (a scalar span) keeps its paragraph — that spacing is the intended prose.
        _is_block_frag(f) && (html = replace(html, "<p>" * tok * "</p>" => f))
        html = replace(html, tok => f)                              # remaining (text) interps → HTML fragment
    end
    html = replace(html, "<p>. . .</p>" => "<div class=\"pause\"></div>")
    html = _media_from_img(html)
    # Last, so an image produced by a `{{ }}` interpolation can be sized like a literal one.
    return _apply_md_attrs(html)
end

# ── Groups: `:::: columns` and `:::: grid` ────────────────────────────────────────────────────────────
# A group puts content side by side inside one markdown cell. `:::: columns` holds `::: column` divs;
# `:::: grid` holds `::: cell` divs (grid cells) on one list of tracks, in rows that wrap. The live
# render reads the attributes from the CommonMark tree (`_style_groups!`); the Typst export splits the
# source at the groups of the same tree (`_md_groups`). So both targets see the same groups and values.

# CommonMark ends an unquoted attribute value at `.` or `%`: `size=3.6` is `size="3"` plus a class `6`,
# and `width=40%` is no div at all. Put quotes around each unquoted value of a `::: {…}` line first.
# The line count does not change.
function _quote_fence_values(src::AbstractString)
    occursin(":::", src) || return String(src)
    lines = split(String(src), '\n'; keepempty = true)
    infence = false
    for (i, ln) in enumerate(lines)
        occursin(r"^\s*(```|~~~)", ln) && (infence = !infence; continue)
        infence && continue
        m = match(r"^(\s*:{3,}\s*\{)(.*)(\}\s*)$", ln)
        m === nothing && continue
        lines[i] = string(m[1], replace(m[2], r"(^|\s)([A-Za-z_][\w-]*)=([^\s\"'{}]+)" => s"\1\2=\"\3\""), m[3])
    end
    return join(lines, "\n")
end

_div_classes(n) = (c = CommonMark.getmeta(n, "class", String[]); c isa AbstractString ? split(c) : c)
_is_div(n, cls) = n.t isa CommonMark.FencedDiv && cls in _div_classes(n)
_group_kind(n) = _is_div(n, "grid") ? :grid : _is_div(n, "columns") ? :columns : nothing

# The colour roles of the deck settings (`deck_settings.jl` `_DECK_ROLES`): a `fill` word is a palette
# name, else one of these.
const _FILL_ROLES = ("fg", "strong", "dim", "accent", "accent2", "surface", "ink")
const _FILL_RE = r"^[A-Za-z][A-Za-z0-9_-]{0,47}$"

# A length attribute: a bare number or a number with `unit`, in `lo`..`hi`. `nothing` when absent;
# a warning in `warns` and `nothing` when not valid.
function _attr_num(d, k, unit, lo, hi, warns)
    v = get(d, k, nothing)
    v === nothing && return nothing
    m = match(Regex("^([0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)(?:$unit)?\$"), strip(String(v)))
    x = m === nothing ? nothing : parse(Float64, m[1])
    x !== nothing && lo <= x <= hi && return x
    push!(warns, "`$k=\"$v\"` must be a number from $(_fmtnum(lo)) to $(_fmtnum(hi))$(unit == "" ? "" : " (in $unit)")")
    return nothing
end
_fmtnum(x) = isinteger(x) ? string(Int(x)) : string(x)

function _attr_pick(d, k, ok, warns)
    v = get(d, k, nothing)
    v === nothing && return nothing
    v in ok && return String(v)
    push!(warns, "`$k=\"$v\"` must be one of " * join(ok, ", "))
    return nothing
end

const _GRID_ATTRS = ("columns", "gap")
const _CELL_ATTRS = ("fill", "align", "valign", "size")

function _unknown_attrs!(d, ok, what, warns)
    for k in sort!(collect(keys(d)))
        k in ("class", "id") || k in ok || push!(warns, "`$k` is not an attribute of $what")
    end
end

# The checked values of a grid fence: `tracks` as `(:fr | :u, value)`, `gap` in `u` or `nothing` (the
# deck setting `grid.gap`), and the cell attributes on the fence, which are the defaults of its cells.
# `columns` is a count from 1 to 12, or a list of `Nfr` and `Nu` tracks. A bad list gives one track.
function _grid_spec(d, warns = String[])
    _unknown_attrs!(d, (_GRID_ATTRS..., _CELL_ATTRS...), "a grid", warns)
    cols = strip(String(get(d, "columns", "1")))
    tracks = Tuple{Symbol,Float64}[]
    if occursin(r"^[0-9]+$", cols)
        n = parse(Int, cols)
        1 <= n <= 12 ? append!(tracks, fill((:fr, 1.0), n)) : push!(warns, "`columns=\"$cols\"` must be a count from 1 to 12")
    else
        for t in split(cols)
            m = match(r"^([0-9]+(?:\.[0-9]+)?|\.[0-9]+)(fr|u)$", t)
            x = m === nothing ? 0.0 : parse(Float64, m[1])
            if m === nothing || x > 10000 || (m[2] == "fr" && x == 0)
                push!(warns, "`columns=\"$cols\"` must be a count, or tracks such as \"1fr 2fr\" or \"400u 1fr\"")
                empty!(tracks)
                break
            end
            push!(tracks, (Symbol(m[2]), x))
        end
    end
    isempty(tracks) && push!(tracks, (:fr, 1.0))
    gap = _attr_num(d, "gap", "u", 0, 10000, warns)
    cell = Dict{String,Any}(k => d[k] for k in _CELL_ATTRS if haskey(d, k))
    return (; tracks, gap, cell)
end

# The checked values of a grid cell: the attributes of its fence over those of the grid fence.
function _cell_spec(d, defaults = Dict{String,Any}(), warns = String[])
    _unknown_attrs!(d, _CELL_ATTRS, "a grid cell", warns)
    a = merge(defaults, Dict{String,Any}(k => d[k] for k in _CELL_ATTRS if haskey(d, k)))
    f = get(a, "fill", nothing)
    f !== nothing && match(_FILL_RE, String(f)) === nothing && (push!(warns, "`fill=\"$f\"` must be a palette name or a colour role"); f = nothing)
    return (; fill = f === nothing ? nothing : String(f),
            align = something(_attr_pick(a, "align", ("left", "center", "right"), warns), "left"),
            valign = something(_attr_pick(a, "valign", ("top", "middle", "bottom"), warns), "top"),
            size = _attr_num(a, "size", "em", 0.5, 8, warns))
end

# The CSS colour of a `fill` word: the palette colour, and for a role name the role when the palette
# has no such name. Outside a deck the properties do not exist, so a grid cell has no paint there.
_fill_css(f) = f in _FILL_ROLES ? "var(--deck-palette-$f, var(--deck-$f))" : "var(--deck-palette-$f)"
_css_u(x) = string("calc(", _fmtnum(x), " * var(--u, 1px))")

# The child nodes of `n`.
_md_children(n) = (out = CommonMark.Node[]; c = n.first_child; while !CommonMark.isnull(c); push!(out, c); c = c.nxt; end; out)

function _set_warn!(n, warns)
    isempty(warns) && return
    msg = join(warns, "; ")
    n.meta["data-warn"] = msg
    n.meta["title"] = msg
end

# Give each group of the tree its live form. A grid becomes `deck-grid` with its tracks and gap as
# inline style, each grid cell `deck-grid-cell` with its paint and alignment; the notebook rule `.cell`
# must not reach a grid cell. A column with `width` gets that width as its flex basis. Content of a
# grid that is in no grid cell (notebook.css hides it) and a grid cell outside a grid give a warning.
# The pad, the gap and the paint of a grid cell apply on the deck only (notebook.css). A group with a
# warning has it in `data-warn`, which the notebook page shows.
function _style_groups!(n)
    for c in _md_children(n)
        c.t isa CommonMark.FencedDiv || continue
        cls = String.(_div_classes(c))
        warns = String[]
        if "grid" in cls
            g = _grid_spec(c.meta, warns)
            style = ["grid-template-columns:" * join((k === :fr ? _fmtnum(v) * "fr" : _css_u(v) for (k, v) in g.tracks), " ")]
            g.gap === nothing || push!(style, "gap:" * _css_u(g.gap))
            for k in _md_children(c)
                if _is_div(k, "cell")
                    _style_cell!(k, g.cell)
                elseif !("content outside a grid cell is not shown" in warns)
                    push!(warns, "content outside a grid cell is not shown")
                end
            end
            _set_div!(c, replace(cls, "grid" => "deck-grid"), style, warns)
        elseif "cell" in cls
            push!(warns, "a grid cell outside a grid has no effect")
            _set_div!(c, filter(!=("cell"), cls), String[], warns)
        elseif "column" in cls && haskey(c.meta, "width")
            w = strip(String(c.meta["width"]))
            if occursin(r"^[0-9.]+(%|px|em|rem)?$", w)
                w = occursin(r"^[0-9.]+$", w) ? w * "%" : w
                c.meta["style"] = "flex:0 1 $w;max-width:$w"
            end
        end
        _style_groups!(c)
    end
end

function _style_cell!(k, defaults)
    warns = String[]
    cs = _cell_spec(k.meta, defaults, warns)
    style = ["text-align:" * cs.align]
    cs.fill === nothing || push!(style, "background:" * _fill_css(cs.fill))
    cs.valign == "top" || push!(style, "align-content:" * (cs.valign == "middle" ? "center" : "end"))
    cs.size === nothing || push!(style, "font-size:$(_fmtnum(cs.size))em")
    cls = replace(String.(_div_classes(k)), "cell" => "deck-grid-cell")
    cs.fill === nothing || push!(cls, "filled")
    _set_div!(k, cls, style, warns)
end

# Keep the id and the classes of a group div, put `style` on it, and drop its other attributes.
function _set_div!(n, cls, style, warns)
    meta = Dict{String,Any}("class" => cls)
    haskey(n.meta, "id") && (meta["id"] = n.meta["id"])
    isempty(style) || (meta["style"] = join(style, ";"))
    n.meta = meta
    _set_warn!(n, warns)
end

# The groups of the markdown `src` for the Typst export, found in the same CommonMark tree as the live
# render finds them. The result holds the text between groups as strings and each group as
# `(kind, grid, metas, cells, cols, warns)`: `kind` is `:columns` or `:grid`, `grid` the `_grid_spec`
# of a grid, then for each container (a column or a grid cell) the attributes of its fence, the
# `_cell_spec` of a grid cell, and its markdown source. `warns` holds the warnings of the group. A
# group inside a container stays in the source of that container, where the next pass finds it; a
# group inside another div (`::: step`) is found, and the fences of that div stay in the text. Other
# content between the containers is not in the result. A grid cell outside a grid gives a warning in
# `warns`.
function _md_groups(src::AbstractString; warns::Vector{String} = String[])
    occursin(r"columns|grid|cell", src) || return Any[String(src)]
    src = _quote_fence_values(src)
    lines = split(src, '\n'; keepempty = true)
    pieces = Any[]
    done = 0                                         # the last line in `pieces`
    function visit(n)
        for c in _md_children(n)
            c.t isa CommonMark.FencedDiv || continue
            kind = _group_kind(c)
            if kind === nothing
                _is_div(c, "cell") && push!(warns, "a grid cell outside a grid has no effect")
                visit(c)
                continue
            end
            a, b = c.sourcepos[1][1], c.sourcepos[2][1]
            a > done + 1 && push!(pieces, join(lines[done+1:a-1], "\n"))
            push!(pieces, _group_piece(c, kind, lines))
            done = b
        end
    end
    visit(_md_parser()(_mask_math(src)))
    isempty(pieces) && return Any[src]
    done < length(lines) && push!(pieces, join(lines[done+1:end], "\n"))
    return pieces
end

function _group_piece(c, kind, lines)
    warns = String[]
    grid = kind === :grid ? _grid_spec(c.meta, warns) : nothing
    metas, cells, cols = Dict{String,Any}[], Any[], String[]
    for k in _md_children(c)
        if _is_div(k, kind === :grid ? "cell" : "column")
            a, b = k.sourcepos[1][1], k.sourcepos[2][1]
            # The last line is the closing fence when the div has one: a fence line after its content.
            inner = CommonMark.isnull(k.last_child) ? a : k.last_child.sourcepos[2][1]
            b > inner && occursin(r"^\s*:{3,}\s*$", lines[b]) && (b -= 1)
            push!(metas, something(k.meta, Dict{String,Any}()))
            push!(cells, kind === :grid ? _cell_spec(k.meta, grid.cell, warns) : nothing)
            push!(cols, join(lines[a+1:b], "\n"))
        elseif kind === :grid && !("content outside a grid cell is not shown" in warns)
            push!(warns, "content outside a grid cell is not shown")
        end
    end
    return (; kind, grid, metas, cells, cols, warns)
end

# `![flags](clip.mp4)` → a `<video>` (or `<audio>` for a sound file): image syntax is what an author
# reaches for, and an `<img>` pointing at a clip renders as a broken image. The alt text carries the
# playback flags — `autoplay`, `loop`, `muted`, `nocontrols` — which a presented slide also reads to
# start the clip when it comes on screen.
const _VIDEO_EXT = r"\.(mp4|m4v|webm|mov|ogv)(?:[?#][^\"]*)?$"i
const _AUDIO_EXT = r"\.(mp3|m4a|wav|ogg|oga|flac|aac)(?:[?#][^\"]*)?$"i
const _MEDIA_FLAGS = ("autoplay", "loop", "muted", "nocontrols")
function _media_from_img(html::AbstractString)
    occursin("<img", html) || return String(html)
    return replace(html, r"<img\b([^<>]*?)\s*/?>" => function (tag)
        src = match(r"\ssrc=\"([^\"]*)\"", tag)
        src === nothing && return tag
        url = String(src.captures[1])
        kind = occursin(_VIDEO_EXT, url) ? "video" : occursin(_AUDIO_EXT, url) ? "audio" : ""
        isempty(kind) && return tag
        alt = match(r"\salt=\"([^\"]*)\"", tag)
        flags = Set(lowercase.(split(alt === nothing ? "" : alt.captures[1])))
        style = match(r"\sstyle=\"([^\"]*)\"", tag)
        attrs = String[]
        "nocontrols" in flags || push!(attrs, "controls")
        "loop" in flags && push!(attrs, "loop")
        # `autoplay` is played by the deck (a slide coming up follows a keypress, which lets sound play),
        # not by the `autoplay` attribute, so a clip keeps its sound unless the author mutes it.
        "muted" in flags && push!(attrs, "muted")
        "autoplay" in flags && push!(attrs, "data-autoplay")
        kind == "video" && push!(attrs, "playsinline", "preload=\"metadata\"")
        style === nothing || push!(attrs, "style=\"" * style.captures[1] * "\"")
        return string("<", kind, " src=\"", url, "\" ", join(attrs, " "), "></", kind, ">")
    end)
end

# ── Pandoc-style attribute blocks on media ────────────────────────────────────────────────────────
# `![alt](pic.png){width=300}` sizes the image it directly follows. CommonMark has no such rule, so it
# renders the block as literal text after the tag; this folds that text back onto the tag as real
# attributes. Adjacency is required (as in Pandoc/Quarto) — a `{` after a space is just prose.
#   width= / height=   a bare number is px (`300` → `300px`); any CSS length or `%` passes through
#   align=             `center` centres the block; `left`/`right` float it with prose flowing beside
#   .name / #name      appended to the tag's class / set as its id
#   title=             hover text; quote the value if it has spaces
# Applies to `<img>` and to the `<video>`/`<audio>` a dropped clip becomes. Unknown keys are dropped
# rather than emitted, so a typo can't inject an arbitrary attribute into the page.
const _MEDIA_ATTR_RE = r"(<(img|video|audio)\b[^<>]*?)(\s*/?>)((?:</[A-Za-z][\w-]*>)*)\{([^{}<>\n]*)\}"
const _ATTR_ITEM_RE = r"\.([A-Za-z][\w-]*)|#([A-Za-z][\w-]*)|([A-Za-z][\w-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s}]+))"
# A bare number means pixels — the unit an author writing `{width=300}` for the web has in mind.
_css_len(v::AbstractString) = occursin(r"^-?\d+(?:\.\d+)?$", v) ? v * "px" : String(v)

# Set (or extend) one attribute on an open tag, preserving whatever the tag already carries — a
# dropped clip arrives with its own `style`, and `{width=…}` must add to it, not replace it.
function _set_attr(tag::AbstractString, name::AbstractString, value::AbstractString;
                   append::Bool = false, sep::AbstractString = " ")
    isempty(value) && return String(tag)
    m = match(Regex("(\\s" * name * "\\s*=\\s*)([\"'])(.*?)\\2", "i"), tag)
    m === nothing && return string(tag, " ", name, "=\"", _esc(value), "\"")
    old = strip(String(m.captures[3]), [' ', ';'])
    new = (append && !isempty(old)) ? string(old, sep, _esc(value)) : _esc(value)
    return string(SubString(tag, 1, prevind(tag, m.offset)), m.captures[1], "\"", new, "\"",
                  SubString(tag, m.offset + ncodeunits(m.match)))
end

# One attribute block → (styles, classes, id, plain attributes).
function _media_attrs(raw::AbstractString)
    # The block arrives as CommonMark's escaped TEXT, so a quoted value reads `&quot;…&quot;` here.
    spec = replace(String(raw), "&quot;" => "\"", "&#39;" => "'", "&amp;" => "&")
    styles = String[]; classes = String[]; id = ""; extra = Pair{String,String}[]
    for m in eachmatch(_ATTR_ITEM_RE, spec)
        if m.captures[1] !== nothing
            push!(classes, String(m.captures[1]))
        elseif m.captures[2] !== nothing
            id = String(m.captures[2])
        else
            k = lowercase(String(m.captures[3]))
            v = String(something(m.captures[4], m.captures[5], m.captures[6], ""))
            if k in ("width", "height")
                push!(styles, string(k, ":", _css_len(v)))
            elseif k == "align"
                a = lowercase(v)
                a == "center" ? push!(styles, "display:block;margin-left:auto;margin-right:auto") :
                a == "left"   ? push!(styles, "float:left;margin-right:1em") :
                a == "right"  ? push!(styles, "float:right;margin-left:1em") : nothing
            elseif k in ("title", "alt")
                push!(extra, k => v)
            elseif k == "class"
                append!(classes, split(v))
            elseif k == "id"
                id = v
            end
        end
    end
    return (styles, classes, id, extra)
end

function _apply_md_attrs(html::AbstractString)
    occursin('{', html) || return String(html)
    return replace(html, _MEDIA_ATTR_RE => function (m)
        mm = match(_MEDIA_ATTR_RE, m)
        tag = String(mm.captures[1])
        styles, classes, id, extra = _media_attrs(String(mm.captures[5]))
        # Nothing recognised ⇒ this wasn't an attribute block. Leave the author's braces as prose.
        (isempty(styles) && isempty(classes) && isempty(id) && isempty(extra)) && return m
        isempty(styles)  || (tag = _set_attr(tag, "style", join(styles, ";"); append = true, sep = ";"))
        isempty(classes) || (tag = _set_attr(tag, "class", join(classes, " "); append = true))
        isempty(id)      || (tag = _set_attr(tag, "id", id))
        for (k, v) in extra
            tag = _set_attr(tag, k, v)
        end
        return string(tag, mm.captures[3], mm.captures[4])
    end)
end

# Raw text of an interpolation for *math* context (inside `$…$`/`$$…$$`): a scalar's
# value, or a text/latex chunk's TeX (delimiters stripped). KaTeX is already in math
# mode there, so we want bare TeX, not an HTML span.
function _math_value(o::Union{CellOutput,Nothing})
    o === nothing && return ""
    o.exception === nothing || return "?"
    isempty(o.value_repr) || return _interp_scalar(o.value_repr)
    for ch in o.display
        if ch.mime == "text/latex"
            t = strip(String(copy(ch.data)))
            # `chop`, not byte slicing: `$θ$` would index into the middle of the last character.
            startswith(t, "\$\$") && endswith(t, "\$\$") && length(t) >= 4 &&
                return chop(t; head = 2, tail = 2)
            startswith(t, "\$") && endswith(t, "\$") && length(t) >= 2 &&
                return chop(t; head = 1, tail = 1)
            return t
        end
    end
    return ""
end

# Render captured MIME chunks to trusted HTML: images → base64 data-URI <img>,
# text/html injected as-is. (Returned via the template's `|> safe` filter.)
#
# NOTE: read text bytes with `String(copy(ch.data))`, never `String(ch.data)` —
# the latter *steals* the byte vector (empties it), so a cell rendered twice (every
# `/state` poll) would come back blank on the second render. Images/base64encode
# read non-destructively, which is why only text/html + text/latex were affected.
# The columns of a gallery of `n` figures: two for 2 or 4, three up to 9, four beyond.
_gallery_cols(n) = n == 2 || n == 4 ? 2 : n <= 9 ? 3 : 4

# The display forms a value's export-only markdown chunk can follow.
const _RESTATED_MIMES = ("text/html", "text/latex", "application/vnd.kaimonslate.component+json",
                         "application/vnd.kaimonslate.html+html")

# Julia's HTML of a `Markdown.MD` value starts with this tag.
const _MD_VALUE_HTML = codeunits("<div class=\"markdown\">")

# True when chunk `i` is the HTML of a `Markdown.MD` value and its markdown form comes next.
function _is_md_value_html(chunks, i)
    d = chunks[i].data
    return chunks[i].mime == "text/html" && i < lastindex(chunks) && chunks[i + 1].mime == "text/markdown" &&
           length(d) >= length(_MD_VALUE_HTML) && view(d, 1:length(_MD_VALUE_HTML)) == _MD_VALUE_HTML
end

function _render_chunks(chunks)
    io = IOBuffer()
    grid = 0                                   # images still to place in an open gallery grid
    prev = ""
    for (i, ch) in pairs(chunks)
        # Markdown right after a value's HTML, LaTeX or Slate display is that value's other form, kept
        # for export (capture.jl `_capture_export_markdown!`); markdown on its own is the value's display.
        alt = ch.mime == "text/markdown" && prev in _RESTATED_MIMES
        prev = ch.mime
        alt && continue
        # A `Markdown.MD` value shows its markdown form, not Julia's HTML: the markdown renders as a
        # markdown cell does, so its blocks get their kinds (`<slate-key-message>` and the others).
        if _is_md_value_html(chunks, i)
            prev = ""
            continue
        end
        if ch.mime == "application/vnd.kaimonslate.gallery"
            n = something(tryparse(Int, String(copy(ch.data))), 0)
            n > 0 || continue
            grid > 0 && print(io, "</div>")
            # the grid's layout inline as well as in the stylesheet, so a page holding an older stylesheet, or an
            # export without it, still lays the figures out side by side
            print(io, "<div class=\"disp gallery\" style=\"--gallery-cols:", _gallery_cols(n),
                  ";display:grid;grid-template-columns:repeat(", _gallery_cols(n), ",minmax(0,1fr));gap:8px;align-items:start\">")
            grid = n
            continue
        end
        if ch.mime == "text/html"
            print(io, "<div class=\"disp html\">", String(copy(ch.data)), "</div>")
        elseif ch.mime == "text/latex"
            # Emit the raw TeX (with its delimiters) inside a marked div; the SPA
            # typesets it in DISPLAY mode via KaTeX so block output matches markdown
            # `$$…$$` sizing. Bare TeX (no delimiters) is wrapped so it still renders.
            # HTML-escape so the browser hands KaTeX the raw text node verbatim.
            tex = String(copy(ch.data))
            wrapped = (occursin('$', tex) || occursin("\\(", tex) || occursin("\\[", tex)) ?
                      tex : "\\[" * tex * "\\]"
            print(io, "<div class=\"disp latex\">", _esc(wrapped), "</div>")
        elseif startswith(ch.mime, "image/")
            b64 = Base64.base64encode(ch.data)
            print(io, "<div class=\"disp img\"><img alt=\"output\" src=\"data:",
                  ch.mime, ";base64,", b64, "\"/></div>")
            grid > 0 && (grid -= 1) == 0 && print(io, "</div>")
        elseif ch.mime == "application/vnd.kaimonslate.component+json"
            # A Slate component descriptor {v, component, props} (SlateExtensionsBase `slate_render`):
            # emit a mount placeholder carrying the raw descriptor in a sibling JSON script; the SPA looks
            # up the registered component and mounts it (props + a display ctx exposing call/stream, no
            # bind value). `<\/` keeps the JSON from closing the <script> early.
            desc = replace(String(copy(ch.data)), "</" => "<\\/")
            print(io, "<div class=\"disp slatecomp\"><span class=\"slatecomponent\"></span>",
                  "<script type=\"application/json\" class=\"slatecomponent-desc\">", desc, "</script></div>")
        elseif ch.mime == "application/vnd.kaimonslate.html+html"
            # A self-contained HTML fragment (the `slate_render` escape hatch) — trusted, injected as-is.
            print(io, "<div class=\"disp html\">", String(copy(ch.data)), "</div>")
        elseif ch.mime == "text/markdown"
            # Prose, rendered as a markdown cell's would be. A `[name](@ref)` link of a docstring becomes
            # the inert docs link that an HTML output gets (capture.jl `_fix_at_refs`).
            html = _md_html(String(copy(ch.data)))
            occursin("\"@ref", html) && (html = replace(html, ReportEngine._ATREF_RE => ReportEngine._atref_span))
            print(io, "<div class=\"disp md\">", html, "</div>")
        end
    end
    grid > 0 && print(io, "</div>")
    return String(take!(io))
end

# A flat, uniform view of a cell for the template (every field always present so
# field access never errors). Markdown → pre-rendered HTML; code → raw text the
# template autoescapes; rich output → trusted HTML via `display`.
function _cell_view(cell::Cell)
    if is_prose(cell.kind)
        return (kind = "md", state = "", source = "", stdout = "", value = "",
                error = "", display = "", html = _md_html(cell.source, cell.interp))
    end
    o = cell.output
    chunks = o === nothing ? MimeChunk[] : o.display
    return (kind    = "code",
            state   = lowercase(string(shown_state(cell))),
            source  = cell.source,
            stdout  = o === nothing ? "" : o.stdout,
            # suppress the text/plain value repr when richer output is present
            value   = (o === nothing || !isempty(chunks)) ? "" : o.value_repr,
            error   = (o === nothing || o.exception === nothing) ? "" : o.exception,
            display = _render_chunks(chunks),
            html    = "")
end

"""
    render_html(report) -> String

Render an (already-evaluated) `Report` to a self-contained HTML string.
"""
function render_html(report::Report)
    tmpl = Template(_TEMPLATE; config = Dict("autoescape" => true))
    cells = [_cell_view(c) for c in report.cells if renders(c.kind)]
    title = isempty(report.title) ? report.id : report.title
    return tmpl(init = Dict(:title => title, :cells => cells))
end

"""
    render_report_file(path; out=..., title="", reset=false) -> out_path

End-to-end convenience: read a hybrid `.jl`, parse → evaluate → render → write
HTML. Returns the output path.
"""
function render_report_file(path::AbstractString;
                            out::AbstractString = replace(path, r"\.jl$" => "") * ".html",
                            title::AbstractString = "",
                            reset::Bool = false)
    src = read(path, String)
    id = replace(splitext(basename(path))[1], r"[^A-Za-z0-9]" => "_")
    report = parse_report(src; id = id, title = title)
    eval_report!(report; reset = reset)
    write(out, render_html(report))
    return out
end

end # module ReportRender
