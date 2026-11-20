# ── Block kinds ───────────────────────────────────────────────────────────────────────────────────
# A block is one top-level element of markdown: a paragraph, a list, a block quote, a table, a code
# block, an admonition. Each block has one kind of `BLOCK_KINDS`. `_md_blocks` is the one detector:
# every target (the notebook view, the HTML export, the documents, the slide deck) reads the kind that
# it finds. It puts each block of a kind in `_WRAPPED_KINDS` into a `<slate-<kind>>` element.
# CommonMark keeps the element in the HTML, where the deck CSS selects it. cmarker sends it to an
# `html:` handler of the Typst preamble.
#
# | Kind          | Markdown                                                                 | Attributes            |
# |---------------|--------------------------------------------------------------------------|-----------------------|
# | `key-message` | A block quote.                                                           |                       |
# | `caption`     | A paragraph that is one emphasis, with optional citations after it.      |                       |
# | `caption`     | Each block of a cell with the `caption` tag (a figure caption).          | `number`              |
# | `admonition`  | `!!! category "Title"`.                                                  | `category`, `heading` |
# | `figure`      | A paragraph that holds only one image, or only one `{{ }}` figure value. |                       |
# | `table`       | A table.                                                                 |                       |
# | `code`        | A code block. No element.                                                |                       |
# | `prose`       | Each other block. No element.                                            |                       |
#
# The detector looks at the top-level blocks and at the blocks of each `:::` fenced div (a div is a
# container: print drops its fence lines and keeps its blocks). It does not look inside a block: a
# table in an admonition is part of the admonition. It does not look inside the element of a region
# of the title slide (`_REGION_ELEMENTS`): the text of a region is plain text on every target, so an
# emphasis byline is no caption. Such an element is one part of the kind `prose`.

const BLOCK_KINDS = ("prose", "key-message", "caption", "admonition", "code", "figure", "table")
const _WRAPPED_KINDS = ("key-message", "caption", "admonition", "figure", "table")
const _REGION_ELEMENTS = ("subtitle", "byline", "abstract")
const _SLATE_TAG_RE = Regex("<(/?)slate-(" * join((_WRAPPED_KINDS..., _REGION_ELEMENTS...), "|") * ")(?=[\\s>])")
# The text after the emphasis of a caption: citations only, in the source form (`[@key]`, `@key`), as
# the citation link of the page, or as the citation mark of the Typst export.
const _CAPTION_TAIL_RE = r"^(?:\s*(?:\[[^\]]*@[^\]]*\]|<a class=\"(?:cite|figref)\"[^>]*>.*?</a>|§c§[^§]*§[^§]+§[^§]*§|@[\w:.\-]+)[,;.]?)*\s*$"s
const _INTERP_ONLY_RE = r"^xslateinterpx(\d+)x$"

# The parser of every markdown renderer of Slate: GFM tables, `!!! category "Title"` admonitions and
# Pandoc `:::` fenced divs.
function _md_parser()
    p = CommonMark.Parser()
    enable!(p, CommonMark.TableRule())
    enable!(p, CommonMark.AdmonitionRule())
    enable!(p, CommonMark.FencedDivRule())
    return p
end

_attr_esc(s) = replace(String(s), '&' => "&amp;", '"' => "&quot;", '<' => "&lt;", '>' => "&gt;", r"\s+" => " ")

function _children(n)
    out = CommonMark.Node[]
    c = n.first_child
    while !CommonMark.isnull(c)
        push!(out, c)
        c = c.nxt
    end
    return out
end

# The kind of a paragraph. `figure(i)` is true when the i-th `{{ }}` value of the source is a figure.
function _paragraph_kind(p, figure)
    kids = filter(_children(p)) do k
        !(k.t isa CommonMark.SoftBreak || k.t isa CommonMark.LineBreak ||
          (k.t isa CommonMark.Text && isempty(strip(k.literal))))
    end
    isempty(kids) && return "prose"
    all(k -> k.t isa Union{CommonMark.Text,CommonMark.HtmlInline}, kids[2:end]) || return "prose"
    tail = join(k.literal for k in kids[2:end])
    t = first(kids).t
    if t isa CommonMark.Emph
        return occursin(_CAPTION_TAIL_RE, tail) ? "caption" : "prose"
    elseif t isa CommonMark.Image                    # `{width=…}` can follow the image
        return occursin(r"^\s*(?:\{[^{}]*\})?\s*$", tail) ? "figure" : "prose"
    elseif t isa CommonMark.Text && isempty(tail)
        m = match(_INTERP_ONLY_RE, strip(first(kids).literal))
        return m !== nothing && figure(parse(Int, m[1])) ? "figure" : "prose"
    end
    return "prose"
end

function _block_kind(n, figure)
    t = n.t
    t isa CommonMark.BlockQuote && return "key-message"
    t isa CommonMark.Admonition && return "admonition"
    t isa CommonMark.Table && return "table"
    t isa CommonMark.CodeBlock && return "code"
    t isa CommonMark.Paragraph && return _paragraph_kind(n, figure)
    return "prose"
end

# The last source line of a block node. An end column of 0 says that the node ends before that line.
_last_line(n) = n.sourcepos[2][2] == 0 ? n.sourcepos[2][1] - 1 : n.sourcepos[2][1]
# +1 for each start tag of a block-kind element in `s`, -1 for each end tag.
_slate_depth(s) = sum(m -> isempty(m[1]) ? 1 : -1, eachmatch(_SLATE_TAG_RE, s); init = 0)

"""
    _md_blocks(src; plain = false, caption = nothing, figure = Returns(false)) -> Vector{(kind, text)}

The markdown `src` in parts, in reading order. A part with a kind of `BLOCK_KINDS` is one block:
`text` is its source, inside its `<slate-<kind>>` element when the kind has one. A part with the kind
`""` is the text between two blocks (empty lines, the fence lines of a `:::` div, link definitions).
The parts joined with a line feed are the markdown with the block kinds marked (`_md_kinds`).

- `plain`: write the body of an admonition as plain CommonMark, for a reader with no admonition rule
  (cmarker, an exporter). The category and the title are the attributes of the element.
- `caption`: the figure number of a cell with the `caption` tag. Each block is then a caption, and
  the first one has the `number` attribute.
- `figure(i)`: true when the i-th `{{ }}` value of `src` is a figure.

A block that is in a `<slate-…>` element already stays as it is, so a second call changes nothing.
"""
function _md_blocks(src::AbstractString; plain::Bool = false, caption::Union{Nothing,Integer} = nothing,
                    figure = Returns(false), only_admonitions::Bool = false)
    lines = split(String(src), '\n'; keepempty = true)
    parts = @NamedTuple{kind::String, text::String}[]
    gap = String[]                                   # the lines since the last block
    next = 1                                         # the first line that is in no part yet
    numbered = false
    # Lines `a:b` are one block. With `wrap`, `body` goes into the element of `kind`. The element is an
    # HTML block: it starts after an empty line and it ends at an empty line.
    function block!(kind, a, b; wrap = false, attrs = "", body = @view lines[a:b])
        append!(gap, @view lines[next:a-1])
        next = b + 1
        wrap && (isempty(gap) ? !isempty(parts) : !isempty(strip(last(gap)))) && push!(gap, "")
        isempty(gap) || push!(parts, (kind = "", text = join(gap, "\n")))
        empty!(gap)
        text = wrap ? string("<slate-", kind, attrs, ">\n\n", join(body, "\n"), "\n\n</slate-", kind, ">") : join(body, "\n")
        push!(parts, (; kind, text))
        wrap && b < length(lines) && !isempty(strip(lines[b+1])) && push!(gap, "")
    end
    # `limit` is the last line that a block of `parent` can have. The parser gives the last block of a
    # div the end tag line of the div.
    function walk(parent, limit)
        kids = _children(parent)
        i = 1
        while i <= length(kids)
            n = kids[i]; i += 1
            if n.t isa CommonMark.FencedDiv              # a container: its blocks are blocks of the source
                e = min(_last_line(n), limit)
                walk(n, occursin(r"^\s*:{3,}\s*$", lines[e]) ? e - 1 : e)
                continue
            end
            a, b = n.sourcepos[1][1], _last_line(n)
            m = n.t isa CommonMark.HtmlBlock ? match(_SLATE_TAG_RE, lstrip(n.literal)) : nothing
            if m !== nothing && m.offset == 1 && isempty(m[1])
                # A block that has its element already: the nodes up to its end tag are one part.
                d = _slate_depth(n.literal)
                while d > 0 && i <= length(kids)
                    kids[i].t isa CommonMark.HtmlBlock && (d += _slate_depth(kids[i].literal))
                    b = _last_line(kids[i])
                    i += 1
                end
            end
            b = min(b, limit)
            while b > a && isempty(strip(lines[b])); b -= 1; end
            if m !== nothing && m.offset == 1 && isempty(m[1])
                block!(m[2] in _REGION_ELEMENTS ? "prose" : String(m[2]), a, b)
            elseif caption !== nothing
                block!("caption", a, b; wrap = true, attrs = numbered ? "" : " number=\"$caption\"")
                numbered = true
            else
                kind = _block_kind(n, figure)
                wrap = kind in _WRAPPED_KINDS && (!only_admonitions || kind == "admonition")
                if kind == "admonition" && wrap
                    attrs = string(" category=\"", _attr_esc(n.t.category), "\" heading=\"", _attr_esc(n.t.title), "\"")
                    plain ? block!(kind, a, b; wrap, attrs, body = _admonition_body(lines[a+1:b])) : block!(kind, a, b; wrap, attrs)
                else
                    block!(kind, a, b; wrap)
                end
            end
        end
    end
    walk(_md_parser()(_mask_math(src)), length(lines))
    append!(gap, @view lines[next:end])
    isempty(gap) || push!(parts, (kind = "", text = join(gap, "\n")))
    return parts
end

"The markdown `src` with each block of a wrapped kind in its `<slate-<kind>>` element (see `_md_blocks`)."
_md_kinds(src::AbstractString; kw...) = join((p.text for p in _md_blocks(src; kw...)), "\n")

# The source with each formula as one word on each of its lines, so that a `*` or a `_` of TeX is not
# emphasis for the parser. The lines keep their numbers.
_mask_math(src) = join(k === :math ? replace(t, r"[^\n]+" => "xslatemathx") : t for (k, t) in _md_segments(src))

# The body lines of an admonition as plain CommonMark: without the four columns of indent (one tab
# counts as four) and without the empty lines at its start. An admonition inside it gets its element.
function _admonition_body(body)
    out = [startswith(l, '\t') ? l[2:end] : replace(l, r"^ {1,4}" => "") for l in body]
    while !isempty(out) && isempty(strip(first(out))); popfirst!(out); end
    return split(_md_kinds(join(out, "\n"); plain = true, only_admonitions = true), '\n')
end

# A footnote definition at the start of a block or of a line: `[^id]: text`.
const _FOOTNOTE_DEF_RE = r"^ {0,3}\[\^([^\]\s]+)\]:"

"""
    _md_split(src) -> Vector{(kind, text)}

The blocks of the markdown `src`, in reading order, for a reader that draws each block alone (the
slides PDF makes one `cmarker.render` call for each block). `kind` is one of `BLOCK_KINDS`. `text`
is the source of the block and the definitions that the block needs:

- Each link reference definition of `src` goes after every block. A block that does not use a
  definition ignores it.
- A footnote definition is not a block. It goes before the block that refers to it, because cmarker
  reads a footnote only when its definition is in the same call, and it draws the note where the
  definition is. A definition that no block refers to goes before the last block.
- When two blocks refer to one footnote, `src` stays one `prose` block: two calls with the same
  definition give the same Typst label two times, which stops the compile.
"""
function _md_split(src::AbstractString)
    blocks = @NamedTuple{kind::String, text::String}[]
    links = String[]
    notes = Pair{String,String}[]                    # footnote id => definition
    innote = false                                   # the last block was a footnote definition
    for p in _md_blocks(src; plain = true)
        if isempty(p.kind)                           # CommonMark makes no block for a definition
            for ln in split(p.text, '\n')
                isempty(strip(ln)) && continue
                m = match(_FOOTNOTE_DEF_RE, ln)
                m === nothing ? push!(links, String(ln)) : push!(notes, String(m[1]) => String(ln))
            end
            continue
        end
        m = p.kind == "prose" ? match(_FOOTNOTE_DEF_RE, p.text) : nothing
        if m !== nothing
            push!(notes, String(m[1]) => p.text)
            innote = true
        elseif innote && p.kind == "code" && occursin(r"^(?: {4}|\t)", p.text)   # a later paragraph of the note
            notes[end] = first(notes[end]) => string(last(notes[end]), "\n\n", p.text)
        else
            push!(blocks, p)
            innote = false
        end
    end
    isempty(blocks) && return blocks
    texts = [b.text for b in blocks]
    for (id, def) in notes
        users = findall(b -> occursin("[^$id]", b.text), blocks)
        length(users) > 1 && return [(kind = "prose", text = String(src))]
        k = isempty(users) ? lastindex(texts) : only(users)
        texts[k] = string(def, "\n\n", texts[k])
    end
    tail = isempty(links) ? "" : "\n\n" * join(links, "\n")
    return [(kind = b.kind, text = t * tail) for (b, t) in zip(blocks, texts)]
end
