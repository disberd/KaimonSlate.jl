# Presentation / slideshow mode: slide segmentation, the `slide`/`notes` tags, the slide-deck
# config footer round-trip, cell_json flag exposure, and a Typst slide-deck compile smoke test.
# Loads the package (NotebookServer holds the segmentation + export), so it runs under Pkg.test.
using ReTest
import JSON
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

_mknb(src) = NS.LiveNotebook("deck", "/tmp/slidetest.jl", RE.parse_report(src),
    RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
    ReentrantLock(), "", false, Dict{String,String}())

@testset "slideshow mode" begin

    @testset "heading depth + rule splitting" begin
        @test NS._first_heading_depth("intro\n## Slide\nbody") == 2
        @test NS._first_heading_depth("# Title") == 1
        @test NS._first_heading_depth("no headings here") === nothing
        @test NS._first_heading_depth("```\n## fenced\n```\n### real") == 3   # fenced code skipped
        @test length(NS._split_md_rules("a\n---\nb\n---\nc")) == 3
        @test length(NS._split_md_rules("plain text, no rule")) == 1
        # A leading `---` is an ordinary thematic break now (no YAML front matter): break, then body.
        @test length(NS._split_md_rules("---\nbody")) == 2
    end

    @testset "segmentation: headings / slide tag / notes / collapsed" begin
        src = """
        #%% md id=title
        intro, no heading

        #%% md id=s1
        ## First
        body

        #%% code id=c1
        x = 1

        #%% md id=n1 notes
        speaker note

        #%% md id=s2
        ## Second

        #%% code id=expl slide
        y = 2
        """
        cells = RE.parse_report(src).cells
        segs = NS._slide_segments(cells; level = 2)
        ids(s) = [f[1].id for f in s.frags]
        @test length(segs) == 4
        @test ids(segs[1]) == ["title"]                 # pre-heading → title slide
        @test ids(segs[2]) == ["s1", "c1"]              # heading starts, code flows in
        @test [n.id for n in segs[2].notes] == ["n1"]   # notes attach to the current slide
        @test ids(segs[3]) == ["s2"]
        @test ids(segs[4]) == ["expl"]                  # explicit `slide` tag starts a slide
    end

    @testset "level controls the boundary" begin
        src = "#%% md id=a\n## two\n\n#%% md id=b\n### three\n"
        cells = RE.parse_report(src).cells
        @test length(NS._slide_segments(cells; level = 2)) == 1   # ### does not break at level 2
        @test length(NS._slide_segments(cells; level = 3)) == 2   # ### breaks at level 3
    end

    @testset "--- splits a markdown cell mid-cell" begin
        src = "#%% md id=s\n## Topic\n\npart one\n\n---\n\npart two\n"
        segs = NS._slide_segments(RE.parse_report(src).cells; level = 2)
        @test length(segs) == 2
        @test occursin("part one", segs[1].frags[1][2])
        @test occursin("part two", segs[2].frags[1][2])
    end

    @testset "a --- chunk resolves ITS OWN interpolations" begin
        # `_md_template` numbers a fragment's interpolations from 1, but `Cell.interp` is numbered
        # across the whole cell — so a chunk has to carry how many precede it or every chunk after the
        # first silently renders an earlier chunk's value. The fence matters: `_desugar_fences` turns
        # every tagged fence into an interpolation too, so counting `{{` would put the offset at 1 here
        # and still land on the wrong entry.
        src = "#%% md id=s\n## One\n\n```julia\nx = 1\n```\n\nalpha {{ a }}\n\n---\n\n## Two\n\nbeta {{ b }}\n"
        c = RE.parse_report(src).cells[end]
        out(v) = RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], v, nothing, nothing, 1.0)
        c.interp = [out(""), out("111"), out("222")]        # slot 1 is the fence (no captured value)
        segs = NS._slide_segments([c]; level = 2)
        @test length(segs) == 2
        f1, f2 = segs[1].frags[1], segs[2].frags[1]
        @test (f1.interpbase, f2.interpbase) == (0, 2)
        m1 = NS._md_for_typst(c, f1.src; interpbase = f1.interpbase)
        m2 = NS._md_for_typst(c, f2.src; interpbase = f2.interpbase)
        @test occursin("111", m1) && !occursin("222", m1)
        @test occursin("222", m2) && !occursin("111", m2)
        @test occursin("x = 1", m1)                          # unclaimed fence still prints as code
        # The offset is what does the work. Drop it and chunk two reads slot 1 — here the fence, which
        # captured nothing — so `beta` renders with its value missing entirely rather than merely wrong.
        @test !occursin("222", NS._md_for_typst(c, f2.src; interpbase = 0))
    end

    @testset "dropping the hoisted H1 shifts the interpolation base" begin
        # The title cell's H1 is hoisted into the title block and removed from the body. Anything
        # interpolated in that line goes with it, so the body no longer starts at interpolation 1.
        src = "#%% md id=t\n# Report for {{ who }}\n\nbody says {{ what }}\n"
        c = RE.parse_report(src).cells[end]
        out(v) = RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], v, nothing, nothing, 1.0)
        c.interp = [out("ACME"), out("hello")]
        body, base = NS._body_after_hoisted_h1(c)
        @test base == 1 && !occursin("Report for", body)
        md = NS._md_for_typst(c, body; interpbase = base)
        @test occursin("hello", md) && !occursin("ACME", md)
    end

    @testset "slide_deck: layout, title, frags, transition, auto, notes" begin
        src = """
        #%% md id=a layout=title transition=zoom auto=5
        # Hello *world*

        body one

        #%% md id=b notes
        say hello

        #%% md id=c
        ## Plain

        - x

        #%% code id=d column=2
        1 + 1

        #%% md id=e
        intro, no heading first
        ### Later heading

        #%% code id=f slide layout=center
        y = 2

        #%% md id=g slide layout=section
        #### Deep title
        """
        deck = NS.slide_deck(_mknb(src); level = 3)
        @test length(deck) == 5
        # a tagged slide that starts with a heading: tag values, title out of the body
        @test deck[1].layout == "title" && deck[1].transition == "zoom" && deck[1].auto == "5"
        @test deck[1].title.text == "Hello *world*" && deck[1].title.depth == 1
        @test [b.cell for b in deck[1].frags] == ["a"]
        @test strip(deck[1].frags[1].src) == "body one"
        @test deck[1].notes == ["b"]
        # an untagged slide: no tag values
        @test deck[2].layout === nothing && deck[2].transition === nothing && deck[2].auto === nothing
        @test deck[2].title.text == "Plain" && deck[2].title.depth == 2
        @test deck[2].notes == String[]
        # column group of a body block
        @test [(b.cell, b.row, b.column) for b in deck[2].frags] == [("c", 1, 1), ("d", 1, 2)]
        # a slide whose first block is not a heading has no title
        @test deck[3].title === nothing && deck[3].frags[1].cell == "e"
        # the first cell with a layout tag wins; a code cell first means no title
        @test deck[4].layout == "center" && deck[4].title === nothing
        # a title-only slide stays in the deck, with no fragments
        @test deck[5].title.depth == 4 && isempty(deck[5].frags) && deck[5].layout == "section"
    end

    @testset "slide_deck: a heading with an interpolation keeps the body's numbering" begin
        src = "#%% md id=a\n## Total {{ t }}\n\nvalue {{ v }}\n"
        deck = NS.slide_deck(_mknb(src))
        @test deck[1].title.interpbase == 0
        @test deck[1].frags[1].interpbase == 1
    end

    @testset "slide_deck: the title follows the CommonMark ATX rule" begin
        title(src) = (d = NS.slide_deck(_mknb("#%% md id=a\n" * src)); isempty(d) ? nothing : d[1].title)
        @test title("   ## Indented").text == "Indented"
        @test title("    ## Code block") === nothing        # four spaces make a code block
        @test title("# Title##").text == "Title##"           # a closing run needs a space before it
        @test title("# Title ##").text == "Title"
    end

    @testset "slides project: layouts and titles reach doc.typ" begin
        src = """
        #%% md id=a layout=center
        ## Tagged

        text

        #%% md id=b
        plain body, no heading
        ## Second

        #%% md id=c notes
        a note

        #%% md id=s layout=section
        ## Part one

        #%% md id=r bibliography
        @book{k, author = {A, B}, title = {T}, publisher = {P}, year = {2000}}
        """
        dir = NS._build_slides_project(_mknb(src); notes = true)
        try
            doc = read(joinpath(dir, "doc.typ"), String)
            @test occursin(r"#slide\(layout: \"center\", title: heading\(level: 2,", doc)
            @test occursin(r"#slide\(layout: \"section\", title: heading\(level: 2,", doc)
            @test occursin("#slide[\n", doc)                                  # untagged, untitled
            @test occursin("#slide(layout: \"references\")[", doc)
            @test occursin(r"#slide\(layout: \"notes\", n: 2\)\[", doc)      # slide 2 has no title
        finally
            rm(dir; recursive = true, force = true)
        end
        # the title slide from role-tagged metadata passes its layout
        dir = NS._build_slides_project(_mknb("#%% md id=t title\n# Doc\n\n#%% md id=a\n## One\n"))
        try
            @test occursin("#slide(layout: \"title\", metablock(", read(joinpath(dir, "doc.typ"), String))
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "slides project: columns" begin
        # A `:::: columns` group and a `column=N` row both reach doc.typ as one `slidecols` call, with
        # the `width` of each column or `none`. Other fenced divs keep their content.
        src = """
        #%% md id=a
        ## Cols

        :::: columns
        ::: {.column width="40%"}
        <!--raw-typst #context { let p = here().position(); [#metadata((x: p.x.pt())) <colx>] }-->left
        :::
        ::: column
        <!--raw-typst #context { let p = here().position(); [#metadata((x: p.x.pt())) <colx>] }-->right
        :::
        ::::

        ::: step
        kept text
        :::

        #%% md id=b
        ## Rows

        one

        #%% md id=c column=2
        two

        #%% md id=d
        ## Equal

        :::: columns
        ::: column
        <!--raw-typst #context { let p = here().position(); [#metadata((x: p.x.pt())) <eqx>] }-->a
        :::
        ::: column
        <!--raw-typst #context { let p = here().position(); [#metadata((x: p.x.pt())) <eqx>] }-->b
        :::
        ::::
        """
        dir = NS._build_slides_project(_mknb(src))
        try
            doc = read(joinpath(dir, "doc.typ"), String)
            @test occursin("#slidecols((40%, none,),", doc)
            @test occursin("#slidecols((none, none,),", doc)
            @test count("#slidecols((none, none,),", doc) == 2     # the `column=2` row and the equal group
            @test NS._column_width_typst("min-width=50%") == "none" && NS._column_width_typst(".column width=30") == "30%"
            md = join((read(joinpath(dir, f), String) for f in readdir(dir) if endswith(f, ".md")), "\n")
            @test occursin("kept text", md) && !occursin(":::", md)
            # The columns start where the widths say: on a 16:9 page 1 u is 720 pt / 1920, the margins
            # are the 120 u of the live deck plus the 16 u padding of a markdown cell, and the gutter is
            # the deck setting `columns.gap`.
            xs(label) = [p["x"] for p in NS._typst_query(joinpath(dir, "doc.typ"), label)]
            u = 720 / 1920
            left, row, gap = 136u, 720 - 272u, NS.deck_settings("", "").values["columns"]["gap"].value * u
            @test xs("<colx>") ≈ [left, left + 0.4row + gap] atol = 1       # `width="40%"` and the rest
            @test xs("<eqx>") ≈ [left, left + (row - gap) / 2 + gap] atol = 1   # equal columns
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "slide/notes are known tags and round-trip" begin
        @test :slide in RE._KNOWN_TAGS
        @test :notes in RE._KNOWN_TAGS
        r = RE.parse_report("#%% code id=a slide\nx=1\n\n#%% md id=b notes\nhi\n")
        @test :slide in r.cells[1].flags
        @test :notes in r.cells[2].flags
        r2 = RE.parse_report(RE.serialize_report(r))
        @test :slide in r2.cells[1].flags && :notes in r2.cells[2].flags
    end

    @testset "config footer round-trips slide prefs (typed)" begin
        r = RE.parse_report("#%% code id=a\nx=1\n")
        r.meta["slidelevel"] = 3
        r.meta["slidetransition"] = "slide"
        r.meta["slideratio"] = "4:3"
        r.meta["decksettings"] = "[text]\nsize = \"36u\"  # a comment\n"
        r2 = RE.parse_report(RE.serialize_report(r))
        @test r2.meta["slidelevel"] === 3           # parsed back as an Int, not a String
        @test r2.meta["slidetransition"] == "slide"
        @test r2.meta["slideratio"] == "4:3"
        @test r2.meta["decksettings"] == r.meta["decksettings"]   # several lines survive the footer
    end

    # The deck settings: base file ← deck template ← notebook, key by key. A value that fails a check
    # gives a warning, and the value below it stays.
    @testset "deck settings: merge order and checks" begin
        base = NS.deck_settings("", "")
        @test isempty(base.warnings)
        @test base.values["text"]["size"] == (value = 34.0, unit = :u)
        len(g, k, r) = r.values[g][k]

        r = NS.deck_settings("[text]\nsize = \"36u\"\nline-height = 1.3\n", "[text]\nsize = \"38u\"\n")
        @test isempty(r.warnings)
        @test len("text", "size", r) == (value = 38.0, unit = :u)       # the notebook wins
        @test len("text", "line-height", r) == 1.3                      # the template's other key stays
        @test len("text", "paragraph-after", r) == (value = 0.55, unit = :em)   # the base fills the rest

        # An unknown group or key: a warning, and no value.
        r = NS.deck_settings("[text]\nsizes = \"36u\"\n[nogroup]\na = 1\n", "")
        @test length(r.warnings) == 2 && all(w -> occursin("is not a", w), r.warnings)
        @test r.values == base.values

        # A unit that is not the unit of the key, or not u or em: a warning, and the value below stays.
        r = NS.deck_settings("[text]\nsize = \"36u\"\n", "[text]\nsize = \"2em\"\n[columns]\ngap = \"56px\"\n")
        @test len("text", "size", r).value == 36 && len("columns", "gap", r) == (value = 56.0, unit = :u)
        @test count(w -> occursin("unit", w), r.warnings) == 2

        # Values reach CSS and Typst text, so each must match a strict pattern.
        r = NS.deck_settings("[roles]\nfg = \"red; } body { x\"\n[text]\nfont = [\"Inter\\\"; }\"]\n" *
                             "[code]\nsyntax = \"neon\"\n[palette]\nbad = \"blue\"\n", "")
        @test length(r.warnings) == 4 && r.values == base.values

        # A base key from a deck template warns; from the notebook it does not.
        @test any(w -> occursin("base key", w), NS.deck_settings("[rhythm]\ncell-gap = \"20u\"\n", "").warnings)
        @test isempty(NS.deck_settings("", "[rhythm]\ncell-gap = \"20u\"\n").warnings)

        # A colour word must be in [palette] (or [roles], outside the roles); else the base value stays.
        r = NS.deck_settings("[palette]\nnavy = \"#003247\"\n[roles]\nfg = \"navy\"\n[caption]\ncolor = \"accent\"\n", "")
        @test isempty(r.warnings) && r.values["roles"]["fg"] == "navy" && r.values["caption"]["color"] == "accent"
        r = NS.deck_settings("[roles]\nfg = \"dim\"\n", "")
        @test length(r.warnings) == 1 && r.values["roles"]["fg"] == "slate.text"

        # A fixed surface with text roles on the Slate palette warns.
        r = NS.deck_settings("[roles]\nsurface = \"#ffffff\"\nfg = \"#003247\"\n", "")
        @test length(r.warnings) == 1 && occursin("roles.strong", r.warnings[1]) && occursin("roles.dim", r.warnings[1])
        @test isempty(NS.deck_settings("[roles]\nsurface = \"#ffffff\"\nfg = \"#003247\"\nstrong = \"#003247\"\n" *
                                       "dim = \"#8197a6\"\n", "").warnings)

        # Text that is not TOML: one warning, and the layer is not used.
        r = NS.deck_settings("[text\n", "")
        @test length(r.warnings) == 1 && r.values == base.values

        # An admonition category takes the default for the keys it does not set; any word is a category.
        r = NS.deck_settings("[admonition.aside]\naccent = \"#123456\"\n", "")
        @test isempty(r.warnings)
        d = NS.deck_settings_dict(r.values; palette = "daylight")
        @test d["admonition"]["aside"]["accent"] == "#123456"
        @test d["admonition"]["aside"]["radius"] == d["admonition"]["radius"]
    end

    # A `slate.` colour is a CSS reference on the live deck and a hex value of the export's Slate
    # palette in the PDF and for an exporter.
    @testset "deck settings: slate. colours, the live CSS and deck-settings.typ" begin
        s = NS.deck_settings("", "").values
        for (name, p) in RE.SLATE_PALETTES
            d = NS.deck_settings_dict(s; palette = name)
            @test (d["roles"]["fg"], d["roles"]["strong"], d["roles"]["dim"], d["roles"]["accent"], d["roles"]["surface"]) ==
                  (p.text, p.text, p.dim, p.accent, p.bg)
            @test d["slate_palette"] == name
            typ = NS.deck_settings_typ(s; ratio = "16:9", palette = name)
            @test occursin("\"fg\": rgb(\"$(p.text)\")", typ) && occursin("\"surface\": rgb(\"$(p.bg)\")", typ)
        end
        # A figure palette that the deck settings name wins over the export palette.
        fixed = NS.deck_settings("[figures]\nslate-palette = \"daylight\"\n", "").values
        @test NS.deck_settings_dict(fixed; palette = "midnight")["slate_palette"] == "daylight"

        # Live: `slate.` names stay CSS references, and every rule is inside `:where(…)`, so that a
        # package CSS overrides it.
        nb = _mknb("#%% md id=a\n## A\n\nbody\n")
        css = NS.state_json(nb)["deckCss"]
        @test occursin("--deck-fg: var(--text);", css) && occursin("--deck-surface: var(--bg);", css)
        @test occursin("--deck-rhythm-cell-gap: calc(18 * var(--u));", css)
        rules = [strip(r) for r in split(css, '}') if !isempty(strip(r))]
        @test !isempty(rules) && all(r -> startswith(r, ":where("), rules)

        # The slides PDF: with no export palette, `theme = "light"` gives daylight and `"dark"` midnight.
        for (theme, name) in (("light", "daylight"), ("dark", "midnight"))
            dir = NS._build_slides_project(nb; theme)
            try
                typ = read(joinpath(dir, "deck-settings.typ"), String)
                @test occursin("\"fg\": rgb(\"$(RE.SLATE_PALETTES[name].text)\")", typ)
                @test occursin("#import \"deck-settings.typ\"", read(joinpath(dir, "doc.typ"), String))
            finally
                rm(dir; recursive = true, force = true)
            end
        end
    end

    # The Typst preamble reads the deck settings: a template's `text.size` moves the body text size that
    # the fit record measures, in `u`.
    @testset "a deck setting moves the measured text size in the PDF" begin
        sizes = map(("", "[text]\nsize = \"40u\"\n")) do set
            nb = _mknb("#%% md id=a\n## A\n\nbody text\n")
            nb.deck_template = (; hash = "h", source = "", settings = set, files = Dict{String,Vector{UInt8}}())
            dir = NS._build_slides_project(nb)
            try
                recs = NS._typst_query(joinpath(dir, "doc.typ"), "<slate>")
                only(r["size"] for r in recs if r isa AbstractDict && r["kind"] == "fit")
            finally
                rm(dir; recursive = true, force = true)
            end
        end
        @test sizes[1] ≈ 34 && sizes[2] ≈ 40
    end

    # The base preamble copies the rhythm and the geometry of the live base deck: two paragraphs are
    # `text.line-height` + `text.paragraph-after` apart, and a content slide shows its number at the
    # bottom right.
    @testset "the base PDF: the paragraph gap of the settings, the slide number" begin
        # A mark inside the first line of each paragraph (at the start of a line, the comment would be
        # an HTML block that joins the two paragraphs).
        mark(k) = "<!--raw-typst #context [#metadata(here().position().y.pt()) <$k>]-->"
        set = "[text]\nparagraph-after = \"1em\"\n"
        nb = _mknb("#%% md id=a\n## A\n\nOne$(mark("p1")) line.\n\nThe$(mark("p2")) next line.\n")
        nb.deck_template = (; hash = "h", source = "", settings = set, files = Dict{String,Vector{UInt8}}())
        dir = NS._build_slides_project(nb)
        try
            doc = joinpath(dir, "doc.typ")
            y(k) = only(NS._typst_query(doc, "<$k>")) / (720 / 1920)      # in u
            t = NS.deck_settings(set, "").values["text"]
            @test y("p2") - y("p1") ≈ t["size"].value * (t["line-height"] + t["paragraph-after"].value) atol = 0.5
            pdf = joinpath(dir, "out.pdf")
            NS._typst_compile(doc, pdf)
            num = match(r"xMin=\"([\d.]+)\" yMin=\"([\d.]+)\"[^>]*>1</word>", read(`pdftotext -bbox -f 1 -l 1 $pdf -`, String))
            @test num !== nothing && parse(Float64, num[1]) > 680 && parse(Float64, num[2]) > 380
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    # The base deck font is Inter in the PDF too: the project carries the shipped files, and Typst
    # embeds them on a machine that has no Inter of its own.
    @testset "the base slides PDF is set in the shipped Inter" begin
        nb = _mknb("#%% md id=a\n## A\n\nbody text\n")
        dir = NS._build_slides_project(nb)
        try
            @test isfile(joinpath(dir, "fonts", "Inter-Regular.ttf")) && isfile(joinpath(dir, "fonts", "Inter-Bold.ttf"))
            pdf = joinpath(dir, "out.pdf")
            NS._typst_compile(joinpath(dir, "doc.typ"), pdf)
            @test occursin("Inter-Regular", read(`pdffonts $pdf`, String))
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "cell_json exposes slide/notes flags" begin
        r = RE.parse_report("#%% code id=a slide\nx=1\n\n#%% md id=b notes\nhi\n")
        j1 = NS.cell_json(r.cells[1]); j2 = NS.cell_json(r.cells[2])
        @test get(j1, "slide", false) == true
        @test get(j2, "notes", false) == true
        @test "slide" in j1["tags"] && "notes" in j2["tags"]
    end

    @testset "slide-deck PDF compiles" begin
        nb = _mknb("#%% md id=t\n# Deck\nhi\n\n#%% md id=s\n## One\n\n- a\n- b\n")
        # Typst fetches registry packages on first compile; guard on network/availability so the
        # suite stays green offline — but assert real bytes whenever it does run.
        pdf = try
            NS.export_pdf(nb; layout = "slides", theme = "dark")
        catch err
            @info "slide PDF compile skipped" err
            nothing
        end
        @test pdf === nothing || length(pdf) > 1000
    end

    @testset "a deck template drives the PDF and the bundle" begin
        # The template font comes from a pinned commit of google/fonts (SIL OFL). Without curl or a
        # network, the deck still compiles in the fallback font, and only the font check is skipped.
        fonturl = "https://raw.githubusercontent.com/google/fonts/90abd17b4f97671435798b6147b698aa9087612f/ofl/monoton/Monoton-Regular.ttf"
        font = try
            Sys.which("curl") === nothing ? nothing : read(`curl -sSfL --max-time 30 $fonturl`)
        catch
            nothing
        end
        tpl = """
        #let slide(body, layout: none, title: none, n: none) = page[
          #set text(font: "Monoton")
          TPL layout=#repr(layout) title=#(if title == none { "none" } else { title.body }) name=#toml("cfg.toml").name
          #body
        ]
        """
        files = Dict("cfg.toml" => Vector{UInt8}("name = \"tomlvalue\"\n"))
        font === nothing || (files["fonts/Monoton-Regular.ttf"] = font)
        src = "#%% md id=s layout=center\n## Shown\n\nbody text\n"
        text(pdf) = (f = tempname() * ".pdf"; write(f, pdf);
                     try read(`pdftotext -layout $f -`, String) finally rm(f) end)
        plain = _mknb(src)
        before = try
            dir = NS._build_slides_project(plain)
            try
                read(joinpath(dir, "doc.typ"), String)
            finally
                rm(dir; recursive = true, force = true)
            end
        catch
            nothing
        end
        nb = _mknb(src)
        nb.deck_template = (; hash = "h", source = tpl, settings = "", files)
        pdf = try
            NS.export_pdf(nb; layout = "slides")
        catch err
            @info "deck template PDF skipped" err
            nothing
        end
        if pdf === nothing || Sys.which("pdftotext") === nothing
            @test true
        else
            t = text(pdf)
            @test occursin("TPL layout=\"center\"", t) && occursin("title=Shown", t) && occursin("name=tomlvalue", t)
            if font === nothing || Sys.which("pdffonts") === nothing
                @info "font check skipped (font download or pdffonts unavailable)"
                @test true
            else
                f = tempname() * ".pdf"; write(f, pdf)
                fonts = try read(`pdffonts $f`, String) finally rm(f) end
                @test occursin("Monoton", fonts)
            end

            # The bundle holds the same files; unpacked, it compiles to the same text and page count.
            bundle = NS.export_typst_bundle(nb; layout = "slides")
            out = mktempdir()
            try
                gz = joinpath(out, "b.tar.gz"); write(gz, bundle)
                proj = joinpath(out, "proj"); mkpath(proj)
                run(`tar -xzf $gz -C $proj`)
                @test read(joinpath(proj, "cfg.toml"), String) == "name = \"tomlvalue\"\n"
                NS._typst_compile(joinpath(proj, "doc.typ"), joinpath(proj, "again.pdf"))
                @test text(read(joinpath(proj, "again.pdf"))) == t
            finally
                rm(out; recursive = true, force = true)
            end
        end

        # Without a template the preamble is the only prefix; no template text leaks in.
        @test before === nothing || !occursin("deck template", before)

        # A file name that leaves the project directory is refused at the write site.
        io = IOBuffer(); d = mktempdir()
        try
            @test_throws ArgumentError NS._apply_deck_template!(io, d, (; hash = "h", source = "", settings = "",
                                                                      files = Dict("../x" => UInt8[])))
        finally
            rm(d; recursive = true, force = true)
        end
    end

    @testset "slide-deck with CITATIONS compiles (measure-in-isolation regression)" begin
        # A cite() inside the slide fit-scaler's measure() used to abort the whole deck with
        # "cannot format citation in isolation" — the measured copy must render citation
        # sentinels as a stand-in, while the real slide keeps the true citation. Gate on a PLAIN
        # deck compiling first (typst/packages/network available), so offline skips both but a
        # citation-specific failure can never hide behind the skip.
        plain = try
            NS.export_pdf(_mknb("#%% md id=s\n## One\n\nplain\n"); layout = "slides")
        catch
            nothing
        end
        if plain === nothing
            @info "cited slide PDF compile skipped (typst unavailable)"
            @test true
        else
            nb = _mknb("#%% md id=s\n## Cited slide\n\nSee [@knuth1984, p. 3].\n\n" *
                       "#%% md id=refs bibliography\n@book{knuth1984,\n  author = {Knuth, D.},\n" *
                       "  title = {The TeXbook},\n  publisher = {Addison-Wesley},\n  year = {1984}\n}\n")
            pdf = NS.export_pdf(nb; layout = "slides")   # a throw here IS the regression
            @test length(pdf) > 1000
        end
    end

    @testset "the PDF deck fits each slide and records the fit" begin
        # The fixture deck at 16:9 and at 4:3, with three slides added: a figure wider than its column
        # that shares a tall slide with text, a portrait figure alone whose drawn height is measured,
        # and a slide of text that is taller than the page at full size. One `typst query` per ratio
        # reads the fit records of `fit` (label `<slate>`).
        fixture = read(joinpath(@__DIR__, "fixtures", "deck_fixture.jl"), String)
        svg(w, h) = """<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h"><rect width="$w" height="$h" fill="#38c"/></svg>"""
        extra = """
        #slide(title: heading(level: 2)[A figure that shares the slide])[
        Two lines of text above the figure make this slide taller than the page at full size, so
        that the text and the figure share the shrink of the slide.

        #figureimg("wide.svg")
        ]
        #slide[#layout(sz => [#metadata(measure(block(width: sz.width, figureimg("tall.svg"))).height / SLIDE_H) <figcap>])]
        #slide(title: heading(level: 2)[A tall slide of text])[
        #for i in range(20) [Line #i of a slide that is a little taller than the page at full size.\\ ]
        ]
        """
        function query(ratio)
            dir = NS._build_slides_project(_mknb(fixture); ratio)
            try
                write(joinpath(dir, "wide.svg"), svg(2400, 1200)); write(joinpath(dir, "tall.svg"), svg(300, 900))
                doc = joinpath(dir, "doc.typ")
                open(io -> print(io, extra), doc, "a")
                vals = NS._typst_query(doc, "selector(<slate>).or(<figcap>)")
                fits = filter(v -> v isa AbstractDict && v["kind"] == "fit", vals)
                return Dict(r["slide"] => r for r in fits), only(filter(v -> v isa Number, vals)), fits
            finally
                rm(dir; recursive = true, force = true)
            end
        end
        tie(r) = (1 + r["s"]) / 2
        fit, cap, recs = query("16:9")
        @test sort(collect(keys(fit))) == 1:17              # one page per slide: no slide breaks
        tall, atfloor, fig = fit[17], fit[13], fit[15]      # the added tall slide, fixture "…at the floor"
        @test 0.62 <= tall["s"] < 1 && tall["f"] >= tie(tall) && !tall["at_floor"]
        @test atfloor["at_floor"] && atfloor["s"] == 0.62
        @test count(r -> r["at_floor"], recs) == 1
        @test 0.62 <= fig["s"] < 1 && tie(fig) <= fig["f"] < 1 && !fig["at_floor"]   # the figure shrinks less than the text
        @test cap ≈ 0.7 atol = 0.01                          # a tall figure takes at most 0.7 of the slide height
        warns = NS._fit_warnings(recs)                       # the export dialog's warnings
        @test length(warns) == 1 && occursin("Slide 13 ", only(warns))
        # At 4:3 the slide unit is 1/1440 of the page width, as on the live canvas: the body text has
        # the same size in `u` as at 16:9.
        fit43, cap43, _ = query("4:3")
        @test fit43[2]["size"] ≈ fit[2]["size"] && fit43[2]["s"] == 1
        @test cap43 ≈ 0.7 atol = 0.01
    end
end

@testset "deck markup" begin
    R = KaimonSlate.ReportRender
    @testset "fenced divs: columns, steps, incremental" begin
        h = R.markdown_html(":::: columns\n::: {.column width=\"40%\"}\nL\n:::\n::: column\nR\n:::\n::::\n\n" *
                            "::: {.step .zoom step=3}\nS\n:::\n\n::: incremental\n- a\n- b\n:::\n\nkeep {braces}")
        @test occursin("<div class=\"columns\">", h) && occursin("max-width:40%", h)
        @test occursin("class=\"step zoom\"", h) && occursin("step=\"3\"", h)
        @test occursin("<div class=\"incremental\">", h)
        @test occursin("keep {braces}", h)                  # prose braces are not attributes
        # A step that names terms, and a derive equation placed on an explicit step
        h2 = R.markdown_html("::: {.step terms=\"t01\"}\nS\n:::\n\n:::: derive\n\$\$a\$\$\n\n::: {step=4}\n\$\$b\$\$\n:::\n::::")
        @test occursin("terms=\"t01\"", h2) && occursin("step=\"4\"", h2) && occursin("<div class=\"derive\">", h2)
    end
    @testset "pause marker" begin
        h = R.markdown_html("one\n\n. . .\n\ntwo")
        @test occursin("<div class=\"pause\"></div>", h)
        @test !occursin(". . .", h)
    end
    @testset "media from image syntax" begin
        v = R.markdown_html("![autoplay loop](clips/a.mp4){width=600}")
        @test occursin("<video src=\"clips/a.mp4\"", v)
        @test all(occursin(v), ("controls", "loop", "data-autoplay", "playsinline", "width:600px"))
        @test !occursin("muted", v)                                   # autoplay keeps its sound
        @test occursin(" muted", R.markdown_html("![autoplay muted](a.mp4)"))
        a = R.markdown_html("![nocontrols](sound.m4a)")
        @test occursin("<audio src=\"sound.m4a\"", a) && !occursin("controls", a)
        @test occursin("<img", R.markdown_html("![plot](fig.png)"))
    end
    @testset "print drops deck markup, keeps content" begin
        s = NS._strip_deck_markup("::: step\nA\n:::\n. . .\nB\n```\n:::\n```")
        @test s == "A\nB\n```\n:::\n```"                     # fenced code untouched
        @test NS._strip_deck_markup("plain") == "plain"
    end
    @testset "SlideSteps" begin
        w = RE.SlideSteps(4)
        @test w.kind == "slider" && w.params["slidesteps"] === true
        @test w.params["min"] == 0 && w.params["max"] == 4 && w.default == 0
        @test_throws ArgumentError RE.SlideSteps(0)
    end
    @testset "asset byte ranges" begin
        p = tempname(); write(p, collect(UInt8, 0:9))
        req(r) = NS.HTTP.Request("GET", "/n/x/asset/a.mp4", r === nothing ? [] : ["Range" => r])
        full = NS._asset_response(req(nothing), p)
        @test full.status == 200 && length(full.body) == 10
        part = NS._asset_response(req("bytes=2-4"), p)
        @test part.status == 206 && part.body == UInt8[2, 3, 4]
        @test NS.HTTP.header(part, "Content-Range") == "bytes 2-4/10"
        @test NS._asset_response(req("bytes=7-"), p).body == UInt8[7, 8, 9]
        @test NS._asset_response(req("bytes=-3"), p).body == UInt8[7, 8, 9]
        @test NS._asset_response(req("bytes=20-"), p).status == 416
        # Bytes held in memory (a slide figure's clip in the blob store) answer ranges the same way
        bytes = collect(UInt8, 10:19)
        mem(r) = NS._ranged(req(r), ["Accept-Ranges" => "bytes"], length(bytes), () -> bytes, (lo, hi) -> bytes[lo+1:hi+1])
        @test mem(nothing).status == 200 && mem("bytes=0-1").body == UInt8[10, 11] && mem("bytes=-2").body == UInt8[18, 19]
    end
end

@testset "relative media resolves to the asset route" begin
    h = NS._asset_srcs("talk", "<img src=\"figs/a.png\"><video src=\"c.mp4\" poster=\"p.jpg\"></video>" *
                               "<img src=\"/n/x/asset/b.png\"><img src=\"https://x/y.png\"><img src=\"data:image/png;base64,AA\">")
    @test occursin("src=\"/n/talk/asset/figs/a.png\"", h) && occursin("poster=\"/n/talk/asset/p.jpg\"", h)
    @test occursin("src=\"/n/x/asset/b.png\"", h) && occursin("src=\"https://x/y.png\"", h) && occursin("src=\"data:", h)
    @test NS._asset_srcs("", "<img src=\"a.png\">") == "<img src=\"a.png\">"
end

@testset "column widths become flex widths" begin
    h = KaimonSlate.ReportRender.markdown_html(":::: columns\n::: {.column width=\"40%\"}\nL\n:::\n::: {.column width=60}\nR\n:::\n::::")
    @test occursin("style=\"flex:0 1 40%;max-width:40%\"", h)
    @test occursin("style=\"flex:0 1 60%;max-width:60%\"", h)
end

@testset "presentation math macros print as plain math" begin
    f = NS._plain_math_macros
    @test f(raw"$\term{x}{\ddot x} + \stepat{2}{\term{g}{\gamma}\dot x} = \hl{0}$") == raw"${\ddot x} + {{\gamma}\dot x} = {0}$"
    @test f(raw"\cancelat{3}{\omega^2 x}") == raw"\cancel{\omega^2 x}"
    @test f(raw"\termc{F}{red}{\step{F(t)}}") == raw"{{F(t)}}"
    @test f(raw"\termination{a} \text{b}") == raw"\termination{a} \text{b}"      # other commands untouched
    @test f(raw"\term{x}") == raw"\term{x}"                                       # missing argument: left alone
    @test f(raw"\braceat{2}{c\dot x}{friction}") == raw"\underbrace{c\dot x}_{\text{friction}}"
    @test f(raw"\obraceat{1}{m}{mass}") == raw"\overbrace{m}^{\text{mass}}"
    @test f(raw"\focusat{4}{0}") == raw"{0}"
    @test f(raw"x = 0 \qquad \note{divide by m}") == raw"x = 0 \qquad \text{divide by m}"
end

@testset "the slides template defines every helper shared output calls" begin
    pre = NS._typst_preamble_slides("T")
    for h in ("codeblock", "outblock", "valblock", "errblock", "figureimg", "notefig", "figcaption", "paramblock")
        @test occursin("#let $h(", pre)
    end
end

@testset "deck lengths: em for text, the slide unit for geometry" begin
    # The fit changes the text size only, so a deck length that must follow the text is in em and a
    # fixed one is in the slide unit (`--u` live, `u` in Typst), never in px, pt, mm or rem. This scans
    # the notebook.css rules whose selector starts with `.deck-slide`, and the Typst slides preamble.
    # It does not cover deck rules under other selectors (`.slide-title`, `.slide-body`,
    # `.deck-sheet`, `.cell.role-title`), the notebook rules that reach into a slide, or template
    # CSS: the parity run (`parity.mjs`) catches what leaks from those. Markdown image sizes that the
    # author writes (`mdlen`) stay as written.
    abslen = r"(?<![\w.])\d*\.?\d+(px|pt|mm|rem)\b"
    css = replace(read(joinpath(@__DIR__, "..", "src", "assets", "notebook.css"), String), r"/\*.*?\*/"s => "")
    rules = [m for m in eachmatch(r"(?:^|(?<=[{}]))\s*([^{}@]+?)\s*\{([^{}]*)\}", css) if startswith(m[1], ".deck-slide")]
    @test length(rules) > 100                          # the scan reads every rule, not a few
    bad = String[]
    for m in rules, d in split(m[2], ';')
        d = strip(d)
        startswith(d, "--u:") && continue              # the slide unit itself
        occursin(abslen, d) && push!(bad, "$(m[1]) { $d }")
    end
    @test isempty(bad)
    pre = split(NS._typst_preamble_slides("T"), '\n')
    @test isempty(filter(l -> occursin(abslen, l) && !occursin(r"#let (SLIDE_[WH]|mdlen)\b", l), pre))
end

@testset "the API reference covers the deck" begin
    r = NS.slate_api_reference
    @test all(k -> occursin(k, r("cell tags")), ("layout=", "bg=", "transition=", "step", "morph=", "ghost", "column="))
    @test occursin("steps =", r("echart"))
    @test all(k -> occursin(k, r("markdown")), (":::", "columns", ". . .", "clip.mp4", "math slides"))
    @test all(k -> occursin(k, r("slides")), ("deckstyle", "settings(notebook)", "nocontrols", "recordings/"))
    @test occursin("deckstyle", r("settings"))
    @test all(k -> occursin(k, r("math slides")), ("\\term", "\\braceat", "\\note", "::: derive", "STEPS."))
end

@testset "slide_figure: stacked states and the shared palette" begin
    RE = KaimonSlate.ReportEngine
    sf = RE.SlideFigure(800, 400, "data/s0.png",
                        [(; step = 1, kind = :png, path = "data/s1.png", poster = "", terms = String[]),
                         (; step = 2, kind = :video, path = "data/s2.mp4", poster = "data/s2-end.png", terms = ["t01", "t0"])])
    h = sprint(show, MIME("text/html"), sf)
    @test occursin("class=\"slidefig\"", h) && occursin("aspect-ratio:800/400", h)
    @test occursin("<img class=\"step fade sf-layer\" step=\"1\" alt=\"\" data-slate-src=\"data/s1.png\"", h)
    @test occursin("<video class=\"step fade sf-layer sf-anim\" step=\"2\" data-terms=\"t01 t0\"", h)
    @test occursin("data-slate-poster=\"data/s2-end.png\"", h) && !occursin("base64", h)   # paths, not bytes
    # The figure palette is the one the slide math colours terms with (core.js SLATE_TERM_PALETTE).
    js = read(joinpath(@__DIR__, "..", "src", "assets", "js", "core.js"), String)
    for (k, v) in pairs(RE.SLATE_COLORS)
        @test occursin("$k: '$v'", js)
    end
    @test RE.slate_color(:red) == "#fc6255"
    # Moves interpolate any number of values: an Axis window, an Axis3 box, a camera's two angles.
    @test RE._lerp((0.0, 1.0, 0.0, 1.0), (2.0, 3.0, 2.0, 3.0), 1.0) == (2.0, 3.0, 2.0, 3.0)
    @test RE._lerp(Tuple(zeros(6)), Tuple(ones(6)), 0.5) == Tuple(fill(0.5, 6))
    @test RE._view_target((; elevation = Ref(0.3)), (1.0, 0.5)) == (1.0, 0.5)
    @test RE._view_target((; elevation = Ref(0.3)), 2.0) == (2.0, 0.3)      # azimuth only keeps the elevation
    @test RE._terms_of("t01") == ["t01"] && RE._terms_of([:a, "b"]) == ["a", "b"] && isempty(RE._terms_of(nothing))
end

@testset "print takes a slide_figure's finished state" begin
    RE = KaimonSlate.ReportEngine
    sf = RE.SlideFigure(10, 10, "data/a.png", [(; step = 1, kind = :png, path = "data/b.png", poster = "", terms = String[]),
                                               (; step = 2, kind = :video, path = "data/c.mp4", poster = "data/c-end.png", terms = String[])])
    html = Vector{UInt8}(codeunits(sprint(show, MIME("text/html"), sf)))
    assets = [(; path = p, bytes = UInt8[k]) for (k, p) in enumerate(("data/a.png", "data/b.png", "data/c.mp4", "data/c-end.png"))]
    out = (; display = [(; mime = "text/html", data = html)], assets)
    @test NS._slidefig_final_png(out) == UInt8[4]          # the final clip's poster frame
    @test NS._slidefig_final_png((; display = [(; mime = "text/html", data = UInt8[0x3c])], assets)) === nothing
end

@testset "deck print: the page asks for the steps and palette given" begin
    @test NS.deck_print_url("http://h:1", "nb") == "http://h:1/n/nb?deck=print&shot=1"
    @test NS.deck_print_url("http://h:1", "nb"; steps = "all", theme = "daylight") ==
          "http://h:1/n/nb?deck=print&shot=1&steps=all&slatetheme=daylight"
    @test NS.deck_print_url("http://h:1", "nb"; steps = "last", theme = "x\"><script>") ==
          "http://h:1/n/nb?deck=print&shot=1"                    # an unknown value or a bad name: the default
end

@testset "deck browser: KAIMONSLATE_CHROME is used, and a wrong one is named" begin
    exe = tempname(); write(exe, "")
    withenv("KAIMONSLATE_CHROME" => exe) do
        @test NS.chrome_status() == (path = exe, problem = "")
    end
    gone = joinpath(tempdir(), "no-such-browser-$(rand(UInt32))")
    withenv("KAIMONSLATE_CHROME" => gone) do
        st = NS.chrome_status()
        @test st.path === nothing && occursin(gone, st.problem)
    end
    rm(exe)
    # The places searched cover the browsers that drive the same way, on each system.
    files = NS._browser_files()
    @test any(endswith("Microsoft Edge"), files) && any(endswith("Brave Browser"), files)
    @test any(f -> startswith(f, joinpath(homedir(), "Applications")), files)
end

@testset "deck aspect ratios: canvas, video and Typst page agree" begin
    for (r, (w, h)) in ("16:9" => (1920, 1080), "16:10" => (1920, 1200), "4:3" => (1440, 1080))
        @test NS.deck_canvas(r) == (w, h)
        pw, ph = (parse(Float64, chop(s; tail = 2)) for s in NS._slide_geom(r))
        @test isapprox(pw / ph, w / h; rtol = 1e-6)
    end
    @test NS.deck_canvas("") == (1920, 1080)                     # unset: 16:9
end

@testset "deck video: the length is shared out among the steps" begin
    st(t0, t1; words = 0, step = 1, timing = nothing) =
        Dict{String,Any}("t0" => t0, "t1" => t1, "words" => words, "step" => step, "timing" => timing)
    steps = [st(0, 0; step = 0, words = 10), st(0, 2.0), st(0, 0.5; words = 40), st(0, 0.2; step = 0, words = 5)]
    h = NS.deck_hold_times(steps, 60)
    @test isapprox(sum(h), 60; atol = 1e-6)
    # no step is shorter than its own motion, and a step that brings in more words holds longer
    @test all(i -> h[i] >= steps[i]["t1"] - steps[i]["t0"], eachindex(h)) && h[3] > h[2]
    @test_throws ErrorException NS.deck_hold_times(steps, 2)          # the motion alone is longer
    # rehearsed times set the proportions
    r = NS.deck_hold_times([st(0, 0; timing = 4.0), st(0, 0; timing = 12.0)], 32)
    @test isapprox(r[2] / r[1], 3; atol = 1e-3)
end

@testset "deck video: timeline and chapters" begin
    # frames at 0, 1, 1.1, 1.2 s; step 1 starts on frame 1 and holds 2 s, step 2 moves 1.0..1.25 then holds to 3 s
    ts = [0.0, 1.0, 1.1, 1.2]
    steps = [Dict{String,Any}("t0" => 0.0, "t1" => 0.0), Dict{String,Any}("t0" => 1.0, "t1" => 1.25)]
    seq = NS._deck_timeline(ts, steps, [2.0, 3.0])
    @test isapprox(sum(last.(seq)), 5.0; atol = 1e-9)
    @test first.(seq) == [1, 2, 3, 4] && isapprox(seq[end][2], 2.8; atol = 1e-9)   # the last motion frame holds
    @test NS._vtt_time(3725.5) == "01:02:05.500" && NS._vtt_time(0) == "00:00:00.000"
end
