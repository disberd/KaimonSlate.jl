# ── Publication-quality PDF export (Typst) ───────────────────────────────────
# Assemble the notebook into a Typst document and compile it to PDF. Markdown cells
# render through the `cmarker` package with math routed to `mitex` (LaTeX math); a small
# `\newcommand` shim preamble covers common commands mitex doesn't know natively. Code is
# shown as syntax-highlighted listings; outputs (value/stdout/error/figures/tables) are
# typeset; `@bind` controls are omitted by default — a PDF is a snapshot — but can be shown
# as a frozen parameter strip via `include_params`. Figures use the bytes we already
# have (server CairoMakie PNG or the client ECharts snapshot); a later pass upgrades these
# to vector/high-res via a browser handoff.
#
# Pinned package versions (fetched from the Typst registry on first compile, then cached).
const _CMARKER_VER = "0.1.6"
const _MITEX_VER = "0.2.5"

# Cap on a single on-demand-rendered chart SVG we'll cache across exports (see
# `_figure_for_export`'s live round-trip) — small charts stay cached indefinitely (no TTL,
# same as the existing PNG snapshot store), a rare huge one just re-renders next export.
const _LIVE_SVG_CACHE_MAX_BYTES = 2 * 1024 * 1024

# Ask the open browser tab to render `cell`'s chart as vector SVG right now (see core.js
# `_renderChartSvg`). Only an export asks, not each chart update. `nothing` if no tab is open, the
# round-trip times out, or the cell has no live chart.
_live_render_svg(nb::LiveNotebook, cell::AbstractString; theme::AbstractString = "midnight") =
    _live_svg(nb, "window._renderChartSvg && window._renderChartSvg(" * JSON.json(String(cell)) * ", " *
                  JSON.json(String(theme)) * ")")

# The answer of a tab that loaded its page before Slate had `_renderInterpChartSvg`.
const _STALE_TAB = "<stale tab>"

# Ask the open tab for the chart `index` (from 0) of the `{{ }}` values of the markdown cell `cell`,
# as SVG at `width` × `height` px (core.js `_renderInterpChartSvg`), with the slide styling of the
# live deck when `present`. The SVG, `_STALE_TAB` when the tab runs an older page of Slate, or
# `nothing` as for `_live_render_svg`.
function _live_interp_chart_svg(nb::LiveNotebook, cell::AbstractString; theme::AbstractString, index::Integer,
                                width::Real, height::Real, present::Bool)
    args = join(JSON.json.((String(cell), String(theme), Int(index), Float64(width), Float64(height), present)), ", ")
    return _live_svg(nb, "typeof window._renderInterpChartSvg === 'function' ? window._renderInterpChartSvg(" *
                         args * ") : " * JSON.json(_STALE_TAB))
end

# Ask the open tab for the chart of the code cell `cell` as SVG for a slide, as the live deck draws it
# in a column `width` px wide with the figure cap `height` px (slides.js `_renderSlideChartSvg`). The
# SVG, `_STALE_TAB`, or `nothing` as for `_live_interp_chart_svg`.
function _live_slide_chart_svg(nb::LiveNotebook, cell::AbstractString; theme::AbstractString, width::Real, height::Real)
    args = join(JSON.json.((String(cell), String(theme), Float64(width), Float64(height))), ", ")
    return _live_svg(nb, "typeof window._renderSlideChartSvg === 'function' ? window._renderSlideChartSvg(" *
                         args * ") : " * JSON.json(_STALE_TAB))
end

# The non-empty string that the JS expression `code` gives in the open tab, or `nothing`.
function _live_svg(nb::LiveNotebook, code::AbstractString)
    res = request_live_eval(nb, code; timeout = 6.0)
    res isa AbstractDict || return nothing
    get(res, "ok", false) === true || return nothing
    raw = get(res, "result", nothing)
    raw isa AbstractString || return nothing
    s = try; JSON.parse(raw); catch; nothing; end
    return (s isa AbstractString && !isempty(s)) ? s : nothing
end

# ── Components in print ───────────────────────────────────────────────────────
# A `slate_render` component (SlateExtensionsBase) has no server-side bytes at all — it exists only
# as a mounted DOM subtree — so the browser is asked for a picture of each mount, the same handoff
# `_warm_chart_svgs!` uses for a client-rendered chart. Both surfaces a component reaches are
# covered: a cell that RETURNED one, and a markdown fence an extension claimed (```mermaid → that
# package's value). A component can render itself for print via the module's `exportFigure`
# (slate-widget.js); without one the mount's own SVG, or a DOM raster of it, is captured.
const _COMPONENT_MIME = "application/vnd.kaimonslate.component+json"
const _CompFigs = Dict{Tuple{String,Int},Tuple{Vector{UInt8},String}}
const _NO_COMPFIGS = _CompFigs()

_has_component(o) = o !== nothing && any(ch -> ch.mime == _COMPONENT_MIME, o.display)

# Which of a cell's component mounts to capture, as `(slot, interp index)`. `slot` indexes the
# cell's `.disp.slatecomp` elements in document order — what the browser side addresses — and the
# interp index is 0 for a code cell's own output. A markdown cell renders exactly one mount per
# component-valued interpolation, in order (`_render_chunks`), so the two enumerations agree by
# construction rather than by a shared counter.
function _component_slots(c::Cell)
    is_prose(c.kind) || return _has_component(c.output) ? [(0, 0)] : Tuple{Int,Int}[]
    return [(s - 1, i) for (s, i) in enumerate(findall(_has_component, c.interp))]
end

# Rasterise every HTML-output cell (a record grid, a custom card) in ONE round-trip, before the
# document is written, so `_emit_output!` finds each picture already in the snapshot store. Asking
# per cell as it emits costs a push and a 4 s wait EACH, so a notebook with a dozen of them spends a
# dozen timeouts in series and the slowest raster quietly comes out as text — the failure is per
# cell, silent, and different run to run. Returns how many pictures arrived. A cell whose figure
# hook gave a picture (in `figs`) needs no raster.
function _warm_html_rasters!(nb::LiveNotebook; theme::AbstractString = "", figs::_CompFigs = _NO_COMPFIGS)
    ids = lock(nb.lock) do
        [c.id for c in nb.report.cells if _has_html_output(c) && !_has_server_raster(nb, c.id) &&
                                          _output_chunk(c.output, "text/markdown") === nothing &&   # typeset instead
                                          !haskey(figs, (c.id, _hook_slot(0)))]
    end
    isempty(ids) && return 0
    return try; request_live_inspect_many(nb, ids; theme = theme); catch; 0; end
end

# A native figure's PDF, asked of the worker that ran the cell when the export starts, since a cell
# run no longer renders one (capture.jl `figure_vector`). Kept with the component figures under
# `_VECTOR_SLOT`, a slot no component uses. Only cells with nothing but a raster are asked; a cell
# whose figure the worker no longer holds keeps that raster.
const _VECTOR_SLOT = -1

_raster_only(c::Cell) = c.output !== nothing &&
    any(ch -> ch.mime == "image/png", c.output.display) &&
    !any(ch -> ch.mime in ("application/pdf", "image/svg+xml"), c.output.display)

function _warm_vector_figs!(nb::LiveNotebook, figs::_CompFigs; progress = nothing)
    targets = lock(nb.lock) do
        [(c.id, _cell_region(c)) for c in nb.report.cells if exports_figures(c.kind) && _raster_only(c)]
    end
    for (cid, region) in targets
        k = _running_kernel(nb, region)
        k === nothing && continue
        progress === nothing || (try; progress(cid); catch; end)
        bytes = try; ReportEngine.export_vector(k, cid); catch; nothing; end
        bytes === nothing || (figs[(cid, _VECTOR_SLOT)] = (bytes, "pdf"))
    end
    return figs
end

# The notebook's component figures, keyed `(cell id, slot)`, into `figs`. Called BEFORE the caller
# takes `nb.lock`, like the other warm passes — each round-trip blocks up to its timeout, and holding
# the notebook lock for that would stall everything else on the notebook for the whole export. Nothing
# is cached between exports: a component draws from live state, so a stale picture is worse than
# paying the round-trip again. Best-effort — a mount that fails or times out is simply absent, and
# the caller says so rather than dropping it silently. An output whose figure hook already gave a
# picture is not asked: the Julia hook wins. `geo` gives the size fields of the component's `ctx`
# (see `_figure_ctx`).
function _warm_component_figs!(nb::LiveNotebook, figs::_CompFigs, geo; theme::AbstractString = "midnight",
                               progress = nothing)
    targets = lock(nb.lock) do
        [(c.id, s, i) for c in nb.report.cells for (s, i) in _component_slots(c)]
    end
    for (cid, slot, i) in targets
        haskey(figs, (cid, _hook_slot(i))) && continue
        progress === nothing || (try; progress(cid); catch; end)
        ctx = _figure_ctx(geo, cid, i)
        got = try
            request_live_compfig(nb, cid, slot, theme; width = ctx.width, max_height = ctx.max_height, scale = ctx.scale,
                                 text_size = ctx.text_size, roles = ctx.roles)
        catch
            nothing
        end
        got === nothing || (figs[(cid, slot)] = got)
    end
    return figs
end

# The width a captured component figure prints at, as a percentage of the text column — `nothing`
# to take `figureimg`'s default. A component sizes itself in CSS pixels against the notebook's
# column, so scaling that against a nominal print column keeps the on-screen proportions: a small
# diagram stays small instead of being blown up to fill the page, a wide one is capped so it can't
# overflow. A raster has no intrinsic column to reason about, so it takes the default.
const _COMP_FIG_REF_PX = 640    # the notebook column width a component lays itself out against
function _comp_fig_width_pct(bytes::Vector{UInt8}, ext::AbstractString)
    ext == "svg" || return nothing
    m = match(r"viewBox\s*=\s*[\"']\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+[\d.]+", String(first(bytes, 4000)))
    m === nothing && return nothing
    w = tryparse(Float64, String(m.captures[1]))
    (w === nothing || w <= 0) && return nothing
    return clamp(round(Int, 100 * w / _COMP_FIG_REF_PX), 25, 100)
end

# ── Figures from the figure hook ──────────────────────────────────────────────────────────────────
# The type of a value can have a `slate_export_figure` method (SlateExtensionsBase): the value draws its
# own picture for the export, on the worker that ran its cell, with no tab. Its output carries a marker
# chunk (capture.jl `_FIGURE_HOOK_MIME`). Before the document is written, the export asks the hook for
# each marked output, with the size of the column of the figure, and keeps the picture with the
# component figures under `_hook_slot(i)`: `i` is 0 for the output of a code cell and the index of the
# value for a `{{ }}` or fence value of a markdown cell. The hook picture comes before every other path
# of the output.
const _TYPST_FIGURE_MIMES = ("application/pdf", "image/svg+xml", "image/png")   # the order Typst asks in
const _FIGURE_MIME_EXT = Dict("application/pdf" => "pdf", "image/svg+xml" => "svg", "image/png" => "png")
_hook_slot(i::Integer) = -2 - Int(i)
_hook_output(o) = o !== nothing && any(ch -> ch.mime == ReportEngine._FIGURE_HOOK_MIME, o.display)

# The size of a figure for an export: `width` maps `(cell id, slot)` to the width of the column of the
# figure in px, `body` is the width of a figure that is not in it, `max_height` the figure cap (`nothing`
# in a document), `palette` the Slate palette of the figures, `text_size` the body text size in px and
# `roles` the colour roles as hex.
_figure_ctx(geo, cid::AbstractString, slot::Integer) =
    SlateExtensionsBase.FigureContext(; width = get(geo.width, (String(cid), Int(slot)), geo.body),
                                      max_height = geo.max_height, scale = 2.0, slate_palette = geo.palette,
                                      dark = !_export_is_light(geo.palette), text_size = geo.text_size,
                                      roles = geo.roles)

# The colour roles of the settings `s` as hex, in the Slate palette `palette` (`deck_settings_dict`).
_figure_roles(s, palette::AbstractString) =
    Dict{String,String}(k => String(v) for (k, v) in deck_settings_dict(s; palette)["roles"])

# The outputs whose value has a figure hook, as `(cell, slot, region, held)`: slot 0 is the output of a
# code cell, slot `i` the `i`-th `{{ }}` or fence value of a markdown cell. `held` is false for the
# output of a code cell that the memo restored: that run did not happen, so a value that its worker
# keeps is of an earlier run, maybe with other inputs.
_hook_targets(nb::LiveNotebook) = lock(nb.lock) do
    out = Tuple{String,Int,String,Bool}[]
    for c in nb.report.cells
        renders(c.kind) || continue
        if is_prose(c.kind)
            for (i, o) in enumerate(c.interp)
                _hook_output(o) && push!(out, (c.id, i, _cell_region(c), true))
            end
        elseif _hook_output(c.output)
            push!(out, (c.id, 0, _cell_region(c), c.output.memo != "restored"))
        end
    end
    out
end

_hook_throw_warning(cid, r) =
    "Cell $cid: the figure hook of $(r.type) threw an error, so the output prints as it shows: $(r.error)"

# Ask the figure hook for the picture of each marked output and keep it in `figs`. A hook that throws
# adds a line to `warnings`. The cells whose worker keeps no value for an output add one line together,
# with their ids. Their output comes from storage: the hub restored it from the memo, or the notebook
# opened from its stored outputs and did not run, or its worker is not running. A run of the notebook
# restores such a cell from the memo again; only a forced run of the cell (its ▶) computes the value.
# Called before the caller takes `nb.lock`, like the other warm passes.
function _warm_hook_figs!(nb::LiveNotebook, figs::_CompFigs, warnings::Vector{String}, geo; progress = nothing)
    stored = String[]
    for (cid, slot, region, held) in _hook_targets(nb)
        k = held ? _running_kernel(nb, region) : nothing
        k === nothing && (push!(stored, cid); continue)
        progress === nothing || (try; progress(cid); catch; end)
        r = try; ReportEngine.export_figure(k, cid, slot, _TYPST_FIGURE_MIMES, _figure_ctx(geo, cid, slot)); catch; nothing; end
        r === nothing && continue
        if !r.held
            push!(stored, cid)
        elseif !isempty(r.mime)
            figs[(cid, _hook_slot(slot))] = (r.bytes, _FIGURE_MIME_EXT[r.mime])
        elseif !isempty(r.error)
            push!(warnings, _hook_throw_warning(cid, r))
        end
    end
    isempty(stored) || push!(warnings, _stored_figs_warning(unique!(stored)))
    return figs
end

# The pictures of the figure hooks in the MIME types of an exporter (`plan.mimes`), into `plan.forms`:
# the hook gets one MIME type at a time, so each output can give a form in each type. The picture of
# the Typst pass (`figs`, from `_warm_hook_figs!`) is the form of its type, with no second round trip,
# and a video or audio type is not asked: a figure hook draws pictures only. A throw stops the search
# for that output and adds the warning of the Typst export.
function _hook_forms!(plan, nb::LiveNotebook, warnings::Vector{String}, geo, figs::_CompFigs)
    for (cid, slot, region, held) in _hook_targets(nb)
        k = held ? _running_kernel(nb, region) : nothing
        k === nothing && continue
        typst = get(figs, (cid, _hook_slot(slot)), nothing)   # (bytes, file extension)
        forms = Tuple{String,Vector{UInt8}}[]
        for m in plan.mimes
            (startswith(m, "video/") || startswith(m, "audio/")) && continue
            typst !== nothing && get(_FIGURE_MIME_EXT, m, "") == typst[2] && (push!(forms, (m, typst[1])); continue)
            r = try; ReportEngine.export_figure(k, cid, slot, [m], _figure_ctx(geo, cid, slot)); catch; nothing; end
            (r === nothing || !r.held) && break
            isempty(r.error) || (push!(warnings, _hook_throw_warning(cid, r)); break)
            isempty(r.mime) || push!(forms, (r.mime, r.bytes))
        end
        isempty(forms) || (plan.forms[(cid, slot)] = forms)
    end
    return plan
end

# The warning for the cells whose figure output comes from storage. The advice comes first and the cell
# ids last, so that the header of the export dialog (300 characters a line) cuts ids, not the advice.
function _stored_figs_warning(cells::Vector{String})
    one = length(cells) == 1
    return string("The output of ", one ? "a cell" : "$(length(cells)) cells", " comes from storage (the memo or ",
                  "the saved notebook), so the figure hook has no value to draw and the PDF has the output as it ",
                  "shows. Run ", one ? "the cell" : "each cell", " with its ▶ button, then export again: a run of ",
                  "the notebook restores it from the memo. ", one ? "Cell: " : "Cells: ", join(cells, ", "), ".")
end

# The width of each `{{ }}` value of the markdown `src` (numbered from `ib + 1`) in a column `w` px wide,
# into `out`. A group shares the width among its containers (`_group_widths`). `gaps` holds the deck
# settings `columns` (the gap of a `:::: columns` group), `grid` (the gap of a grid) and `pad` (the pad
# of a grid cell with a fill), in px. Returns the number of the last value.
function _interp_widths!(out, cid::AbstractString, src::AbstractString, ib::Integer, w::Real, gaps)
    for p in _split_groups(src)
        if p isa AbstractString
            n = _md_interp_count(p)
            for g in ib+1:ib+n
                out[(String(cid), g)] = Float64(w)
            end
            ib += n
        else
            ws = _group_widths(p, w, gaps)
            for (j, col) in enumerate(p.cols)
                ib = _interp_widths!(out, cid, col, ib, ws[j], gaps)
            end
        end
    end
    return ib
end

# The width of each container of the group `p` in a column `w` wide, as `slidecols` and `slidegrid`
# draw them. A grid cell `j` is in track `(j - 1) mod n + 1`. The `fr` tracks share what the `u` tracks
# and the gaps leave, and a grid cell with a fill loses its pad on each side.
function _group_widths(p, w::Real, gaps)
    p.kind === :columns && return _column_widths(p.widths, w, gaps.columns)
    tracks = p.grid.tracks
    n = length(tracks)
    gap = something(p.grid.gap, gaps.grid)
    fixed = sum((v for (k, v) in tracks if k === :u); init = 0.0)
    frs = sum((v for (k, v) in tracks if k === :fr); init = 0.0)
    free = max(w - fixed - (n - 1) * gap, 0.0)
    tw = [k === :u ? v : free * v / frs for (k, v) in tracks]
    return [max(tw[mod1(j, n)] - (c.fill === nothing ? 0.0 : 2 * gaps.pad), 0.0) for (j, c) in enumerate(p.cells)]
end

# The widths of the columns of a `:::: columns` group `w` wide, with `gap` between them, as `slidecols`
# draws them. A percentage is of `w`, and percentages that fill the row or more shrink in proportion. A
# column with no width shares the rest equally; so does a width in another unit.
function _column_widths(widths, w::Real, gap::Real)
    avail = w - (length(widths) - 1) * gap
    pct = [endswith(x, "%") ? parse(Float64, chop(x)) : nothing for x in widths]
    all(!isnothing, pct) && sum(pct) >= 100 && return [avail * p / sum(pct) for p in pct]
    rest = max(avail - sum((w * p / 100 for p in pct if p !== nothing); init = 0.0), 0.0) / max(count(isnothing, pct), 1)
    return [p === nothing ? rest : w * p / 100 for p in pct]
end

# The figure geometry of a slide deck (see `_figure_ctx`), in px = u. The body is `body_width` of the deck
# template, else the slide width less the base margins (240 u). A row of `n` cells shares it with
# `columns.row-gap` between the cells. A markdown cell has the 16 u padding of `mdcell` on each side.
# The figure cap is `fit.figure-cap` of the slide height.
function _slide_figure_geometry(nb::LiveNotebook, ds, ratio::AbstractString, level::Integer, palette::AbstractString;
                                page_palette::AbstractString = palette)
    W, H = deck_canvas(ratio)
    t = notebook_deck_template(nb)
    body = something(t === nothing ? nothing : t.body_width, W - 240.0)
    gaps = (columns = ds.values["columns"]["gap"].value, grid = ds.values["grid"]["gap"].value, pad = ds.values["grid"]["pad"].value)
    rowgap = ds.values["columns"]["row-gap"].value
    width = Dict{Tuple{String,Int},Float64}()
    lock(nb.lock) do
        fm = report_frontmatter(nb.report)
        bycell = Dict(c.id => c for c in nb.report.cells)
        for sl in slide_deck(nb; level, drop = c -> c.id in fm.skip || :bibliography in c.flags),
            row in unique(b.row for b in sl.frags)
            fs = filter(b -> b.row == row, sl.frags)
            cw = (body - (length(fs) - 1) * rowgap) / length(fs)
            for f in fs
                c = bycell[f.cell]
                is_prose(c.kind) ? _interp_widths!(width, c.id, something(f.src, c.source), f.interpbase, cw - 32, gaps) :
                                   (width[(c.id, 0)] = cw)
            end
        end
    end
    return (; width, body, max_height = ds.values["fit"]["figure-cap"] * H, palette = String(palette),
            text_size = Float64(ds.values["text"]["size"].value), roles = _figure_roles(ds.values, page_palette))
end

# The figure geometry of a document (see `_figure_ctx`), in px at 96 dpi: the text width of the A4 page,
# or one of its two columns (Typst `columns` puts 4 % between them). A row of cells shares the column
# with the 1.2 em gutter of its grid. No figure cap.
function _doc_figure_geometry(nb::LiveNotebook; style::AbstractString, cols::Integer, body::AbstractString,
                              palette::AbstractString)
    st = get(_STYLES, style, _STYLES["article"])
    px(mm) = mm / 25.4 * 96
    textw = px(210 - 20 * parse(Float64, match(r"x: ([\d.]+)cm", st.margin)[1]))
    colw = cols == 2 ? 0.48 * textw : textw
    gutter = 1.2 * parse(Float64, chop(_body_size(body); tail = 2)) * 96 / 72
    width = Dict{Tuple{String,Int},Float64}()
    lock(nb.lock) do
        fm = report_frontmatter(nb.report)
        cells = filter(c -> renders(c.kind), nb.report.cells)
        rowopen, _, rowmembers = _column_row_brackets(cells,
            c -> !(:collapsed in c.flags) && !(c.id in fm.skip) && !(:bibliography in c.flags))
        n = 1
        for c in cells
            haskey(rowopen, c.id) && (n = rowopen[c.id])
            w = c.id in rowmembers ? (colw - (n - 1) * gutter) / n : colw
            for slot in (is_prose(c.kind) ? (1:length(c.interp)) : (0:0))
                width[(c.id, slot)] = w
            end
        end
    end
    return (; width, body = colw, max_height = nothing, palette = String(palette),
            text_size = parse(Float64, chop(_body_size(body); tail = 2)) * 96 / 72,
            roles = _figure_roles(deck_settings("", "").values, palette))
end

# LaTeX macro shims for commands mitex lacks. mitex honors parameterized \newcommand, so
# these inject cheaply ahead of every equation. Grow as needed.
const _MITEX_SHIMS = raw"""
\newcommand{\argmax}{\operatorname*{arg\,max}}
\newcommand{\argmin}{\operatorname*{arg\,min}}
\newcommand{\mathscr}[1]{\mathcal{#1}}
\newcommand{\dv}[2]{\frac{d#1}{d#2}}
\newcommand{\pdv}[2]{\frac{\partial #1}{\partial #2}}
\newcommand{\abs}[1]{\left|#1\right|}
\newcommand{\norm}[1]{\left\|#1\right\|}
"""

# Escape a Julia string for a Typst double-quoted string literal (\ and " only; Typst
# strings interpret \\, \", \n, … so backslashes MUST be doubled).
# Escape for a Typst "…" string literal. Must also escape newlines/tabs — a literal can't span a
# raw newline, so a multiline table cell / bind value (a wrapped string, a vector repr) would
# otherwise produce invalid `.typ` and fail the WHOLE PDF export.
_typ_str(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")

# Built-in style presets. `article` is the default single-column research-note look;
# `report` is roomier with a larger title. `columns` (1 or 2) lays the body out in one
# or two columns — figures/code span the full width so they never overflow a column.
const _STYLES = Dict(
    # `article` — compact, unnumbered research-note look. `report` — roomier and with NUMBERED
    # sections + a larger title block, the academic-report distinction (not just a font bump).
    "article" => (textsize = "10.5pt", margin = "(x: 2.2cm, y: 2.4cm)", titlesize = "19pt",
                  headabove = "2.1em", headbelow = "1.2em",  parspace = "1.35em", number = false),
    "report"  => (textsize = "11pt",   margin = "(x: 2.7cm, y: 3.0cm)", titlesize = "26pt",
                  headabove = "2.7em", headbelow = "1.45em", parspace = "1.6em",  number = true),
)

# Colour palettes per theme. `light` is the publication default; `dark` matches the live
# notebook UI (dark page, light text) — a natural fit for figures drawn with the Makie
# dark theme. Each field is a Typst colour expression (string).
const _PALETTES = Dict(
    "light" => (page = "white",          text = "black",            rule = "luma(180)",
                title = "black",         codebg = "luma(248)",      codetheme = "",
                outbg = "luma(250)",     outfg = "rgb(\"#444444\")",
                valbg = "rgb(\"#f0f7f1\")", valfg = "rgb(\"#177245\")",
                errbg = "rgb(\"#fdeeee\")", errfg = "rgb(\"#b00020\")",
                parbg = "rgb(\"#eef2fb\")", parborder = "rgb(\"#c3d0ec\")", parlabel = "rgb(\"#3a4a72\")",
                tablestroke = "luma(200)", tableheadbg = "luma(244)", tablestripe = "luma(250)"),
    "dark"  => (page = "rgb(\"#12141c\")", text = "rgb(\"#d6dae8\")",  rule = "luma(90)",
                title = "white",         codebg = "rgb(\"#1b1f2b\")", codetheme = "code-dark.tmTheme",
                outbg = "rgb(\"#181c26\")", outfg = "rgb(\"#aeb6cc\")",
                valbg = "rgb(\"#142318\")", valfg = "rgb(\"#5fcf6e\")",
                errbg = "rgb(\"#2a1619\")", errfg = "rgb(\"#f08a8a\")",
                parbg = "rgb(\"#1a2233\")", parborder = "rgb(\"#2c3a57\")", parlabel = "rgb(\"#8ab4f8\")",
                tablestroke = "luma(90)",  tableheadbg = "rgb(\"#1b1f2b\")", tablestripe = "rgb(\"#171b25\")"),
)
# The colours of the slides layout, as Typst expressions that read the deck settings (`settings`,
# deck_settings.jl): the slides preamble and the tables of a slide (`_typst_table`) take no
# `_PALETTES` entry. `deckpaint` (slides preamble) turns a `none` paint into a transparent colour.
const _DECK_PALETTE = (page = "settings.roles.surface", text = "settings.roles.fg",
    rule = "deckpaint(settings.table.rule-color)", title = "settings.roles.strong", codebg = "settings.code.fill",
    codetheme = "", outbg = "settings.code.fill", outfg = "settings.roles.dim",
    valbg = "settings.code.fill", valfg = "settings.roles.accent", errbg = "settings.code.fill",
    errfg = "settings.roles.ink", parbg = "settings.code.fill", parborder = "deckpaint(settings.table.rule-color)",
    parlabel = "settings.roles.dim", tablestroke = "deckpaint(settings.table.rule-color)",
    tableheadbg = "settings.table.header-fill", tablestripe = "settings.table.stripe-fill")
_palette(theme) = theme == "deck" ? _DECK_PALETTE : get(_PALETTES, theme, _PALETTES["light"])

# A compact Tokyo-Night-style dark syntax theme for Typst `raw` (written to the export
# dir when `theme=dark`; its background matches `codebg` so the block reads uniformly).
const _CODE_DARK_TMTHEME = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>name</key><string>SlateDark</string>
<key>settings</key><array>
<dict><key>settings</key><dict><key>background</key><string>#1b1f2b</string><key>foreground</key><string>#d6dae8</string></dict></dict>
<dict><key>scope</key><string>comment</string><key>settings</key><dict><key>foreground</key><string>#6a7080</string></dict></dict>
<dict><key>scope</key><string>string</string><key>settings</key><dict><key>foreground</key><string>#9ece6a</string></dict></dict>
<dict><key>scope</key><string>constant.numeric, constant.language</string><key>settings</key><dict><key>foreground</key><string>#ff9e64</string></dict></dict>
<dict><key>scope</key><string>keyword, storage, keyword.operator</string><key>settings</key><dict><key>foreground</key><string>#bb9af7</string></dict></dict>
<dict><key>scope</key><string>entity.name.function, support.function</string><key>settings</key><dict><key>foreground</key><string>#7aa2f7</string></dict></dict>
<dict><key>scope</key><string>entity.name.type, support.type</string><key>settings</key><dict><key>foreground</key><string>#2ac3de</string></dict></dict>
</array></dict></plist>
"""

# Code-listing font sizes (the `code` option, minus "hidden" which suppresses source).
const _CODE_SIZES = Dict("normal" => "9.5pt", "small" => "8.5pt", "smaller" => "7.5pt", "tiny" => "6.5pt")
_code_size(code) = get(_CODE_SIZES, code, _CODE_SIZES["normal"])

# Body (prose) font sizes (the `body` option). Two-column layouts usually want a smaller
# body, so the export defaults `body` to "compact" when columns == 2.
const _BODY_SIZES = Dict("large" => "11.5pt", "normal" => "10.5pt", "compact" => "9.5pt", "small" => "8.5pt")
_body_size(body) = get(_BODY_SIZES, body, _BODY_SIZES["normal"])

# True if the document's section headings (the level-2+ ones Typst would auto-number) are MOSTLY
# numbered by hand already — "3.1 · …", "1.2)", "Section 3" — so we should leave Typst's numbering off
# and let the author's numbers stand (avoids the doubled "1 3.1 · …").
function _manual_heading_numbers(cells)
    head = r"^\s*#{2,6}\s+(.*\S)\s*$"
    num  = r"^(\d+([.)]\s*\d+)*[.):·\-]|\d+\s|(section|part|chapter|appendix)\b)"i
    total = 0; numbered = 0
    for c in cells
        is_prose(c.kind) || continue
        infence = false
        for ln in split(String(c.source), '\n')
            occursin(r"^\s*(```|~~~)", ln) && (infence = !infence; continue)
            infence && continue
            m = match(head, ln); m === nothing && continue
            total += 1
            occursin(num, m.captures[1]) && (numbered += 1)
        end
    end
    return total > 0 && numbered * 2 >= total      # majority manually numbered
end

function _typst_preamble(title::AbstractString; style::AbstractString = "article",
                         columns::Int = 1, theme::AbstractString = "light",
                         code::AbstractString = "normal", body::AbstractString = "normal",
                         number::Union{Bool,Nothing} = nothing)
    pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
    st = get(_STYLES, style, _STYLES["article"])
    donumber = number === nothing ? st.number : number   # caller can force off (e.g. headings are manually numbered)
    p = _palette(theme)
    csize = _code_size(code)
    bsize = _body_size(body)
    # Two-column flows via a `#columns()` wrapper on the body (see export_pdf), NOT a
    # page setting — that keeps the title block and abstract spanning the full width.
    pageopts = "paper: \"a4\", margin: $(st.margin), numbering: \"1\", fill: $(p.page)"
    rawtheme = isempty(p.codetheme) ? "" : "\n    #set raw(theme: \"$(p.codetheme)\")"
    return """
    #import "@preview/cmarker:$(_CMARKER_VER)"
    #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
    #set document(title: "$(_typ_str(title))")
    #set page($pageopts)
    #set text(font: "New Computer Modern", size: $(bsize), fill: $(p.text))$(rawtheme)
    #set par(justify: true, spacing: $(st.parspace))
    #show heading: set block(above: $(st.headabove), below: $(st.headbelow))
    #show heading: set text(fill: $(p.title))
    $(donumber ? "#set heading(numbering: (..n) => { let m = n.pos(); if m.len() <= 1 { none } else { numbering(\"1.1\", ..m.slice(1)) } })" : "")
    #let PRE = "$pre "
    #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
    // Room between the rows of matrices and of multi-line display math: fractions and roots are
    // tall, and LaTeX's own spacing tricks for them (struts, row gaps) don't survive mitex.
    #show math.mat: set math.mat(row-gap: 0.6em)
    #show math.equation.where(block: true): set par(leading: 1.1em)
    // A display formula wider than its column is scaled down to fit (on screen it scrolls; on a
    // page it would run into the margin). In a table cell, math sits at the start of the cell.
    #show math.equation.where(block: true): it => layout(size => {
      let w = measure(it).width
      if w > size.width { scale(size.width / w * 100%, reflow: true, it) } else { it }
    })
    #show table.cell: it => { show math.equation.where(block: true): set align(left); it }
    // Markdown tables take the theme's thin rule colour rather than cmarker's heavy black lines.
    #set table(stroke: 0.5pt + $(p.rule), inset: (x: 7pt, y: 5pt))
    // Author-embedded markdown images stage into the doc root; resolve them relative to THIS file
    // (not cmarker's package dir, where its built-in image() looks) — passed to cmarker as scope.image.
    // `media.json` carries any `{width=…}` block the author wrote (see `_stage_typst_md_media`), as
    // (magnitude, unit) — markdown has no place to hang a size, so it travels beside the document.
    #let MEDIASZ = json("media.json")
    #let mdlen(e) = if e == none { auto } else if e.at(1) == "%" { e.at(0) * 1% } else if e.at(1) == "em" { e.at(0) * 1em } else { e.at(0) * 1pt }
    #let mdalign(s) = if s == "left" { left } else if s == "right" { right } else { center }
    // An image alone in its paragraph is a figure — centred, matching the notebook and the HTML export.
    // One sitting in a run of prose stays inline, where the author put it.
    #let mdimage(src, alt: none) = {
      let a = MEDIASZ.at(src, default: (:))
      let im = image(src, alt: alt, width: mdlen(a.at("width", default: none)), height: mdlen(a.at("height", default: none)))
      if a.at("block", default: false) { align(mdalign(a.at("align", default: "center")), im) } else { im }
    }
    #let mdscope = (image: mdimage)
    // The elements of the block kinds of markdown (`ReportRender._md_blocks`), as `html:` handlers of
    // `cmarker.render`. A document draws an admonition as a box with its heading. Each other kind
    // prints as its markdown does.
    #let admonition(attrs, body) = block(width: 100%, inset: (x: 9pt, y: 7pt), radius: 3pt, fill: $(p.parbg), stroke: (left: 2pt + $(p.parlabel)), {
      let h = attrs.at("heading", default: "")
      if h != "" { text(weight: "bold", fill: $(p.parlabel), h); parbreak() }
      body
    })
    #let mdhtml = (slate-admonition: admonition, slate-key-message: (attrs, body) => body, slate-caption: (attrs, body) => body,
      slate-figure: (attrs, body) => body, slate-table: (attrs, body) => body)
    $(_CITE_SHOW)
    #let titleblock(t) = { align(center, text(size: $(st.titlesize), weight: "bold", fill: $(p.title), t)); v(2pt); line(length: 100%, stroke: 0.5pt + $(p.rule)); v(10pt) }
    #let metablock(title, subtitle, byline, abstract) = {
      align(center)[
        #text(size: $(st.titlesize), weight: "bold", fill: $(p.title))[#title]
        #if subtitle != none { v(4pt); text(size: 1.25em, fill: $(p.title))[#subtitle] }
        #if byline != none { v(6pt); text(size: 0.86em, fill: $(p.parlabel))[#byline] }
      ]
      v(6pt); line(length: 100%, stroke: 0.5pt + $(p.rule)); v(10pt)
      if abstract != none {
        block(width: 100%, inset: 0pt)[
          #text(size: 0.82em, weight: "bold", tracking: 0.08em, fill: $(p.parlabel))[ABSTRACT]
          #v(3pt)
          #text(size: 0.94em, style: "italic")[#abstract]
        ]
        v(12pt)
      }
    }
    #let codeblock(s) = block(width: 100%, fill: $(p.codebg), inset: 8pt, radius: 4pt, text(size: $(csize), raw(block: true, lang: "julia", s)))
    #let outblock(s) = block(width: 100%, inset: 7pt, fill: $(p.outbg), radius: 3pt, text(size: 8.5pt, fill: $(p.outfg), raw(s)))
    #let valblock(s) = block(width: 100%, inset: 7pt, fill: $(p.valbg), radius: 3pt, text(size: 8.5pt, fill: $(p.valfg), raw(s)))
    #let errblock(s) = block(width: 100%, inset: 7pt, fill: $(p.errbg), radius: 3pt, text(size: 8.5pt, fill: $(p.errfg), raw(s)))
    #let figureimg(p, width: 85%) = align(center, image(p, width: width))
    #let notefig(s) = block(width: 100%, inset: 7pt, text(size: 8.5pt, style: "italic", fill: $(p.parlabel), s))
    #let figcaption(lbl, body) = block(width: 100%, inset: (x: 24pt, y: 4pt), text(size: 8.6pt, fill: $(p.parlabel))[#text(weight: "bold")[#lbl.] #body])
    #let paramblock(items) = block(width: 100%, inset: (x: 8pt, y: 5pt), fill: $(p.parbg), radius: 3pt, stroke: 0.5pt + $(p.parborder),
      text(size: 8.5pt)[#text(fill: $(p.parlabel), weight: "bold")[parameters] #h(6pt) #items.map(it => [#raw(it.at(0)) = #text(weight: "bold", it.at(1))]).join([#h(10pt)])])

    """
end

# ── Slide-deck preamble (16:9 / 16:10 / 4:3 landscape, one slide per page) ────────────────────────
# Slide page geometry (width, height) for a 254mm-wide canvas. 16:9 is the default deck size.
_slide_geom(ratio) = ratio == "4:3" ? ("254mm", "190.5mm") :
                     ratio == "16:10" ? ("254mm", "158.75mm") : ("254mm", "142.875mm")

# The size of a code listing on a slide: the deck setting `code.size`, times the factor of the `code`
# option (its point size over the 8.5 pt of "small"; "normal" is "small").
_slide_code_size(code) =
    string(round(parse(Float64, chop(_code_size(code == "normal" ? "small" : code); tail = 2)) / 8.5; digits = 4),
           " * settings.code.size")

# The fit parameters of a slide. The text floor and the figure cap are deck settings; `slides.js`
# holds the same figure floor and math floor in `FIT`.
const _FIT_TYPST = "(text-floor: settings.fit.text-floor, fig-floor: 0.25, fig-cap: settings.fit.figure-cap, math-floor: 0.4)"

# Preamble for the slides layout. Reuses the same block helpers as the article preamble but on a
# landscape slide page with bigger type. It imports `deck-settings.typ` (`deck_settings_typ`):
# `SLIDE_W` and `SLIDE_H` (the page size), `u` (the slide unit: 1/1920 of the page width at 16:9 and
# 16:10, 1/1440 at 4:3, as the live canvas) and `settings` (the deck settings). It defines `FIT` (the fit
# parameters), `mdscope` (the scope of each `cmarker.render`), `mdcell` (a markdown cell),
# `#let base-rhythm(body)` and `#let fit(body)` (see their comments),
# `#let slidecols(widths, ..cols)` (a row of columns, see its comment) and
# `#let slide(body, layout: none, title: none, n: none)`: one page per slide, the body inside `fit`.
# `layout` is the slide's layout tag and `title` its heading (a `heading` element), both `none` when
# unset; `n` is the slide number on a notes page. A template that is added after this preamble can
# redefine `slide` or `slidecols` to draw each layout its own way. It must draw the body through `fit`,
# because `fit` sizes the figures and records the fit. `base-slide` and `base-fit` are the base `slide`
# and `fit`, so that a template that redefines them can still call them.
# The page copies the geometry of the live base deck (notebook.css `.deck-slide`, `.slide-title`,
# `.slide-num`): the body padding, the body at the top of the slide, the slide number, the title. The
# base `slide` draws the body in `base-rhythm`, the vertical rhythm of the live deck from the deck
# settings, with the line boxes of CSS.
# Lengths in the body follow the live deck: text sizes and spacing in `em` (they follow the text
# scale of `fit`), geometry in `u` (fixed).
# `syntax` is the colour scheme of code, "light" or "dark" (the deck setting `code.syntax`, resolved):
# "dark" needs `code-dark.tmTheme` in the project.
function _typst_preamble_slides(title::AbstractString; syntax::AbstractString = "light", code::AbstractString = "small")
    pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
    p = _DECK_PALETTE
    rawtheme = syntax == "dark" ? "\n    #set raw(theme: \"code-dark.tmTheme\")" : ""
    return """
    #import "@preview/cmarker:$(_CMARKER_VER)"
    #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
    #import "deck-settings.typ": SLIDE_W, SLIDE_H, u, settings
    #let deckpaint(c) = if c == none { rgb(0, 0, 0, 0) } else { c }
    #let FIT = $_FIT_TYPST
    #set document(title: "$(_typ_str(title))")
    #set page(width: SLIDE_W, height: SLIDE_H, margin: (top: 84 * u, x: 120 * u, bottom: 72 * u), fill: $(p.page))
    #set text(font: settings.text.font, size: settings.text.size, fill: $(p.text))$(rawtheme)
    #show raw: set text(font: settings.code.font)
    #set par(justify: false)
    #show heading: set text(fill: $(p.title))
    #set heading(numbering: none)
    #let PRE = "$pre "
    #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
    // Room between the rows of matrices and of multi-line display math: fractions and roots are
    // tall, and LaTeX's own spacing tricks for them (struts, row gaps) don't survive mitex.
    #show math.mat: set math.mat(row-gap: 0.6em)
    #show math.equation.where(block: true): set par(leading: 1.1em)
    // A display formula wider than its column is set smaller until it fits, down to `FIT.math-floor`
    // (on screen it would run off the slide). In a table cell, math sits at the start of the cell.
    #show math.equation.where(block: true): it => layout(size => {
      let w = measure(it).width
      if w > size.width { scale(calc.max(FIT.math-floor, size.width / w) * 100%, reflow: true, it) } else { it }
    })
    #show table.cell: it => { show math.equation.where(block: true): set align(left); it }
    // Headings have the line height of the live headings (`HEAD-LH`). Code in markdown is at
    // `CODE-INLINE` of its text, as the live `code`.
    #let HEAD-LH = 1.1
    #let CODE-INLINE = 0.85
    // A row of a table has `table.line-height` in the line boxes of the body text: the leading takes
    // the difference, and the inset half of it on each side. A rule of `TRULE` under each row adds its
    // width to the row, as a CSS border does.
    #let TL = settings.table.line-height
    #let TRULE = settings.table.rule-width
    #let tinset(pad) = pad - (settings.text.line-height - TL) / 2 * 1em
    // The plain text of a table cell, for its widest word.
    #let plaintext(c) = if type(c) == str { c } else if c.has("text") and type(c.text) == str { c.text } else if c.has("children") { c.children.map(plaintext).sum(default: "") } else if c.has("body") { plaintext(c.body) } else if c.has("child") { plaintext(c.child) } else { " " }
    // A markdown table at `table.text-size`, with the column widths that CSS auto table layout gives
    // it in its column: each column gets at least its widest word (min) and at most its widest line
    // (max), and the room between the sums of min and max goes to the columns in proportion to
    // max - min. A word ends at a space and after a hyphen, where a browser breaks a line too. When
    // `table.full-width` is on, a table narrower than its column takes the full width, in proportion
    // to max, as the live `width: 100%`. The rebuilt table has `fr` columns, which tell this rule that
    // the table is done.
    #let base-table(it) = if type(it.columns) == array and it.columns.len() > 0 and it.columns.all(c => type(c) == fraction) { it } else {
      set text(size: settings.table.text-size)
      block(above: settings.text.paragraph-after, below: settings.rhythm.after-table, layout(sz => {
        if type(it.columns) != array or it.columns.any(c => c != auto) { return it }
        let n = it.columns.len()
        let cells = it.children.map(c => if c.func() == table.header { c.children } else { (c,) }).flatten()
        let pad = 2 * settings.table.pad-x.to-absolute()
        let col(i) = cells.enumerate().filter(((j, _)) => calc.rem(j, n) == i).map(((j, c)) => if j < n { strong(c.body) } else { c.body })
        let mx = range(n).map(i => calc.max(..col(i).map(b => measure(b).width)) + pad)
        let mn = range(n).map(i => calc.max(..col(i).map(b => calc.max(0 * u, ..plaintext(b).replace("-", "- ").split(" ").map(w => measure(w).width)))) + pad)
        let w = if mx.sum() <= sz.width {
          if not settings.table.full-width { return it }
          mx.map(x => x / mx.sum() * sz.width)
        } else if mn.sum() >= sz.width { mn } else {
          let d = range(n).map(i => mx.at(i) - mn.at(i))
          range(n).map(i => mn.at(i) + (sz.width - mn.sum()) * (d.at(i) / d.sum()))
        }
        let f = it.fields()
        let children = f.remove("children")
        table(..f, columns: w.map(x => x / u * 1fr), ..children)
      }))
    }
    // The paint of each block kind that has an element (`ReportRender._md_blocks`). `base-draw` holds
    // one function for each kind. A function gets `it`, a dictionary with the `body` of the block and
    // its attributes (`category` and `heading` of an admonition, `number` of a figure caption), and it
    // reads the deck settings. A deck template gives its own function for a kind by its key:
    // `#let draw = (caption: it => …)`. `draw-kind` says which function draws a block.
    // A function paints and does not size. `fit` sizes a figure before `figure` gets it. The base
    // sizes a table whatever paint `table` puts around it.
    // `barbox` is a band with a bar on its left, as a CSS box with a left border: the bar has its
    // width beside the padding. It has the gap between cells below it.
    #let barbox(bar, w, fill, inset, radius, body) = block(width: 100%, radius: radius, clip: true,
      above: settings.text.paragraph-after, below: settings.rhythm.cell-gap,
      grid(columns: (w, 1fr), fill: (x, _) => if x == 0 { bar } else { fill }, [], block(width: 100%, inset: inset, body)))
    #let base-draw = (
      key-message: it => barbox(settings.key-message.bar-color, settings.key-message.bar-width, settings.key-message.fill,
        (x: settings.key-message.pad-x, y: settings.key-message.pad-y), 0 * u, text(fill: settings.key-message.text-color, it.body)),
      caption: it => {
        set text(size: settings.caption.size, fill: settings.caption.color)
        if "number" in it [#text(fill: settings.roles.fg, weight: "bold")[Figure #it.number.] ]
        it.body
      },
      // `[admonition.<category>]` of the deck settings replaces the values of `[admonition]`.
      admonition: it => {
        let c = settings.admonition.at(it.at("category", default: ""), default: none)
        let v = (accent: settings.admonition.accent, fill: settings.admonition.fill, title-color: settings.admonition.title-color,
          bar-width: settings.admonition.bar-width, pad-x: settings.admonition.pad-x, pad-y: settings.admonition.pad-y,
          radius: settings.admonition.radius) + if type(c) == dictionary { c } else { (:) }
        let h = it.at("heading", default: "")
        barbox(v.accent, v.bar-width, v.fill, (x: v.pad-x, y: v.pad-y), v.radius, {
          if h != "" { text(fill: v.title-color, weight: "bold", h); parbreak() }
          it.body
        })
      },
      figure: it => box(radius: settings.figures.radius, clip: true, it.body),
      table: it => {
        set table(stroke: (x, y) => (bottom: TRULE + $(p.rule)),
          fill: (x, y) => if y == 0 { settings.table.header-fill } else if calc.even(y) { settings.table.stripe-fill })
        show table.cell.where(y: 0): set text(fill: settings.table.header-color, weight: "bold")
        it.body
      },
    )
    #let draw = (:)
    // `base-rhythm(body)` draws `body` with the vertical rhythm of the live base deck, from the deck
    // settings. The base `slide` puts it around `fit`; a template that draws its own pages can put it
    // around its `fit` too, or keep its own rules. Inside it, `mdcell` and `cellgap` (`RHYTHM`) draw
    // the padding of a markdown cell and the gap between cells; outside it they add nothing.
    // - Line boxes as in CSS: a line of line height `L` (a ratio of the text size) is the line box of
    //   the font, from its ascender `A` to its descender `D`, with `(L - (A + D)) / 2` above and below
    //   it. `A` and `D` are measured on the font in use, so the rule holds for any font. The lines of a
    //   code block are `text.line-height` of `code.size` apart, as the live `pre` puts them.
    // - The space between blocks follows the CSS margins of the live deck. Typst puts only the
    //   `above` of a block between a paragraph and the block, and only its `below` between the block
    //   and a paragraph; two blocks take the larger of the two, as CSS margins collapse. A block has no
    //   space of its own, as a `div`; the blocks of markdown set theirs. A list has
    //   `text.paragraph-after` above it and `.6em` below it, as a live `ul`. A nested list has the item
    //   spacing above and below it: Typst spaces a tight list so, and the live deck does the same.
    // - Headings take the sizes and the margins of the deck settings and the weights of the live deck
    //   (800, 750, 650). Typst sets a level-1 heading at 1.4em and a level-2 heading at 1.2em of the
    //   text around it, below any show rule, so those sizes divide by these factors. A level-2
    //   heading has the accent bar of the live deck.
    // - A block quote has the gap between cells below it. A code block has
    //   `code.size` above and below it, as the margin of a live `pre`. Display math is at 1.4em with
    //   .8em above and 1em below it (the margin and the padding of a live `.katex-display`), inline
    //   math at 1.1em.
    // - Tables take the structure keys of `[table]`, and `base-table` sets their text size and column
    //   widths. A table that has no `<slate-table>` element (a table in a list) takes the base paint.
    #let RHYTHM = state("slate-rhythm", false)
    #let base-rhythm(body) = { RHYTHM.update(true); context {
      let m(t, b) = measure(text(top-edge: t, bottom-edge: b, "x")).height / text.size
      let (A, D) = (m("ascender", "baseline"), m("baseline", "descender"))
      let edges(L) = (top-edge: (A + (L - A - D) / 2) * 1em, bottom-edge: -(D + (L - A - D) / 2) * 1em)
      set text(..edges(settings.text.line-height))
      show heading: set text(..edges(HEAD-LH))
      show raw.where(block: true): set text(..edges(settings.text.line-height / CODE-INLINE))
      set par(leading: 0em, spacing: settings.text.paragraph-after)
      set block(spacing: 0em)
      // Typst counts the list depth from 0: a top-level item gets "•", as on the live deck.
      set list(spacing: settings.text.list-item-after, indent: 0em, body-indent: 0.5em,
        marker: depth => box(width: settings.text.list-indent - 0.5em, align(right, text(fill: settings.text.list-marker, ("•", "◦", "▪").at(calc.rem(depth, 3))))))
      set enum(spacing: settings.text.list-item-after, indent: 0em, body-indent: 0.5em,
        numbering: n => box(width: settings.text.list-indent - 0.5em, align(right, [#n.])))
      show list: set block(above: settings.text.paragraph-after, below: 0.6em)
      show enum: set block(above: settings.text.paragraph-after, below: 0.6em)
      show grid: set block(above: settings.text.paragraph-after, below: settings.text.paragraph-after)
      show heading.where(level: 1): set text(size: settings.heading.h1 / 1.4, weight: 800)
      show heading.where(level: 2): set text(size: settings.heading.h2 / 1.2, weight: 750)
      show heading.where(level: 3): set text(size: settings.heading.h3, weight: 650)
      show heading: set block(above: settings.rhythm.heading-above, below: settings.rhythm.heading-below)
      show heading.where(level: 2): it => block(it.body + block(above: 0.32em, box(width: 2.2em, height: 6 * u,
        radius: 99 * u, fill: gradient.linear(settings.roles.accent, settings.roles.accent2))))
      show quote.where(block: true): it => block(above: settings.text.paragraph-after, below: settings.rhythm.cell-gap, it.body)
      show raw.where(block: true): set block(above: settings.code.size / CODE-INLINE, below: settings.code.size / CODE-INLINE)
      show math.equation.where(block: true): set text(size: 1.4em)
      show math.equation.where(block: true): set block(above: 0.8em / 1.4, below: 1em / 1.4)
      show math.equation.where(block: false): set text(size: 1.1em)
      set table(inset: (x, y) => { let p = tinset(if y == 0 { settings.table.header-pad-y } else { settings.table.body-pad-y }); (x: settings.table.pad-x, top: p, bottom: p + TRULE) })
      show table: set par(leading: (TL - settings.text.line-height) * 1em)
      show table.cell: set align(horizon)
      show table: base-table
      (base-draw.table)((body: body))
    }; RHYTHM.update(false) }
    // Author-embedded markdown images stage into the doc root; resolve them relative to THIS file
    // (not cmarker's package dir, where its built-in image() looks) — passed to cmarker as scope.image.
    // `media.json` carries any `{width=…}` block the author wrote (see `_stage_typst_md_media`), as
    // (magnitude, unit) — markdown has no place to hang a size, so it travels beside the document.
    #let MEDIASZ = json("media.json")
    #let mdlen(e) = if e == none { auto } else if e.at(1) == "%" { e.at(0) * 1% } else if e.at(1) == "em" { e.at(0) * 1em } else { e.at(0) * 1pt }
    #let mdalign(s) = if s == "left" { left } else if s == "right" { right } else { center }
    // `figrec(body)` gives `body` the label `<slate-figure>` inside a box of its own, so that the figure
    // record of the marks has the top left corner of `body`. A record in the line of a labelled inline
    // box has the y of the baseline, and inside `layout` the x of the start of the line.
    #let figrec(body) = box([#body <slate-figure>])
    // An image alone in its paragraph is a figure — centred, matching the notebook and the HTML export.
    // A centred one with no height is a `<slate-fig>` marker that `fit` sizes, as an image output is
    // (see `figureimg`); its `width` is an upper bound. One sitting in a run of prose stays inline,
    // where the author put it.
    #let mdimage(src, alt: none) = {
      let a = MEDIASZ.at(src, default: (:))
      let (w, h) = (a.at("width", default: none), a.at("height", default: none))
      if a.at("block", default: false) and h == none and a.at("align", default: "center") == "center" {
        return [#metadata((p: src, w: if w == none { none } else { mdlen(w) }, hook: a.at("hook", default: false))) <slate-fig>]
      }
      let im = image(src, alt: alt, width: mdlen(w), height: mdlen(h))
      if a.at("block", default: false) { align(mdalign(a.at("align", default: "center")), figrec(box(im))) } else { im }
    }
    // Code in markdown as on the live deck: inline code at `CODE-INLINE` of its text, a code block at
    // `code.size` with its code at `CODE-INLINE` of that. Typst sets raw text at 0.8em of the text
    // around it, below any show rule, so the sizes divide by it.
    #let mdraw(..a) = text(size: (if a.named().at("block", default: false) { settings.code.size / 1em } else { 1 }) * CODE-INLINE / 0.8 * 1em, raw(..a))
    #let mdscope = (image: mdimage, raw: mdraw)
    // A markdown cell has the padding of a live markdown cell, 16 u on each side; the slide title has it
    // too. It keeps the space below its last block, as a live cell does; the empty block at its end
    // holds that space. A cell that ends with a key message, an admonition or a table is `tight`: the
    // live deck puts no space below such a block at the end of a cell, so the empty block is left out
    // (Typst drops the space below the last block of a container). `cellgap` is the gap between the
    // cells of a slide.
    #let mdcell(body, tight: false) = context if RHYTHM.get() { pad(x: 16 * u, { body; if not tight { block(height: 0em, above: settings.text.paragraph-after) } }) } else { body }
    #let cellgap = context if RHYTHM.get() { v(settings.rhythm.cell-gap) }
    // `draw-kind` draws the block `it` of kind `k`. `draw` holds the function of each kind, and `own`
    // the kinds for which the deck template gives the function. Inside `base-rhythm` each kind has its
    // function. Outside it a deck template draws the slide with its own rules, so only its own
    // functions apply: each other block is `plain`, the block as its markdown gives it.
    #let draw-kind(draw, own, k, it, plain) = context if k in own or RHYTHM.get() { (draw.at(k))(it) } else { plain }
    // The `html:` handlers of `cmarker.render` for the elements of the block kinds. The function of a
    // key message gets the content of its block quote. A plain admonition is a block quote with its
    // heading in bold. A figure gets its function when its size is known (the label `<slate-figure>`,
    // see `drawfig`).
    #let slate-html(draw, own) = (
      slate-key-message: (attrs, body) => draw-kind(draw, own, "key-message", attrs + (body: { show quote.where(block: true): q => q.body; body }), body),
      slate-caption: (attrs, body) => draw-kind(draw, own, "caption", attrs + (body: body), body),
      slate-admonition: (attrs, body) => draw-kind(draw, own, "admonition", attrs + (body: body),
        quote(block: true, { strong(attrs.at("heading", default: "")); parbreak(); body })),
      slate-figure: (attrs, body) => body,
      slate-table: (attrs, body) => draw-kind(draw, own, "table", attrs + (body: body), body),
    )
    $(_CITE_SHOW)
    // Marks: the layout source of an exporter. With `--input slate-marks=1` each block (`blk`) and
    // each region (`region`) of a slide writes records under the label `<slate>`; without it they
    // draw their body and nothing else. All lengths of a record are in `u`, from the top left corner
    // of the page.
    // - `(kind: "block", frag, cell, i, block, page, x, y, w, h, nw, ah, size, lh)`: block `i` of the cell
    //   fragment `frag` ("s<slide>f<fragment>") of cell `cell`, of block kind `block`. `x`, `y` and `w` are the left
    //   edge, the top and the width of its column, `h` its height and `nw` the width of its content.
    //   `ah` is the height of its container, when that has one. `size` is the text size at its place,
    //   `lh` the line pitch `P` at its place (see below).
    // - `(kind: "region", name, page, x, y, w, h, nw, ah, size, lh)`: the same for a region.
    // - `(kind: "text", size, lh, page, …)`: the text size and the line pitch of a paragraph, a heading,
    //   a list or a code block inside a block or a region, with the `frag` and `i` of the block or the
    //   `name` of the region. The first one of a block is the text size and the line pitch of the block.
    // - `(kind: "figure", page, x, y, w, h, frag, i)`: the picture of a figure block, after the fit.
    // - `(kind: "cell", col, row, end, page, x, y, size, lh, frag, i)`: a corner of a cell in the first
    //   row or the first column of a table block: the top left one (`end` false) and the bottom right
    //   one (`end` true). They give the start and the end of each column and of each row, and the text
    //   size and the line pitch of the cells.
    // The box of prose, of a caption and of a region holds whole line boxes of CSS (`lines`): a line
    // of pitch `P` (its top edge, its bottom edge and the leading) has `(P - (A + D)) / 2` above its
    // ascender `A` and below its descender `D`, measured on the font in use. Inside `base-rhythm` a
    // line has those edges already, so nothing is added, and `P` is the CSS line height.
    // The mark is placed, so it takes no space: the layout is the same with and without marks. The
    // measured copies of `fit` draw the body with no mark.
    #let MARKS = sys.inputs.at("slate-marks", default: "0") == "1"
    #let slate-mark(rec, body, lines: false) = {
      let id = rec + (kind: "text")
      let here-u() = { let p = here().position(); (page: p.page, x: p.x / u, y: p.y / u) }
      // The line pitch `P` in force, in `u`. Call it inside `context`.
      let pitch() = (measure(text(bottom-edge: "baseline", "x")).height + measure(text(top-edge: "baseline", "x")).height
        + par.leading.to-absolute()) / u
      let sized(it) = context { [#metadata(id + (page: here().page(), size: text.size / u, lh: pitch())) <slate>]; it }
      place(layout(c => context {
        let (above, below) = if lines {
          let m(t, b) = measure(text(top-edge: t, bottom-edge: b, "x")).height
          let (A, D) = (m("ascender", "baseline"), m("baseline", "descender"))
          let (t, b) = (measure(text(bottom-edge: "baseline", "x")).height, measure(text(top-edge: "baseline", "x")).height)
          let half = (pitch() * u - A - D) / 2
          (A + half - t, D + half - b)
        } else { (0 * u, 0 * u) }
        let sz = measure(width: c.width, body)
        let p = here-u()
        [#metadata(rec + p + (y: p.y - above / u, w: c.width / u, h: (sz.height + above + below) / u, nw: sz.width / u,
          ah: if c.height < 100 * SLIDE_H { c.height / u }, size: text.size / u, lh: pitch())) <slate>]
      }))
      show par: sized
      show heading: sized
      show list: sized
      show enum: sized
      // An output of a code cell (`outblock`, `valblock`, `errblock`) is inline raw text, with no
      // paragraph: in a code block the first line of any raw text gives the record.
      show raw: it => if it.block or rec.at("block", default: none) == "code" { show raw.line.where(number: 1): sized; it } else { it }
      show <slate-figure>: it => { context { let s = measure(it); [#metadata(id + here-u() + (kind: "figure", w: s.width / u, h: s.height / u)) <slate>] }; it }
      show table.cell: it => if rec.at("block", default: none) == "table" and (it.x == 0 or it.y == 0) {
        let corner(end) = context [#metadata(id + here-u() + (kind: "cell", col: it.x, row: it.y, end: end, size: text.size / u, lh: pitch())) <slate>]
        place(top + left, corner(false))
        place(bottom + right, corner(true))
        it
      } else { it }
      body
    }
    #show <slate-mark>: it => slate-mark(it.value.rec, it.value.body, lines: it.value.lines)
    // `blk(i, kind, frag: …, cell: …)[…]` is block `i` of a cell fragment: Slate writes one call for
    // each block of a slide body.
    #let blk(i, kind, body, frag: none, cell: none) = if MARKS {
      [#metadata((rec: (kind: "block", frag: frag, cell: cell, i: i, block: kind), body: body, lines: kind in ("prose", "caption"))) <slate-mark>]
    } else { body }
    // `region(name, body)` draws `body` as the region `name` of the slide: "title", "subtitle",
    // "byline" or "abstract". A deck template puts each region that it draws from notebook content in
    // it, inside the text size of the region and inside the box that is the area of the region. Slate
    // warns when the region is taller than that box, off the page, or over a block or another region.
    // Only a region in `region` is in the layout source: a template that draws its own layout and
    // does not call it gives an exporter no region and no region text.
    #let region(name, body) = if MARKS { [#metadata((rec: (kind: "region", name: name), body: body, lines: true)) <slate-mark>] } else { body }
    // The base title slide draws the regions of a `title` cell with the sizes and the spacing of the
    // live title slide. The title is at 0.94 em, weight 800, in the strong colour, with 0.18 em above
    // it and 0.2 of its size below it. The subtitle is at the size of its heading level in the deck
    // settings (`SUBLEVEL`, 2 or 3, which the document sets before the title slide), weight 500, in
    // the dim colour, with 0.08 of its size above it. Both have the line height of a heading
    // (`HEAD-LH`). The byline is a paragraph of body text with `text.paragraph-after` below it.
    // `linebox(L, body)` gives `body` the line box of CSS for the line height `L`, as `base-rhythm` does.
    #let SUBLEVEL = state("slate-subtitle-level", 3)
    #let linebox(L, body) = context {
      let m(t, b) = measure(text(top-edge: t, bottom-edge: b, "x")).height / text.size
      let (A, D) = (m("ascender", "baseline"), m("baseline", "descender"))
      text(top-edge: (A + (L - A - D) / 2) * 1em, bottom-edge: -(D + (L - A - D) / 2) * 1em, body)
    }
    // A region holds a block as wide as the column, so that its mark has the box of the column. The
    // line box is set outside the region, so that its mark records the line height of its lines.
    #let metablock(title, subtitle, byline, abstract) = align(center, {
      let line(name, L, body) = linebox(L, region(name, block(width: 100%, body)))
      if title != none {
        block(inset: (top: 0.18em), text(size: 0.94em, weight: 800, fill: $(p.title),
          block(inset: (bottom: 0.2em), line("title", HEAD-LH, title))))
      }
      if subtitle != none {
        context text(size: if SUBLEVEL.get() == 2 { settings.heading.h2 } else { settings.heading.h3 }, weight: 500,
          fill: settings.roles.dim, block(inset: (top: 0.08em), line("subtitle", HEAD-LH, subtitle)))
      }
      if byline != none { region("byline", block(width: 100%, byline)); v(settings.text.paragraph-after) }
      if abstract != none { v(0.84em); block(width: 80%, text(size: 0.8em, style: "italic")[#region("abstract", abstract)]) }
    })
    // `metarest(m, rest)` adds `rest`, the blocks of the title cell that are no region, to the result
    // `m` of `metablock`: below it when it is content, as the field `rest` when a deck template makes
    // it a dictionary.
    #let metarest(m, rest) = if type(m) == dictionary { m + (rest: rest) } else { m + align(center, rest) }
    #let codeblock(s) = block(width: 100%, fill: $(p.codebg), inset: 21 * u, radius: 11 * u, text(size: $(_slide_code_size(code)), raw(block: true, lang: "julia", s)))
    // The text of an output is 0.7 em of the body, as the live `.deck-slide .output`. Typst sets raw
    // text at 0.8 em of the text around it, so the size is 0.7 / 0.8 em.
    #let outblock(s) = block(width: 100%, inset: 19 * u, fill: $(p.outbg), radius: 8 * u, text(size: 0.875em, fill: $(p.outfg), raw(s)))
    #let valblock(s) = block(width: 100%, inset: 19 * u, fill: $(p.valbg), radius: 8 * u, text(size: 0.875em, fill: $(p.valfg), raw(s)))
    #let errblock(s) = block(width: 100%, inset: 19 * u, fill: $(p.errbg), radius: 8 * u, text(size: 0.875em, fill: $(p.errfg), raw(s)))
    // A figure is a marker that `fit` sizes for the slide. `width` is an upper bound on its drawn
    // width: a ratio of the column, or a length. With no `width`, the full size of a figure is the
    // natural size of the picture that the live deck shows (`natural-w`), at most its column. A picture
    // with no natural size fills its column. At figure scale `f`, a figure is `f` of its full size, and
    // at most `FIT.fig-cap` of the slide height. Outside `fit` it is drawn at `f = 1`. The sized picture
    // has the label `<slate-figure>`: the rule for that label, after the deck template, gives it to
    // `draw.figure`.
    #let figureimg(p, width: none, hook: false) = [#metadata((p: p, w: width, hook: hook)) <slate-fig>]
    // The root `<svg>` tag of an SVG file: `width` and `height` tell if the tag has that size as an
    // absolute length (a number, px, pt, ...; not `%`), `aspect` is height / width of its `viewBox`,
    // `none` without one.
    #let svg-tag(p) = {
      let m = read(p).match(regex("<svg[^>]*"))
      let t = if m == none { "" } else { m.text }
      let absolute(k) = {
        let a = t.match(regex("[[:space:]]" + k + "[[:space:]]*=[[:space:]]*[^[:space:]>]+"))
        a != none and not a.text.contains("%")
      }
      let vb = t.match(regex("[[:space:]]viewBox[[:space:]]*=[[:space:]]*.([-0-9.eE,[:space:]]+)"))
      let q = if vb == none { () } else { vb.captures.at(0).trim().split(regex("[,[:space:]]+")) }
      (width: absolute("width"), height: absolute("height"),
       aspect: if q.len() == 4 and float(q.at(2)) > 0 { float(q.at(3)) / float(q.at(2)) })
    }
    // The size of an SVG as a browser draws it, from `n`, the size that Typst measures. With one
    // absolute side, Typst gives the other side the viewBox size; the browser takes it from the
    // viewBox aspect.
    #let svg-size(n, s) = if s.aspect == none or s.width == s.height { n } else if s.width {
      (width: n.width, height: n.width * s.aspect)
    } else { (width: n.height / s.aspect, height: n.height) }
    // The natural width in CSS px (1/96 in), which is `u` on the slide, or `none` for a picture with no
    // natural size. `n` is the size of the picture and `svg` the root tag of an SVG that is not a hook
    // picture (`svg-tag`). A PNG has its pixel width (a browser does not read its density). An SVG has
    // a natural size only when its root tag has an absolute `width` or `height`: the browser takes the
    // other side from the aspect. An SVG with only a `viewBox`, or with sizes in `%`, fills its column
    // on the live deck: `none`. A PDF figure (a Makie figure) shows on the live deck as a PNG at twice
    // its size, so it fills its column: `none`. A picture of a figure hook (`hook`) has the size at
    // which the live deck draws its value: the page size of a PDF or an SVG, and a PNG at
    // `FigureContext.scale` (2) px for each px.
    #let natural-w(p, n, hook: false, svg: none) = if lower(p).ends-with(".png") {
      let b = read(p, encoding: none)
      (b.at(16) * 16777216 + b.at(17) * 65536 + b.at(18) * 256 + b.at(19)) / if hook { 2 } else { 1 }
    } else if hook { n.width / (1in / 96) } else if svg != none {
      if svg.width or svg.height { n.width / (1in / 96) }
    }
    // A video or audio file of markdown alone in its paragraph (Julia `_clip_typ`). A PDF cannot play
    // it, so it draws a placeholder in the box that the live deck gives the clip: a frame with a play
    // mark and `label`. A video of `w` × `h` px fills the width of its column at that aspect, up to the
    // figure cap, as on the live deck (notebook.css `--clip-ar`). An audio file has the size of the live
    // audio controls, 300 × 54 u, in the centre of its column.
    #let clipframe(w, h, label) = box(width: w, height: h, inset: 8 * u, clip: true, fill: settings.roles.dim.transparentize(80%), align(center + horizon, {
        let s = calc.min(0.4 * h, 64 * u)
        let mark = polygon(fill: settings.roles.dim, (0 * u, 0 * u), (0.87 * s, s / 2), (0 * u, s))
        let t = text(size: 0.7em, fill: settings.roles.dim, label)
        if h < 120 * u { grid(columns: 2, column-gutter: 12 * u, align: horizon, mark, t) } else { stack(spacing: 16 * u, align(center, mark), t) }
      }))
    // An SVG with one absolute side is drawn in the box of its browser size (`svg-size`). Typst draws
    // the viewBox in the middle of the box that it measures, so `cover` crops the empty bands.
    #let drawfig(v, f) = layout(c => {
      let clip = v.at("clip", default: none)
      let hook = v.at("hook", default: false)
      let svg = if clip == none and not hook and lower(v.p).ends-with(".svg") { svg-tag(v.p) }
      let n = if clip != none { (width: clip.w * u, height: clip.h * u) } else if svg != none { svg-size(measure(image(v.p)), svg) } else { measure(image(v.p)) }
      let nw = if clip == none { natural-w(v.p, n, hook: hook, svg: svg) } else { none }
      let cw = if v.w != none { if type(v.w) == ratio { c.width * v.w } else { calc.min(c.width, v.w) } } else if nw == none { c.width } else { calc.min(c.width, nw * u) }
      let h = calc.max(u, f * calc.min(FIT.fig-cap * SLIDE_H, cw * (n.height / n.width)))
      let pic = if clip != none { clipframe(h * (n.width / n.height), h, clip.label) } else if svg == none { box(image(v.p, height: h)) } else {
        box(image(v.p, width: h * (n.width / n.height), height: h, fit: "cover"))
      }
      align(center, figrec(pic))
    })
    #show <slate-fig>: it => drawfig(it.value, 1)
    #let clipfig(kind, w, h, label) = if kind == "audio" { align(center, figrec(clipframe(300 * u, 54 * u, label))) } else {
      [#metadata((p: none, w: none, clip: (w: w, h: h, label: label))) <slate-fig>]
    }
    #let notefig(s) = block(width: 100%, inset: 19 * u, text(size: 0.7em, style: "italic", fill: $(p.parlabel), s))
    #let figcaption(lbl, body) = block(width: 100%, inset: (x: 64 * u, y: 11 * u), text(size: 0.7em, fill: $(p.parlabel))[#text(weight: "bold")[#lbl.] #body])
    #let paramblock(items) = block(width: 100%, inset: (x: 21 * u, y: 13 * u), fill: $(p.parbg), radius: 8 * u, stroke: 1.33 * u + $(p.parborder),
      text(size: 0.7em)[#text(fill: $(p.parlabel), weight: "bold")[parameters] #h(0.45em) #items.map(it => [#raw(it.at(0)) = #text(weight: "bold", it.at(1))]).join([#h(0.75em)])])
    // `fit(body)` draws `body` at the full content width so that it fits the page, as the live deck
    // does (`slides.js` `_fitSearch`). It changes only the font size: text scale `s` sets
    // `text(size: s * 1em)`, so every em length follows the text and every `u` length stays fixed.
    // Figure scale `f` sizes the figures (see `drawfig`); all figures share one `f`.
    // 1. Try `s = 1`, `f = 1`.
    // 2. Bisect `s` over [`FIT.text-floor`, 1] in 6 steps, each at `f = (1 + s) / 2`: the figures
    //    give up height at half the rate of the text.
    // 3. At that `s`, take the largest `f` in [(1 + s) / 2, 1].
    // 4. When the slide does not fit at the text floor, keep the floor and take `f` down to
    //    `FIT.fig-floor`. When it does not fit there either, the slide is at the floor: it is drawn
    //    from the top and runs past the page bottom. Its figures keep `f = 1` if a smaller `f` gains
    //    no height (a figure beside a taller column of text).
    // Each slide records `(kind: "fit", slide, s, f, at_floor, size)` under the label `<slate>`;
    // `slide` is the page number and `size` the body text size at `s = 1`, in `u`.
    // Typst cannot measure a cite() in isolation ("cannot format citation in isolation", it needs
    // document context to resolve), so the MEASURED copy renders citation sentinels as a fixed
    // stand-in of comparable width; the real body still renders true citations.
    #let fit(body) = layout(sz => {
      let draw(s, f) = {
        set text(size: s * 1em)
        show <slate-fig>: it => drawfig(it.value, f)
        body
      }
      let tall(s, f) = measure(block(width: sz.width, { show regex("§c§[^§]*§[^§]+§[^§]*§"): it => [[0]]; show <slate-mark>: it => it.value.body; draw(s, f) })).height
      let fits(s, f) = tall(s, f) <= sz.height
      let tie(s) = (1 + s) / 2
      // The largest `f` in [lo, 1] that fits at text scale `s`, or `lo` when none does.
      let best-f(s, lo) = if fits(s, 1.0) { 1.0 } else {
        let (a, b) = (lo, 1.0)
        for _ in range(6) { let m = (a + b) / 2; if fits(s, m) { a = m } else { b = m } }
        a
      }
      let lo = FIT.text-floor
      let (s, f, at-floor) = if fits(1.0, 1.0) { (1.0, 1.0, false) } else if not fits(lo, tie(lo)) {
        let f = best-f(lo, FIT.fig-floor)
        if fits(lo, f) { (lo, f, false) } else if tall(lo, f) < tall(lo, 1.0) - u { (lo, f, true) } else { (lo, 1.0, true) }
      } else {
        let hi = 1.0
        for _ in range(6) { let m = (lo + hi) / 2; if fits(m, tie(m)) { lo = m } else { hi = m } }
        (lo, best-f(lo, tie(lo)), false)
      }
      context [#metadata((kind: "fit", slide: here().page(), s: s, f: f, at_floor: at-floor, size: text.size / u)) <slate>]
      // A slide at the floor is taller than the page: a box as tall as the body keeps its items apart
      // (in a shorter one they break and pile up at its end), and a block as tall as the page puts its
      // top at the top of the page.
      if at-floor { block(height: sz.height, align(top, box(width: sz.width, height: tall(s, f), draw(s, f)))) }
      else { block(width: sz.width, breakable: false, draw(s, f)) }
    })
    // Side-by-side columns. `widths` holds one entry per column: a ratio or a length, or `none` for a
    // column that shares the rest equally. The other arguments are the column bodies. Ratios that fill
    // the row or more shrink in proportion, as the flex columns of the live deck do. The gap is the
    // deck setting `columns.gap`. A row of cells (`row: true`) gives `columns.row-gap`, no spacing of
    // its own in `base-rhythm` (the gap between cells is around it) and `align: horizon` when it holds
    // a markdown cell, as on the live deck.
    #let slidecols(widths, gap: settings.columns.gap, align: top, row: false, ..cols) = {
      let shrink = widths.all(w => type(w) == ratio) and widths.map(w => w / 1%).sum() >= 100
      let g = grid(columns: widths.map(w => if w == none { 1fr } else if shrink { w / 1% * 1fr } else { w }),
        column-gutter: gap, align: align, ..cols.pos())
      if row { context if RHYTHM.get() { block(above: 0em, below: 0em, g) } else { g } } else { g }
    }
    // A `:::: grid` group (`_print_slidegrid`): its tracks and its gap (the deck setting `grid.gap` by
    // default) between the columns and between the rows, as the CSS grid of the live deck. `gridfill`
    // reads the colour word of a grid cell: a palette name, else a colour role, else no paint. A grid
    // cell with a fill has the pad `grid.pad`. `marks` are the marks of the cell (`cellmark`). The
    // body is in a block, which the cell aligns as one: Typst puts a `place` at the start of a cell at
    // the top of the cell, before the vertical alignment, so with no block the mark of the first block
    // of a `middle` or `bottom` cell (`slate-mark`) would be at the top of the cell, not at its text.
    #let slidegrid(columns: (1fr,), gap: settings.grid.gap, ..cells) = grid(columns: columns,
      column-gutter: gap, row-gutter: gap, ..cells.pos())
    #let gridfill(n) = settings.palette.at(n, default: settings.roles.at(n, default: none))
    #let gridcell(fill: none, align: left + top, size: none, marks, body) = grid.cell(align: align,
      fill: if fill == none { none } else { gridfill(fill) }, inset: if fill == none { 0 * u } else { settings.grid.pad },
      { marks; block(width: 100%, if size == none { body } else { set text(size: size * 1em); body }) })
    // The marks of a grid cell, with the marks on (see `slate-mark`): its top left and bottom right
    // corners inside its pad, as `(kind: "gridcell", frag, path, end, pad, page, x, y)` in `u`.
    #let cellmark(frag, path, filled: false) = if MARKS {
      let corner(end) = context { let p = here().position()
        [#metadata((kind: "gridcell", frag: frag, path: path, end: end, pad: if filled { settings.grid.pad / u } else { 0 },
          page: p.page, x: p.x / u, y: p.y / u)) <slate>] }
      place(top + left, corner(false))
      place(bottom + right, corner(true))
    }
    // One slide = one page, with the body at the top. The title goes at the top of the body, inside
    // `fit`, with the padding of the live title cell (12 u above, 16 u at the sides); a notes page gets
    // a "Notes · slide N" label in its place. The slide number is at the bottom right, as on the live
    // deck, but not on a title, section, cover or notes page; a notes page does not count. The layouts
    // follow the live deck: `center`, `title` and `section` centre the body on the page, `center` centres
    // the text as well, and `section` has a wider left margin, a larger title and a dimmed level-3
    // heading.
    #let slidenum = counter("slate-slide")
    #let slide(body, layout: none, title: none, n: none) = {
      if layout != "notes" { slidenum.step() }
      page(margin: (top: 84 * u, bottom: 72 * u, left: (if layout == "section" { 180 } else { 120 }) * u, right: 120 * u),
        foreground: if layout not in ("title", "section", "cover", "notes") {
          place(bottom + right, dx: -44 * u, dy: -30 * u,
            text(size: 20 * u, fill: settings.roles.dim.transparentize(30%), context slidenum.display()))
        })[
        #set std.align(horizon) if layout in ("center", "title", "section")
        #base-rhythm(fit({
          set std.align(center) if layout == "center"
          show heading.where(level: 3): it => if layout == "section" { text(fill: $(p.text).transparentize(40%), it) } else { it }
          if layout == "notes" { text(fill: luma(130))[Notes · slide #n]; v(0.32em) } else if title != none {
            v(12 * u)
            pad(x: 16 * u, { if layout == "section" { text(size: 1.6em, region("title", title)) } else { region("title", title) }; block(height: 0em) })
          }
          body
        }))
      ]
    }
    // A deck template that defines its own `slide` or `fit` calls the base one by these names.
    #let base-fit = fit
    #let base-slide = slide

    """
end

# The Typst call that draws the markdown file `file` of the project. `mdhtml` holds the handlers of the
# block-kind elements (`ReportRender._md_blocks`): the document preamble defines it, and the slides get
# it from `_SLIDES_TAIL`.
_md_render(file) = string("cmarker.render(read(\"", file, "\"), math: mathfn, scope: mdscope, html: mdhtml)")

# The Typst text that Slate writes after the deck template of a slides project. At this point `draw`
# holds the block-kind functions that the deck template gives (none with no template). The tail puts
# them on the base functions and binds the result to the code that draws the blocks: the `html:`
# handlers of the markdown (`mdhtml`) and the rule for a sized figure. A Typst function keeps the
# definitions that it saw, so without the tail a function of the template does not reach the base
# code. A key of `draw` that is no block kind gives a `(kind: "warning", about: "draw", key)` record
# under `<slate>`.
const _SLIDES_TAIL = """
// ── Slate: bind `draw` ──
#let own = draw.keys()
#for k in own.filter(k => k not in base-draw) [#metadata((kind: "warning", about: "draw", key: k)) <slate>]
#let draw = base-draw + draw
#let mdhtml = slate-html(draw, own)
#show <slate-figure>: it => draw-kind(draw, own, "figure", (body: it), it)

"""

# Citation rewriting. `cmarker` only honors a bare `[@key]` (it makes the whole bracket the
# citation label), so Pandoc locators/forms break it. We rewrite citation syntax into a plain-text
# sentinel `§c§<form>§<key>§<supplement>§` (survives cmarker verbatim) and a preamble `#show regex`
# turns each sentinel into a real Typst `cite(label(key), supplement: …, form: …)`. Supported:
#   [@key]              normal           [@key, p. 7] / [@key, pp. 3–9]   page locator (supplement)
#   [@a; @b]            multiple (adjacent cites — the CSL style groups them)
#   @key (bare)         prose form ("Knuth (1984)") — only when `key` is a defined bibliography key
# (Suppress-author isn't offered: Typst's year form drops the parentheses, which reads wrong; use the
#  prose form `@key` for an author-year mention.)
const _CITE_OPEN = "§c§"
# Preamble rule that turns each citation sentinel back into a real Typst cite (resolved against
# whatever `#bibliography(...)` the document emits). Harmless when there are no citations.
const _CITE_SHOW = raw"""#show regex("§c§[^§]*§[^§]+§[^§]*§"): it => {
  let p = it.text.split("§")
  let f = if p.at(2) == "y" { "year" } else if p.at(2) == "p" { "prose" } else { "normal" }
  if p.at(4) == "" { cite(label(p.at(3)), form: f) } else { cite(label(p.at(3)), supplement: [#p.at(4)], form: f) }
}"""
function _cite_token(key, sup, form)
    return string(_CITE_OPEN, form, "§", key, "§", replace(strip(sup), "§" => ""), "§")
end
# Default `emit` for the export path: a sentinel the preamble's `#show` rule turns into a Typst cite.
_cite_sentinel(key, sup, form) = _cite_token(key, sup, form)

# A `[@fig:label]` cross-reference → its rendered text. `figrefs` maps label → (num, anchor); the
# export default emits plain "Figure N" (the number is authoritative even without a hyperlink), the
# live view overrides `figemit` with an HTML link that jumps to the figure.
_fig_text(num, anchor) = string("Figure ", num)

# Rewrite one `[...]` citation group (its inner text, which contains an `@`); `emit(key,sup,form)`
# builds each replacement (a Typst sentinel for export, an HTML link for the live view). A `fig:`
# label resolved in `figrefs` becomes a figure cross-reference via `figemit` instead of a bib cite.
function _rewrite_bracket_cite(inner, emit; figrefs = Dict{String,Tuple{Int,String}}(), figemit = _fig_text)
    io = IOBuffer()
    for spec in split(inner, ';')
        # Accept an optional leading `-` (Pandoc suppress-author) but render normally — Typst's year
        # form drops the parentheses, which reads wrong, so we don't honor suppression.
        m = match(r"^\s*-?@([\w:.\-]+)\s*(?:,\s*(.*\S))?\s*$", spec)
        m === nothing && return nothing            # not a clean citation group → leave the bracket as-is
        key = m.captures[1]
        if haskey(figrefs, key)                    # figure cross-reference
            num, anchor = figrefs[key]
            print(io, figemit(num, anchor))
        else
            sup = m.captures[2] === nothing ? "" : m.captures[2]
            print(io, emit(key, sup, "n"))
        end
    end
    return String(take!(io))
end
# Rewrite the citation syntax in one stretch of TEXT (no code spans). Bracketed groups first, then
# bare `@key` (prose) — the latter only for defined keys, so emails/handles are left literal.
function _rewrite_text_citations(text, citekeys, emit; figrefs = Dict{String,Tuple{Int,String}}(), figemit = _fig_text)
    t = replace(text, r"\[([^\]\n]*@[^\]\n]*)\]" => m -> begin
        # `chop` strips the brackets safely; byte slicing breaks on a non-ASCII locator (`[@k, p. 3–4]`).
        r = _rewrite_bracket_cite(chop(m; head = 1, tail = 1), emit; figrefs = figrefs, figemit = figemit)
        r === nothing ? m : r
    end)
    (isempty(citekeys) && isempty(figrefs)) && return t
    return replace(t, r"(?<![\w@/])@([\w:.\-]+)" => m -> begin
        raw = m[2:end]
        key = rstrip(raw, ['.', ',', ';', ':', ')', ']', '!', '?'])
        suffix = raw[(ncodeunits(key) + 1):end]
        if haskey(figrefs, key)
            num, anchor = figrefs[key]; figemit(num, anchor) * suffix
        elseif key in citekeys
            emit(key, "", "p") * suffix
        else
            m
        end
    end)
end
# Apply `f` to the text of a markdown source outside its fenced code blocks and inline `code` spans:
# `f` gets one line at a time, with each code span masked, and the spans come back after it.
function _map_outside_code(f, md::AbstractString)
    out = IOBuffer(); infence = false
    for (li, ln) in enumerate(split(md, '\n'))
        li == 1 || print(out, '\n')
        if occursin(r"^\s*(```|~~~)", ln); infence = !infence; print(out, ln); continue; end
        if infence; print(out, ln); continue; end
        spans = SubString{String}[]
        masked = replace(ln, r"`[^`]*`" => s -> (push!(spans, s); "\x00$(length(spans))\x00"))
        done = f(masked)
        for (i, s) in enumerate(spans); done = replace(done, "\x00$(i)\x00" => s); end
        print(out, done)
    end
    return String(take!(out))
end
# Rewrite citations across a markdown source, skipping fenced code blocks AND inline `code` spans
# (so a literal `[@key]` shown in backticks is left untouched). `emit` selects sentinel vs HTML link;
# `figrefs`/`figemit` handle `[@fig:label]` figure cross-references.
_rewrite_citations(md::AbstractString, citekeys = Set{String}(); emit = _cite_sentinel,
                   figrefs = Dict{String,Tuple{Int,String}}(), figemit = _fig_text) =
    _map_outside_code(t -> _rewrite_text_citations(t, citekeys, emit; figrefs = figrefs, figemit = figemit), md)

# Bare text of a `{{ expr }}` interpolation for the Typst export — mirrors the live renderer's
# `_math_value`: a scalar's text, else a `text/latex` chunk's TeX with its `$`/`$$` delimiters
# stripped. So a `{{ giac_expr }}` sitting inside `$$…$$` splices its LaTeX straight in and mitex
# typesets it in the PDF, exactly as KaTeX does live (before this it resolved to nothing).
function _interp_typst_text(o)
    o === nothing && return ""
    o.exception === nothing || return ""
    isempty(o.value_repr) || return ReportRender._interp_scalar(o.value_repr)
    for ch in o.display
        if ch.mime == "text/latex"
            t = strip(String(copy(ch.data)))
            # `chop`, not byte slicing: `$θ$` would index into the middle of the last character.
            startswith(t, "\$\$") && endswith(t, "\$\$") && length(t) >= 4 &&
                return chop(t; head = 2, tail = 2)
            startswith(t, "\$")  && endswith(t, "\$")  && length(t) >= 2 &&
                return chop(t; head = 1, tail = 1)
            return t
        end
    end
    return ""
end

# What a `{{ expr }}` interpolation becomes in the markdown handed to cmarker. Three cases, in order:
# a captured component figure is an image block; otherwise the value's own text; and a claimed FENCE
# that produced neither falls back to the code block CommonMark would have made of it. That last case
# mirrors `_md_html` and is why a diagram with no capture no longer takes its own source down with it
# — before this, an unrenderable ```` ```mermaid ```` block vanished from the PDF without a trace,
# which is strictly worse than the plain-code-block treatment an UNCLAIMED fence gets.
function _interp_typst_md(expr, o, figfile)
    figfile === nothing || return string("\n\n![](", figfile, ")\n\n")
    t = _interp_typst_text(o)
    isempty(t) || return t
    fence = ReportEngine._fence_call(expr)
    fence === nothing && return ""
    return _md_fence_block(fence.lang, fence.body)
end

# The `compfig` callback `_md_for_typst` takes: interpolation index → the filename of that
# value's captured figure (from its figure hook, else from its component), written into the project
# dir on first ask, or `nothing`. Staging is the caller's job (only it has `dir`), so this closes over
# it and registers the figure's width in `media.json` — the one place a markdown image can carry a size.
# A hook figure is drawn at most as wide as its column, at the size of the live value: `media.json`
# marks it with `hook`, so the preamble takes the size of the picture (`natural-w`).
function _compfig_stager(c::Cell, dir::AbstractString, base::AbstractString, compfigs::_CompFigs, sizes)
    slotof = Dict(i => s for (s, i) in _component_slots(c))
    # A staged file has the number of its value in its name, so that an exporter finds the value.
    return function (i::Integer)
        hook = get(compfigs, (c.id, _hook_slot(i)), nothing)
        slot = get(slotof, Int(i), nothing)
        got = hook !== nothing ? hook : slot === nothing ? nothing : get(compfigs, (c.id, slot), nothing)
        got === nothing && return nothing
        bytes, ext = got
        fname = string(base, "_comp", i, ".", ext)
        write(joinpath(dir, fname), bytes)
        if sizes !== nothing
            e = Dict{String,Any}("block" => true)
            pct = hook === nothing ? _comp_fig_width_pct(bytes, ext) : nothing
            pct === nothing || (e["width"] = (Float64(pct), "%"))
            hook === nothing || (e["hook"] = true)
            sizes[fname] = e
        end
        return fname
    end
end

const _md_fence_block = ReportEngine._md_fence_block   # the one fence-source reconstruction (widgets.jl)

# ── Math delimiters ───────────────────────────────────────────────────────────────────────────────
# KaTeX is configured (core.js) for FOUR spellings — `$…$`, `$$…$$`, `\(…\)`, `\[…\]` — but cmarker's
# math hook only fires on the dollar forms, so the LaTeX-bracket ones used to reach the PDF as literal
# text with the backslashes eaten (`\(a^2\)` printed as "(a^2)"). Prose that looked right on screen
# quietly came out as garbage in print. Normalize to the spelling cmarker understands, and escape a
# prose `$` so cmarker cannot pair two of them into math the screen shows as text.
#
# Code is left alone: a fenced block or an inline span may legitimately SHOW `\[…\]` (a LaTeX sample),
# and rewriting it there would corrupt the listing rather than typeset anything — cmarker's math hook
# doesn't fire inside code in the first place. `tex` rewrites the TeX of each formula, and only that.
function _normalize_math_delims(src::AbstractString; tex = identity)
    out = IOBuffer()
    for (kind, t) in ReportRender._md_segments(src)
        if kind === :math
            body, display = ReportRender._math_parts(t)
            print(out, display ? "\$\$" : "\$", tex(body), display ? "\$\$" : "\$")
        elseif kind === :dollar
            print(out, "\\\$")
        else
            print(out, t)
        end
    end
    return String(take!(out))
end

# Markdown source with `{{ expr }}` interpolations resolved (scalars, a text/latex value's TeX, or a
# component's captured figure), math delimiters normalized, each block of a kind in its `<slate-…>`
# element (`ReportRender._md_blocks`; cmarker has no admonition rule, so the body of an admonition is
# plain CommonMark there), and citations rewritten to sentinels for the preamble's cite rule.
# `compfig(i)` returns the staged filename for the i-th interpolation's component figure, or
# `nothing` — the caller owns staging because only it has the project dir (see
# `_build_typst_project`). `fignum` is the figure number of a cell with the `caption` tag.
#
# `src` may be a FRAGMENT of the cell (a `---`-split slide chunk, or the body left after the hoisted
# H1 was dropped). `_md_template` numbers a fragment's interpolations from 1, while `c.interp` and
# `_component_slots` are numbered across the whole cell, so a fragment must say how many precede it:
# that is `interpbase`. Get it wrong and the fragment silently renders an earlier one's value.
function _md_for_typst(c::Cell, src::AbstractString = c.source; citekeys = Set{String}(),
                       figrefs = Dict{String,Tuple{Int,String}}(), compfig = _ -> nothing,
                       interpbase::Integer = 0, fignum::Union{Nothing,Integer} = nothing)
    tmpl, exprs = ReportEngine._md_template(src)
    s = tmpl
    for i in 1:length(exprs)
        g = i + Int(interpbase)                      # this fragment's i-th ⇒ the cell's g-th
        o = g <= length(c.interp) ? c.interp[g] : nothing
        s = replace(s, ReportEngine._interp_token(i) => _interp_typst_md(exprs[i], o, compfig(g)))
    end
    s = _normalize_math_delims(s)
    s = _strip_deck_markup(s)
    s = ReportRender._md_kinds(s; plain = true, caption = :caption in c.flags ? fignum : nothing)
    s = _plain_math_macros(s)
    return _rewrite_citations(s, citekeys; figrefs = figrefs)
end

# The presentation macros (`\term`, `\step`, … — see SLATE_TEX_MACROS in core.js) mark up an equation
# for the deck. Print shows the finished equation, so each becomes the math it wraps (its last argument);
# `\cancelat` keeps its cancel line and the brace macros keep their brace and label.
const _MATH_MACROS = Dict("term" => 2, "termc" => 3, "step" => 1, "stepat" => 2, "hl" => 1, "hlat" => 2,
                          "cancelat" => 2, "fadeat" => 2, "focusat" => 2, "brace" => 2, "braceat" => 3,
                          "obraceat" => 3, "note" => 1)
# The braces print as braces, with their label.
function _print_math_macro(name, args)
    name == "cancelat" && return string("\\cancel{", args[end], "}")
    name == "brace"    && return string("\\underbrace{", args[1], "}_{\\text{", args[2], "}}")
    name == "braceat"  && return string("\\underbrace{", args[2], "}_{\\text{", args[3], "}}")
    name == "obraceat" && return string("\\overbrace{", args[2], "}^{\\text{", args[3], "}}")
    name == "note"     && return string("\\text{", args[1], "}")
    return string("{", args[end], "}")
end
function _plain_math_macros(src::AbstractString)
    occursin('\\', src) || return String(src)
    s = String(src)
    for _ in 1:8                                  # nested macros unwrap one level per pass
        changed = false
        io = IOBuffer(); i = firstindex(s)
        while i <= lastindex(s)
            m = s[i] == '\\' ? match(r"^\\([A-Za-z]+)", SubString(s, i)) : nothing
            n = m === nothing ? 0 : get(_MATH_MACROS, m.captures[1], 0)
            if n > 0
                j = i + ncodeunits(m.match)
                args = String[]
                while length(args) < n
                    while j <= lastindex(s) && isspace(s[j]); j = nextind(s, j); end
                    (j <= lastindex(s) && s[j] == '{') || break
                    depth = 0; k = j
                    while k <= lastindex(s)
                        s[k] == '{' ? (depth += 1) : s[k] == '}' ? (depth -= 1) : nothing
                        depth == 0 && break
                        k = nextind(s, k)
                    end
                    k > lastindex(s) && break
                    push!(args, s[nextind(s, j):prevind(s, k)])
                    j = nextind(s, k)
                end
                if length(args) == n
                    print(io, _print_math_macro(m.captures[1], args))
                    i = j; changed = true
                    continue
                end
            end
            print(io, s[i]); i = nextind(s, i)
        end
        s = String(take!(io))
        changed || break
    end
    return s
end

# `:::` fenced-div lines and `. . .` pauses structure a presented slide (columns, builds); cmarker would
# print them as text. Print shows a slide's finished state, so the markers go and their content stays.
function _strip_deck_markup(src::AbstractString)
    (occursin(":::", src) || occursin(". . .", src)) || return String(src)
    out = String[]
    infence = false
    for ln in split(String(src), '\n'; keepempty = true)
        if occursin(r"^\s*(```|~~~)", ln)
            infence = !infence
        elseif !infence && (occursin(r"^\s*:{3,}", ln) || strip(ln) == ". . .")
            continue
        end
        push!(out, ln)
    end
    return join(out, "\n")
end


# A static Typst table from a wire table spec (Dict with "columns"/"rows"). Capped.
# Cell/header text inherits the document text colour, so it follows the theme; only the
# rule colour and header fill are themed explicitly via the palette.
# Wrap a Typst table-cell body in a `table.cell(fill: …)` for an in-cell `:bar`/`:heat` column,
# scaled over the column's numeric domain. `:bar` uses a hard-stop linear gradient (the Typst analog
# of the CSS bar); `:heat` an alpha-shaded fill. The empty part is fully transparent so zebra shows.
function _typ_viz_cell(v, col, inner::AbstractString)
    col isa AbstractDict || return inner
    viz = get(col, "viz", nothing); viz === nothing && return inner
    dom = get(col, "domain", nothing)
    (v isa Real && !(v isa Bool) && dom isa AbstractVector && length(dom) == 2) || return inner
    lo, hi = Float64(dom[1]), Float64(dom[2])
    f = hi > lo ? clamp((Float64(v) - lo) / (hi - lo), 0.0, 1.0) : 1.0
    if viz == "bar"
        p = string(round(f * 100; digits = 1))
        fill = "gradient.linear((rgb(\"#58a6ff\").transparentize(80%), 0%), " *
               "(rgb(\"#58a6ff\").transparentize(80%), $p%), " *
               "(rgb(\"#58a6ff\").transparentize(100%), $p%), " *
               "(rgb(\"#58a6ff\").transparentize(100%), 100%))"
        return "table.cell(fill: $fill)$inner"
    elseif viz == "heat"
        t = string(round((1 - (0.10 + 0.35 * f)) * 100; digits = 1))   # transparentize %  (0% ⇒ opaque)
        return "table.cell(fill: rgb(\"#58a6ff\").transparentize($t%))$inner"
    end
    return inner
end

function _typst_table(spec; theme::AbstractString = "light")::String
    cols = get(spec, "columns", Any[])
    rows = get(spec, "rows", Any[])
    opts = get(spec, "opts", Dict{String,Any}())
    isempty(cols) && return ""
    ncol = length(cols)
    p = _palette(theme)
    # On a slide each size is in `em` (of `table.text-size` inside the table), so that the fit's text
    # scale shrinks the table with the text. The table sets no rule, inset or fill: the base slide gives
    # them and the column widths (`base-rhythm`, `base-table` in the slides preamble), as for a markdown
    # table, and a deck template gives its own.
    deck = theme == "deck"
    z = deck ? (body = "", head = "", title = "1.05em", gap = ("0.6em", "0.5em"), more = "settings.table.text-size") :
               (body = "size: 8pt, ", head = "size: 8.5pt, ", title = "10.5pt", gap = ("6pt", "5pt"), more = "8pt")
    _typalign(a) = a == "right" ? "right" : (a == "center" ? "center" : "left")
    fmts = Any[_col_format(c) for c in cols]   # _col_* column-spec accessors are shared (server_export.jl)
    inner(v, fmt) = "[#text($(z.body)\"" * _typ_str(ReportEngine._format_cell(v, fmt)) * "\")]"
    cell(v, col, fmt) = _typ_viz_cell(v, col, inner(v, fmt))
    io = IOBuffer()
    # per-column alignment (numbers right, bools center) + a themed grid stroke
    print(io, "#align(center)[\n")   # center the table block on the page
    # A caption above the table, matching the browser and the HTML export.
    ttl = _table_title(opts)
    ttl === nothing || print(io, "#block(above: $(z.gap[1]), below: $(z.gap[2]))[#text(size: $(z.title), weight: \"bold\", \"",
                             _typ_str(ttl), "\")]\n")
    aligns = join((_typalign(_col_align(c)) for c in cols), ", ")
    if deck
        print(io, "#(mdhtml.slate-table)((:), [#set text(size: settings.table.text-size)\n#table(columns: ", ncol, ", align: (", aligns, ",),\n")
    else
        print(io, "#table(columns: ", ncol, ", inset: 5pt, align: (", aligns, "), stroke: 0.4pt + $(p.tablestroke),\n")
        # zebra: header shaded (row 0), odd body rows a subtle stripe
        print(io, "  fill: (_, row) => if row == 0 { $(p.tableheadbg) } else if calc.odd(row) { $(p.tablestripe) },\n")
    end
    # repeat the header on every page a long table spills onto
    print(io, "  table.header(repeat: true, ", join(["[#text($(z.head)weight: \"bold\", \"" * _typ_str(_col_name(c)) * "\")]" for c in cols], ", "), "),\n")
    maxr = Int(something(get(opts, "export_rows", nothing), 200))   # per-table export_rows hint, else default cap
    for (ri, r) in enumerate(rows)
        ri > maxr && break
        print(io, "  ", join([cell(ci <= length(r) ? r[ci] : nothing, cols[ci], fmts[ci]) for ci in 1:ncol], ", "), ",\n")
    end
    print(io, deck ? ")\n])\n" : ")\n")
    # accurate truncation: the wire ships at most `maxr` here AND a paged table ships only page 1,
    # so report against opts.nrows (the true total), not the shipped-row count.
    total = Int(get(opts, "nrows", length(rows)))
    shown = min(length(rows), maxr)
    shown < total && print(io, "#text(size: $(z.more), fill: gray)[… ", total - shown, " more rows (", total, " total)]\n")
    print(io, "]\n")   # close #align(center)
    return String(take!(io))
end

# Resolve the best figure representation for publication export: prefer VECTOR (the
# `application/pdf` chunk a CairoMakie figure carries — fonts embedded, crisp at any
# scale — then a captured SVG), and only fall back to raster PNG. Client-rendered charts
# (ECharts) come through the snapshot store: a cached SVG snapshot if one exists (see
# `_warm_chart_svgs!`, which populates it via a live browser round-trip BEFORE the caller
# takes `nb.lock` — `_figure_for_export` itself must stay lock-safe, so it only ever READS
# the cache, never triggers a round-trip), else its PNG. Returns `(bytes, ext)` with
# `ext ∈ ("pdf","svg","png")`, or `nothing` when the cell has no figure.
function _figure_for_export(nb::LiveNotebook, c::Cell; theme::AbstractString = "midnight", override::Bool = false,
                            compfigs::_CompFigs = _NO_COMPFIGS)
    # The picture that the value's figure hook drew for this export comes first (`_warm_hook_figs!`).
    hook = get(compfigs, (c.id, _hook_slot(0)), nothing)
    hook === nothing || return (copy(hook[1]), hook[2])
    # Themed OVERRIDE: a native figure re-rendered under the chosen palette (`_warm_makie_figs!`) wins
    # over the baked-in bytes, which carry the theme the cell was last RUN in — Makie can't be re-themed
    # any other way. Falls through to the baked bytes when the re-render was unavailable.
    if override
        fig = _snapshot_fig(nb.id, c.id, theme; raster = false)   # PDF wants the vector re-render
        fig !== nothing && return fig
    end
    o = c.output
    if o !== nothing
        for (mime, ext) in (("application/pdf", "pdf"), ("image/svg+xml", "svg"))
            for ch in o.display
                ch.mime == mime && return (copy(ch.data), ext)
            end
        end
        vec = get(compfigs, (c.id, _VECTOR_SLOT), nothing)   # the figure's PDF, rendered for this export
        vec === nothing || return (copy(vec[1]), vec[2])
        for ch in o.display
            ch.mime == "image/png" && return (copy(ch.data), "png")
        end
    end
    comp = get(compfigs, (c.id, 0), nothing)         # a returned `slate_render` component, captured from the open tab
    comp === nothing || return (copy(comp[1]), comp[2])
    svg = _snapshot_svg(nb.id, c.id, theme)          # theme-matched vector chart, if the browser supplied one (live or pre-warmed)
    svg !== nothing && return (Vector{UInt8}(codeunits(svg)), "svg")
    png = _snapshot(nb.id, c.id)
    png !== nothing && return (copy(png), "png")
    return nothing
end

# Tell the open tab a chart is being rendered live for export — best-effort UI feedback (the
# activity log; see runstatus.js `onExportProgress`), never load-bearing for the export itself.
_export_progress(nb::LiveNotebook, cid::AbstractString) =
    (try; _broadcast(nb, "exportprog:" * JSON.json(Dict("cell" => cid))); catch; end; nothing)

# Pre-warm the SVG snapshot cache for every ECharts cell that doesn't already have one, via a
# live round-trip to an open browser tab — called BEFORE the caller takes `nb.lock` (each
# `request_live_eval` blocks up to its timeout; doing this under the notebook lock would stall
# every other operation on the notebook for the whole export). `progress` (optional) is called
# with each cell id as its round-trip starts, so the caller can report what's happening (a
# multi-chart export is the one case this is newly slower than the old eager-render design).
# Best-effort throughout: a cell that fails/times out just falls through to PNG in
# `_figure_for_export`, same as when no tab is open at all.
function _warm_chart_svgs!(nb::LiveNotebook; theme::AbstractString = "midnight", progress = nothing)
    targets = lock(nb.lock) do
        [c.id for c in nb.report.cells
         if c.output !== nothing && !isempty(c.output.echarts) && _snapshot_svg(nb.id, c.id, theme) === nothing]
    end
    for cid in targets
        progress === nothing || (try; progress(cid); catch; end)
        live = _live_render_svg(nb, cid; theme = theme)
        live === nothing && continue
        # Cache small ones so tweak-and-reexport doesn't re-pay the round-trip each time — but a
        # genuinely huge chart's SVG (a downsampled heatmap can still run to a few MB) isn't
        # worth holding onto forever; it's still used for THIS export, just re-rendered next time.
        sizeof(live) <= _LIVE_SVG_CACHE_MAX_BYTES && set_snapshot_svg!(nb.id, cid, theme, live)
    end
    return nothing
end

# The charts of the `{{ }}` values of the markdown cells, as `(cell, value, chart, width, height)`.
# `chart` is the number of the chart from 0 among the charts of the values of the cell, as the page
# state holds them (`_md_interp_echarts`). `width` is the width of the column of the value (`geo`,
# see `_figure_ctx`) and `height` half of it, at most the figure cap. A value with more than one chart
# gives its first.
_interp_chart_targets(nb::LiveNotebook, geo) = lock(nb.lock) do
    out = Tuple{String,Int,Int,Float64,Float64}[]
    for c in nb.report.cells
        is_prose(c.kind) && renders(c.kind) || continue
        k = 0
        for (i, o) in enumerate(c.interp)
            if !isempty(o.echarts)
                w = get(geo.width, (c.id, i), geo.body)
                push!(out, (c.id, i, k, w, geo.max_height === nothing ? w / 2 : min(w / 2, geo.max_height)))
            end
            k += length(o.echarts)
        end
    end
    out
end

# The picture of each chart of a `{{ }}` value, drawn by the open tab at the width of its column, into
# `figs` under `_hook_slot(value)`, the place of a picture that is drawn for its column: the markdown
# takes it as a hook figure (`_compfig_stager`), and an exporter as a staged picture. `present` gives
# the chart the slide styling of the live deck (a slides export). A value whose figure hook drew a
# picture keeps it. A chart that no tab drew, or that a tab with an older page of Slate answered for,
# adds a line to `warnings`. `draw(cell; theme, index, width, height, present)` asks the tab
# (`_live_interp_chart_svg`). Called before the caller takes `nb.lock`, like the other warm passes.
function _warm_interp_charts!(nb::LiveNotebook, figs::_CompFigs, warnings::Vector{String}, geo;
                              theme::AbstractString = "midnight", present::Bool = false, progress = nothing,
                              draw = (cid; kw...) -> _live_interp_chart_svg(nb, cid; kw...))
    lost, stale = String[], String[]
    for (cid, i, k, w, h) in _interp_chart_targets(nb, geo)
        haskey(figs, (cid, _hook_slot(i))) && continue
        progress === nothing || (try; progress(cid); catch; end)
        svg = draw(cid; theme, index = k, width = w, height = h, present)
        if svg === nothing
            push!(lost, cid)
        elseif svg == _STALE_TAB
            push!(stale, cid)
        else
            figs[(cid, _hook_slot(i))] = (Vector{UInt8}(codeunits(svg)), "svg")
        end
    end
    isempty(lost) || push!(warnings, string("No open tab of the notebook drew the chart of a `{{ }}` value, so the ",
                                            "export leaves it out. Open the notebook in a browser, then export again. ",
                                            "Cells: ", join(unique!(lost), ", "), "."))
    isempty(stale) || push!(warnings, string("The open tab of the notebook has a page of an older Slate, which cannot ",
                                             "draw the chart of a `{{ }}` value, so the export leaves it out. Reload ",
                                             "the tab, then export again. Cells: ", join(unique!(stale), ", "), "."))
    return figs
end

# The chart of each code cell on a slide, drawn by the open tab as the live deck draws it at figure
# scale 1 (`_live_slide_chart_svg`): its natural size scaled to fill its column (`geo`), at most the
# figure cap high, with the slide styling. It goes into `figs` under `_hook_slot(0)`, so the slide takes
# it as a hook picture, as wide as it is drawn. A cell whose figure hook drew a picture keeps it. With
# no open tab the chart keeps its picture at its notebook size (`_figure_for_export`); a tab with an
# older page of Slate adds a line to `warnings`. `draw(cell; theme, width, height)` asks the tab.
# Called before the caller takes `nb.lock`, like the other warm passes.
function _warm_slide_charts!(nb::LiveNotebook, figs::_CompFigs, warnings::Vector{String}, geo;
                             theme::AbstractString = "midnight", progress = nothing,
                             draw = (cid; kw...) -> _live_slide_chart_svg(nb, cid; kw...))
    targets = lock(nb.lock) do
        [c.id for c in nb.report.cells
         if !is_prose(c.kind) && c.output !== nothing && !isempty(c.output.echarts) && haskey(geo.width, (c.id, 0))]
    end
    stale = String[]
    for cid in targets
        haskey(figs, (cid, _hook_slot(0))) && continue
        progress === nothing || (try; progress(cid); catch; end)
        w = geo.width[(cid, 0)]
        svg = draw(cid; theme, width = w, height = something(geo.max_height, w))
        svg === nothing && continue
        svg == _STALE_TAB ? push!(stale, cid) : (figs[(cid, _hook_slot(0))] = (Vector{UInt8}(codeunits(svg)), "svg"))
    end
    isempty(stale) || push!(warnings, string("The open tab of the notebook has a page of an older Slate, so the chart ",
                                             "of a code cell has its notebook size on the slide. Reload the tab, then ",
                                             "export again. Cells: ", join(stale, ", "), "."))
    return figs
end

# Resolve the ECharts export theme (a Slate palette NAME the browser renders in) from the export
# request: an explicit `charttheme` (the "As-is" case sends the notebook's live palette; Light/Dark
# send "daylight"/"midnight") wins; otherwise fall back to the page theme's canonical palette so a
# caller that passes only `theme=` (older callers, tests) still gets a real Slate look.
_chart_theme(charttheme::AbstractString, theme::AbstractString) =
    isempty(strip(charttheme)) ? (theme == "dark" ? "midnight" : "daylight") : String(strip(charttheme))

# True when a cell carries a native, server-rendered figure (Makie's raster/vector) — the cells the
# themed-override path re-renders. ECharts (client-rendered) come through the SVG snapshot path, and a
# hand-authored `text/html` / inline-SVG card isn't a re-runnable native figure, so both are excluded.
_is_native_figure(c::Cell) = c.output !== nothing &&
    any(ch -> ch.mime in ("application/pdf", "image/png", "image/svg+xml"), c.output.display)

# Re-render every native figure under `theme` (a Slate palette) for a themed OVERRIDE export. Makie
# bakes its theme at build time, so honoring a Light/Dark override means re-running those cells under
# `with_theme(slate_theme(theme))` on the worker (see gate_kernel.jl `rerender_fig`). Called BEFORE the
# caller takes `nb.lock` (each round-trip re-evaluates a cell and can be slow), mirroring
# `_warm_chart_svgs!`. Best-effort: a cell whose re-render fails/times out falls back to its baked
# bytes in `_figure_for_export`. A non-gate (in-process) kernel has no worker to re-render on → skip.
# The worker a cell runs on, if it is running: the notebook's own, or its region's. An export only
# asks a worker that is already up; it does not start one.
_running_kernel(nb::LiveNotebook, region::AbstractString) =
    isempty(region) ? lock(() -> nb.kernel, nb.lock) :
    lock(() -> get(_REGION_KERNELS, (nb.id, String(region)), nothing), _REGION_LOCK)

function _warm_makie_figs!(nb::LiveNotebook; theme::AbstractString, raster::Bool = false, progress = nothing)
    targets = lock(nb.lock) do
        [(c.id, c.source, _cell_region(c)) for c in nb.report.cells if _is_native_figure(c)]
    end
    for (cid, src, region) in targets
        # A region cell re-runs where it ran: its data and packages are on the region's worker.
        k = _running_kernel(nb, region)
        k isa ReportEngine.GateKernel || continue
        progress === nothing || (try; progress(cid); catch; end)
        res = try; ReportEngine.rerender_fig(k, nb.report, src, theme; cellid = cid, raster = raster); catch; nothing; end
        res === nothing && continue
        set_snapshot_fig!(nb.id, cid, theme, raster, res[1], res[2])
    end
    return nothing
end

# ── Math and markdown outputs, typeset natively ─────────────────────────────────────────────────────
# A `text/latex` output, or the export-only `text/markdown` form of an HTML/LaTeX output (see
# `_capture_export_markdown!`), prints as real text and formulas through mitex/cmarker instead of a
# screenshot of the page.

# TeX with its `$`/`$$` delimiters stripped (`chop`, not byte slicing: `$θ$` ends in a multibyte char).
function _strip_math_delims(t::AbstractString)
    t = strip(t)
    startswith(t, "\$\$") && endswith(t, "\$\$") && length(t) >= 4 && return chop(t; head = 2, tail = 2)
    startswith(t, "\$") && endswith(t, "\$") && length(t) >= 2 && return chop(t; head = 1, tail = 1)
    return String(t)
end

# LaTeX written for KaTeX may use layout commands mitex doesn't know: struts (`\rule`), phantom
# widths, overlaps (`\mathllap`), negative `\hspace`, and row gaps (`\\[len]`, which mitex prints as
# text). They only adjust spacing, so they are dropped; the preamble's math rules space rows instead.
function _portable_tex(s::AbstractString)
    s = replace(String(s), r"\\rule(\[[^\]]*\])?\{[^}]*\}\{[^}]*\}" => "")
    s = _drop_braced(s, "\\hphantom")
    s = replace(s, "\\mathllap{" => "{", "\\mathrlap{" => "{")
    s = replace(s, r"\\hspace\{-[^}]*\}" => "")
    s = replace(s, r"\\\\\[[^\]]*\]" => "\\\\")
    # rows left empty by a dropped strut: a run of row breaks becomes one. (No backslashes just
    # before the closing quote: a raw string halves those.)
    return replace(s, r"(?:\\\\\s*){2,}" => "\\\\ ")
end

# `s` with every `cmd{…}` removed, the braces matched (they nest: `\hphantom{\begin{matrix}…}`).
function _drop_braced(s::String, cmd::String)
    while (r = findfirst(cmd * "{", s)) !== nothing
        depth, i = 0, last(r)
        while i <= lastindex(s)
            s[i] == '{' && (depth += 1)
            s[i] == '}' && (depth -= 1; depth == 0 && break)
            i = nextind(s, i)
        end
        s = s[1:prevind(s, first(r))] * s[nextind(s, min(i, lastindex(s))):end]
    end
    return s
end

# Whether Typst can typeset this math (`:tex`) or markdown (`:md`) through the export's own mitex and
# cmarker. A single unsupported command fails the whole compile, so each piece is tried alone first and
# one that fails falls back to the picture path. Cached by content: re-exports pay nothing.
const _TYPST_OK = Dict{UInt64, Bool}()
const _TYPST_OK_LOCK = ReentrantLock()
function _typst_typesets(kind::Symbol, content::AbstractString)
    key = hash((kind, content))
    cached = lock(() -> get(_TYPST_OK, key, nothing), _TYPST_OK_LOCK)
    cached === nothing || return cached
    ok = mktempdir() do dir
        pre = _typ_str(strip(replace(_MITEX_SHIMS, r"\s+" => " ")))
        write(joinpath(dir, "piece." * String(kind)), content)
        body = kind === :md ? "#cmarker.render(read(\"piece.md\"), math: mathfn, scope: (image: (src, alt: none) => []))" :
                              "#mathfn(read(\"piece.tex\"), block: true)"
        write(joinpath(dir, "check.typ"), """
            #import "@preview/cmarker:$(_CMARKER_VER)"
            #import "@preview/mitex:$(_MITEX_VER)": mitex, mi
            #let PRE = "$pre "
            #let mathfn = (s, block: false) => if block { mitex(PRE + s) } else { mi(PRE + s) }
            $body
            """)
        try
            _typst_compile(joinpath(dir, "check.typ"), joinpath(dir, "check.pdf")); true
        catch
            false
        end
    end
    lock(() -> (_TYPST_OK[key] = ok), _TYPST_OK_LOCK)
    return ok
end

_output_chunk(o, mime) = (i = findfirst(ch -> ch.mime == mime, o.display); i === nothing ? nothing : String(copy(o.display[i].data)))
_has_figure_bytes(o) = any(ch -> ch.mime in ("application/pdf", "image/svg+xml", "image/png"), o.display)

# The display size `(w, h)` in px of the first video track of an MP4 or QuickTime file: the width and
# the height of its `tkhd` box (16.16 fixed point). A browser shows a video at this natural size.
# `nothing` when the file gives no size.
_mp4_size(path::AbstractString) = try open(io -> _mp4_walk(io, filesize(path)), path) catch; nothing end
function _mp4_walk(io::IO, stop::Integer)
    while position(io) + 8 <= stop
        start = position(io)
        n, typ = Int(ntoh(read(io, UInt32))), String(read(io, 4))
        n == 1 && (n = Int(ntoh(read(io, UInt64))))
        n == 0 && (n = stop - start)
        n < 8 && return nothing
        if typ in ("moov", "trak")
            sz = _mp4_walk(io, start + n)
            sz === nothing || return sz
        elseif typ == "tkhd"
            skip(io, read(io, UInt8) == 1 ? 87 : 75)   # to the width, after the version byte
            w, h = ntoh(read(io, UInt32)) / 65536, ntoh(read(io, UInt32)) / 65536
            w > 0 && h > 0 && return (w, h)           # a sound track has 0 × 0
        end
        seek(io, start + n)
    end
    return nothing
end

# The Typst text that draws the video or audio file `clip` of a figure block in place of its markdown
# file `file` (the alt text): `clipfig` of the slides preamble. The label is the alt text, else the file
# name. A video gives the aspect of the file, else that of 300 × 150, the size that the live deck gives a
# video with no known size (the default size of a CSS replaced element); `drawfig` fills the column with it.
function _clip_typ(clip::AbstractString, text::AbstractString, file::AbstractString)
    audio = startswith(_site_ctype(clip), "audio/")
    w, h = audio ? (0, 0) : something(_mp4_size(clip), (300, 150))
    label = isempty(strip(replace(text, r"</?slate-figure>" => ""))) ? string("\"", _typ_str(basename(clip)), "\"") : _md_render(file)
    return string("#clipfig(\"", audio ? "audio" : "video", "\", ", w, ", ", h, ", ", label, ")")
end

# Write the markdown `md` of an output (block kinds marked) to `file` and print its `cmarker` call
# through `blk`, with `tail` after it. On a slide (`blk` is a `_block_printer`) each block of `md` is a
# block of the layout source, split by the rules of a markdown cell, in a file of its own. A figure
# block gets the video or audio file of its media mark (`_take_media_marks`) as its `file`, and draws
# its placeholder (`_clip_typ`).
function _emit_output_md!(io::IO, dir, file, md, tail, blk)
    parts = blk === _plain_block ? [(kind = "prose", text = md)] : ReportRender._md_split(md)
    for (k, b) in enumerate(parts)
        f = k == 1 ? file : string(chopsuffix(file, ".md"), "_", k, ".md")
        text, clip = _take_media_marks(b.text)
        clip = b.kind == "figure" ? clip : nothing
        write(joinpath(dir, f), text)
        print(io, blk(b.kind, string(clip === nothing ? "#" * _md_render(f) : _clip_typ(clip, text, f), tail); src = text, file = clip))
    end
end

# Emit an output's markdown or math form natively; false if it has neither, or Typst can't set it.
# `stage` gets the markdown before it is written (see `_emit_output!`).
function _emit_typeset_output!(io::IO, dir::AbstractString, base::AbstractString, o; blk = _plain_block, stage = identity)
    _has_figure_bytes(o) && return false
    md = _output_chunk(o, "text/markdown")
    if md !== nothing
        src = _normalize_math_delims(md; tex = _portable_tex)
        if _typst_typesets(:md, src)
            _emit_output_md!(io, dir, base * ".md", stage(ReportRender._md_kinds(src; plain = true)), "\n", blk)
            return true
        end
    end
    tex = _output_chunk(o, "text/latex")
    if tex !== nothing
        src = _portable_tex(_strip_math_delims(tex))
        if _typst_typesets(:tex, src)
            write(joinpath(dir, base * ".tex"), src)
            print(io, blk("prose", string("#align(center, mathfn(read(\"", base, ".tex\"), block: true))\n")))
            return true
        end
    end
    return false
end

# True if the cell's output includes an HTML chunk (a custom card Typst can't render) — either a
# hand-rolled `text/html` show method or `slate_render`'s `html_fragment` escape hatch. Both are
# arbitrary DOM with no figure bytes behind them, so both want the same DOM-raster rescue; matching
# only `text/html` left every `html_fragment` output (a WGLMakie figure among them) out of the PDF.
_has_html_output(c::Cell) = c.output !== nothing &&
    any(ch -> ch.mime in ("text/html", "application/vnd.kaimonslate.html+html"), c.output.display)

# The finished state of a `slide_figure` output (slide_figure.jl): the last PNG its block names (the last
# state's image, or the poster frame of a final clip), read from the cell's saved assets. `nothing` for
# any other output.
function _slidefig_final_png(o)
    for ch in o.display
        ch.mime in ("text/html", "application/vnd.kaimonslate.html+html") || continue
        h = String(copy(ch.data))
        occursin("class=\"slidefig\"", h) || continue
        last = nothing
        for m in eachmatch(r"data-slate-(?:src|poster)=\"([^\"]+\.png)\"", h)
            last = m.captures[1]
        end
        last === nothing && continue
        for a in o.assets
            String(getfield(a, :path)) == last && return _asset_bytes(a)
        end
    end
    return nothing
end

# Emit a code cell's outputs (value / stdout / error / figure / tables) into the doc.
# Export output-verbosity: `"all"` (everything), `"figures"` (only figures / charts / tables / rendered
# math — drop scalar text reprs, stdout, and errors, the "working output" noise), `"none"` (nothing).
# Each output goes through `blk(kind, typ)`, which gives the Typst text to print for it. On a slide
# each output is one block of the layout source (`_block_printer`); a document prints `typ` as it is.
_outputs_text_ok(outputs) = String(outputs) == "all"
_outputs_any(outputs) = String(outputs) != "none"
_plain_block(kind, typ; kw...) = typ

function _emit_output!(io::IO, dir::AbstractString, base::AbstractString, nb::LiveNotebook, c::Cell;
                       theme::AbstractString = "light", charttheme::AbstractString = "",
                       override::Bool = false, outputs::AbstractString = "all",
                       compfigs::_CompFigs = _NO_COMPFIGS, blk = _plain_block, warnings = nothing)
    put(kind, parts...) = print(io, blk(kind, string(parts...)))
    # The images of a markdown output are staged as those of a markdown cell (`warnings` gets a line
    # for each image whose file is not in the project).
    stage(md) = _stage_typst_md_media(md, dir, base * "_out", _proj_root(nb); warnings, cell = c.id, media = true)
    o = c.output
    (o === nothing || !_outputs_any(outputs)) && return
    texts = _outputs_text_ok(outputs)
    # Captured text carries colour (the page renders it as spans). Typst typesets these sidecar
    # files literally, so the escape codes have to come off or they print as visible garbage. Every
    # text field, not just stdout: a package whose `show`/`showerror` colours unconditionally
    # (ignoring the stream's `:color`) puts it in the value repr and the error too.
    plain = ReportEngine.strip_sgr
    if o.exception !== nothing
        texts || return                                # figures-only: skip error text
        write(joinpath(dir, base * ".err"), rstrip(plain(o.exception)))
        put("code", "#errblock(read(\"", base, ".err\"))\n")
        return
    end
    if texts && !isempty(strip(o.stdout))
        write(joinpath(dir, base * ".out"), rstrip(plain(o.stdout)))
        put("code", "#outblock(read(\"", base, ".out\"))\n")
    end
    # A figure hook that gave a picture wins over the text forms of the value too.
    hooked = haskey(compfigs, (c.id, _hook_slot(0)))
    md = hooked ? nothing : ReportRender._markdown_output(o)
    if md !== nothing
        # Prose: typeset as a markdown cell's would be, rather than rasterized as HTML.
        _emit_output_md!(io, dir, base * "_out.md", stage(ReportRender._md_kinds(_normalize_math_delims(md); plain = true)), "\n\n", blk)
        return
    end
    if texts && isempty(o.display) && !isempty(o.value_repr)
        val = plain(o.value_repr)
        write(joinpath(dir, base * ".val"), val)
        # The `text/plain` value is the one output whose text an exporter gets, as a code block.
        print(io, blk("code", string("#valblock(read(\"", base, ".val\"))\n");
                      src = strip(ReportEngine._md_fence_block("", val), '\n') * "\n"))
    end
    # Math, and HTML with a markdown form, print as text and formulas — ahead of any page snapshot.
    if !hooked && _emit_typeset_output!(io, dir, base, o; blk, stage)
        for spec in _table_specs(c)
            put("table", _typst_table(spec; theme = theme))
        end
        return
    end
    fig = _figure_for_export(nb, c; theme = _chart_theme(charttheme, theme), override = override,
                             compfigs = compfigs)   # vector (pdf/svg) preferred, else raster png
    # An HTML output (a custom `text/html` card, e.g. the grading `check(...)` cells) can't be
    # rendered by Typst and isn't an embeddable figure — so rasterize the rendered card via the open
    # tab (the same round-trip slate.inspect uses) and embed that image. Needs a live tab;
    # falls back to nothing (just the code) if none is open or the capture times out.
    # A `slide_figure` carries its states as PNGs; print shows the finished one, no tab needed.
    fig === nothing && (sf = _slidefig_final_png(o); sf === nothing || (fig = (sf, "png")))
    if fig === nothing && _has_html_output(c)
        # `cell_image`, not `cell_image_fresh`: `_warm_html_rasters!` already asked the tab for
        # every one of these in a single round-trip, so this is a store read. Asking again here
        # would reintroduce the per-cell wait the batch exists to remove.
        png = try; cell_image(nb, c.id); catch; nothing; end
        png === nothing || (fig = (copy(png), "png"))
    end
    if fig !== nothing
        data, ext = fig
        write(joinpath(dir, base * "." * ext), data)
        # A component keeps its on-screen proportions rather than filling the column like a figure
        # the author sized for print; a hook picture has the size of the live value (`natural-w`);
        # everything else takes `figureimg`'s default.
        pct = _has_component(o) && !hooked ? _comp_fig_width_pct(data, ext) : nothing
        opts = string(pct === nothing ? "" : ", width: $(pct)%", hooked ? ", hook: true" : "")
        print(io, blk("figure", string("#figureimg(\"", base, ".", ext, "\"", opts, ")\n");
                      file = base * "." * ext))
    elseif !isempty(_echarts_specs(c))
        # A client-rendered chart that no browser tab was open to snapshot (headless export) —
        # don't silently drop it, note the gap (mirrors the HTML export path).
        put("prose", "#notefig(\"[chart not captured — open this notebook in a browser, then re-export]\")\n")
    elseif _has_component(o)
        put("prose", "#notefig(\"[component not captured — open this notebook in a browser, then re-export]\")\n")
    elseif _hook_output(o)
        put("prose", "#notefig(\"[figure not captured — run this cell with its ▶ button, then re-export]\")\n")
    elseif _has_html_output(c)
        put("prose", "#notefig(\"[figure not captured — open this notebook in a browser, then re-export]\")\n")
    end
    for spec in _table_specs(c)
        put("table", _typst_table(spec; theme = theme))
    end
    return
end

# A frozen snapshot of a cell's `@bind` controls: a PDF is static, so interactive
# widgets are typeset as a compact "parameter" strip showing each control at its
# current value (what the reader is looking at). Empty string when the cell has none.
function _emit_controls(c::Cell)::String
    isempty(c.binds) && return ""
    item(b) = "(" * "\"" * _typ_str(string(b.name)) * "\", \"" *
              _typ_str(_bind_text(b)) * "\")"
    return "#paramblock((" * join((item(b) for b in c.binds), ", ") *
           (length(c.binds) == 1 ? ",))\n" : "))\n")
end

# Render a control's current value for the parameter strip (concise, no type noise).
function _bind_value_repr(v)::String
    v isa AbstractFloat && return string(round(v; sigdigits = 6))
    v isa AbstractString && return String(v)
    return string(v)
end

# The text of a control's value for the parameter strip. A keyed option widget (see `_norm_options`
# in widgets.jl) holds `#opt:` keys: show the label of each key, as the live page does.
function _bind_text(b)::String
    v, opts = b.value, get(b.params, "options", nothing)
    iskey(x) = x isa AbstractString && startswith(x, "#opt:")
    (opts isa AbstractVector && (iskey(v) || v isa AbstractVector && any(iskey, v))) || return _bind_value_repr(v)
    label(k) = (i = findfirst(o -> o isa AbstractDict && get(o, "value", nothing) == k, opts);
                i === nothing ? _bind_value_repr(k) : string(opts[i]["label"]))
    return v isa AbstractVector ? join(map(label, v), ", ") : label(v)
end

# Run the Typst command `sub` (`compile`, `query`) on a .typ, preferring a system `typst`, else the
# bundled Typst_jll. `--root` is the project dir so read()/image() of the per-cell aux files resolve
# (Typst sandboxes IO). A `fonts` subdirectory of it (a deck template may ship fonts there) is added
# as a font path. `rest` follows the input file; the command's stdout goes to `out`.
# Every stream is given explicitly: a detached host process can have its stdin/stdout closed, and
# a child that inherits a closed descriptor fails to spawn (EBADF).
# Typst_jll is used in its `Cmd` form, which carries its own environment: the do-block form changes
# the process `ENV` and restores it, so two runs at the same time (the compile and the query of a
# slides PDF) can restore each other's `ENV`.
function _typst_run(sub::String, typ::String, rest::Vector{String}; out::Union{IO,Nothing} = nothing)
    root = dirname(typ)
    fonts = joinpath(root, "fonts")
    fontflags = isdir(fonts) ? ["--font-path", fonts] : String[]
    sys = Sys.which("typst")
    exe = sys === nothing ? Typst_jll.typst() : `$sys`
    err = IOBuffer()
    try
        run(pipeline(`$exe $sub --root $root $fontflags $typ $rest`; stdin = devnull, stdout = something(out, err), stderr = err))
    catch e
        # `run` throws only `ProcessExited(1)` — useless on its own. Surface Typst's actual diagnostic
        # (the source line + reason) so an export failure is debuggable instead of opaque.
        msg = strip(String(take!(err)))
        isempty(msg) && rethrow()
        error("typst $sub failed:\n" * first(msg, 4000))
    end
    return
end

_typst_compile(typ::String, pdf::String) = _typst_run("compile", typ, [pdf])

# The values of the metadata elements that `selector` (for example "<slate>") finds in the document.
# `typst query` compiles the document again. `marks` turns on the block and region marks of a slides
# project (`slate-mark` of its preamble), so that their records are among the values.
function _typst_query(typ::String, selector::AbstractString; marks::Bool = false)
    out = IOBuffer()
    _typst_run("query", typ, [String(selector), "--field", "value", (marks ? ["--input", "slate-marks=1"] : String[])...]; out)
    return JSON.parse(String(take!(out)))
end

# The box `(x, y, w, h)` of a mark record, in `u`.
_mark_box(r) = (x = Float64(r["x"]), y = Float64(r["y"]), w = Float64(r["w"]), h = Float64(r["h"]))

# An export warning for each region of a slide (a `region` record of the marks) that is out of its
# area, or over another region or a block. A region is out of its area when it is taller than its
# container, or when it is not inside the page; `canvas` is the page size in `u`. Boxes that only
# touch are not over each other: the check lets them share 1 u. `label(p)` names page `p` in the
# warning (`_page_label`).
function _region_warnings(records, canvas, label)
    W, H = canvas
    of(kind) = [r for r in records if r isa AbstractDict && get(r, "kind", "") == kind]
    over(a, b) = a.x < b.x + b.w - 1 && b.x < a.x + a.w - 1 && a.y < b.y + b.h - 1 && b.y < a.y + a.h - 1
    regions, blocks = of("region"), of("block")
    out = String[]
    for (i, r) in enumerate(regions)
        b, p, name = _mark_box(r), r["page"], r["name"]
        ah = get(r, "ah", nothing)
        (b.x < -1 || b.y < -1 || b.x + b.w > W + 1 || b.y + b.h > H + 1 || (ah !== nothing && b.h > ah + 1)) &&
            push!(out, "$(label(p)): the $name region is out of its area.")
        for q in @view regions[i+1:end]
            q["page"] == p && over(b, _mark_box(q)) && push!(out, "$(label(p)): the $name region is over the $(q["name"]) region.")
        end
        for k in blocks
            k["page"] == p && over(b, _mark_box(k)) && push!(out, "$(label(p)): the $name region is over a block of cell $(k["cell"]).")
        end
    end
    return out
end

# An export warning for each slide that a fit record marks at the floor. `label(n)` names the number
# `n` of the record: the deck print gives the live index of the slide, the slides preamble `fit` the
# page of the PDF (`_page_label`).
_fit_warnings(records; label = n -> "Slide $n") =
    ["$(label(r["slide"])) does not fit at the smallest text size: its end runs past the page bottom."
     for r in records if r isa AbstractDict && get(r, "kind", "") == "fit" && get(r, "at_floor", false) === true]

# The name of page `p` of a slides PDF in a warning: "Slide N", with N the number of its slide in the
# deck (`plan.pages`). The PDF drops a slide with no content and gives a title cell its own page, so a
# page number is not always the slide number. A page that holds no slide of the deck (the references,
# the notes) is "Page p".
_page_label(plan, p) = (si = get(plan.pages, p, 0); si > 0 ? "Slide $si" : "Page $p")

# An export warning for each key of the `draw` dictionary of a deck template that is no block kind
# (the warning records of `_SLIDES_TAIL`).
_draw_warnings(records) =
    ["The deck template sets `draw.$(r["key"])`, which is not a block kind (" * join(ReportRender._WRAPPED_KINDS, ", ") *
     "). Slate does not use it."
     for r in records if r isa AbstractDict && get(r, "kind", "") == "warning" && get(r, "about", "") == "draw"]

# The export warnings of a slides PDF from the records of its marks compile: the checks of the deck
# settings, the `draw` keys, the slides at the fit floor, the regions out of place, then `figwarns`.
# `plan` is the plan of the slides project (`_SlidePlan`): it maps a page to its slide.
function _slides_warnings(nb::LiveNotebook, recs, figwarns, plan)
    label = p -> _page_label(plan, p)
    return vcat(notebook_deck_settings(nb).warnings, _draw_warnings(recs), _fit_warnings(recs; label),
                _region_warnings(recs, deck_canvas(String(get(nb.report.meta, "slideratio", "16:9"))), label), figwarns)
end

# One export warning for each part of slide `si` that stopped with an error: a code cell whose output
# is an error, and a `{{ }}` of a markdown cell that threw (the export leaves its value out). `parts`
# holds `(cell, src, interpbase)` as the fragments of `slide_deck` do; `src === nothing` is the whole
# cell.
function _error_warnings!(warnings::Vector{String}, si::Integer, parts)
    line(e) = (l = first(split(strip(ReportEngine.strip_sgr(e)), '\n')); length(l) > 120 ? first(l, 119) * "…" : l)
    for (c, src, ib) in parts
        if is_prose(c.kind)
            exprs = ReportEngine._md_template(something(src, c.source))[2]
            for (i, e) in enumerate(exprs)
                o = get(c.interp, ib + i, nothing)
                (o === nothing || o.exception === nothing) && continue
                f = ReportEngine._fence_call(e)
                what = f === nothing ? string("`{{ ", length(strip(e)) > 60 ? first(strip(e), 59) * "…" : strip(e), " }}`") :
                       string("the `", f.lang, "` code block")
                push!(warnings, string("Slide ", si, ", cell ", c.id, ": ", what,
                                       " stopped with an error, so the export leaves its value out: ", line(o.exception)))
            end
        elseif c.output !== nothing && c.output.exception !== nothing
            push!(warnings, string("Slide ", si, ", cell ", c.id, ": the cell stopped with an error, so its output is the error: ",
                                   line(c.output.exception)))
        end
    end
end

"""
    export_pdf(nb; include_source=true, style="article", columns=1,
               theme="light", code="normal", body="normal") -> Vector{UInt8}

Render the notebook to a publication-quality PDF via Typst and return the bytes.
`style ∈ ("article", "report")` picks a layout preset; `columns ∈ (1, 2)` lays the body
out single- or two-column; `theme ∈ ("light", "dark")` sets the colour scheme (dark
matches the live UI and Makie-dark figures). `code ∈ ("normal","small","smaller","tiny")`
sets the code-listing font size, or `"hidden"` to omit source entirely (also honoured via
`include_source`). `body ∈ ("large","normal","compact","small")` sets the prose font size
(defaults to "compact" for two-column). Figures use vector data when available (CairoMakie
PDF, ECharts SVG). `@bind` controls are omitted by default (a PDF is a static snapshot);
set `include_params=true` to show them frozen to their current values as a parameter strip.

Document metadata is authored as role-tagged cells (`#%% md id=… title` / `abstract` /
`bibliography`): the title/abstract are hoisted into an academic title block. With no `title`
cell the document title falls back to the first markdown H1 (then the notebook filename).
"""
export_pdf(nb::LiveNotebook; kwargs...) = first(_export_pdf_report(nb; kwargs...))

# `export_pdf` and the export warnings of the PDF: the figure warnings of every layout (a figure hook
# that threw, figures from stored output) and, for slides, the checks of the deck settings, the
# slides at the fit floor and the regions that are out of place.
# For slides, the query of the marks runs as a second Typst process beside the compile. The compile
# always waits for it, so no `typst` process stays behind, and a compile error is the error of the
# export. A query that fails does not stop the export: it gives one warning, with the reason from
# Typst.
function _export_pdf_report(nb::LiveNotebook; kwargs...)
    figwarns = String[]
    plan = _SlidePlan()                                    # a slides project writes its pages here
    dir = _build_typst_project(nb; warnings = figwarns, plan, kwargs...)
    try
        typ = joinpath(dir, "doc.typ"); pdf = joinpath(dir, "out.pdf")
        slides = get(kwargs, :layout, "") == "slides"
        query = slides ? @async(try _typst_query(typ, "<slate>"; marks = true) catch e; e end) : nothing
        try
            _typst_compile(typ, pdf)
        finally
            query === nothing || wait(query)
        end
        slides || return read(pdf), figwarns
        recs = fetch(query)
        recs isa Exception || return read(pdf), _slides_warnings(nb, recs, figwarns, plan)
        # The reason is the first `error:` line of Typst (its warnings come first), else the first line.
        lines = split(replace(sprint(showerror, recs), r"^typst query failed:\n" => ""), '\n')
        why = strip(lines[something(findfirst(startswith("error:"), lines), 1)])
        qwarn = "The layout check of the slides did not run, so the export cannot warn about a slide that does not fit " *
                "or a region that is out of place. Typst says: " * (length(why) > 200 ? first(why, 199) * "…" : why)
        return read(pdf), _slides_warnings(nb, Any[], [qwarn; figwarns], plan)
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ── Slide segmentation (shared boundary rules; mirrored in assets/js/slides.js) ───────────────────
# A notebook becomes a deck by grouping its cells into slides. Boundaries:
#   1. a markdown cell whose first heading is at depth ≤ `level` (default H2),
#   2. any cell flagged `:slide` (explicit start),
#   3. a thematic-break line (`---`) inside a markdown cell (splits it mid-cell),
#   4. a cell flagged `:notes` attaches to the current slide's speaker notes (not its body),
#   5. cells before the first boundary form the leading (title) slide.
# `:collapsed` cells are omitted, matching the article/report export.

# Depth of a markdown source's first ATX heading (skipping fenced code), or `nothing`.
function _first_heading_depth(src::AbstractString)
    infence = false
    for ln in split(src, '\n')
        if occursin(r"^\s*(```|~~~)", ln); infence = !infence; continue; end
        infence && continue
        m = match(r"^(#{1,6})\s+\S", ln)
        m === nothing || return length(m.captures[1])
    end
    return nothing
end

# Split a markdown source on thematic-break lines (`---`/`***`/`___`, 3+), skipping fenced code
# and a leading YAML front-matter block (its `---` fences are NOT slide breaks). Returns the
# inter-break chunks (≥1); a source with no rule returns `[src]`.
function _split_md_rules(src::AbstractString)
    parts = String[]
    buf = IOBuffer(); infence = false
    lines = split(src, '\n')
    for ln in lines
        if occursin(r"^\s*(```|~~~)", ln); infence = !infence; print(buf, ln, '\n'); continue; end
        if !infence && occursin(r"^\s*([-*_])(\s*\1){2,}\s*$", ln)
            push!(parts, String(take!(buf))); continue
        end
        print(buf, ln, '\n')
    end
    push!(parts, String(take!(buf)))
    return parts
end

# A slide: ordered body fragments plus the `:notes` cells attached to it. `src` is a `---`-split
# markdown chunk, or `nothing` for the whole cell. `interpbase` is how many of the cell's `{{ }}`
# interpolations precede this chunk: a chunk is numbered from 1 by `_md_template` while `Cell.interp`
# is numbered across the whole cell, so the chunk has to carry where it starts. It is computed here,
# where the chunks are cut in order, rather than left to whoever renders one.
const SlideFrag = NamedTuple{(:cell, :src, :interpbase),Tuple{Cell,Union{String,Nothing},Int}}

function _slide_segments(cells; level::Integer = 2)
    slides = NamedTuple{(:frags, :notes),Tuple{Vector{SlideFrag},Vector{Cell}}}[]
    frags = SlideFrag[]; notes = Cell[]
    function flush!()
        (isempty(frags) && isempty(notes)) && return
        push!(slides, (frags = frags, notes = notes))
        frags = SlideFrag[]; notes = Cell[]
    end
    for c in cells
        (:collapsed in c.flags) && continue
        if :notes in c.flags
            push!(notes, c); continue
        end
        d = is_prose(c.kind) ? _first_heading_depth(c.source) : nothing
        starts = (:slide in c.flags) || (d !== nothing && d <= level)
        if is_prose(c.kind) && length(_split_md_rules(c.source)) > 1
            base = 0                                  # interpolations consumed by the chunks so far
            for (j, part) in enumerate(_split_md_rules(c.source))
                ((j == 1 && starts) || j > 1) && flush!()
                isempty(strip(part)) ||
                    push!(frags, (cell = c, src = String(part), interpbase = base))
                base += _md_interp_count(part)        # counted even for a skipped blank chunk
            end
        else
            starts && flush!()
            push!(frags, (cell = c, src = nothing, interpbase = 0))
        end
    end
    flush!()
    return slides
end

# The ATX heading that opens a markdown source, if its first non-blank line is one: its depth, its
# text (closing `#`s dropped) and the source after it, without the blank lines that follow.
function _split_leading_heading(src::AbstractString)
    lines = split(src, '\n')
    i = findfirst(l -> !isempty(strip(l)), lines)
    i === nothing && return nothing
    m = match(r"^ {0,3}(#{1,6})[ \t]+(\S.*?)[ \t]*$", lines[i])
    m === nothing && return nothing
    text = replace(m.captures[2], r"[ \t]+#+$" => "")
    rest = replace(join(lines[i+1:end], '\n'), r"\A(?:[ \t]*\n)+" => "")
    return (depth = length(m.captures[1]), text = String(text), rest = String(rest))
end

"""
    slide_deck(nb; level = <the notebook's slide level>, drop = Returns(false)) -> Vector{NamedTuple}

The slide model of a notebook: one entry per slide, in order, from the same segmentation as the live
deck (`_slide_segments`). Plain Base types only. Internal: it is not exported.

Each entry has these fields:

- `layout`, `transition`, `auto`: the value of the `layout=`, `transition=` and `auto=` tag of the
  first cell of the slide that has it, as a string, or `nothing`.
- `title`: `nothing`, or `(text, depth, cell, interpbase)` when the first block of the slide is a
  markdown heading. `text` is the heading without its `#` marks, `depth` is 1 to 6, `cell` is the id of
  the cell that holds it. The heading is not in `frags`.
- `frags`: the body, in order. Each fragment is `(cell, src, interpbase, row, column)`: the cell id,
  the markdown to draw (`nothing` is the whole cell), the number of `{{ }}` interpolations before it in
  its cell, the side-by-side row that it belongs to, and its `column=` value.
- `notes`: the ids of the `notes` cells that belong to the slide.

`drop(cell)` removes a cell from the fragments, and so from the title search; the entry stays in the deck
so that slide numbers stay stable.
"""
function slide_deck(nb::LiveNotebook; level::Integer = get(nb.report.meta, "slidelevel", 2), drop = Returns(false))
    cells = filter(c -> renders(c.kind), nb.report.cells)
    deck = NamedTuple[]
    for seg in _slide_segments(cells; level = level)
        function tag(k)                                  # the first cell's value wins
            for f in seg.frags
                v = ReportEngine._tag_value(f.cell.flags, k * "=")
                isempty(v) || return String(v)
            end
            return nothing
        end
        frags = filter(f -> !drop(f.cell), seg.frags)
        title = nothing
        if !isempty(frags) && is_prose(frags[1].cell.kind)
            f = frags[1]
            src = f.src === nothing ? f.cell.source : f.src
            h = _split_leading_heading(src)
            if h !== nothing
                title = (text = h.text, depth = h.depth, cell = f.cell.id, interpbase = f.interpbase)
                taken = _md_interp_count(src) - _md_interp_count(h.rest)   # interpolations in the heading
                frags[1] = (cell = f.cell, src = h.rest, interpbase = f.interpbase + taken)
                isempty(strip(h.rest)) && popfirst!(frags)
            end
        end
        body = NamedTuple[]
        row = 0
        for f in frags
            col = _cell_column(f.cell)
            (col >= 2 && row > 0) || (row += 1)
            push!(body, (cell = f.cell.id, src = f.src, interpbase = f.interpbase, row = row, column = col))
        end
        push!(deck, (layout = tag("layout"), title = title, frags = body, transition = tag("transition"),
                     auto = tag("auto"), notes = [n.id for n in seg.notes]))
    end
    return deck
end

# ── Document metadata from role-tagged cells (title / abstract / bibliography) ────────────────────
# Metadata is authored as ordinary cells carrying a role tag, in natural document order, and each
# export target interprets the role for placement. `title`/`subtitle`/`byline` come from a `:title`
# cell's markdown (H1 / H2-H3 / first plain line); `:abstract` cell(s) supply the abstract; both are
# hoisted into the title block and dropped from the body (their ids land in `skip`). With no `:title`
# cell, the document title falls back to the first markdown H1 (then the notebook filename). One
# resolver for PDF, slides, and HTML.
#
# `_title_cell` gives the parts of a `title` cell. `title`, `subtitle` and `byline` are plain text: the
# first H1, the first H2 or H3, and the first paragraph that is no heading. `marked` is the markdown of
# the cell with the subtitle in a `<slate-subtitle>` element and the byline in a `<slate-byline>`
# element. The live deck draws `marked`, and each target reads the regions of the title slide from
# this one function. `rest` is the markdown of the lines that are no region: the body blocks of the
# title slide. `sublevel` is the heading level of the subtitle, 2 or 3 (3 when there is no subtitle).
function _title_cell(src)
    # The byline/subtitle are usually authored with markdown emphasis (`*A pipeline over…*`), but
    # the title block renders them as PLAIN Typst text — literal asterisks in the PDF. The block
    # already styles them, so strip one surrounding emphasis layer rather than render markdown.
    unemph(s) = begin
        t = strip(String(s))
        for d in ("***", "**", "*", "__", "_")
            if startswith(t, d) && endswith(t, d) && ncodeunits(t) > 2ncodeunits(d)
                return strip(t[nextind(t, firstindex(t), length(d)):prevind(t, lastindex(t), length(d))])
            end
        end
        return t
    end
    lines = split(String(src), '\n')
    title = ""; subtitle = ""; byline = ""; sublevel = 3
    marked = String[]; rest = String[]
    region!(tag, ls) = append!(marked, ["", "<slate-$tag>", "", ls..., "", "</slate-$tag>", ""])
    plain(l) = !isempty(strip(l)) && !startswith(strip(l), "#")
    i = 1
    while i <= length(lines)
        ln = lines[i]
        if isempty(title) && (m = match(r"^#\s+(.+?)\s*#*$", ln)) !== nothing
            title = unemph(m.captures[1])
            push!(marked, ln)
        elseif isempty(subtitle) && (m = match(r"^(#{2,3})\s+(.+?)\s*#*$", ln)) !== nothing
            subtitle = unemph(m.captures[2])
            sublevel = length(m.captures[1])
            region!("subtitle", [ln])
        elseif isempty(byline) && plain(ln)
            j = i                                    # the paragraph runs to an empty line or a heading
            while j < length(lines) && plain(lines[j+1]); j += 1; end
            byline = unemph(join((strip(l) for l in lines[i:j]), " "))
            region!("byline", lines[i:j])
            i = j
        else
            push!(marked, ln); push!(rest, ln)
        end
        i += 1
    end
    return (; title, subtitle, byline, sublevel, marked = join(marked, "\n"), rest = String(strip(join(rest, "\n"))))
end
_parse_title_cell(src) = (t = _title_cell(src); (t.title, t.subtitle, t.byline))

# `report_frontmatter` adds `rolecell`, the id of the `title` cell ("" with none), and `rest`, the
# markdown of that cell that is no region. `untitled` is the title when no cell gives one: the title of
# the report (a loaded notebook has its file name there) for a document, "" for the deck value.

function report_frontmatter(report; untitled::AbstractString = report.title)
    cells = report.cells
    title = untitled; subtitle = ""; byline = ""; abstract = ""; sublevel = 3
    skip = Set{String}(); titlecell = ""; rolecell = ""; rest = ""
    titlei = findfirst(c -> :title in c.flags, cells)
    if titlei !== nothing
        tc = _title_cell(cells[titlei].source)
        isempty(tc.title) || (title = tc.title); subtitle = tc.subtitle; byline = tc.byline; rest = tc.rest
        sublevel = tc.sublevel
        rolecell = cells[titlei].id
        push!(skip, rolecell)
    else
        # No explicit `title` role tag → derive the document title from the FIRST markdown H1, so
        # exports read the real title instead of the notebook filename. The cell KEEPS its other
        # content in the body, but its leading H1 is stripped (via `titlecell`) so the title doesn't
        # render twice — once hoisted, once as a body heading.
        for c in cells
            is_prose(c.kind) || continue
            m = match(r"(?m)^#[ \t]+(.+?)[ \t]*#*$", c.source)
            m === nothing && continue
            title = strip(m.captures[1]); titlecell = c.id; break
        end
    end
    abscells = Cell[c for c in cells if :abstract in c.flags]
    if !isempty(abscells)
        abstract = join((strip(c.source) for c in abscells), "\n\n")
        for c in abscells; push!(skip, c.id); end
    end
    bibcells = Cell[c for c in cells if :bibliography in c.flags]
    has = titlei !== nothing || !isempty(strip(abstract))
    return (; title, subtitle, byline, sublevel, abstract, skip, bibcells, titlecell, has, rolecell, rest)
end

# ── Figure captions + numbering ───────────────────────────────────────────────────────────────
# A caption is an ORDINARY markdown cell tagged `caption` (so it carries full markdown / $math$ /
# {{ }} / [@cite]). It attaches to a figure cell either by FLOW (the nearest preceding figure-bearing
# cell) or EXPLICITLY (`for=<id>`), and cross-refs resolve `[@fig:<label>]` → "Figure N" (label =
# `label=<name>`, else the caption cell's id). The `for=`/`label=` bindings ride the header as free-
# form tokens (they round-trip through `_parse_header`/`_cell_source`), so no schema change is needed.

# Value of a `key=…` header token stored as a free-form flag on the cell (e.g. `for=scaling`), or "".
function _flag_attr(cell::Cell, key::AbstractString)
    pre = key * "="
    for f in cell.flags
        s = String(f)
        startswith(s, pre) && return s[(length(pre) + 1):end]
    end
    return ""
end

# A code cell counts as a "figure" once it has run and produced an image / chart / table / component.
# A component belongs here for the same reason a chart does: it draws in the browser rather than on
# the server, so it has no bytes until an export asks for them — but it is what the reader sees, and
# a caption that follows it means it. Feeds `figure_index` only; the social-preview picker has its
# own predicate (`_cell_has_og_figure`, server_export.jl), which still wants real raster bytes.
function _cell_has_figure(c::Cell)
    exports_figures(c.kind) || return false
    o = c.output
    o === nothing && return false
    return any(ch -> startswith(ch.mime, "image/"), o.display) || _has_component(o) ||
           !isempty(_echarts_specs(c)) || !isempty(_table_specs(c))
end

"""
    figure_index(report) -> (; numbers, labels, capfor)

Resolve figure numbering from `caption`-tagged cells (document order):
- `numbers`  :: caption-cell-id → Figure number (Int)
- `labels`   :: cross-ref label → (num, anchor)  (label = `label=` attr, else the caption cell id;
               anchor = the bound figure cell's id when known, else the caption cell id). Each label
               is also registered under a `fig:` prefix, so both `[@x]` and `[@fig:x]` resolve.
- `capfor`   :: caption-cell-id → bound figure cell id ("" if none resolved)
"""
function figure_index(report)
    numbers = Dict{String,Int}(); labels = Dict{String,Tuple{Int,String}}(); capfor = Dict{String,String}()
    lastfig = ""; n = 0
    for c in report.cells
        _cell_has_figure(c) && (lastfig = c.id)
        (is_prose(c.kind) && :caption in c.flags) || continue
        n += 1; numbers[c.id] = n
        forid = _flag_attr(c, "for"); forid = isempty(forid) ? lastfig : forid
        capfor[c.id] = forid
        label = _flag_attr(c, "label"); label = isempty(label) ? c.id : label
        anchor = isempty(forid) ? c.id : forid
        labels[label] = (n, anchor)
        # `[@fig:<label>]` is the documented cross-reference, and the lookup key includes the prefix —
        # but no input path can produce a label that HAS one: `_parse_tag_symbols` folds punctuation
        # in a tag value, so `label=fig:x` is stored as `fig_x` whether it was typed in the browser's
        # tag editor or passed to add_cell. Registering the prefixed alias here makes the documented
        # form resolve against the label the author was actually able to write.
        startswith(label, "fig:") || (labels["fig:" * label] = (n, anchor))
    end
    return (; numbers, labels, capfor)
end

# How many `{{ }}` interpolations a markdown fragment consumes, numbered the way `Cell.interp` is.
# NOT a scan for `{{`: `_desugar_fences` rewrites every language-tagged fence into an interpolation
# too, so an ordinary ```julia block occupies an index exactly like an explicit `{{ }}`.
_md_interp_count(src::AbstractString) = length(ReportEngine._md_template(String(src))[2])

# The title cell's body copy with the hoisted H1 dropped, plus how many interpolations went with it.
# `Cell.interp` is numbered across the WHOLE cell, so a body that no longer starts at the top no longer
# starts at interpolation 1; the returned offset is what keeps source and interp list paired.
function _body_after_hoisted_h1(c::Cell)
    src = _strip_leading_h1(c.source)
    return (src, _md_interp_count(c.source) - _md_interp_count(src))
end

# Drop the FIRST H1 line (and any blank lines it leaves at the top) from a markdown source — used to
# suppress the body copy of a heading that `report_frontmatter` hoisted into the title block.
function _strip_leading_h1(src::AbstractString)
    lines = collect(split(String(src), '\n'))
    i = findfirst(l -> occursin(r"^#[ \t]+\S", l), lines)
    i === nothing && return String(src)
    deleteat!(lines, i)
    while i <= length(lines) && isempty(strip(lines[i])); deleteat!(lines, i); end
    return join(lines, '\n')
end

# Resolve `:bibliography` cells into Typst bib files written into the project dir, returning the
# project-relative filenames for `#bibliography(...)`. Embedded BibTeX is written to refs.bib; a
# `.bib` path is copied in; an address contributes only the entries in `cited`, since the whole
# library is the knowledge base's to publish, not the document's. `cmarker` already emits a markdown
# `@key` as a native Typst reference, so citations resolve against these with no bridge.
function _bibliography_files!(dir::AbstractString, bibcells, nbdir::AbstractString; cited = Set{String}())
    files = String[]
    embedded = IOBuffer()
    for c in bibcells, s in bib_sources(c, nbdir)
        if s.kind == :inline
            println(embedded, strip(c.source))
        elseif s.kind == :file
            isfile(s.path) || error("bibliography file not found: $(s.name)")
            fn = "ext_" * basename(s.path)
            cp(s.path, joinpath(dir, fn); force = true)
            fn in files || push!(files, fn)
        else
            println(embedded, _bib_cited_text(s, cited))
        end
    end
    emb = String(take!(embedded))
    if !isempty(strip(emb))
        write(joinpath(dir, "refs.bib"), emb)
        pushfirst!(files, "refs.bib")
    end
    return files
end

# The cited entries of an address's bibliography, as BibTeX. Throws when the hub has no copy of it.
function _bib_cited_text(s, cited)
    r = s.remote
    isempty(r.text) && error("bibliography at $(s.name) is not available" *
                             (isempty(r.message) ? " yet" : ": " * r.message))
    raw = _bibtex_raw_entries(r.text)
    return join((raw[k] for k in sort!(collect(cited)) if haskey(raw, k)), "\n\n")
end

# `surname` is the first author's, read before the braces go (`{W7-X Team}` stays whole).
const _BibEntry = NamedTuple{(:key, :title, :author, :year, :surname),NTuple{5,String}}

# LaTeX accent command → the Unicode COMBINING mark it puts on the next letter; NFC then composes
# (`c`+◌̧ → ç, `e`+◌́ → é). Covers the accents BibTeX author/title fields actually use.
const _TEX_ACCENT = Dict{Char,Char}(
    '\'' => '́', '`' => '̀', '^' => '̂', '"' => '̈', '~' => '̃',   # acute grave circumflex diaeresis tilde
    '='  => '̄', '.' => '̇', 'c' => '̧', 'v' => '̌', 'u' => '̆',   # macron dot-above cedilla caron breve
    'H'  => '̋', 'k' => '̨', 'r' => '̊', 'b' => '̱', 'd' => '̣')    # double-acute ogonek ring macron-below dot-below
# Standalone LaTeX letter commands (no accent argument) → their Unicode letter. Multi-letter first so
# `\ss` isn't split as `\s`+`s`.
const _TEX_LETTER = ["ss" => "ß", "aa" => "å", "AA" => "Å", "ae" => "æ", "AE" => "Æ", "oe" => "œ",
    "OE" => "Œ", "o" => "ø", "O" => "Ø", "l" => "ł", "L" => "Ł", "i" => "ı", "j" => "ȷ"]

_tex_accent_sub(m::AbstractString) =
    (mm = match(r"\\([`'^\"~=.cvuHkrbd])\s*\{?\s*([A-Za-z])\}?", m);
     mm === nothing ? m : Base.Unicode.normalize(string(mm.captures[2], _TEX_ACCENT[mm.captures[1][1]]), :NFC))

# Math commands, super/subscripts: `_TEX_MACRO`, `_TEX_SUP`, `_TEX_SUB` (server_export.jl), shared with `_demath`.

# Map every char of `s` through `tbl` (super/subscript), or `nothing` if any char has no mapping.
function _tex_mapscript(s, tbl)
    io = IOBuffer()
    for c in s; haskey(tbl, c) ? print(io, tbl[c]) : return nothing; end
    return String(take!(io))
end
_tex_script_sub(m::AbstractString, tbl) =
    (mm = match(r"[\^_]\{?([^{}]+)\}?", m); mm === nothing ? m : something(_tex_mapscript(mm.captures[1], tbl), m))

# Decode a `$…$` math span (the `$` are dropped): operators/Greek, then super/subscripts.
function _tex_math_sub(m::AbstractString)
    inner = String(SubString(m, nextind(m, firstindex(m)), prevind(m, lastindex(m))))
    # Decoded only INSIDE `$…$`, so an operator like `\cdot` isn't read as the `\c` cedilla accent. A whole
    # word is matched, so `\cdots` is not `\cdot` + `s`; an unknown command stays as written.
    inner = replace(inner, r"\\[A-Za-z]+" => m -> get(_TEX_MACRO, String(m)[2:end], m))
    inner = replace(inner, r"\^\{[^{}]+\}" => x -> _tex_script_sub(x, _TEX_SUP))
    inner = replace(inner, r"\^[A-Za-z0-9+\-]" => x -> _tex_script_sub(x, _TEX_SUP))
    inner = replace(inner, r"_\{[^{}]+\}" => x -> _tex_script_sub(x, _TEX_SUB))
    inner = replace(inner, r"_[A-Za-z0-9+\-]" => x -> _tex_script_sub(x, _TEX_SUB))
    return inner
end

# Decode the common LaTeX macros a BibTeX field carries so the LIVE view reads cleanly:
#  • accents — SYMBOL accents (`\'e`/`\'{e}` → é) bare or braced; LETTER accents (`\c{c}` → ç, `\H{o}`
#    → ő) ONLY braced, so a word command like `\cdot`/`\vec` isn't mis-read as `\c`+`d` / `\v`+`e`;
#  • standalone letters (`{\ss}` → ß, `{\o}` → ø);
#  • `$…$` math — operators/Greek (`\cdot` → ·) + super/subscripts (`10^9` → 10⁹), dropping the `$`;
#  • case-protecting braces (`{M}ontgomery` → `Montgomery`).
# Best-effort, LIVE-view only — the exported `.bib` keeps the raw source for the CSL engine.
function _delatex(s::AbstractString)
    str = String(s)
    (occursin('\\', str) || occursin('{', str) || occursin('$', str)) || return str   # fast path
    str = replace(str, r"\$[^$]*\$" => _tex_math_sub)                  # math spans first (scopes ^/_ )
    str = replace(str, r"\\['`^\"~=.]\s*\{?\s*[A-Za-z]\}?" => _tex_accent_sub)   # symbol accents (bare/braced)
    str = replace(str, r"\\[cvuHkrbd]\{[A-Za-z]\}" => _tex_accent_sub)           # letter accents (braced only)
    for (cmd, ch) in _TEX_LETTER
        str = replace(str, Regex("\\\\" * cmd * "(?![A-Za-z])") => ch)  # \o \ss … (no trailing letter)
    end
    str = replace(str, r"\\([&%_#\$])" => s"\1")                        # \& \% \_ \# \$ → literal
    return replace(str, r"[{}]" => "")                                  # drop remaining protective braces
end

# Parse BibTeX entries from a string — best-effort (not a full parser; keys are exact, fields
# snipped) — for citation autocomplete, the card, and the live author-date label.
function _parse_bibtex_entries(text::AbstractString)
    out = _BibEntry[]
    for part in split(String(text), r"(?=@\w+\s*\{)")
        m = match(r"^@\w+\s*\{\s*([^,\s]+)", part)
        m === nothing && continue
        # A braced value with ARBITRARILY nested braces (a recursive subpattern — `{\c{C}}` nests two
        # deep, so a fixed one-level match would truncate it), else a quoted value or a bare token
        # (`year = 1984`). LaTeX-decoded for display.
        function fld(n; dec = _delatex)
            mb = match(Regex(n * raw"\s*=\s*(\{(?:[^{}]|(?1))*\})", "i"), part)
            mb === nothing || return dec(strip(chop(mb.captures[1]; head = 1, tail = 1)))   # drop outer { }
            mq = match(Regex(n * raw"\s*=\s*\"([^\"\n]*)\"", "i"), part)
            mq === nothing || return dec(strip(mq.captures[1]))
            mn = match(Regex(n * raw"\s*=\s*(\d[\w\-]*)", "i"), part)
            mn === nothing ? "" : dec(strip(mn.captures[1]))
        end
        push!(out, (key = String(m.captures[1]), title = fld("title"), author = fld("author"), year = fld("year"),
                    surname = _delatex(_surname(fld("author"; dec = String)))))
    end
    return out
end

# Citation styles Slate ships as CSL files of its own (the rest of `_CITATION_STYLES` are Typst's), which
# the PDF export copies into its project.
const _SLATE_CSL = Dict("author-year-brackets" => joinpath(@__DIR__, "assets", "csl", "author-year-brackets.csl"))

# `author-year-brackets` cites as [Sun 2026]: the first author's surname and the year.
_is_bracket_style(style::AbstractString) = lowercase(String(style)) == "author-year-brackets"

# The first author's surname; a braced name (`{W7-X Team}`) is a literal name and is kept whole.
function _surname(author::AbstractString)
    a = strip(String(author))
    isempty(a) && return ""
    first = strip(split(a, r"\s+and\s+")[1])
    m = match(r"^\{([^{}]*)\}$", first)
    m === nothing || return String(strip(m.captures[1]))
    s = occursin(",", first) ? strip(split(first, ",")[1]) : String(strip(split(first)[end]))
    return replace(String(s), r"[{}]" => "")
end

"""
    _cite_labels(style, entries, numbers) -> (; labels, open, close)

How a style labels each entry in running text, and the brackets a group goes in: a number for a
numeric style (`[1; 3]`), the surname and year for `author-year-brackets` (`[Sun 2026; Elder 2025]`,
with `a`, `b`, … where two entries would share a label, in order of first citation as Typst assigns
them), and otherwise author and year (`(Sun et al., 2026)`). `numbers` is the first-citation order
(`citation_numbers`).
"""
function _cite_labels(style::AbstractString, entries, numbers)
    if _is_numeric_style(style)
        return (labels = Dict{String,String}(e.key => string(get(numbers, e.key, "?")) for e in entries), open = "[", close = "]")
    elseif _is_bracket_style(style)
        base = Dict(e.key => strip(string(e.surname, " ", e.year)) for e in entries)
        labels = Dict{String,String}()
        for lab in unique(values(base))
            es = sort([e for e in entries if base[e.key] == lab];
                      by = e -> (get(numbers, e.key, typemax(Int)), lowercase(_delatex(e.title))))
            for (i, e) in enumerate(es)
                labels[e.key] = length(es) == 1 ? lab : string(lab, Char('a' + i - 1))
            end
        end
        return (labels = labels, open = "[", close = "]")
    end
    return (labels = Dict{String,String}(e.key => _author_year_label(e.author, e.year) for e in entries), open = "(", close = ")")
end

# Numeric CSL styles cite as [1]; the rest are author-date. Drives the LIVE citation format (the PDF
# uses the real CSL engine either way).
_is_numeric_style(style::AbstractString) =
    lowercase(String(style)) in ("ieee", "vancouver", "nature", "chicago-notes", "iso-690-numeric",
                                 "american-physics-society", "american-institute-of-physics")

# A compact author-date label for the live view, e.g. "Knuth, 1984" / "Cormen et al., 2009".
function _author_year_label(author::AbstractString, year::AbstractString)
    a = strip(String(author))
    surname = ""
    if !isempty(a)
        first = strip(split(a, r"\s+and\s+")[1])                 # first listed author
        surname = occursin(",", first) ? strip(split(first, ",")[1]) :  # "Knuth, Donald"
                  String(strip(split(first)[end]))                       # "Donald E. Knuth" → "Knuth"
        occursin(r"\band\b", a) && (surname *= " et al.")
    end
    yr = strip(String(year))
    isempty(surname) && return yr
    return isempty(yr) ? surname : string(surname, ", ", yr)
end

# The sources one `:bibliography` cell names: its embedded BibTeX, or one per line, each a `.bib`
# path (resolved against `nbdir`) or an address (see `bib_endpoint`). `nb` is redrawn when an
# address's fetch brings a change. `remote` is the address's `BibRemote`, else `nothing`.
function bib_sources(cell, nbdir::AbstractString; nb = nothing)
    out = NamedTuple{(:kind, :name, :path, :remote, :entries),Tuple{Symbol,String,String,Any,Vector{_BibEntry}}}[]
    if occursin(r"@\w+\s*\{", cell.source)
        push!(out, (kind = :inline, name = "", path = "", remote = nothing, entries = _parse_bibtex_entries(cell.source)))
        return out
    end
    for ln in split(cell.source, '\n')
        p = String(strip(ln)); isempty(p) && continue
        if _bib_is_url(p)
            r = bib_remote(bib_endpoint(p); nb)
            push!(out, (kind = :url, name = p, path = "", remote = r, entries = r.entries))
        else
            src = isabspath(p) ? p : joinpath(nbdir, p)
            push!(out, (kind = :file, name = p, path = src, remote = nothing,
                        entries = isfile(src) ? _parse_bibtex_entries(read(src, String)) : _BibEntry[]))
        end
    end
    return out
end

# All citation entries defined by a report's `:bibliography` cells. Powers `[@`-completion, the
# references card and the citation labels.
function bibliography_index(report, nbdir::AbstractString; nb = nothing)
    entries = _BibEntry[]
    for c in report.cells
        :bibliography in c.flags || continue
        for s in bib_sources(c, nbdir; nb)
            append!(entries, s.entries)
        end
    end
    return entries
end

# Citation keys actually referenced in the notebook's prose — every `@key` in a markdown cell
# (skipping fenced code and the bibliography cells themselves, whose `@book{…}` aren't citations).
# Mirrors what cmarker turns into Typst references; drives the adaptive references card.
function cited_citation_keys(report)
    keys = Set{String}()
    for c in report.cells
        is_prose(c.kind) || continue
        :bibliography in c.flags && continue
        infence = false
        for ln in split(first(ReportRender._md_spliced(c.source, c.interp)), '\n')   # spliced prose too
            if occursin(r"^\s*(```|~~~)", ln); infence = !infence; continue; end
            infence && continue
            for m in eachmatch(r"(?<![\w@])@([A-Za-z][\w:.\-]*)", ln)
                push!(keys, String(m.captures[1]))
            end
        end
    end
    return keys
end

# Citation NUMBERS by first appearance (key → 1,2,3…) across the notebook's prose — matches the
# numeric CSL ordering, so the live view can show [1]/[2] like the PDF. Reuses the rewriter's exact
# detection (code-skipping + defined-key check) via a recording emit, so it never drifts.
function citation_numbers(report, citekeys)
    order = String[]; seen = Set{String}()
    # Only a key in the bibliography takes a number: `[@fig:…]` and unknown keys reach `emit` too.
    rec = (key, _sup, _form) -> (k = String(key); (k in citekeys && !(k in seen)) && (push!(order, k); push!(seen, k)); "")
    for c in report.cells
        (is_prose(c.kind) && !(:bibliography in c.flags)) || continue
        _rewrite_citations(first(ReportRender._md_spliced(c.source, c.interp)), citekeys; emit = rec)
    end
    return Dict{String,Int}(k => i for (i, k) in enumerate(order))
end

# Typst `#bibliography(...)` call for the resolved files, or "" when there are none.
function _bibliography_typst(files, style::AbstractString; dir = nothing)::String
    isempty(files) && return ""
    farg = length(files) == 1 ? "\"$(files[1])\"" : "(" * join(("\"$f\"" for f in files), ", ") * ")"
    csl = get(_SLATE_CSL, lowercase(String(style)), nothing)
    if csl !== nothing && dir !== nothing                 # a style Slate ships: staged beside doc.typ
        cp(csl, joinpath(dir, basename(csl)); force = true)
        style = basename(csl)
    end
    return "#bibliography($farg, style: \"$(style)\", title: [References])\n"
end

# Assemble the Typst PROJECT — `doc.typ` plus every per-cell aux file it reads (.md / .jl /
# figures / output blocks) — into a fresh temp dir and return its path. Shared by `export_pdf`
# (compile it) and `export_typst_bundle` (archive it). Holds `nb.lock` while reading the report;
# the caller owns the returned dir and must `rm` it. The figure warnings (a figure hook that threw,
# figures from stored output) go into `warnings`.
function _build_typst_project(nb::LiveNotebook; include_source::Bool = true,
                              style::AbstractString = "article", columns::Integer = 1,
                              theme::AbstractString = "light", charttheme::AbstractString = "",
                              override::Bool = false, code::AbstractString = "normal",
                              body::AbstractString = "", include_params::Bool = false,
                              layout::AbstractString = "article", notes::Bool = false,
                              level::Integer = 2, outputs::AbstractString = "all",
                              warnings::Vector{String} = String[], plan = _SlidePlan())
    # Slide-deck layout takes a wholly different page geometry/flow — dispatch early.
    layout == "slides" && return _build_slides_project(nb; theme = theme, charttheme = charttheme, override = override,
        code = code, include_source = include_source, include_params = include_params, notes = notes,
        level = level, ratio = get(nb.report.meta, "slideratio", "16:9"), outputs = outputs, warnings = warnings, plan)
    show_source = include_source && code != "hidden"
    cols = clamp(Int(columns), 1, 2)
    body = isempty(body) ? (cols == 2 ? "compact" : "normal") : body   # narrow columns → smaller default
    ct = _chart_theme(charttheme, theme)                               # the Slate palette charts render in
    geo = _doc_figure_geometry(nb; style, cols, body, palette = ct)
    compfigs = _warm_hook_figs!(nb, _CompFigs(), warnings, geo; progress = cid -> _export_progress(nb, cid))
    _warm_chart_svgs!(nb; theme = ct, progress = cid -> _export_progress(nb, cid))
    _warm_interp_charts!(nb, compfigs, warnings, geo; theme = ct, progress = cid -> _export_progress(nb, cid))
    # Themed override: re-render native (Makie) figures under the picked palette too (see the export
    # dialog's warning). No-op when not overriding — the baked figure bytes already match the live theme.
    override && _warm_makie_figs!(nb; theme = ct, progress = cid -> _export_progress(nb, cid))
    _warm_html_rasters!(nb; theme = ct, figs = compfigs)   # one round-trip, under the EXPORT's palette (see above)
    _warm_component_figs!(nb, compfigs, geo; theme = ct, progress = cid -> _export_progress(nb, cid))
    _warm_vector_figs!(nb, compfigs; progress = cid -> _export_progress(nb, cid))
    lock(nb.lock) do
        dir = mktempdir()
        mediasz = Dict{String,Any}()   # staged image => its `{width=…}` block, written out as media.json
        # Dark theme highlights code via a bundled tmTheme that Typst reads from the root.
        theme == "dark" && write(joinpath(dir, "code-dark.tmTheme"), _CODE_DARK_TMTHEME)
        io = IOBuffer()
        # If the author manually numbers their headings ("3.1 · …", "Section 3"), suppress Typst's
        # auto-numbering so it doesn't prepend a second number ("1 3.1 · …").
        numoverride = _manual_heading_numbers(nb.report.cells) ? false : nothing
        print(io, _typst_preamble(nb.report.title; style = style, columns = cols,
                                  theme = theme, code = code, body = body, number = numoverride))
        # Role-tagged metadata (title / abstract) → academic title block spanning full width;
        # the hoisted cells are then dropped from the body.
        cells = filter(c -> renders(c.kind), nb.report.cells)   # a cell a newer Slate wrote shows nothing
        fm = report_frontmatter(nb.report)
        figidx = figure_index(nb.report)
        citekeys = Set(e.key for e in bibliography_index(nb.report, dirname(abspath(nb.path))))
        arg(s) = isempty(strip(s)) ? "none" : "\"" * _typ_str(s) * "\""
        if !fm.has
            print(io, "#titleblock(\"", _typ_str(fm.title), "\")\n\n")
        else
            absarg = "none"
            if !isempty(strip(fm.abstract))
                write(joinpath(dir, "abstract.md"),
                      _stage_typst_md_media(_rewrite_citations(fm.abstract, citekeys), dir, "abstract", _proj_root(nb);
                                            sizes = mediasz, warnings, cell = fm.rolecell))
                absarg = _md_render("abstract.md")
            end
            print(io, "#metablock(", arg(fm.title), ", ", arg(fm.subtitle), ", ", arg(fm.byline), ", ", absarg, ")\n\n")
        end
        cols == 2 && print(io, "#columns(2)[\n")
        # Side-by-side rows (`column=N`): wrap a multi-cell run in a Typst `grid`, each cell a `[…]` slot.
        rowopen, rowclose, rowmembers = _column_row_brackets(cells,
            c -> !(:collapsed in c.flags) && !(c.id in fm.skip) && !(:bibliography in c.flags))
        for (k, c) in enumerate(cells)
            base = "c$(k)"
            (:collapsed in c.flags) && continue       # folded cell → omit from the export entirely
            c.id in fm.skip && continue               # hoisted into the title block above
            (:bibliography in c.flags) && continue    # rendered as #bibliography at the end, not raw
            inrow = c.id in rowmembers
            haskey(rowopen, c.id) &&                  # first cell of a multi-cell row → open the grid
                print(io, "#grid(columns: (", join(fill("1fr", rowopen[c.id]), ", "), "), column-gutter: 1.2em, align: top,\n")
            inrow && print(io, "[")                   # each row cell is one grid slot
            if is_prose(c.kind)
                # hoisted H1 → not in body, and the interpolations it held come off the front too
                src, ibase = c.id == fm.titlecell ? _body_after_hoisted_h1(c) : (c.source, 0)
                md = _md_for_typst(c, src; citekeys = citekeys, figrefs = figidx.labels,
                                   compfig = _compfig_stager(c, dir, base, compfigs, mediasz),
                                   fignum = get(figidx.numbers, c.id, nothing),
                                   interpbase = ibase)
                md = _stage_typst_md_media(md, dir, base, _proj_root(nb); sizes = mediasz, warnings, cell = c.id)   # author-embedded images → staged files
                if isempty(strip(md))
                    inrow || continue                # empty markdown: standalone → skip; in a row → empty slot
                else
                    write(joinpath(dir, base * ".md"), md)
                    if haskey(figidx.numbers, c.id)  # a caption cell → numbered "Figure N." block
                        print(io, "#figcaption(\"Figure ", figidx.numbers[c.id], "\", ", _md_render(base * ".md"), ")\n\n")
                    else
                        print(io, "#", _md_render(base * ".md"), "\n\n")
                    end
                end
            else
                # Match the browser: `show_source` is the global toggle; also hide source for the
                # per-cell 🙈 `hidecode` flag and for widget cells — `@bind` and `@web` — which show
                # their widget, not code.
                if show_source && !(:hidecode in c.flags) && isempty(c.binds) && !_is_web_cell(c) && !isempty(strip(c.source))
                    write(joinpath(dir, base * ".jl"), c.source)
                    print(io, "#codeblock(read(\"", base, ".jl\"))\n")
                end
                include_params && print(io, _emit_controls(c))   # frozen @bind controls — off by default
                _emit_output!(io, dir, base, nb, c; theme = theme, charttheme = ct, override = override,
                              outputs = outputs, compfigs = compfigs, warnings)
                print(io, "\n")
            end
            if inrow                                  # close this grid slot; the row's last cell closes the grid
                print(io, "],\n")
                c.id in rowclose && print(io, ")\n\n")
            end
        end
        # References — `:bibliography` cells (embedded + external .bib), rendered via Typst's CSL.
        biblio = _bibliography_files!(dir, fm.bibcells, dirname(abspath(nb.path)); cited = cited_citation_keys(nb.report))
        print(io, _bibliography_typst(biblio, get(nb.report.meta, "bibstyle", "ieee"); dir))
        cols == 2 && print(io, "]\n")
        write(joinpath(dir, "media.json"), JSON.json(mediasz))   # always present: the preamble reads it
        write(joinpath(dir, "doc.typ"), String(take!(io)))
        return dir
    end
end

# Typst length of the `width` attribute of a `::: column` (`d`: the attributes of its fence), or "none"
# when it has none. A bare number is a percentage, as in the live deck; `px` becomes points and `rem`
# becomes `em`.
function _column_width_typst(d)
    w = get(d, "width", nothing)
    m = w === nothing ? nothing : match(r"^([0-9]+(?:\.[0-9]+)?|\.[0-9]+)(%|px|em|rem)?$", strip(String(w)))
    m === nothing && return "none"
    unit = something(m[2], "%")
    return string(m[1], unit == "px" ? "pt" : unit == "rem" ? "em" : unit)
end

# The groups of a markdown source (`ReportRender._md_groups`). A `:::: columns` group also has the
# Typst width of each column in `widths`. Other fenced divs (`::: step`) stay in the text for
# `_strip_deck_markup`.
_split_groups(src::AbstractString; warns = String[]) =
    Any[p isa AbstractString ? p :
        merge(p, (; widths = p.kind === :columns ? String[_column_width_typst(m) for m in p.metas] : String[]))
        for p in ReportRender._md_groups(src; warns)]

# One `slidegrid` call for the grid group `p`: `body(j)` prints grid cell `j`, and `mark(j)` gives the
# Typst text of its marks.
function _print_slidegrid(body, mark, io::IO, p)
    num = ReportRender._fmtnum
    tracks = [k === :fr ? num(v) * "fr" : num(v) * " * u" for (k, v) in p.grid.tracks]
    print(io, "#slidegrid(columns: (", join(tracks, ", "), ",),", p.grid.gap === nothing ? "" : " gap: $(num(p.grid.gap)) * u,", "\n")
    for (j, c) in enumerate(p.cells)
        print(io, "gridcell(align: ", c.align, " + ", c.valign == "middle" ? "horizon" : c.valign,
              c.fill === nothing ? "" : ", fill: \"$(_typ_str(c.fill))\"", c.size === nothing ? "" : ", size: $(num(c.size))",
              ")[", rstrip(mark(j)), "][\n")
        body(j)
        print(io, "],\n")
    end
    print(io, ")\n\n")
end

# The export warnings of the groups of cell `c` (`gw`: the warnings of `_split_groups`, `pieces` its
# result): each warning of a group, and a fill word that the deck settings `ds` do not have, or that
# paints a fixed colour under text that follows the Slate palette.
function _group_warnings!(warnings, c, ds, gw, pieces)
    warnings === nothing && return
    ws = copy(gw)
    pal, roles = ds.values["palette"], ds.values["roles"]
    follows(v) = startswith(get(roles, v, v), "slate.")
    for p in pieces
        p isa AbstractString && continue
        append!(ws, p.warns)
        for cs in p.cells
            (cs === nothing || cs.fill === nothing) && continue
            f = cs.fill
            if !haskey(pal, f) && !(f in _DECK_ROLES)
                push!(ws, "`fill=\"$f\"` is not a palette name or a colour role of the deck settings, so the grid cell has no paint")
            elseif !(!haskey(pal, f) && follows(roles[f])) && follows(roles["fg"])
                push!(ws, "`fill=\"$f\"` is a fixed colour, but `roles.fg` follows the Slate palette, so the text can be hard to read on some palettes")
            end
        end
    end
    for w in unique(ws)
        msg = "Cell $(c.id): $w."
        msg in warnings || push!(warnings, msg)
    end
end

# One `slidecols` call: `body(j)` prints the j-th column of the row. `gap` and `align` are Typst
# expressions, or `nothing` for the defaults of `slidecols`; `row` marks a row of cells.
function _print_slidecols(body, io::IO, widths; gap = nothing, align = nothing, row::Bool = false)
    print(io, "#slidecols((", join(widths, ", "), ",),", gap === nothing ? "" : " gap: $gap,",
          align === nothing ? "" : " align: $align,", row ? " row: true," : "", "\n")
    for j in eachindex(widths)
        print(io, "[")
        body(j)
        print(io, "],\n")
    end
    print(io, ")\n\n")
end

# Emit one slide fragment (a whole cell, or a `---`-split markdown chunk) into the doc.
# `frag` is a `SlideFrag`-shaped NamedTuple, annotated loosely on purpose: NamedTuple type parameters
# are INVARIANT, so a literal whose `src` is a concrete `String` (or `Nothing`) is not a subtype of
# `SlideFrag`'s `Union{String,Nothing}` field, and a `::SlideFrag` annotation would reject every caller
# that builds one inline rather than pushing it through a `Vector{SlideFrag}`.
# A markdown cell prints inside one `mdcell`, which gives it the padding of a live markdown cell;
# `incell` is true for the parts of a cell that a group (`:::: columns`, `:::: grid`) splits.
# Returns `true` when the markdown that it printed ends with a key message, an admonition or a table.
# On the live deck such a block has no space below it at the end of its cell, so the cell is `tight`.
# Each block of the fragment goes through `blk` (`_block_printer`): a markdown fragment is split into
# its blocks (`ReportRender._md_split`), each in a file of its own, and each output of a code cell is
# one block. `path` is the place of the markdown among the groups: for each group, outermost first, the
# number of the group in its container and the number of the container in the group. `figidx` is the
# `figure_index` of the notebook: the number of a caption and the target of a `[@fig:label]`.
function _emit_slide_frag!(io::IO, dir, base, nb, frag::NamedTuple; theme, charttheme = "", override = false, show_source, include_params, citekeys = Set{String}(), figidx = figure_index(nb.report), outputs::AbstractString = "all", sizes = nothing, warnings = nothing, compfigs::_CompFigs = _NO_COMPFIGS, incell::Bool = false, blk = _plain_block, path::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[])
    c, srcoverride = frag.cell, frag.src     # `frag.src` is a per-frag SOURCE override (String/nothing), NOT the themed-render Bool `override`
    if is_prose(c.kind) && !incell
        cio = IOBuffer()
        tight = _emit_slide_frag!(cio, dir, base, nb, frag; theme, charttheme, override, show_source, include_params, citekeys, figidx,
                                  outputs, sizes, warnings, compfigs, blk, path, incell = true)
        position(cio) == 0 || print(io, tight ? "#mdcell(tight: true)[\n" : "#mdcell[\n", String(take!(cio)), "]\n\n")
        return false
    end
    if is_prose(c.kind)
        src = srcoverride === nothing ? c.source : srcoverride
        gw = String[]
        pieces = _split_groups(src; warns = gw)
        _group_warnings!(warnings, c, notebook_deck_settings(nb), gw, pieces)
        if !(length(pieces) == 1 && pieces[1] isa AbstractString)    # a group splits the cell
            kw = (; theme, charttheme, override, show_source, include_params, citekeys, figidx, outputs, sizes, warnings, compfigs, incell, blk)
            ib = frag.interpbase     # interpolations are numbered across the cell, so each piece starts after the last
            tight = false
            gi = 0                   # the number of the group in this container
            for (k, p) in enumerate(pieces)
                pbase = string(base, "p", k)
                if p isa AbstractString
                    tight = _emit_slide_frag!(io, dir, pbase, nb, (cell = c, src = String(p), interpbase = ib); path, kw...)
                    ib += _md_interp_count(p)
                else
                    tight = false
                    gi += 1
                    emit = function (j)
                        _emit_slide_frag!(io, dir, string(pbase, "c", j), nb, (cell = c, src = p.cols[j], interpbase = ib);
                                          path = [path; (gi, j)], kw...)
                        ib += _md_interp_count(p.cols[j])
                    end
                    p.kind === :columns ? _print_slidecols(emit, io, p.widths) :
                        _print_slidegrid(emit, j -> blk("gridcell", ""; path = [path; (gi, j)], gridcell = p.cells[j]), io, p)
                end
            end
            return tight
        end
        md = _md_for_typst(c, src; citekeys = citekeys, figrefs = figidx.labels,
                           compfig = _compfig_stager(c, dir, base, compfigs, sizes),
                           interpbase = frag.interpbase,
                           fignum = :caption in c.flags ? get(figidx.numbers, c.id, nothing) : nothing)
        md = _stage_typst_md_media(md, dir, base, _proj_root(nb); sizes, warnings, cell = c.id, media = true)   # author-embedded images → staged files
        isempty(strip(first(_take_media_marks(md)))) && return false
        for (k, b) in enumerate(ReportRender._md_split(md))
            file = string(base, "b", k, ".md")
            text, clip = _take_media_marks(b.text)
            clip = b.kind == "figure" ? clip : nothing
            write(joinpath(dir, file), text)
            print(io, blk(b.kind, string(clip === nothing ? "#" * _md_render(file) : _clip_typ(clip, text, file), "\n\n"); src = text, path, file = clip))
        end
        return occursin(r"</slate-(?:key-message|admonition|table)>\s*$", md)
    else
        if show_source && !(:hidecode in c.flags) && isempty(c.binds) && !_is_web_cell(c) && !isempty(strip(c.source))
            write(joinpath(dir, base * ".jl"), c.source)
            print(io, blk("code", string("#codeblock(read(\"", base, ".jl\"))\n")))
        end
        ctl = include_params ? _emit_controls(c) : ""
        isempty(ctl) || print(io, blk("prose", ctl))
        _emit_output!(io, dir, base, nb, c; theme = theme, charttheme = charttheme, override = override,
                      outputs = outputs, compfigs = compfigs, blk, warnings)
        print(io, "\n")
    end
    return false
end

# What `_build_slides_project` writes down about the slides that it draws, for `slide_layout`.
# `deck` is the slide model. `pages[p]` is the index in `deck` of the slide on page `p` of the PDF
# (0 for the title page of a notebook with no `title` cell); the pages after `pages` hold no slide of
# the model (the references, the notes). `blocks` holds each block in the order of the document:
# `(slide, frag, index, kind, cell, row, column, path, src, file)`; `file` is the picture of a figure
# output in the project directory, or the video or audio file of a figure of markdown, else `nothing`.
# `cells` holds each grid cell in the order of the document: `(slide, frag, path, fill, align, valign)`.
# `texts` holds the markdown of each region, by `(slide, name)`. For an exporter (`exporter_deck`),
# `mimes` are its figure MIME types and `forms` the pictures of the figure hooks in those types, by
# output `(cell, slot)`.
mutable struct _SlidePlan
    deck::Vector{NamedTuple}
    pages::Vector{Int}
    blocks::Vector{NamedTuple}
    cells::Vector{NamedTuple}
    texts::Dict{Tuple{Int,String},String}
    mimes::Vector{String}
    forms::Dict{Tuple{String,Int},Vector{Tuple{String,Vector{UInt8}}}}
end
_SlidePlan(mimes::Vector{String} = String[]) =
    _SlidePlan(NamedTuple[], Int[], NamedTuple[], NamedTuple[], Dict{Tuple{Int,String},String}(), mimes,
               Dict{Tuple{String,Int},Vector{Tuple{String,Vector{UInt8}}}}())

# The key of a path in the marks of the slides project: "1.2/1.1" for `[(1, 2), (1, 1)]`.
_path_key(path) = join(("$g.$j" for (g, j) in path), "/")

# The `blk` function of `_emit_slide_frag!` for fragment `frag` of slide `slide`; `f` holds the cell,
# the row and the column of the fragment. It numbers the blocks of the fragment in reading order,
# writes each one down in `plan`, and gives the Typst text that draws it: `typ` inside
# `#blk(i, kind, frag: "s<slide>f<frag>", cell: "<id>")[…]`, with the line ends that follow `typ`.
# The kind "gridcell" writes down the grid cell `gridcell` (a `_cell_spec`) at `path` and gives the
# text of its marks (`cellmark`).
function _block_printer(plan::_SlidePlan, slide::Integer, frag::Integer, f)
    n = Ref(0)
    return function (kind, typ; src = nothing, path = Tuple{Int,Int}[], file = nothing, gridcell = nothing)
        if kind == "gridcell"
            push!(plan.cells, (; slide, frag, path, gridcell.fill, gridcell.align, gridcell.valign))
            return string("#cellmark(\"s", slide, "f", frag, "\", \"", _path_key(path), "\", filled: ",
                          gridcell.fill !== nothing, ")\n")
        end
        n[] += 1
        push!(plan.blocks, (; slide, frag, index = n[], kind, cell = f.cell, row = f.row, column = f.column, path, src, file))
        body = rstrip(typ)
        return string("#blk(", n[], ", \"", kind, "\", frag: \"s", slide, "f", frag, "\", cell: \"", _typ_str(f.cell), "\")[", lstrip(body), "]",
                      SubString(typ, ncodeunits(body) + 1))
    end
end

"""
    slide_layout(nb; level = <the notebook's slide level>, ratio = <the notebook's slide ratio>, kwargs...) -> Vector{NamedTuple}

The slide model of `slide_deck` with the layout of the slides PDF: each entry has three more fields,
`regions`, `blocks` and `cells`. The boxes come from one `typst query` on the slides project of the notebook,
compiled with the block and region marks on (`slate-mark` of the slides preamble). `kwargs` are the
other options of the slides PDF (`theme`, `charttheme`, `outputs`, …). Internal: it is not exported.

A box is `(x, y, w, h)` in the slide unit `u`, from the top left corner of the page. The box of prose,
of a caption and of a region holds whole line boxes of CSS. A text size is in `u`. A line height is
the line pitch of the text in `u`, from the top of a line to the top of the next line: inside the base
rhythm, the CSS line height times the text size.

- `regions`: each region that the PDF draws, as `(name, page, box, size, lineheight)`. `name` is
  "title", "subtitle", "byline" or "abstract".
- `blocks`: each block of the body, in reading order, as
  `(kind, cell, frag, index, row, column, path, src, page, box, size, lineheight, cols, rows)`.
  - `kind`: one of `ReportRender.BLOCK_KINDS`.
  - `cell`, `row`, `column`: the cell, the row and the `column=` value of its fragment, as in `frags`.
  - `frag`: the index of its fragment in `frags`; 0 for a block of the `title` cell.
  - `index`: its number in the fragment, in reading order. A container (a `::: column` or a grid
    cell) holds blocks: the blocks of container 1 come before the blocks of container 2.
  - `path`: its place among the groups (`:::: columns`, `:::: grid`), as `(group, container)` pairs,
    outermost first: the number of the group in its container and the number of the container in the
    group. Empty outside a group.
  - `src`: its markdown, with `{{ }}` resolved and the block kinds marked; `nothing` for an output
    of a code cell, with two exceptions. A markdown output splits into blocks as a markdown cell
    does. The `text/plain` value is a fenced code block of its text.
  - `page`, `box`, `size`, `lineheight`: its page in the PDF, its box, its text size and its line
    height; `nothing` when the PDF does not draw it. The box of a figure is the picture, the box of a
    table is the table, the box of each other block is as wide as its column. The text size and the
    line height of a table are those of its cells, and those of a code block are those of its code text.
  - `cols`, `rows`: the column widths and the row heights of a table, in `u`; else `nothing`.
- `cells`: each grid cell, in the order of the document, as `(frag, path, page, box, fill, align, valign)`.
  `path` is the path of the grid cell: a block is in it when the path of the block starts with it.
  `box` is the whole grid cell, its pad included; `nothing` when the PDF does not draw it. `fill` is
  the colour word of the grid cell or `nothing`, `align` "left", "center" or "right" and `valign`
  "top", "middle" or "bottom".
"""
function slide_layout(nb::LiveNotebook; level::Integer = get(nb.report.meta, "slidelevel", 2),
                      ratio::AbstractString = get(nb.report.meta, "slideratio", "16:9"), kwargs...)
    plan = _SlidePlan()
    dir = _build_slides_project(nb; level, ratio, plan, kwargs...)
    try
        return _slide_layout(plan, _typst_query(joinpath(dir, "doc.typ"), "<slate>"; marks = true))
    finally
        rm(dir; recursive = true, force = true)
    end
end

# The widths (or heights) of the tracks of a table, in order: `cells` holds the two corner records of
# each cell of one row (or one column), `at` is their track number ("col" or "row") and `pos` the
# coordinate ("x" or "y").
function _tracks(cells, at, pos)
    span = Dict{Int,Vector{Float64}}()
    foreach(c -> push!(get!(span, Int(c[at]), Float64[]), Float64(c[pos])), cells)
    return [maximum(span[k]) - minimum(span[k]) for k in sort!(collect(keys(span)))]
end

# Join the mark records of a slides project to its plan (see `slide_layout`).
function _slide_layout(plan::_SlidePlan, records)
    recs = Dict{String,Vector{Any}}()
    for r in records
        r isa AbstractDict && push!(get!(recs, String(get(r, "kind", "")), Any[]), r)
    end
    of(kind) = get(recs, kind, Any[])
    # The first record of `kind` for each block, and the cells of each table, in the order of the document.
    key(r) = (get(r, "frag", nothing), get(r, "i", nothing))
    firstof(kind) = (d = Dict{Any,Any}(); foreach(r -> get!(d, key(r), r), of(kind)); d)
    marks, texts, figs = firstof("block"), firstof("text"), firstof("figure")
    cells = Dict{Any,Vector{Any}}()
    foreach(r -> push!(get!(cells, key(r), Any[]), r), of("cell"))
    regions = [NamedTuple[] for _ in plan.deck]
    for r in of("region")
        si = get(plan.pages, r["page"], 0)
        si == 0 && continue
        t = findfirst(t -> get(t, "name", nothing) == r["name"] && t["page"] == r["page"], of("text"))
        tr = t === nothing ? r : of("text")[t]
        push!(regions[si], (name = String(r["name"]), page = Int(r["page"]), box = _mark_box(r),
                            size = Float64(tr["size"]), lineheight = Float64(tr["lh"])))
    end
    blocks = [NamedTuple[] for _ in plan.deck]
    for b in plan.blocks
        b.slide == 0 && continue
        k = ("s$(b.slide)f$(b.frag)", b.index)
        r = get(marks, k, nothing)
        page = box = size = lineheight = cols = rows = nothing
        if r !== nothing
            page, box = Int(r["page"]), _mark_box(r)
            tr = get(texts, k, r)
            size, lineheight = Float64(tr["size"]), Float64(tr["lh"])
            tc = get(cells, k, Any[])
            if b.kind == "figure" && haskey(figs, k)
                box = _mark_box(figs[k])
            elseif b.kind == "table" && !isempty(tc)
                xs, ys = [Float64(c["x"]) for c in tc], [Float64(c["y"]) for c in tc]
                box = (x = minimum(xs), y = minimum(ys), w = maximum(xs) - minimum(xs), h = maximum(ys) - minimum(ys))
                cols = _tracks([c for c in tc if c["row"] == 0], "col", "x")
                rows = _tracks([c for c in tc if c["col"] == 0], "row", "y")
                size, lineheight = Float64(first(tc)["size"]), Float64(first(tc)["lh"])
            end
        end
        push!(blocks[b.slide], (; b.kind, b.cell, b.frag, b.index, b.row, b.column, b.path, b.src, page, box, size,
                                lineheight, cols, rows))
    end
    # The two corners of each grid cell, inside its pad.
    corners = Dict{Any,Any}()
    foreach(r -> get!(corners, (r["frag"], r["path"], r["end"]), r), of("gridcell"))
    gcells = [NamedTuple[] for _ in plan.deck]
    for c in plan.cells
        c.slide == 0 && continue
        k = ("s$(c.slide)f$(c.frag)", _path_key(c.path))
        a, b = get(corners, (k..., false), nothing), get(corners, (k..., true), nothing)
        page = box = nothing
        if a !== nothing && b !== nothing
            pad = Float64(a["pad"])
            page = Int(a["page"])
            box = (x = Float64(a["x"]) - pad, y = Float64(a["y"]) - pad,
                   w = Float64(b["x"]) - Float64(a["x"]) + 2pad, h = Float64(b["y"]) - Float64(a["y"]) + 2pad)
        end
        push!(gcells[c.slide], (; c.frag, c.path, page, box, c.fill, c.align, c.valign))
    end
    return [merge(sl, (regions = regions[si], blocks = blocks[si], cells = gcells[si])) for (si, sl) in enumerate(plan.deck)]
end

# ── Exporters ─────────────────────────────────────────────────────────────────────────────────────
# The deck value of an exporter (`SlateExtensionsBase.register_exporter!`; its docstring states the
# keys) and the export through it.

const _EXPORT_MAX_BYTES = 256 * 1024^2   # the size cap of the file that an exporter gives

# The MIME type of a picture that the slides project staged, by its file extension.
const _STAGED_MIME = Dict("pdf" => "application/pdf", "svg" => "image/svg+xml", "png" => "image/png",
                          "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp")

# The markdown of a block for an exporter: each citation goes back from the sentinel of the Typst
# export (`_cite_token`) to its markdown, `[@key]`, `[@key, supplement]` or `@key`.
const _CITE_SENTINEL_RE = r"§c§([^§]*)§([^§]+)§([^§]*)§"
_exporter_markdown(src::AbstractString) = replace(src, _CITE_SENTINEL_RE => function (s)
    m = match(_CITE_SENTINEL_RE, s)
    return m[1] == "p" ? "@" * m[2] : string("[@", m[2], isempty(m[3]) ? "" : ", " * m[3], "]")
end)

_deck_box(b) = b === nothing ? nothing : Dict{String,Any}("x" => b.x, "y" => b.y, "w" => b.w, "h" => b.h)

# The `forms` of figure block `b`, in the order of `plan.mimes`. For each MIME type: the picture of the
# figure hook, else a chunk of that type of the output, else the picture that the slides project
# staged when it has that type. `file` is the staged picture of an output; a figure of a markdown cell
# names its staged picture in its markdown, and a `{{ }}` value has its number in that name. A figure
# of markdown with a video or audio file has that file as `file` (see `_media_forms`).
function _figure_forms(plan::_SlidePlan, b, file, cells, dir, warnings)
    slot, o = 0, nothing
    if b.src === nothing
        o = cells[b.cell].output
    elseif file !== nothing
        return _media_forms(plan, file, b.cell, warnings)
    else
        m = match(r"!\[[^\]]*\]\(<?([^)\s>]+)", b.src)
        file = m === nothing ? nothing : String(m[1])
        s = file === nothing ? nothing : match(r"_comp(\d+)\.\w+$", file)
        slot = s === nothing ? -1 : parse(Int, s[1])
        interp = cells[b.cell].interp
        o = 1 <= slot <= length(interp) ? interp[slot] : nothing
    end
    hook = get(plan.forms, (b.cell, slot), Tuple{String,Vector{UInt8}}[])
    root = normpath(dir) * Base.Filesystem.path_separator
    path = file === nothing ? "" : normpath(joinpath(dir, file))
    staged = startswith(path, root) && isfile(path) ? get(_STAGED_MIME, lowercase(chopprefix(splitext(path)[2], ".")), "") : ""
    forms = Tuple{String,Vector{UInt8}}[]
    for m in plan.mimes
        i = findfirst(f -> first(f) == m, hook)
        j = o === nothing ? nothing : findfirst(ch -> ch.mime == m, o.display)
        bytes = i !== nothing ? hook[i][2] : j !== nothing ? copy(o.display[j].data) : staged == m ? read(path) : nothing
        bytes === nothing || push!(forms, (m, bytes))
    end
    return forms
end

# The form of the video or audio file `path` of a markdown figure: its bytes under the MIME type of its
# extension, when `plan.mimes` has that type. A file over the size cap gives no form and a warning.
function _media_forms(plan::_SlidePlan, path, cell, warnings)
    mime = first(split(_site_ctype(path), ';'))
    mime in plan.mimes || return Tuple{String,Vector{UInt8}}[]
    if filesize(path) > _EXPORT_MAX_BYTES
        push!(warnings, string("Cell ", cell, ": the file `", basename(path), "` is larger than ", _EXPORT_MAX_BYTES >> 20,
                               " MiB, so the export shows its alt text in its place."))
        return Tuple{String,Vector{UInt8}}[]
    end
    return [(mime, read(path))]
end

_deck_path(path) = Any[Int[g, j] for (g, j) in path]

function _deck_block(si, b, plan::_SlidePlan, files, cells, dir, warnings)
    d = Dict{String,Any}("kind" => b.kind, "cell" => b.cell, "frag" => b.frag, "index" => b.index, "row" => b.row,
                         "column" => b.column, "path" => _deck_path(b.path),
                         "markdown" => b.src === nothing ? nothing : _exporter_markdown(b.src),
                         "box" => _deck_box(b.box), "size" => b.size, "lineheight" => b.lineheight)
    b.kind == "table" && (d["cols"] = b.cols; d["rows"] = b.rows)
    b.kind == "figure" && (d["forms"] = _figure_forms(plan, b, get(files, (si, b.frag, b.index), nothing), cells, dir, warnings))
    return d
end

# The grid cells of a slide for an exporter. The colour of a fill is a hex string: the palette
# colour, else the colour role, against the Slate palette `slate`; `nothing` for no fill or a word that
# the settings `s` do not have.
function _deck_cells(sl, s, slate)
    hex(f) = f === nothing || !(haskey(s["palette"], f) || f in _DECK_ROLES) ? nothing : _deck_colour(s, f, slate)
    return Any[Dict{String,Any}("path" => _deck_path(c.path), "box" => _deck_box(c.box), "fill" => hex(c.fill),
                                "align" => c.align, "valign" => c.valign) for c in sl.cells]
end

function _deck_slide(si, sl, plan::_SlidePlan, files, cells, dir, warnings, s, slate)
    t = sl.title
    return Dict{String,Any}(
        "layout" => sl.layout, "transition" => sl.transition, "auto" => sl.auto,
        "title" => t === nothing ? nothing : Dict{String,Any}("text" => get(plan.texts, (si, "title"), String(t.text)),
                                                              "depth" => Int(t.depth), "cell" => String(t.cell)),
        "notes" => String[cells[id].source for id in sl.notes],
        "regions" => Any[Dict{String,Any}("name" => r.name, "text" => get(plan.texts, (si, r.name), nothing),
                                          "box" => _deck_box(r.box), "size" => r.size, "lineheight" => r.lineheight)
                 for r in sl.regions],
        "blocks" => Any[_deck_block(si, b, plan, files, cells, dir, warnings) for b in sl.blocks],
        "cells" => _deck_cells(sl, s, slate))
end

"""
    exporter_deck(nb; figure_mimes = ["image/png"], theme = "light", charttheme = "", warnings = String[]) -> Dict{String,Any}

The deck value that an exporter gets (`SlateExtensionsBase.register_exporter!`, whose docstring states
its keys): the slide model of the notebook with the boxes and the text sizes of its slides PDF, at the
slide ratio and the slide level of the notebook. A figure block has a form for each type of
`figure_mimes` that Slate has a picture of. `theme` and `charttheme` choose the Slate palette of the
colour roles and of the figures, as for the slides PDF. The export warnings of the slides PDF go into
`warnings`.
"""
function exporter_deck(nb::LiveNotebook; figure_mimes = ["image/png"], theme::AbstractString = "light",
                       charttheme::AbstractString = "", warnings::Vector{String} = String[])
    ratio = String(get(nb.report.meta, "slideratio", "16:9"))
    plan = _SlidePlan(String[String(m) for m in figure_mimes])
    figwarns = String[]
    dir = _build_slides_project(nb; level = get(nb.report.meta, "slidelevel", 2), ratio, theme, charttheme, plan,
                                warnings = figwarns)
    try
        recs = _typst_query(joinpath(dir, "doc.typ"), "<slate>"; marks = true)
        append!(warnings, _slides_warnings(nb, recs, figwarns, plan))
        files = Dict((b.slide, b.frag, b.index) => b.file for b in plan.blocks)
        cells, title = lock(() -> (Dict(c.id => c for c in nb.report.cells),
                                   String(report_frontmatter(nb.report; untitled = "").title)), nb.lock)
        W, H = deck_canvas(ratio)
        s = notebook_deck_settings(nb).values
        palette = _chart_theme(charttheme, theme)
        slate = ReportEngine._resolve_palette(palette)
        return Dict{String,Any}("title" => title, "size" => (Float64(W), Float64(H)), "ratio" => ratio,
            "settings" => deck_settings_dict(s; palette),
            "slides" => Any[_deck_slide(si, sl, plan, files, cells, dir, warnings, s, slate) for (si, sl) in enumerate(_slide_layout(plan, recs))])
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
    export_with(nb, name; theme = "light", charttheme = "", maxbytes = 256 MiB) -> Union{Nothing,NamedTuple}

The file of the exporter `name` that a package of the notebook registers, as `(; exporter, bytes,
warnings)`: Slate builds the deck value (`exporter_deck`) and the exporter runs on the main worker of
the notebook. `warnings` are the export warnings of the slides PDF, then those of the exporter.
`nothing` when no package of the notebook registers `name`. Throws when the exporter
throws, or when its file has more than `maxbytes` bytes.
"""
function export_with(nb::LiveNotebook, name::AbstractString; theme::AbstractString = "light",
                     charttheme::AbstractString = "", maxbytes::Integer = _EXPORT_MAX_BYTES)
    _refresh_extensions_for_page!(nb)       # a package loaded since the last drain
    i = findfirst(e -> e.name == name, notebook_exporters(nb))
    i === nothing && return nothing
    exporter = notebook_exporters(nb)[i]
    warnings = String[]
    deck = exporter_deck(nb; figure_mimes = exporter.figure_mimes, theme, charttheme, warnings)
    out = ReportEngine.run_exporter(_running_kernel(nb, ""), exporter.name, deck; maxbytes)
    append!(warnings, out.warnings)
    return (; exporter, out.bytes, warnings = unique!(warnings))
end

# Write a deck template's files into the project `dir` and append its source to `io`, after the base
# preamble, so a `#let slide` or `#let metablock` in it shadows the base one. The source stays inline
# (an `#include` would not export its lets). A template ships fonts under `fonts/`: `_typst_compile`
# puts that directory on the font path. A template file must not have the name of a file that Slate
# writes into the project.
const _SLATE_PROJECT_FILES = ("doc.typ", "deck-settings.typ", "media.json", "code-dark.tmTheme")
_apply_deck_template!(io::IO, dir::AbstractString, ::Nothing) = nothing
function _apply_deck_template!(io::IO, dir::AbstractString, t)
    root = normpath(dir)
    for (name, bytes) in t.files
        path = normpath(joinpath(root, name))
        startswith(path, root * Base.Filesystem.path_separator) ||
            throw(ArgumentError("deck template file \"$name\" escapes the project directory"))
        relpath(path, root) in _SLATE_PROJECT_FILES &&
            throw(ArgumentError("deck template file \"$name\" has the name of a file that Slate writes"))
        mkpath(dirname(path))
        write(path, bytes)
    end
    print(io, "\n// ── deck template ──\n", t.source, "\n\n")
    return
end

# Assemble a slide-DECK Typst project: one page per slide (segmented by `_slide_segments`),
# 16:9/4:3 landscape, auto-fit. Code listings are hidden by default on slides (set `code`/
# `include_source`). With `notes=true`, a speaker-notes appendix follows the deck.
function _build_slides_project(nb::LiveNotebook; theme::AbstractString = "dark", charttheme::AbstractString = "",
                               override::Bool = false, ratio::AbstractString = "16:9", code::AbstractString = "hidden",
                               include_source::Bool = false, include_params::Bool = false,
                               notes::Bool = false, level::Integer = 2, outputs::AbstractString = "all",
                               warnings::Vector{String} = String[], plan::_SlidePlan = _SlidePlan())
    show_source = include_source && code != "hidden"
    # Pull the manifest now, so an edit to a file-backed template part (`@pkg_asset`) reaches this export
    # without a run or a worker restart.
    _refresh_extensions_for_page!(nb)
    ds = notebook_deck_settings(nb)
    palette = _chart_theme(charttheme, theme)       # the Slate palette of the `slate.` colours
    ct = _deck_figure_palette(ds.values, palette)   # the Slate palette the figures render in
    geo = _slide_figure_geometry(nb, ds, ratio, level, ct; page_palette = palette)
    compfigs = _warm_hook_figs!(nb, _CompFigs(), warnings, geo; progress = cid -> _export_progress(nb, cid))
    isempty(plan.mimes) || _hook_forms!(plan, nb, warnings, geo, compfigs)
    _warm_chart_svgs!(nb; theme = ct, progress = cid -> _export_progress(nb, cid))
    _warm_interp_charts!(nb, compfigs, warnings, geo; theme = ct, present = true, progress = cid -> _export_progress(nb, cid))
    _warm_slide_charts!(nb, compfigs, warnings, geo; theme = ct, progress = cid -> _export_progress(nb, cid))
    override && _warm_makie_figs!(nb; theme = ct, progress = cid -> _export_progress(nb, cid))
    _warm_html_rasters!(nb; theme = ct, figs = compfigs)   # one round-trip, under the EXPORT's palette (see above)
    _warm_component_figs!(nb, compfigs, geo; theme = ct, progress = cid -> _export_progress(nb, cid))
    _warm_vector_figs!(nb, compfigs; progress = cid -> _export_progress(nb, cid))
    lock(nb.lock) do
        dir = mktempdir()
        mediasz = Dict{String,Any}()   # staged image => its `{width=…}` block, written out as media.json
        syntax = _deck_syntax(ds.values, ReportEngine._resolve_palette(palette))
        syntax == "dark" && write(joinpath(dir, "code-dark.tmTheme"), _CODE_DARK_TMTHEME)
        write(joinpath(dir, "deck-settings.typ"), deck_settings_typ(ds.values; ratio, palette))
        _deck_fonts!(dir, ds.values)
        io = IOBuffer()
        print(io, _typst_preamble_slides(nb.report.title; syntax, code))
        _apply_deck_template!(io, dir, notebook_deck_template(nb))
        print(io, _SLIDES_TAIL)
        cells = filter(c -> renders(c.kind), nb.report.cells)
        # Role-tagged metadata → a dedicated title slide (metablock); hoisted title/abstract cells
        # are dropped from the body slides.
        fm = report_frontmatter(nb.report)
        citekeys = Set(e.key for e in bibliography_index(nb.report, dirname(abspath(nb.path))))
        figidx = figure_index(nb.report)
        arg(s) = isempty(strip(s)) ? "none" : "\"" * _typ_str(s) * "\""
        bycell = Dict(c.id => c for c in cells)
        deck = slide_deck(nb; level = level, drop = c -> c.id in fm.skip || :bibliography in c.flags)
        plan.deck = deck
        fragkw = (; theme = "deck", charttheme = ct, override = override, show_source = show_source,
                  include_params = include_params, citekeys = citekeys, figidx = figidx, outputs = outputs, sizes = mediasz, warnings,
                  compfigs = compfigs)
        if fm.has
            # The title page belongs to the slide of the model that holds the `title` cell. The lines of
            # that cell that are no region are the blocks of fragment 0 of that slide.
            tsi = something(findfirst(sl -> (sl.title !== nothing && sl.title.cell == fm.rolecell) ||
                                            any(f -> f.cell == fm.rolecell, sl.frags), slide_deck(nb; level = level)), 0)
            rio = IOBuffer()
            if !isempty(fm.rest)
                tc = bycell[fm.rolecell]
                _emit_slide_frag!(rio, dir, "s$(tsi)f0", nb,
                                  (cell = tc, src = fm.rest, interpbase = _md_interp_count(tc.source) - _md_interp_count(fm.rest));
                                  blk = _block_printer(plan, tsi, 0, (cell = tc.id, row = 1, column = 1)), fragkw...)
            end
            meta = string("metablock(", arg(fm.title), ", ", arg(fm.subtitle), ", ", arg(fm.byline), ", ", arg(fm.abstract), ")")
            print(io, "#SUBLEVEL.update(", fm.sublevel, ")\n")   # the heading level of the subtitle, for `metablock`
            print(io, "#slide(layout: \"title\", ", position(rio) == 0 ? meta : string("metarest(", meta, ", [\n", String(take!(rio)), "])"), ")\n\n")
            haskey(bycell, fm.rolecell) && _error_warnings!(warnings, tsi, [(bycell[fm.rolecell], nothing, 0)])
            push!(plan.pages, tsi)
            for (name, text) in (("title", fm.title), ("subtitle", fm.subtitle), ("byline", fm.byline), ("abstract", fm.abstract))
                isempty(strip(text)) || get!(plan.texts, (tsi, name), String(text))
            end
        end
        titles = fill("", length(deck))   # per slide: its `title: …` argument, or "" without a title
        for (si, sl) in enumerate(deck)
            t = sl.title
            # The H1 that the title slide shows is not drawn again on a body slide.
            (t === nothing || (t.cell == fm.titlecell && t.depth == 1)) && continue
            md = _md_for_typst(bycell[t.cell], t.text; citekeys = citekeys, figrefs = figidx.labels, interpbase = t.interpbase)
            write(joinpath(dir, "s$(si)title.md"),
                  _stage_typst_md_media(md, dir, "s$(si)title", _proj_root(nb); sizes = mediasz, warnings, cell = t.cell))
            titles[si] = "title: heading(level: $(t.depth), $(_md_render("s$(si)title.md")))"
            get!(plan.texts, (si, "title"), _exporter_markdown(md))   # the text that the PDF draws, `{{ }}` resolved
        end
        for (si, sl) in enumerate(deck)
            frags = [(cell = bycell[b.cell], src = b.src, interpbase = b.interpbase) for b in sl.frags]
            parts = Any[(f.cell, f.src, f.interpbase) for f in frags]
            sl.title === nothing || pushfirst!(parts, (bycell[sl.title.cell], sl.title.text, sl.title.interpbase))
            _error_warnings!(warnings, si, parts)
            (isempty(frags) && isempty(titles[si])) && continue
            args = filter(!isempty, [sl.layout === nothing ? "" : "layout: \"$(_typ_str(sl.layout))\"", titles[si]])
            print(io, isempty(args) ? "#slide[\n" : "#slide($(join(args, ", ")))[\n")
            push!(plan.pages, si)
            # Each side-by-side row of the model is one `slidecols` call with a column per fragment. Rows
            # that print something have the gap between cells of the live deck between them.
            gap = false
            for row in unique(b.row for b in sl.frags)
                fis = findall(b -> b.row == row, sl.frags)
                function emit(rio, fi)
                    f = frags[fi]
                    # Strip the hoisted H1 from the implicit-title cell so it isn't repeated on a body
                    # slide, taking the interpolation offset with it (see `_body_after_hoisted_h1`).
                    if f.cell.id == fm.titlecell && f.src === nothing
                        body, off = _body_after_hoisted_h1(f.cell)
                        f = (cell = f.cell, src = body, interpbase = off)
                    end
                    _emit_slide_frag!(rio, dir, "s$(si)f$(fi)", nb, f; blk = _block_printer(plan, si, fi, sl.frags[fi]), fragkw...)
                end
                rio = IOBuffer()
                # A row that holds a markdown cell centres its cells, as on the live deck.
                length(fis) == 1 ? emit(rio, fis[1]) :
                    _print_slidecols(j -> emit(rio, fis[j]), rio, fill("none", length(fis)); gap = "settings.columns.row-gap",
                                     align = any(fi -> is_prose(frags[fi].cell.kind), fis) ? "horizon" : nothing, row = true)
                out = String(take!(rio))
                isempty(strip(out)) && continue       # a cell that draws nothing (no output) has no gap
                gap && print(io, "#cellgap\n")
                gap = true
                print(io, out)
            end
            print(io, "]\n\n")
        end
        # References slide — `:bibliography` cells rendered via Typst's CSL engine.
        biblio = _bibliography_files!(dir, fm.bibcells, dirname(abspath(nb.path)); cited = cited_citation_keys(nb.report))
        isempty(biblio) || print(io, "#slide(layout: \"references\")[\n",
            _bibliography_typst(biblio, get(nb.report.meta, "bibstyle", "ieee"); dir), "]\n\n")
        if notes
            for (si, sl) in enumerate(deck)
                isempty(sl.notes) && continue
                ntext = join((_md_for_typst(bycell[id]; citekeys = citekeys, figrefs = figidx.labels) for id in sl.notes), "\n\n")
                ntext = _stage_typst_md_media(ntext, dir, "notes$(si)", _proj_root(nb); sizes = mediasz, warnings,
                                              cell = join(sl.notes, ", "))   # embedded images → staged files
                isempty(strip(ntext)) && continue
                write(joinpath(dir, "notes$(si).md"), ntext)
                print(io, "#slide(", join(filter(!isempty, ["layout: \"notes\"", titles[si], "n: $(si)"]), ", "), ")[\n",
                      "#", _md_render("notes$(si).md"), "\n]\n\n")
            end
        end
        # The slide of the title page has the layout of that page (`"title"`) in the plan, unless its tag
        # sets one. After the pages: a body page of that slide keeps the layout of its tag.
        fm.has && tsi > 0 && plan.deck[tsi].layout === nothing && (plan.deck[tsi] = merge(plan.deck[tsi], (; layout = "title")))
        write(joinpath(dir, "media.json"), JSON.json(mediasz))   # always present: the preamble reads it
        write(joinpath(dir, "doc.typ"), String(take!(io)))
        return dir
    end
end

"""
    export_typst_bundle(nb; <same options as export_pdf>) -> Vector{UInt8}

The complete Typst PROJECT — `doc.typ` plus every figure / markdown / code-listing asset it
references — as a gzip-compressed tarball (`.tar.gz`). Unpack it and `typst compile doc.typ`
reproduces the PDF, so the layout and preamble can be tweaked by hand. A slide deck carries its deck
settings (`deck-settings.typ`), the files of its deck template, and the shipped Inter font when its
settings use it. When the project has a `fonts` directory, compile with
`typst compile --font-path fonts doc.typ`.
"""
function export_typst_bundle(nb::LiveNotebook; kwargs...)
    dir = _build_typst_project(nb; kwargs...)
    try
        tarball = Tar.create(dir)
        try
            return transcode(GzipCompressor, read(tarball))
        finally
            rm(tarball; force = true)
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end
