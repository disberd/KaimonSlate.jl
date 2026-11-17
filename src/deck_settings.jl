# ── Deck settings ─────────────────────────────────────────────────────────────────────────────────
# The content values of the slide deck (body typography, rhythm, palette, paint of each block kind) in
# one schema that the live deck, the Typst slides PDF and an exporter read. The base file
# `assets/deck-settings.toml` holds every key with its base value and fixes the unit of each length. A
# deck template gives a partial TOML file (`provide_deck_template!(source; settings)`) and the notebook
# gives a second one (the setting `decksettings`). The hub merges base ← deck template ← notebook key by
# key and checks each value once, here. A value that fails a check is dropped with a warning and the
# value below it stays: a warning never stops a deck or an export.

const _DECK_BASE_PATH = joinpath(@__DIR__, "assets", "deck-settings.toml")

# The base deck font: Inter 4.1 (github.com/rsms/inter, release v4.1, the static TTF files of
# `extras/ttf`), under the SIL Open Font License (`LICENSE.txt` beside the files). The live deck loads
# it as "Slate Inter" (notebook.css `@font-face`), after an "Inter" that the machine has; a slides
# export copies it into the project's `fonts` directory.
const _INTER_DIR = joinpath(@__DIR__, "assets", "fonts", "inter")

# Copy the shipped Inter files into `dir/fonts` when a font list of the settings names Inter, so that
# Typst finds the font on any machine. A template's own fonts in `fonts/` stay beside them.
function _deck_fonts!(dir::AbstractString, s)
    "Inter" in s["text"]["font"] || "Inter" in s["code"]["font"] || return
    mkpath(joinpath(dir, "fonts"))
    for f in readdir(_INTER_DIR)
        endswith(f, ".ttf") && cp(joinpath(_INTER_DIR, f), joinpath(dir, "fonts", f); force = true)
    end
end

# Base keys: Slate warns when a deck template sets one. The notebook can set them with no warning.
const _DECK_BASE_GROUPS = ("rhythm", "fit", "columns")
const _DECK_BASE_KEYS = ("table.text-size", "table.line-height", "table.pad-x", "table.header-pad-y",
                         "table.body-pad-y", "table.full-width")
_deck_base_owned(g, k) = g in _DECK_BASE_GROUPS || "$g.$k" in _DECK_BASE_KEYS

# Keys whose value is one word of a fixed list.
_deck_choices(g, k) = g == "code" && k == "syntax" ? ("auto", "light", "dark") :
                      g == "figures" && k == "slate-palette" ? ("", sort!(collect(keys(ReportEngine.SLATE_PALETTES)))...) :
                      nothing

const _DECK_LENGTH_RE = r"^(-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))([a-z%]*)$"
const _DECK_HEX_RE = r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"
const _DECK_NAME_RE = r"^[A-Za-z][A-Za-z0-9_-]{0,47}$"
const _DECK_FONT_RE = r"^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,63}$"
const _DECK_ROLES = ("fg", "strong", "dim", "accent", "accent2", "surface", "ink")
_deck_slate_names() = String.(fieldnames(typeof(ReportEngine.SLATE_PALETTES["midnight"])))

# The kind of a key, from its base value.
function _deck_kind(g, k, v)
    _deck_choices(g, k) === nothing || return :choice
    v isa Bool && return :bool
    v isa Real && return :ratio
    v isa AbstractVector && return :font
    v isa AbstractString && match(_DECK_LENGTH_RE, v) !== nothing && return :length
    return :colour
end

# Parse `v` as a value of `kind` (`unit` for a length). Returns the value, or a `_DeckReject` that says
# why Slate does not accept the value.
struct _DeckReject
    why::String
end
function _deck_parse(kind::Symbol, v, unit::Symbol, choices)
    if kind === :length
        v isa AbstractString || return _DeckReject("must be a length such as \"18u\" or \"0.55em\"")
        m = match(_DECK_LENGTH_RE, v)
        m === nothing && return _DeckReject("must be a length such as \"18u\" or \"0.55em\"")
        u = m.captures[2]
        u in ("u", "em") || return _DeckReject("has the unit \"$u\": only u and em are accepted, and this key takes $unit")
        Symbol(u) === unit || return _DeckReject("has the unit $u: this key takes $unit")
        return (value = parse(Float64, m.captures[1]), unit = unit)
    elseif kind === :ratio
        (v isa Real && !(v isa Bool) && isfinite(v)) || return _DeckReject("must be a plain number")
        return Float64(v)
    elseif kind === :bool
        v isa Bool || return _DeckReject("must be true or false")
        return v
    elseif kind === :font
        names = v isa AbstractString ? [v] : v
        (names isa AbstractVector && !isempty(names) &&
         all(n -> n isa AbstractString && match(_DECK_FONT_RE, n) !== nothing, names)) ||
            return _DeckReject("must be a list of font names (letters, digits, space, . _ + -)")
        return String.(names)
    elseif kind === :choice
        (v isa AbstractString && v in choices) ||
            return _DeckReject("must be one of " * join(repr.(choices), ", "))
        return String(v)
    else
        v isa AbstractString || return _DeckReject("must be a colour: hex, a palette name, a role name or \"slate.<name>\"")
        match(_DECK_HEX_RE, v) !== nothing && return lowercase(v)
        if startswith(v, "slate.")
            v[7:end] in _deck_slate_names() && return String(v)
            return _DeckReject("names no colour of the Slate palette (" * join(_deck_slate_names(), ", ") * ")")
        end
        (v == "none" || match(_DECK_NAME_RE, v) !== nothing) && return String(v)
        return _DeckReject("must be a colour: hex, a palette name, a role name or \"slate.<name>\"")
    end
end

# The base settings as typed values: group → key → value, with each admonition category a Dict under
# its name in `admonition`. Read again when the file changes.
const _DECK_BASE = Ref{Any}(nothing)
const _DECK_BASE_MTIME = Ref(0.0)
const _DECK_LOCK = ReentrantLock()
function _deck_base()
    lock(_DECK_LOCK) do
        t = mtime(_DECK_BASE_PATH)
        if _DECK_BASE[] === nothing || t != _DECK_BASE_MTIME[]
            raw = TOML.parsefile(_DECK_BASE_PATH)
            base = Dict{String,Dict{String,Any}}()
            for (g, tbl) in raw
                d = base[g] = Dict{String,Any}()
                for (k, v) in tbl
                    if v isa AbstractDict      # an admonition category: kinds from the default keys
                        d[k] = Dict{String,Any}(ck => _deck_typed(g, ck, tbl[ck], cv) for (ck, cv) in v)
                    else
                        d[k] = _deck_typed(g, k, v, v)
                    end
                end
            end
            _DECK_BASE[] = base
            _DECK_BASE_MTIME[] = t
            empty!(_DECK_CACHE)
        end
        return _DECK_BASE[]
    end
end
function _deck_typed(g, k, basev, v)
    kind = _deck_kind(g, k, basev)
    unit = kind === :length ? Symbol(match(_DECK_LENGTH_RE, basev).captures[2]) : :none
    p = _deck_parse(kind, v, unit, _deck_choices(g, k))
    p isa _DeckReject && error("deck-settings.toml: $g.$k $(p.why)")
    return p
end
_deck_unit(basev) = basev isa NamedTuple ? basev.unit : :none
_deck_kind_of(g, k, basev) = _deck_choices(g, k) !== nothing ? :choice :
    basev isa NamedTuple ? :length : basev isa Bool ? :bool : basev isa Float64 ? :ratio :
    basev isa Vector{String} ? :font : :colour

# Merge one partial file (`text`, TOML) into `s`. `from` names the layer in the warnings: "deck template"
# or "notebook".
function _deck_merge!(s, base, text::AbstractString, from::AbstractString, warns::Vector{String})
    isempty(strip(text)) && return
    layer = try
        TOML.parse(text)
    catch e
        msg = e isa TOML.ParserError ? sprint(showerror, e) : string(e)
        push!(warns, "Deck settings of the $from: not valid TOML, so they are not used ($(first(split(msg, '\n'))))")
        return
    end
    warn(path, why) = push!(warns, "Deck settings of the $from: `$path` $why. The value is not used.")
    for (g, tbl) in layer
        if !(tbl isa AbstractDict)
            warn(g, "is not a group of the deck settings")
            continue
        end
        if g == "palette"
            for (name, v) in tbl
                match(_DECK_NAME_RE, name) === nothing && (warn("palette.$name", "is not a valid name"); continue)
                p = v isa AbstractString && match(_DECK_HEX_RE, v) !== nothing ? lowercase(v) : nothing
                p === nothing ? warn("palette.$name", "must be a hex colour") : (s["palette"][name] = p)
            end
            continue
        end
        haskey(base, g) || (warn(g, "is not a group of the deck settings"); continue)
        for (k, v) in tbl
            if g == "admonition" && v isa AbstractDict           # [admonition.<category>]
                match(_DECK_NAME_RE, k) === nothing && (warn("admonition.$k", "is not a valid category name"); continue)
                cat = get!(() -> Dict{String,Any}(), s["admonition"], k)
                for (ck, cv) in v
                    bv = get(base["admonition"], ck, nothing)
                    (bv === nothing || bv isa AbstractDict) && (warn("admonition.$k.$ck", "is not a key of the deck settings"); continue)
                    p = _deck_parse(_deck_kind_of(g, ck, bv), cv, _deck_unit(bv), nothing)
                    p isa _DeckReject ? warn("admonition.$k.$ck", p.why) : (cat[ck] = p)
                end
                continue
            end
            bv = get(base[g], k, nothing)
            (bv === nothing || bv isa AbstractDict) && (warn("$g.$k", "is not a key of the deck settings"); continue)
            p = _deck_parse(_deck_kind_of(g, k, bv), v, _deck_unit(bv), _deck_choices(g, k))
            p isa _DeckReject && (warn("$g.$k", p.why); continue)
            from == "deck template" && _deck_base_owned(g, k) &&
                push!(warns, "Deck settings of the deck template: `$g.$k` is a base key, which a deck template should not set.")
            s[g][k] = p
        end
    end
end

# A colour value given as a word must find it in [palette] or [roles]: else the base value comes back.
function _deck_check_refs!(s, base, warns)
    pal = s["palette"]
    function check(path, d, k, bd, roles_ok)
        v = d[k]
        (v isa String && match(_DECK_NAME_RE, v) !== nothing && v != "none") || return
        (haskey(pal, v) || (roles_ok && v in _DECK_ROLES)) && return
        push!(warns, "Deck settings: `$path` names \"$v\", which is not in [palette]" *
                     (roles_ok ? " or [roles]" : "") * ". The value below it is used.")
        d[k] = bd[k]
    end
    for (g, d) in s, k in collect(keys(d))
        g == "palette" && continue
        if d[k] isa AbstractDict
            bcat = get(base[g], k, base[g])
            for ck in collect(keys(d[k]))
                check("$g.$k.$ck", d[k], ck, haskey(bcat, ck) ? bcat : base[g], true)
            end
        elseif _deck_kind_of(g, k, base[g][k]) === :colour
            check("$g.$k", d, k, base[g], g != "roles")
        end
    end
    r = s["roles"]
    for k in _DECK_ROLES                       # text and page colours: "none" paints nothing
        r[k] == "none" || continue
        push!(warns, "Deck settings: `roles.$k` cannot be \"none\". The value below it is used.")
        r[k] = base["roles"][k]
    end
    if !startswith(r["surface"], "slate.")
        left = [k for k in ("fg", "strong", "dim") if startswith(r[k], "slate.")]
        isempty(left) || push!(warns, "Deck settings: `roles.surface` is a fixed colour, but " *
            join(("`roles.$k`" for k in left), ", ") * " follow the Slate palette, so the text can be hard to read on some palettes.")
    end
end

"""
    deck_settings(template, notebook) -> (; values, warnings)

The merged deck settings: the base file, then the partial TOML text `template` of the deck template,
then the partial TOML text `notebook` (the notebook setting `decksettings`), key by key. `values` is
group → key → value: a length is `(value, unit)` with `unit` `:u` or `:em`, a ratio a `Float64`, a font a
`Vector{String}`, a colour the string as written (a hex value, a palette name, a role name, `"none"` or
`"slate.<name>"`). Each admonition category is a `Dict` under its name in `values["admonition"]`. A key or
value that fails a check gives one line in `warnings` and is not used.
"""
function deck_settings(template::AbstractString, notebook::AbstractString)
    base = _deck_base()
    key = hash((template, notebook))
    cached = lock(() -> get(_DECK_CACHE, key, nothing), _DECK_LOCK)
    cached === nothing || return cached
    s = Dict{String,Dict{String,Any}}(g => Dict{String,Any}(k => v isa AbstractDict ? copy(v) : v for (k, v) in d)
                                      for (g, d) in base)
    warns = String[]
    _deck_merge!(s, base, template, "deck template", warns)
    _deck_merge!(s, base, notebook, "notebook", warns)
    _deck_check_refs!(s, base, warns)
    r = (; values = s, warnings = warns)
    lock(_DECK_LOCK) do
        length(_DECK_CACHE) > 64 && empty!(_DECK_CACHE)
        _DECK_CACHE[key] = r
    end
    return r
end
const _DECK_CACHE = Dict{UInt64,Any}()

# The deck settings of a notebook: its deck template's file and its `decksettings` setting.
function notebook_deck_settings(nb)
    t = notebook_deck_template(nb)
    return deck_settings(t === nothing ? "" : t.settings, String(get(nb.report.meta, "decksettings", "")))
end

# The admonition default and each category merged on it, as name → Dict.
function _deck_admonition(s)
    a = s["admonition"]
    dflt = Dict{String,Any}(k => v for (k, v) in a if !(v isa AbstractDict))
    return dflt, Dict{String,Any}(k => merge(dflt, v) for (k, v) in a if v isa AbstractDict)
end

# Resolve a colour value. `slate` is the Slate palette (a NamedTuple of hex) for an export, or `nothing`
# for the live deck, where a `slate.` name and a role stay CSS references. Returns a hex string, a CSS
# `var(…)` (live only) or `nothing` for "none".
function _deck_colour(s, v::AbstractString, slate)
    v == "none" && return nothing
    startswith(v, "#") && return v
    if startswith(v, "slate.")
        return slate === nothing ? "var(--$(v[7:end]))" : getfield(slate, Symbol(v[7:end]))
    end
    haskey(s["palette"], v) && return s["palette"][v]
    slate === nothing && return "var(--deck-$v)"
    return _deck_colour(s, s["roles"][v], slate)
end

_deck_num(x::Real) = isinteger(x) ? string(Int(x)) : string(round(Float64(x); digits = 4))

# The figures' Slate palette: `figures.slate-palette`, else `palette` (the export picker or the UI theme).
_deck_figure_palette(s, palette::AbstractString) =
    (fp = s["figures"]["slate-palette"]; isempty(fp) ? String(palette) : fp)

# True when the export picker changes no colour of the deck: no value refers to the Slate palette and
# `figures.slate-palette` names one.
function deck_fixes_colours(s)
    slate(v) = v isa AbstractString && startswith(v, "slate.") || v isa AbstractDict && any(slate, values(v))
    return !isempty(s["figures"]["slate-palette"]) && !any(d -> any(slate, values(d)), values(s))
end

# True when a hex colour is light (the luminance rule of `_export_is_light`).
function _hex_is_light(hex::AbstractString)
    h = lstrip(hex, '#')
    length(h) in (3, 4) && (h = join(c^2 for c in h[1:3]))
    r, g, b = (parse(Int, h[i:i+1]; base = 16) for i in (1, 3, 5))
    return (0.299r + 0.587g + 0.114b) / 255 >= 0.5
end

# `code.syntax` resolved for an export: "light" or "dark".
function _deck_syntax(s, slate)
    v = s["code"]["syntax"]
    v == "auto" || return v
    bg = _deck_colour(s, s["roles"]["surface"], slate)
    return bg === nothing || _hex_is_light(bg) ? "light" : "dark"
end

# ── Live deck: the custom properties ──────────────────────────────────────────────────────────────
# The roles, the font and the palette go on the deck roots, as the base rule of notebook.css did. Every
# other value goes on each slide: a `u` length reads `--u`, which only the slide has, and a value that
# refers to a role must see a role that the template CSS sets on the slide. Both rules are in `:where`,
# so any package CSS overrides them.
_sorted(d) = sort!(collect(d); by = first)
_deck_css_name(g, k) = g == "roles" ? "--deck-$k" : (g == "text" && k == "font") ? "--deck-font" : "--deck-$g-$k"
function _deck_css_value(s, v, g, k)
    v isa NamedTuple && return v.unit === :u ? "calc($(_deck_num(v.value)) * var(--u))" : "$(_deck_num(v.value))em"
    v isa Bool && return v ? "1" : "0"
    v isa Real && return _deck_num(v)
    # "Slate Inter" is the shipped Inter: a machine that has Inter uses its own, with all its weights.
    v isa Vector{String} && return join((n == "Inter" ? "\"Inter\", \"Slate Inter\"" : "\"$n\"" for n in v), ", ") *
                                   (g == "code" ? ", monospace" : ", sans-serif")
    _deck_choices(g, k) === nothing || return "\"$v\""
    c = _deck_colour(s, v, nothing)
    return c === nothing ? "transparent" : c
end

"""
    deck_settings_css(s) -> String

The live deck's CSS for the merged settings `s` (the `values` of [`deck_settings`](@ref)): one custom
property per value, in two `:where(…)` rules (specificity zero), so that a package's CSS overrides them.
"""
function deck_settings_css(s)
    root, slide = String[], String[]
    for (k, v) in _sorted(s["palette"])
        push!(root, "--deck-palette-$k: $v;")
    end
    for g in sort!(collect(keys(s))), k in sort!(collect(keys(s[g])))
        (g == "palette" || g == "admonition") && continue
        decl = string(_deck_css_name(g, k), ": ", _deck_css_value(s, s[g][k], g, k), ";")
        push!(g == "roles" || (g == "text" && k == "font") ? root : slide, decl)
    end
    dflt, cats = _deck_admonition(s)
    for (k, v) in _sorted(dflt)
        push!(slide, "--deck-admonition-$k: $(_deck_css_value(s, v, "admonition", k));")
    end
    for (c, d) in _sorted(cats), (k, v) in _sorted(d)
        push!(slide, "--deck-admonition-$c-$k: $(_deck_css_value(s, v, "admonition", k));")
    end
    return string(":where(.deck, .pp-frame, .deck-sheet, .deck-print) { ", join(root, " "), " }\n",
                  ":where(.deck-slide) { ", join(slide, " "), " }\n")
end

# ── Typst: deck-settings.typ ──────────────────────────────────────────────────────────────────────
function _deck_typ_value(s, v, g, k, slate)
    v isa NamedTuple && return v.unit === :u ? "$(_deck_num(v.value)) * u" : "$(_deck_num(v.value))em"
    v isa Bool && return v ? "true" : "false"
    v isa Real && return _deck_num(v)
    v isa Vector{String} && return "(" * join(("\"$(_typ_str(n))\"" for n in v), ", ") * ",)"
    g == "code" && k == "syntax" && return "\"$(_deck_syntax(s, slate))\""
    _deck_choices(g, k) === nothing || return "\"$(_typ_str(v))\""
    c = _deck_colour(s, v, slate)
    return c === nothing ? "none" : "rgb(\"$c\")"
end
_deck_typ_dict(pairs) = isempty(pairs) ? "(:)" : "(" * join(("\"$k\": $v" for (k, v) in pairs), ", ") * ")"

"""
    deck_settings_typ(s; ratio, palette) -> String

The Typst module `deck-settings.typ` for the merged settings `s`: `SLIDE_W`, `SLIDE_H`, the slide unit
`u` (the page width over 1920, or 1440 at 4:3) and `settings`, a dictionary of the groups with real
lengths and `rgb("#…")` colours. `palette` is the Slate palette name that fills the `slate.` colours.
"""
function deck_settings_typ(s; ratio::AbstractString, palette::AbstractString)
    slate = ReportEngine._resolve_palette(palette)
    w, h = _slide_geom(ratio)
    io = IOBuffer()
    println(io, "// The deck settings of this export, written by Slate. Do not edit: the next export writes it again.")
    println(io, "#let SLIDE_W = $w")
    println(io, "#let SLIDE_H = $h")
    println(io, "#let u = SLIDE_W / $(first(deck_canvas(ratio)))")
    groups = String[]
    for g in sort!(collect(keys(s)))
        if g == "palette"
            push!(groups, "\"palette\": " * _deck_typ_dict(("$(k)" => "rgb(\"$v\")" for (k, v) in _sorted(s[g]))))
        elseif g == "admonition"
            dflt, cats = _deck_admonition(s)
            pairs = Pair{String,String}[k => _deck_typ_value(s, v, g, k, slate) for (k, v) in _sorted(dflt)]
            for (c, d) in _sorted(cats)
                push!(pairs, c => _deck_typ_dict((k => _deck_typ_value(s, v, g, k, slate) for (k, v) in _sorted(d))))
            end
            push!(groups, "\"admonition\": " * _deck_typ_dict(pairs))
        else
            push!(groups, "\"$g\": " * _deck_typ_dict((k => _deck_typ_value(s, v, g, k, slate) for (k, v) in _sorted(s[g]))))
        end
    end
    println(io, "#let settings = (\n  ", join(groups, ",\n  "), ",\n)")
    return String(take!(io))
end

# ── Exporter ──────────────────────────────────────────────────────────────────────────────────────
"""
    deck_settings_dict(s; palette) -> Dict{String,Any}

The merged settings `s` as an exporter reads them: group → key → value, plain Base types only. A length
is `(value = 34.0, unit = :u)`, a ratio a `Float64`, a font a `Vector{String}`, a colour a hex string
(`nothing` for "none"): the roles and every `slate.` name are resolved against the Slate palette
`palette`. `code.syntax` is "light" or "dark". One more key, `slate_palette`, is the name of the Slate
palette of the figures (`figures.slate-palette`, else `palette`).
"""
function deck_settings_dict(s; palette::AbstractString)
    slate = ReportEngine._resolve_palette(palette)
    val(g, k, v) = v isa NamedTuple || v isa Real || v isa Vector{String} ? v :
                   g == "code" && k == "syntax" ? _deck_syntax(s, slate) :
                   _deck_choices(g, k) !== nothing ? v : _deck_colour(s, v, slate)
    out = Dict{String,Any}()
    for (g, d) in s
        g == "admonition" && continue
        out[g] = g == "palette" ? copy(d) : Dict{String,Any}(k => val(g, k, v) for (k, v) in d)
    end
    dflt, cats = _deck_admonition(s)
    adm = out["admonition"] = Dict{String,Any}(k => val("admonition", k, v) for (k, v) in dflt)
    for (c, d) in cats
        adm[c] = Dict{String,Any}(k => val("admonition", k, v) for (k, v) in d)
    end
    out["slate_palette"] = _deck_figure_palette(s, palette)
    return out
end
