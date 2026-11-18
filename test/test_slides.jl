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
        wpath(r, p) = count(w -> occursin("`$p`", w), r.warnings)       # the warnings about key path `p`

        r = NS.deck_settings("[text]\nsize = \"36u\"\nline-height = 1.3\n", "[text]\nsize = \"38u\"\n")
        @test isempty(r.warnings)
        @test len("text", "size", r) == (value = 38.0, unit = :u)       # the notebook wins
        @test len("text", "line-height", r) == 1.3                      # the template's other key stays
        @test len("text", "paragraph-after", r) == (value = 0.55, unit = :em)   # the base fills the rest

        # An unknown group or key: a warning, and no value.
        r = NS.deck_settings("[text]\nsizes = \"36u\"\n[nogroup]\na = 1\n", "")
        @test length(r.warnings) == 2 && wpath(r, "text.sizes") == 1 && wpath(r, "nogroup") == 1
        @test r.values == base.values

        # A unit that is not the unit of the key, or not u or em: a warning, and the value below stays.
        r = NS.deck_settings("[text]\nsize = \"36u\"\n", "[text]\nsize = \"2em\"\n[columns]\ngap = \"56px\"\n")
        @test len("text", "size", r).value == 36 && len("columns", "gap", r) == (value = 56.0, unit = :u)
        @test length(r.warnings) == 2 && wpath(r, "text.size") == 1 && wpath(r, "columns.gap") == 1

        # Values reach CSS and Typst text, so each must match a strict pattern.
        r = NS.deck_settings("[roles]\nfg = \"red; } body { x\"\n[text]\nfont = [\"Inter\\\"; }\"]\n" *
                             "[code]\nsyntax = \"neon\"\n[palette]\nbad = \"blue\"\n", "")
        @test length(r.warnings) == 4 && r.values == base.values

        # A base key from a deck template warns; from the notebook it does not.
        r = NS.deck_settings("[rhythm]\ncell-gap = \"20u\"\n", "")
        @test length(r.warnings) == 1 && wpath(r, "rhythm.cell-gap") == 1 && r.values["rhythm"]["cell-gap"].value == 20
        @test isempty(NS.deck_settings("", "[rhythm]\ncell-gap = \"20u\"\n").warnings)

        # A colour word must be in [palette] (or [roles], outside the roles); else the base value stays.
        r = NS.deck_settings("[palette]\nnavy = \"#003247\"\n[roles]\nfg = \"navy\"\n[caption]\ncolor = \"accent\"\n", "")
        @test isempty(r.warnings) && r.values["roles"]["fg"] == "navy" && r.values["caption"]["color"] == "accent"
        r = NS.deck_settings("[roles]\nfg = \"dim\"\n", "")
        @test length(r.warnings) == 1 && r.values["roles"]["fg"] == "slate.text"

        # A fixed surface with text roles or admonition accents on the Slate palette warns.
        r = NS.deck_settings("[roles]\nsurface = \"#ffffff\"\nfg = \"#003247\"\n", "")
        @test length(r.warnings) == 1 && occursin("roles.strong", r.warnings[1]) && occursin("roles.dim", r.warnings[1])
        fixedroles = "[roles]\nsurface = \"#ffffff\"\nfg = \"#003247\"\nstrong = \"#003247\"\ndim = \"#8197a6\"\naccent = \"#0055aa\"\n"
        r = NS.deck_settings(fixedroles, "")
        @test length(r.warnings) == 1 && occursin("`admonition.tip.accent`", r.warnings[1]) && !occursin("roles.dim", r.warnings[1])
        cats = join("[admonition.$c]\naccent = \"#22aa55\"\n" for c in ("tip", "hint", "answer", "solution", "warning",
                                                                       "caution", "danger", "error", "compat"))
        @test isempty(NS.deck_settings(fixedroles * cats, "").warnings)

        # Text that is not TOML: one warning that gives the line and the reason, and the layer is not used.
        r = NS.deck_settings("[text\n", "")
        @test length(r.warnings) == 1 && r.values == base.values
        @test occursin(r"\(line \d+: \S", r.warnings[1])

        # An admonition category takes the default for the keys it does not set; any word is a category.
        r = NS.deck_settings("[admonition.aside]\naccent = \"#123456\"\n", "")
        @test isempty(r.warnings)
        d = NS.deck_settings_dict(r.values; palette = "daylight")
        @test d["admonition"]["aside"]["accent"] == "#123456"
        @test d["admonition"]["aside"]["radius"] == d["admonition"]["radius"]

        # A category with the name of a default key: a warning, and the notebook page still loads.
        r = NS.deck_settings("", "[admonition.fill]\naccent = \"#ffffff\"\n")
        @test wpath(r, "admonition.fill") == 1 && r.values == base.values
        nb = _mknb("#%% md id=a\n## A\n")
        nb.report.meta["decksettings"] = "[admonition.fill]\naccent = \"#ffffff\"\n"
        @test NS.state_json(nb)["deckCss"] isa String

        # A number out of its range: a warning, and the value below stays. A large number never reaches
        # the CSS or the Typst text.
        for (g, k, v) in (("text", "size", "\"100000000000000000000u\""), ("text", "size", "\"0u\""),
                          ("text", "size", "\"-5u\""), ("columns", "gap", "\"-100u\""),
                          ("text", "line-height", "1e25"), ("text", "line-height", "-1"),
                          ("fit", "text-floor", "2"), ("fit", "text-floor", "-1"), ("fit", "figure-cap", "0"))
            r = NS.deck_settings("", "[$g]\n$k = $v\n")
            @test wpath(r, "$g.$k") == 1 && r.values == base.values
        end
        r = NS.deck_settings("", "[fit]\ntext-floor = 1\n[columns]\ngap = \"0u\"\n")
        @test isempty(r.warnings)

        # A wrong colour word from the notebook keeps the template's value.
        r = NS.deck_settings("[caption]\ncolor = \"#123456\"\n", "[caption]\ncolor = \"typo\"\n")
        @test wpath(r, "caption.color") == 1 && r.values["caption"]["color"] == "#123456"
        # A palette name of the same layer is found, whatever the order of the groups.
        @test isempty(NS.deck_settings("[caption]\ncolor = \"navy\"\n[palette]\nnavy = \"#003247\"\n", "").warnings)

        # "none" is a paint only: a text colour or a role must have a colour.
        r = NS.deck_settings("[caption]\ncolor = \"none\"\n[roles]\nfg = \"none\"\n[table]\nstripe-fill = \"none\"\nheader-fill = \"none\"\n", "")
        @test wpath(r, "caption.color") == 1 && wpath(r, "roles.fg") == 1 && length(r.warnings) == 2
        @test r.values["table"]["header-fill"] == "none"

        # At most 64 palette names and 32 admonition categories: one warning for the rest.
        many = "[palette]\n" * join(("c$i = \"#000000\"" for i in 1:100), "\n") * "\n" *
               join(("[admonition.k$i]\naccent = \"#000000\"" for i in 1:40), "\n") * "\n"
        r = NS.deck_settings("", many)
        @test length(r.warnings) == 1 && length(r.values["palette"]) == 64
        @test count(v -> v isa AbstractDict, values(r.values["admonition"])) == 32

        # The export picker changes no colour only when no value follows the Slate palette and the
        # figures have a palette of their own.
        @test !NS.deck_fixes_colours(base.values)
        fixed = replace(read(NS._DECK_BASE_PATH, String), r"\"slate\.\w+\"" => "\"#123456\"",
                        "slate-palette = \"\"" => "slate-palette = \"daylight\"")
        @test NS.deck_fixes_colours(NS.deck_settings("", fixed).values)
        @test !NS.deck_fixes_colours(NS.deck_settings("", replace(fixed, "\"daylight\"" => "\"\"")).values)
        # An admonition category accent on the Slate palette is a colour that the picker changes.
        @test !NS.deck_fixes_colours(NS.deck_settings(fixed, "[admonition.tip]\naccent = \"slate.green\"\n").values)
    end

    # A `slate.` colour is a CSS reference on the live deck and a hex value of the export's Slate
    # palette in the PDF and for an exporter.
    @testset "deck settings: slate. colours, the live CSS and deck-settings.typ" begin
        s = NS.deck_settings("", "").values
        for (name, p) in RE.SLATE_PALETTES
            d = NS.deck_settings_dict(s; palette = name)
            @test (d["roles"]["fg"], d["roles"]["strong"], d["roles"]["dim"], d["roles"]["accent"], d["roles"]["surface"]) ==
                  (p.text, p.strong, p.dim, p.accent, p.bg)
            @test d["slate_palette"] == name
            typ = NS.deck_settings_typ(s; ratio = "16:9", palette = name)
            @test occursin("\"fg\": rgb(\"$(p.text)\")", typ) && occursin("\"surface\": rgb(\"$(p.bg)\")", typ)
        end
        # A figure palette that the deck settings name wins over the export palette.
        fixed = NS.deck_settings("[figures]\nslate-palette = \"daylight\"\n", "").values
        @test NS.deck_settings_dict(fixed; palette = "midnight")["slate_palette"] == "daylight"
        # The page gets it too, so that the live deck draws its charts in it ("" = the UI theme).
        nb = _mknb("#%% md id=a\n## A\n")
        @test NS.state_json(nb)["deckFigurePalette"] == ""
        nb.report.meta["decksettings"] = "[figures]\nslate-palette = \"daylight\"\n"
        @test NS.state_json(nb)["deckFigurePalette"] == "daylight"

        # Live: `slate.` names stay CSS references, and every rule is inside `:where(…)`, so that a
        # package CSS overrides it.
        nb = _mknb("#%% md id=a\n## A\n\nbody\n")
        css = NS.state_json(nb)["deckCss"]
        @test occursin("--deck-fg: var(--text);", css) && occursin("--deck-surface: var(--bg);", css)
        @test occursin("--deck-strong: var(--strong);", css)    # bold text and headings keep the theme's --strong
        @test occursin("--deck-font: \"Inter\", \"Slate Inter\", sans-serif;", css)   # the font keeps its property name
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

    # Each key of the base file reaches the live deck (`--deck-<group>-<key>` in notebook.css or
    # slides.js) and the slides PDF (`settings.<group>.<key>` in export_typst.jl). Julia reads the keys
    # in `julia`. The two `todo` lists hold the keys that a target does not read yet: a key must leave
    # its list when a target starts to read it, so the lists only get shorter.
    @testset "deck settings: each key has a reader on each target" begin
        src = joinpath(@__DIR__, "..", "src")
        live = read(joinpath(src, "assets", "notebook.css"), String) * read(joinpath(src, "assets", "js", "slides.js"), String)
        typ = read(joinpath(src, "export_typst.jl"), String)
        julia = ("code.syntax", "figures.slate-palette")
        todo_live = ("code.fill", "code.font")
        todo_typst = ()
        keys_ = ["$g.$k" for (g, d) in NS.deck_settings("", "").values for (k, v) in d if g != "palette" && !(v isa AbstractDict)]
        @test length(keys_) > 50 && "table.rule-width" in keys_
        reads_live(key) = occursin(Regex(NS._deck_css_name(split(key, '.')...) * "(?![\\w-])"), live)
        reads_typst(key) = occursin(Regex("settings\\." * replace(key, "." => "\\.") * "(?![\\w-])"), typ)
        checked = filter(!in(julia), keys_)
        @test isempty(filter(key -> reads_live(key) == (key in todo_live), checked))
        @test isempty(filter(key -> reads_typst(key) == (key in todo_typst), checked))
    end

    # The Typst preamble reads the deck settings: a template's `text.size` moves the body text size that
    # the fit record measures, in `u`.
    @testset "a deck setting moves the measured text size in the PDF" begin
        sizes = map(("", "[text]\nsize = \"40u\"\n")) do set
            nb = _mknb("#%% md id=a\n## A\n\nbody text\n")
            nb.deck_template = (; hash = "h", source = "", settings = set, files = Dict{String,Vector{UInt8}}(), body_width = nothing)
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
    # bottom right. A second slide holds a table wider than its column, which takes the other branch of
    # the column widths.
    @testset "the base PDF: the paragraph gap of the settings, the slide number" begin
        # A mark inside the first line of each paragraph (at the start of a line, the comment would be
        # an HTML block that joins the two paragraphs).
        mark(k) = "<!--raw-typst #context [#metadata(here().position().y.pt()) <$k>]-->"
        set = "[text]\nparagraph-after = \"1em\"\n"
        long = join(fill("word", 30), " ")
        wide = "| $long | $long | x |\n|---|---|---|\n| a | b | c |\n"
        nb = _mknb("#%% md id=a\n## A\n\nOne$(mark("p1")) line.\n\nThe$(mark("p2")) next line.\n\n#%% md id=b\n## B\n\n$wide")
        nb.deck_template = (; hash = "h", source = "", settings = set, files = Dict{String,Vector{UInt8}}(), body_width = nothing)
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

    # A key message, an admonition or a table at the end of a markdown cell has no space of its own
    # below it, as on the live deck: the next cell starts one cell gap below it.
    @testset "the base PDF: a cell that ends with a key message or a table" begin
        mark(k) = "<!--raw-typst #context [#metadata(here().position().y.pt()) <$k>]-->"
        nb = _mknb("#%% md id=a\n## A\n\n> Key$(mark("k1")) message.\n\n#%% md id=b\nNext$(mark("k2")) cell.\n\n" *
                   "#%% md id=c\n## B\n\n| a |\n|---|\n| 1 |\n\n#%% md id=d\nNext cell.\n")
        dir = NS._build_slides_project(nb)
        try
            doc = joinpath(dir, "doc.typ")
            y(k) = only(NS._typst_query(doc, "<$k>")) / (720 / 1920)      # in u
            s = NS.deck_settings("", "").values
            line = s["text"]["size"].value * s["text"]["line-height"]
            @test y("k2") - y("k1") ≈ line + s["key-message"]["pad-y"].value + s["rhythm"]["cell-gap"].value atol = 0.5
            @test count("#mdcell(tight: true)[", read(doc, String)) == 2  # the cell that ends with the table too
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    # A table wider than its column: a column of hyphenated words can break after each hyphen, as in a
    # browser, so it gets less width than a column of words of the same length with no hyphen.
    @testset "the base PDF: a table column breaks its words after a hyphen" begin
        long(w) = join(fill(w, 12), " ")
        nb = _mknb("#%% md id=a\n## A\n\n| $(long("aaaaaaaaaa-bbbbbbbbbb")) | $(long("aaaaaaaaaaxbbbbbbbbbb")) |\n|---|---|\n| x | y |\n")
        dir = NS._build_slides_project(nb)
        try
            out = IOBuffer()
            NS._typst_run("query", joinpath(dir, "doc.typ"), ["table", "--field", "columns"]; out)
            w = [parse(Float64, chopsuffix(c, "fr")) for c in last(JSON.parse(String(take!(out))))]   # the table with its widths
            @test w[1] < 0.9 * w[2]
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
        @test length(NS.export_pdf(nb; layout = "slides", theme = "dark")) > 1000
    end

    @testset "a deck template drives the PDF and the bundle" begin
        # The template sets its text in Inter from its own `fonts` directory (the shipped Inter file).
        # Its settings name another font, so Slate copies no Inter: only the template file can give it.
        tpl = """
        #let slide(body, layout: none, title: none, n: none) = page[
          #set text(font: "Inter")
          TPL layout=#repr(layout) title=#(if title == none { "none" } else { title.body }) name=#toml("cfg.toml").name
          #body
        ]
        """
        files = Dict("cfg.toml" => Vector{UInt8}("name = \"tomlvalue\"\n"),
                     "fonts/Inter-Regular.ttf" => read(joinpath(NS._INTER_DIR, "Inter-Regular.ttf")))
        src = "#%% md id=s layout=center\n## Shown\n\nbody text\n"
        text(pdf) = (f = tempname() * ".pdf"; write(f, pdf);
                     try read(`pdftotext -layout $f -`, String) finally rm(f) end)
        dir = NS._build_slides_project(_mknb(src))
        before = try read(joinpath(dir, "doc.typ"), String) finally rm(dir; recursive = true, force = true) end
        nb = _mknb(src)
        nb.deck_template = (; hash = "h", source = tpl, settings = "[text]\nfont = [\"DejaVu Sans\"]\n", files, body_width = nothing)
        pdf = NS.export_pdf(nb; layout = "slides")
        t = text(pdf)
        @test occursin("TPL layout=\"center\"", t) && occursin("title=Shown", t) && occursin("name=tomlvalue", t)
        f = tempname() * ".pdf"; write(f, pdf)
        fonts = try read(`pdffonts $f`, String) finally rm(f) end
        @test occursin("Inter-Regular", fonts)

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

        # Without a template the preamble is the only prefix; no template text leaks in.
        @test !occursin("── deck template ──", before)

        # The write site refuses a file name that leaves the project directory, and the name of a file
        # that Slate writes.
        io = IOBuffer(); d = mktempdir()
        try
            for name in ("../x", "deck-settings.typ")
                @test_throws ArgumentError NS._apply_deck_template!(io, d, (; hash = "h", source = "", settings = "",
                                                                          files = Dict(name => UInt8[])))
            end
        finally
            rm(d; recursive = true, force = true)
        end
    end

    @testset "slide-deck with CITATIONS compiles (measure-in-isolation regression)" begin
        # A cite() inside the slide fit-scaler's measure() used to abort the whole deck with
        # "cannot format citation in isolation". The measured copy must render citation sentinels
        # as a stand-in, while the real slide keeps the true citation.
        nb = _mknb("#%% md id=s\n## Cited slide\n\nSee [@knuth1984, p. 3].\n\n" *
                   "#%% md id=refs bibliography\n@book{knuth1984,\n  author = {Knuth, D.},\n" *
                   "  title = {The TeXbook},\n  publisher = {Addison-Wesley},\n  year = {1984}\n}\n")
        @test length(NS.export_pdf(nb; layout = "slides")) > 1000   # a throw here IS the regression
    end

    @testset "the PDF deck fits each slide and records the fit" begin
        # The fixture deck at 16:9 and at 4:3, with four slides added: a figure that shares a tall
        # slide with text, a portrait figure alone whose drawn height is measured, a slide of text
        # that is taller than the page at full size, and a data table of 35 rows, which shrinks with the
        # text. One `typst query` per ratio reads the fit records of `fit` (label `<slate>`).
        fixture = read(joinpath(@__DIR__, "fixtures", "deck_fixture.jl"), String)
        svg(w, h) = """<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h"><rect width="$w" height="$h" fill="#38c"/></svg>"""
        table = NS._typst_table(Dict("columns" => [Dict("name" => "n"), Dict("name" => "square")],
                                     "rows" => [[i, i^2] for i in 1:35]); theme = "deck")
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
        #slide(title: heading(level: 2)[A data table])[
        $table
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
        n = length(fit) - 4                                 # the pages of the fixture; the four added slides follow
        @test sort(collect(keys(fit))) == 1:n+4             # one page per slide: no slide breaks
        tall, atfloor, fig = fit[n+3], fit[13], fit[n+1]    # the added tall slide, fixture "…at the floor"
        @test 0.62 <= tall["s"] < 1 && tall["f"] >= tie(tall) && !tall["at_floor"]
        @test fit[n+4]["s"] < 1 && !fit[n+4]["at_floor"]    # the table shrinks with the text
        @test atfloor["at_floor"] && atfloor["s"] == 0.62
        @test count(r -> r["at_floor"], recs) == 1
        @test 0.62 <= fig["s"] < 1 && tie(fig) <= fig["f"] < 1 && !fig["at_floor"]   # the figure shrinks less than the text
        @test cap ≈ 0.7 atol = 0.01                          # a tall figure takes at most 0.7 of the slide height
        warns = NS._fit_warnings(recs; unit = "Page")        # the export dialog's warnings: a PDF page number
        @test length(warns) == 1 && startswith(only(warns), "Page 13 ")
        # The header that carries the warnings to the page is ASCII, at most 21 lines of at most 300
        # characters.
        h = NS._warnings_header(vcat(["tëst"], fill("x"^400, 30)))
        l = JSON.parse(h)
        @test isascii(h) && length(l) == 21 && l[1] == "tëst" && length(l[2]) == 300 && occursin("11 more", l[21])
        # At 4:3 the slide unit is 1/1440 of the page width, as on the live canvas: the body text has
        # the same size in `u` as at 16:9.
        fit43, cap43, _ = query("4:3")
        @test fit43[2]["size"] ≈ fit[2]["size"] && fit43[2]["s"] == 1
        @test cap43 ≈ 0.7 atol = 0.01
    end

    # The block kinds in the PDF (the `draw` dictionary of the slides preamble, the handlers of the
    # document preamble). A mark inside a paragraph records the text size there.
    @testset "block kinds in the PDF: paint, a template draw function, an unknown key" begin
        mark(k) = "<!--raw-typst #context [#metadata(text.size / 1pt) <$k>]-->"
        src = "#%% md id=a\n## A\n\nBody$(mark("body")) text.\n\n*A caption$(mark("cap")) of the figure.*\n\n" *
              "> A key message.\n\n!!! note \"Heads up\"\n    The body.\n"
        # The records of a slides project of `src` with the deck template source `tpl`.
        function records(tpl)
            nb = _mknb(src)
            nb.deck_template = (; hash = "h", source = tpl, settings = "", files = Dict{String,Vector{UInt8}}(), body_width = nothing)
            dir = NS._build_slides_project(nb)
            try
                q(label) = NS._typst_query(joinpath(dir, "doc.typ"), label)
                return (; ratio = only(q("<cap>")) / only(q("<body>")), probe = q("<probe>"), warns = NS._draw_warnings(q("<slate>")))
            finally
                rm(dir; recursive = true, force = true)
            end
        end
        # The base deck: a caption is `caption.size` of the body text, and no key warns.
        base = records("")
        @test base.ratio ≈ 0.8 && isempty(base.warns)
        # A deck template gives `draw.caption`, and a key that is no block kind gives a warning.
        mine = records("#let draw = (caption: it => [#metadata(\"mine\") <probe>#it.body], captoin: it => it.body)\n")
        @test mine.probe == ["mine"] && mine.ratio ≈ 1
        @test length(mine.warns) == 1 && occursin("draw.captoin", only(mine.warns))
        # A deck template that draws its slides with its own rules (no `base-rhythm`) and gives no
        # function keeps each block as its markdown gives it: the base paint does not apply.
        own = "#let slide(body, layout: none, title: none, n: none) = page(fit(body))\n"
        @test records(own).ratio ≈ 1
        @test records(own * "#let draw = (caption: base-draw.caption)\n").ratio ≈ 0.8
        # An article draws an admonition as its box, not as `!!!` text: the heading and the body are
        # inside the box, 9 pt to the right of the text around it.
        dir = NS._build_typst_project(_mknb(src))
        try
            pdf = joinpath(dir, "out.pdf")
            NS._typst_compile(joinpath(dir, "doc.typ"), pdf)
            words = read(`pdftotext -bbox $pdf -`, String)
            x(w) = parse(Float64, match(Regex("xMin=\"([\\d.]+)\"[^>]*>$w</word>"), words)[1])
            @test x("Heads") - x("Body") ≈ 9 atol = 0.1
            @test x("The") - x("Body") ≈ 9 atol = 0.1
            @test !occursin("!!!", words)
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    # The layout source of an exporter (`slide_layout`): the box of each block and of each region of
    # the slides PDF, from the marks of the slides preamble.
    @testset "layout source: blocks in reading order, in the page, as wide as their column" begin
        src = "#%% md id=a\n## A\n\nA paragraph.\n\n- one\n- two\n\n> A key message.\n\n" *
              ":::: columns\n::: column\nLeft one.\n\nLeft two.\n:::\n::: column\nRight one.\n:::\n::::\n\n" *
              "| a | b |\n|---|---|\n| 1 | 2 |\n\n```julia\nx = 1\n```\n"
        b = only(NS.slide_layout(_mknb(src))).blocks
        @test [x.index for x in b] == 1:8
        @test [x.kind for x in b] == ["prose", "prose", "key-message", "prose", "prose", "prose", "table", "code"]
        @test [x.divcolumn for x in b] == [0, 0, 0, 1, 1, 2, 0, 0]
        @test all(x -> x.cell == "a" && x.frag == 1 && x.row == 1 && x.page == 1, b)
        @test occursin("A key message", b[3].src)
        inpage(q) = q.x >= 0 && q.y >= 0 && q.x + q.w <= 1920 && q.y + q.h <= 1080
        over(p, q) = p.x < q.x + q.w - 1 && q.x < p.x + p.w - 1 && p.y < q.y + q.h - 1 && q.y < p.y + p.h - 1
        @test all(x -> inpage(x.box), b)
        @test !any(over(b[i].box, b[j].box) for i in eachindex(b) for j in i+1:lastindex(b))
        # Reading order: down the page, and column 1 before column 2 at the same height.
        flow = b[[1, 2, 3, 4, 7, 8]]
        @test issorted([x.box.y for x in flow])
        @test b[4].box.y < b[5].box.y && b[6].box.y ≈ b[4].box.y && b[6].box.x > b[4].box.x + b[4].box.w
        # A block is as wide as its column: the body less the padding of a markdown cell, or its `::: column`.
        s = NS.deck_settings("", "").values
        body = 1920 - 2 * 120 - 2 * 16
        @test all(x -> x.box.w ≈ body && x.box.x ≈ 120 + 16, b[[1, 2, 3, 7, 8]])
        @test all(x -> x.box.w ≈ (body - s["columns"]["gap"].value) / 2, b[4:6])
        # The text size of a block, and the columns and the rows of the table.
        @test b[1].size ≈ s["text"]["size"].value
        @test b[7].size ≈ s["text"]["size"].value * s["table"]["text-size"].value
        @test length(b[7].cols) == 2 && length(b[7].rows) == 2
        @test sum(b[7].cols) ≈ b[7].box.w && sum(b[7].rows) ≈ b[7].box.h
        @test all(x -> x.cols === nothing && x.rows === nothing, b[1:6])
    end

    # The marks take no space: the pages and the fit of each page are the same with and without them.
    @testset "layout source: the marks change no page and no fit" begin
        list = join(("- item $i of a long list" for i in 1:18), "\n")
        nb = _mknb("#%% md id=a\n## A\n\nText.\n\n#%% md id=b\n## B\n\n$list\n")
        dir = NS._build_slides_project(nb)
        try
            doc = joinpath(dir, "doc.typ")
            off, on = NS._typst_query(doc, "<slate>"), NS._typst_query(doc, "<slate>"; marks = true)
            @test [r["kind"] for r in off] == ["fit", "fit"]      # no mark without the input
            @test [r for r in on if r["kind"] == "fit"] == off
            @test off[1]["s"] == 1 && off[2]["s"] < 1
            @test count(r -> r["kind"] == "block", on) == 2 && count(r -> r["kind"] == "region", on) == 2
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "layout source: the regions of the title slide, the title of a slide" begin
        tc = NS._title_cell("# The title\n\n### The subtitle\n\nThe byline\non two lines\n\nOne more line.\n")
        @test (tc.title, tc.subtitle, tc.byline, tc.rest) == ("The title", "The subtitle", "The byline on two lines", "One more line.")
        html = KaimonSlate.ReportRender.markdown_html(tc.marked)
        @test occursin(r"<slate-subtitle>\s*<h3[^>]*>The subtitle</h3>\s*</slate-subtitle>", html)
        @test occursin(r"<slate-byline>\s*<p>The byline\s+on two lines</p>\s*</slate-byline>", html)
        src = "#%% md id=t title\n# The title\n\n### The subtitle\n\nThe byline\n\nOne more line.\n\n" *
              "#%% md id=abs abstract\nThe abstract.\n\n#%% md id=a\n## A\n\nText.\n"
        # The live deck gets the regions as elements.
        cells = RE.parse_report(src).cells
        @test occursin("<slate-byline>", NS.cell_json(cells[1])["output"]) && occursin("<slate-abstract>", NS.cell_json(cells[2])["output"])
        L = NS.slide_layout(_mknb(src))
        r = L[1].regions
        @test [x.name for x in r] == ["title", "subtitle", "byline", "abstract"]
        @test all(x -> x.page == 1, r)
        @test all(r[i].box.y + r[i].box.h <= r[i+1].box.y + 1 for i in 1:3)
        # The sizes and the spacing of the live title slide: the title at 0.94 em with 0.2 of its size
        # below it, the subtitle at the size of its heading level with 0.08 of its size above it, the
        # byline at the body size just below the subtitle.
        s = NS.deck_settings("", "").values
        S, h3 = s["text"]["size"].value, s["heading"]["h3"].value
        @test r[1].size ≈ 0.94S && r[2].size ≈ h3 * S && r[3].size ≈ S
        @test r[2].box.y - (r[1].box.y + r[1].box.h) ≈ 0.2 * 0.94S + 0.08 * h3 * S atol = 0.1
        @test r[3].box.y ≈ r[2].box.y + r[2].box.h atol = 0.1
        L2 = NS.slide_layout(_mknb(replace(src, "### The subtitle" => "## The subtitle")))
        @test L2[1].regions[2].size ≈ s["heading"]["h2"].value * S
        # The line of the title cell that is no region is a block of the title slide, below the regions.
        rest = only(L[1].blocks)
        @test (rest.cell, rest.frag, rest.page, rest.kind) == ("t", 0, 1, "prose") && occursin("One more line", rest.src)
        @test rest.box.y >= r[4].box.y + r[4].box.h - 1
        # A content slide: its title is a region above its blocks, at the size of its heading.
        t = only(L[2].regions)
        s = NS.deck_settings("", "").values
        @test t.name == "title" && t.page == 2 && t.size ≈ s["text"]["size"].value * s["heading"]["h2"].value
        @test t.box.y + t.box.h <= only(L[2].blocks).box.y
    end

    # cmarker reads a footnote only when its definition is in the same call, and a link reference too.
    @testset "layout source: footnotes and link definitions in a split cell" begin
        R = KaimonSlate.ReportRender
        md = "One[^a] and [a link][ref].\n\n- two[^b]\n\nThree.\n\n[^a]: Note a.\n\n[^b]: Note b.\n\n[ref]: https://example.com\n"
        parts = R._md_split(md)
        @test [p.kind for p in parts] == ["prose", "prose", "prose"]
        @test startswith(parts[1].text, "[^a]: Note a.\n\nOne[^a]") && !occursin("Note b", parts[1].text)
        @test startswith(parts[2].text, "[^b]: Note b.\n\n- two[^b]")
        @test all(p -> endswith(p.text, "[ref]: https://example.com"), parts) && !occursin("Note", parts[3].text)
        # Two blocks that refer to one footnote stay one block.
        two = "One[^a].\n\nTwo[^a].\n\n[^a]: Note a.\n"
        @test R._md_split(two) == [(kind = "prose", text = two)]
        nb = _mknb("#%% md id=a\n## A\n\n$md")
        @test length(only(NS.slide_layout(nb)).blocks) == 3
        dir = NS._build_slides_project(nb)
        try
            pdf = joinpath(dir, "out.pdf")
            NS._typst_compile(joinpath(dir, "doc.typ"), pdf)
            text = read(`pdftotext $pdf -`, String)
            @test occursin("Note a.", text) && occursin("Note b.", text)
            @test !occursin("[^", text) && !occursin("[ref]", text)
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "layout source: a region that is out of place gives an export warning" begin
        function warns(tpl)
            nb = _mknb("#%% md id=a\n## A\n\nText.\n")
            nb.deck_template = (; hash = "h", source = tpl, settings = "", files = Dict{String,Vector{UInt8}}(), body_width = nothing)
            return last(NS._export_pdf_report(nb; layout = "slides"))
        end
        @test isempty(warns(""))
        # A deck template that draws the title over the first block of the body.
        slide(title) = "#let slide(body, layout: none, title: none, n: none) = page({ $title; fit(body) })\n"
        @test warns(slide("place(top + left, block(width: 100%, region(\"title\", title)))")) == ["Page 1: the title region is over a block of cell a."]
        # A title in a box that is too low for it.
        @test "Page 1: the title region is out of its area." in warns(slide("box(width: 100%, height: 10 * u, region(\"title\", title))"))
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
    # Each block of markdown has one kind (block_kinds.jl). The detector puts a block of a kind that a
    # deck paints into a `<slate-…>` element, for the page and for the PDF.
    @testset "block kinds: the kind of each markup, the elements in the HTML" begin
        kind(md; kw...) = only(p.kind for p in R._md_blocks(md; kw...) if !isempty(p.kind))
        for (md, k) in ("> A key message." => "key-message",
                        "*All of it is emphasis.*" => "caption",
                        "_Source: X_ [@key]" => "caption",
                        "*With \$a*b\$ math and [a link](u).*" => "caption",
                        "*Source:* part of it" => "prose",
                        "*one* *two*" => "prose",
                        "!!! note \"Title\"\n    Body.\n\n    | a |\n    |---|\n    | 1 |" => "admonition",
                        "![alt](pic.png)" => "figure",
                        "![alt](pic.png){width=300}" => "figure",
                        "Text with ![alt](pic.png)" => "prose",
                        "| a | b |\n|---|---|\n| 1 | 2 |" => "table",
                        "```julia\n> not a quote\n*not a caption*\n```" => "code",
                        "- a list\n- of items" => "prose",
                        "\$\$x^2\$\$" => "prose",
                        "## Heading" => "prose")
            @test kind(md) == k
        end
        # A `{{ }}` value alone in its paragraph is a figure when it draws one.
        @test kind(RE._interp_token(1); figure = ==(1)) == "figure" && kind(RE._interp_token(1)) == "prose"
        doc = "Intro.\n\n> Key.\n\n*Caption.*\n\n!!! tip\n    Body.\n\n:::: columns\n::: column\n*In a column.*\n:::\n::::\n\n```\n> code\n```\n"
        out = R._md_kinds(doc)
        @test R._md_kinds(out) == out                               # a second run changes nothing
        @test occursin("```\n> code\n```", out)                    # fenced code stays code
        @test count("<slate-caption>", out) == 2                    # a block of a `:::` div has its kind too
        @test R._md_kinds("Plain prose.\n\n- a list\n") == "Plain prose.\n\n- a list\n"
        h = R.markdown_html(doc)
        @test occursin("<slate-caption>\n<p><em>Caption.</em></p>\n</slate-caption>", h)
        @test occursin("<slate-admonition category=\"tip\" heading=\"Tip\">\n<div class=\"admonition tip\">", h)
        # The elements are the only change to the HTML.
        bare(s) = replace(s, r"</?slate-[^>]*>" => "", r"\s+" => "")
        @test bare(h) == bare(R.CommonMark.html(R._md_parser()(doc)))
        # A cell with the `caption` tag: each block is a caption, and the first one has the figure number.
        @test R._md_kinds("One.\n\nTwo."; caption = 3) ==
              "<slate-caption number=\"3\">\n\nOne.\n\n</slate-caption>\n\n<slate-caption>\n\nTwo.\n\n</slate-caption>"
        # An admonition category with its own values has a rule on its element in the deck CSS.
        css = NS.deck_settings_css(NS.deck_settings("[admonition.aside]\naccent = \"#123456\"\n", "").values)
        @test occursin(":where(.deck-slide slate-admonition[category=\"aside\"]) { --deck-admonition-accent: #123456; }", css)
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
    # The public `code=` sizes of the slides PDF are factors on the deck setting `code.size`.
    for (code, f) in (("normal", 1), ("small", 1), ("smaller", 7.5 / 8.5), ("tiny", 6.5 / 8.5))
        m = match(r"#let codeblock\(.*text\(size: ([0-9.]+) \* settings\.code\.size", NS._typst_preamble_slides("T"; code))
        @test m !== nothing && isapprox(parse(Float64, m[1]), f; atol = 1e-4)
    end
end

@testset "deck lengths: em for text, the slide unit for geometry" begin
    # The fit changes the text size only, so a deck length that must follow the text is in em and a
    # fixed one is in the slide unit (`--u` live, `u` in Typst), never in px, pt, mm or rem. This scans
    # the notebook.css rules whose selector starts with `.deck-slide`, the Typst slides preamble and a
    # data table of a slide (`_typst_table`).
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
    # An inline `max-width` of a deck image keeps its effect: only a picture that the fit gave `--fitw`
    # takes an `!important` width.
    img = [m for m in rules if occursin(":is(img, video)", m[1])]
    @test !isempty(img) && all(m -> !occursin(r"max-width[^;]*!important", m[2]) || occursin("[style*=\"--fitw\"]", m[1]), img)
    pre = split(NS._typst_preamble_slides("T"), '\n')
    @test isempty(filter(l -> occursin(abslen, l) && !occursin(r"#let (SLIDE_[WH]|mdlen)\b", l), pre))
    spec = Dict("columns" => [Dict("name" => "a")], "rows" => [[1], [2]],
                "opts" => Dict{String,Any}("title" => "T", "nrows" => 300))
    @test !occursin(abslen, NS._typst_table(spec; theme = "deck"))
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

@testset "deck settings: text.list-marker reaches the live deck and the PDF" begin
    s = NS.deck_settings("[text]\nlist-marker = \"#123456\"\n", "").values
    @test occursin("--deck-text-list-marker: #123456;", NS.deck_settings_css(s))
    @test occursin("\"list-marker\": rgb(\"#123456\")", NS.deck_settings_typ(s; ratio = "16:9", palette = "midnight"))
    @test occursin("--deck-text-list-marker: var(--deck-accent);", NS.deck_settings_css(NS.deck_settings("", "").values))
end

# `table.rule-width = "0u"` gives rows with no rule and no room for it, on the live deck and in the PDF.
@testset "deck settings: table.rule-width 0u removes the rule and its room" begin
    s = NS.deck_settings("", "[table]\nrule-width = \"0u\"\n").values
    @test occursin("--deck-table-rule-width: calc(0 * var(--u));", NS.deck_settings_css(s))
    css = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.css"), String)
    @test occursin(":is(th, td) { border: none; border-bottom: var(--deck-table-rule-width) solid", css)
    mark = "<!--raw-typst #context [#metadata(here().position().y.pt()) <after>]-->"
    got = map(("", "[table]\nrule-width = \"0u\"\n")) do set
        nb = _mknb("#%% md id=a\n## A\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter$mark the table.\n")
        nb.deck_template = (; hash = "h", source = "", settings = set, files = Dict{String,Vector{UInt8}}(), body_width = nothing)
        dir = NS._build_slides_project(nb)
        try
            doc, pdf = joinpath(dir, "doc.typ"), joinpath(dir, "out.pdf")
            y = only(NS._typst_query(doc, "<after>")) / (720 / 1920)     # in u
            NS._typst_compile(doc, pdf)
            (y, count("stroke-width", read(`pdftocairo -svg -f 1 -l 1 $pdf -`, String)))
        finally
            rm(dir; recursive = true, force = true)
        end
    end
    @test got[1][1] - got[2][1] ≈ 2 * 2 atol = 0.01      # two rows, each 2 u shorter
    @test got[1][2] > 0 && got[2][2] == 0                # the base rules, then none
end

# A value whose type has a figure hook (SlateExtensionsBase `slate_export_figure`) prints the picture
# that the hook draws for its column, with no browser tab. A decline or a throw takes the next path.
module FigHook
import SlateExtensionsBase as SEB
struct Svg end
struct Decline end
struct Boom end
struct Two end                                     # draws itself as SVG and as PNG
const PNG = UInt8[0x89, 0x50, 0x4e, 0x47]
Base.show(io::IO, ::MIME"text/html", ::Two) = print(io, "<div>live plot</div>")
SEB.slate_export_figure(io::IO, ::MIME"image/svg+xml", ::Two, ctx) =
    (print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"/>"); true)
SEB.slate_export_figure(io::IO, ::MIME"image/png", ::Two, ctx) = (write(io, PNG); true)
Base.show(io::IO, ::MIME"text/html", ::Svg) = print(io, "<div>live plot</div>")
SEB.slate_export_figure(io::IO, ::MIME"image/svg+xml", ::Svg, ctx) =
    (print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"", ctx.width, "\" height=\"100\" data-cap=\"",
           ctx.max_height, "\" data-palette=\"", ctx.slate_palette, "\" data-text=\"", ctx.text_size,
           "\" data-fg=\"", ctx.roles["fg"], "\" data-accent=\"", ctx.roles["accent"], "\"/>"); true)
const STATIC = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"300\" height=\"100\" id=\"static\"/>"
Base.show(io::IO, ::MIME"image/svg+xml", ::Union{Decline,Boom}) = print(io, STATIC)
SEB.slate_export_figure(::IO, ::MIME"image/svg+xml", ::Decline, _) = false
SEB.slate_export_figure(::IO, ::MIME"image/svg+xml", ::Boom, _) = error("boom\nsecond line")
end

# A notebook whose cells ran in this process, so that the figure values are kept here.
function _hooknb(src)
    nb = _mknb(src)
    Core.eval(RE.report_module(nb.report), :(const FigHook = $FigHook))
    foreach(c -> RE.eval_cell!(nb.report, c, nb.kernel), nb.report.cells)
    return nb
end
# The files that `doc.typ` draws as figures, in order, as (name, text).
_drawn_figs(dir) = [(m[1], read(joinpath(dir, m[1]), String))
                    for m in eachmatch(r"figureimg\(\"([^\"]+)\"", read(joinpath(dir, "doc.typ"), String))]
_svg_width(t) = parse(Float64, match(r"width=\"([\d.]+)\"", t)[1])

@testset "figure hook: the picture of a value reaches the PDF with no tab" begin
    nb = _hooknb("#%% code id=fh1\nFigHook.Svg()\n\n#%% md id=fh2\n{{ FigHook.Svg() }}\n")
    w = String[]
    dir = NS._build_slides_project(nb; warnings = w)
    try
        figs = _drawn_figs(dir)
        @test length(figs) == 1 && endswith(figs[1][1], ".svg")
        @test _svg_width(figs[1][2]) == 1680                      # the base body: 1920 u less 240 u
        @test occursin("data-cap=\"756.0\"", figs[1][2]) && occursin("data-palette=\"midnight\"", figs[1][2])
        # The body text size of the deck in u, and the colour roles as hex in the palette of the export.
        @test occursin("data-text=\"34.0\"", figs[1][2])
        @test occursin("data-fg=\"$(RE.SLATE_PALETTES["midnight"].text)\"", figs[1][2])
        @test occursin("data-accent=\"$(RE.SLATE_PALETTES["midnight"].accent)\"", figs[1][2])
        comp = filter(f -> occursin(r"_comp\d+\.svg$", f), readdir(dir))   # the `{{ }}` value
        @test length(comp) == 1 && _svg_width(read(joinpath(dir, comp[1]), String)) == 1680 - 32
        @test isempty(w)
        NS._typst_compile(joinpath(dir, "doc.typ"), joinpath(dir, "out.pdf"))
        @test isfile(joinpath(dir, "out.pdf"))
    finally
        rm(dir; recursive = true, force = true)
    end
end

# The box of a figure block is the picture as the fit draws it, not its column.
@testset "layout source: the box of a figure is the drawn picture" begin
    nb = _hooknb("#%% code id=lf1\nFigHook.Svg()\n\n#%% md id=lf2\nText.\n")
    fig, text = only(NS.slide_layout(nb)).blocks
    @test (fig.kind, fig.cell, fig.index, fig.src) == ("figure", "lf1", 1, nothing)
    @test fig.box.w ≈ 1680 && fig.box.h ≈ 100 && fig.box.x ≈ 120          # the picture of the hook: 1680 by 100 u
    @test text.box.y >= fig.box.y + fig.box.h
end

# The live deck renders a `Markdown.MD` output as markdown, so the PDF splits it as a markdown cell.
@testset "layout source: a markdown output gives one block for each top-level node" begin
    nb = _hooknb("#%% code id=mo\nimport Markdown\nMarkdown.parse(\"One.\\n\\n> A key message.\\n\\n- a\\n- b\\n\")\n")
    b = only(NS.slide_layout(nb)).blocks
    @test [x.kind for x in b] == ["prose", "key-message", "prose"]
    @test all(x -> x.cell == "mo" && x.page == 1, b) && [x.index for x in b] == 1:3
    @test occursin("A key message", b[2].src) && issorted([x.box.y for x in b])
end

# The `text/plain` value of a code cell reaches an exporter as a code block; stdout carries no text.
@testset "layout source: a text/plain value is a fenced code block" begin
    nb = _hooknb("#%% code id=pv\nprintln(\"hi\")\n1 + 2\n")
    b = only(NS.exporter_deck(nb)["slides"])["blocks"]
    @test [(x["kind"], x["markdown"]) for x in b] == [("code", nothing), ("code", "```\n3\n```\n")]
    v = only(NS.exporter_deck(_hooknb("#%% code id=pq\n\"a ``` b\"\n"))["slides"])["blocks"]
    @test only(v)["markdown"] == "````\n\"a ``` b\"\n````\n"   # the fence is longer than a run of backticks in the text
end

# The text of an output block has the size and the line height that the PDF draws: the code text of
# the block (0.7 em of raw text, which is at 0.8 em), not the body text around it. Each more line
# makes the block one line height taller.
@testset "layout source: an output block has the size and the line height of its text" begin
    nb = _hooknb("#%% md id=pt\nText.\n\n#%% code id=p1\nprintln(\"a\")\n1\n\n#%% code id=p5\n[1, 2, 3, 4]\n\n#%% code id=pe\nerror(\"x\")\n")
    deck = NS.exporter_deck(nb)
    p, o1, v1, v5, e = only(deck["slides"])["blocks"]
    L = deck["settings"]["text"]["line-height"]
    for b in (o1, v1, v5, e)
        @test b["kind"] == "code" && b["size"] ≈ 0.56 * p["size"] && b["lineheight"] ≈ L * b["size"]
    end
    @test v5["box"]["h"] - v1["box"]["h"] ≈ 4 * v1["lineheight"]
end

# A markdown image whose file is not in the project shows its alt text, or its address, and warns, in
# a markdown cell and in a markdown output. The slides PDF, the document PDF and the deck value of an
# exporter are made all the same. An image in code is code.
@testset "a markdown image with no file warns and does not stop the export" begin
    nb = _hooknb("#%% md id=mi\n## Pic\n\n![a clip](slate-no-clip.mp4)\n\nText ![](slate-no-pic.png) and `![x](c.png)`.\n\n```\n![y](f.png)\n```\n\n" *
                 "#%% code id=mo\nimport Markdown\nMarkdown.parse(\"Out ![an output](slate-no-out.png)\")\n")
    w = String[]
    b = only(NS.exporter_deck(nb; warnings = w)["slides"])["blocks"]
    @test w == ["Cell mi: the file of the image `slate-no-clip.mp4` is not in the project, so the export shows its alt text in its place.",
                "Cell mi: the file of the image `slate-no-pic.png` is not in the project, so the export shows its address in its place.",
                "Cell mo: the file of the image `slate-no-out.png` is not in the project, so the export shows its alt text in its place."]
    @test [x["markdown"] for x in b][1:3] == ["<slate-figure>\n\na clip\n\n</slate-figure>", "Text slate-no-pic.png and `![x](c.png)`.",
                                              "```\n![y](f.png)\n```"]
    @test occursin("Out an output", b[end]["markdown"])
    for kw in ((; layout = "slides"), (;))
        pdf, ws = NS._export_pdf_report(nb; kw...)
        @test String(pdf[1:4]) == "%PDF" && issubset(w, ws)
    end
end

# A markdown video or audio file of the project is a figure whose form is the bytes of the file, for an
# exporter that asks for its MIME type, in a markdown cell and in a markdown output. The markdown keeps
# the alt text, and the files of the slides project have no media mark. A file over the cap warns.
@testset "a markdown video or audio file gives a figure form" begin
    root = mktempdir()
    write(joinpath(root, "clip.mp4"), "mp4 bytes")
    write(joinpath(root, "talk.mp3"), "mp3 bytes")
    open(io -> truncate(io, NS._EXPORT_MAX_BYTES + 1), joinpath(root, "big.mp4"), "w")   # sparse
    nb = _hooknb("#%% md id=mv\n## Media\n\n![a clip](clip.mp4)\n\n![](talk.mp3)\n\nText ![inline](talk.mp3) here.\n\n![big](big.mp4)\n\n" *
                 "#%% code id=mo\nimport Markdown\nMarkdown.parse(\"![out clip](clip.mp4)\")\n")
    nb.report.meta["assetbase"] = root
    w = String[]
    b = only(NS.exporter_deck(nb; figure_mimes = ["image/png", "video/mp4", "audio/mpeg"], warnings = w)["slides"])["blocks"]
    @test [x["kind"] for x in b] == ["figure", "figure", "prose", "figure", "figure"]
    @test b[1]["forms"] == [("video/mp4", Vector{UInt8}("mp4 bytes"))] && b[1]["markdown"] == "<slate-figure>\n\na clip\n\n</slate-figure>"
    @test b[2]["forms"] == [("audio/mpeg", Vector{UInt8}("mp3 bytes"))]
    @test b[3]["markdown"] == "Text inline here." && !haskey(b[3], "forms")
    @test isempty(b[4]["forms"])
    @test w == ["Cell mv: the file `big.mp4` is larger than 256 MiB, so the export shows its alt text in its place."]
    @test b[5]["forms"] == [("video/mp4", Vector{UInt8}("mp4 bytes"))] && occursin("out clip", b[5]["markdown"])
    @test !any(x -> occursin('\x1f', something(x["markdown"], "")), b)
    # An exporter that does not ask for the type gets no form and no warning.
    w = String[]
    b = only(NS.exporter_deck(nb; warnings = w)["slides"])["blocks"]
    @test all(isempty(x["forms"]) for x in b if x["kind"] == "figure") && isempty(w)
    dir = NS._build_slides_project(nb)
    try
        @test !any(f -> occursin('\x1f', read(joinpath(dir, f), String)), filter(endswith(".md"), readdir(dir)))
    finally
        rm(dir; recursive = true, force = true)
    end
end

# The base slides PDF marks list items as the live deck does: `•`, then `◦`, then `▪`.
@testset "slides PDF: the list markers of the live deck" begin
    f = tempname() * ".pdf"
    write(f, NS.export_pdf(_mknb("#%% md id=l\n## List\n\n- top\n  - nested\n    - third\n"); layout = "slides"))
    t = try read(`pdftotext $f -`, String) finally rm(f) end
    @test occursin(r"•\s*top", t) && occursin(r"◦\s*nested", t) && occursin(r"▪\s*third", t)
end

@testset "figure hook: the width comes from the columns and the template's body width" begin
    widths(nb) = (dir = NS._build_slides_project(nb);
                  try; [_svg_width(t) for (_, t) in _drawn_figs(dir)]; finally; rm(dir; recursive = true, force = true); end)
    nb = _hooknb("#%% code id=fw1\nFigHook.Svg()\n\n#%% code id=fw2 column=2\nFigHook.Svg()\n")
    @test widths(nb) == [816, 816]                                # two cells share 1680 u with the 48 u row gap
    # A deck template with its own body width (the template reaches the hub through the manifest).
    SEB = RE.SlateExtensionsBase
    try
        SEB.provide_deck_template!(""; body_width = 1000)
        @test widths(nb) == [476, 476]                            # (1000 − 48) / 2
    finally
        SEB._DECK_TEMPLATE[] = nothing
    end
    # A document: the text width of the A4 page in px at 96 dpi (article margins 2.2 cm).
    dir = NS._build_typst_project(_hooknb("#%% code id=fw3\nFigHook.Svg()\n"))
    try
        @test only(_svg_width(t) for (_, t) in _drawn_figs(dir)) ≈ (210 - 44) / 25.4 * 96
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "figure hook: a decline and a throw take the next path; a throw warns" begin
    w = String[]
    dir = NS._build_slides_project(_hooknb("#%% code id=fd1\nFigHook.Decline()\n\n#%% code id=fd2\nFigHook.Boom()\n");
                                   warnings = w)
    try
        @test [t for (_, t) in _drawn_figs(dir)] == [FigHook.STATIC, FigHook.STATIC]   # the image the cell showed
        @test length(w) == 1 && occursin("Cell fd2", w[1]) && occursin("Boom", w[1]) && endswith(w[1], ": boom")
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "figure hook: a notebook from stored output warns and notes the figure" begin
    nb = _hooknb("#%% code id=fs1\nFigHook.Svg()\n")
    RE._figure_forget!("fs1")              # the output stays and the value is gone, as after an open from storage
    w = String[]
    dir = NS._build_slides_project(nb; warnings = w)
    try
        @test length(w) == 1 && startswith(w[1], "Cell fs1: the output comes from storage")
        @test occursin("Run it with its ▶ button (`POST /api/<notebook>/cell/<cell>` with `force: true`)", w[1])
        @test occursin("#notefig(\"[figure not captured — run this cell with its ▶ button, then re-export]\")",
                       read(joinpath(dir, "doc.typ"), String))
    finally
        rm(dir; recursive = true, force = true)
    end
    # Two cells: the warning names both, once each.
    nb = _hooknb("#%% code id=fs2\nFigHook.Svg()\n\n#%% md id=fs3\n{{ FigHook.Svg() }} {{ FigHook.Svg() }}\n")
    RE._figure_forget!("fs2"); RE._figure_forget!("fs3")
    w = String[]
    rm(NS._build_slides_project(nb; warnings = w); recursive = true, force = true)
    @test length(w) == 1 && startswith(w[1], "Cells fs2, fs3: ") && occursin("Run each of them", w[1])
end

# The roles follow the deck settings of the notebook on a slide; a document gives the body text size in
# px at 96 dpi.
@testset "figure hook: text_size and roles follow the deck settings and the document" begin
    nb = _hooknb("#%% code id=ft1\nFigHook.Svg()\n")
    nb.report.meta["decksettings"] = "[text]\nsize = \"40u\"\n[roles]\nfg = \"#003247\"\n"
    dir = NS._build_slides_project(nb)
    try
        t = only(t for (_, t) in _drawn_figs(dir))
        @test occursin("data-text=\"40.0\"", t) && occursin("data-fg=\"#003247\"", t)
    finally
        rm(dir; recursive = true, force = true)
    end
    dir = NS._build_typst_project(_hooknb("#%% code id=ft2\nFigHook.Svg()\n"))
    try
        t = only(t for (_, t) in _drawn_figs(dir))
        pal = match(r"data-palette=\"(\w+)\"", t)[1]
        @test occursin("data-text=\"14.0\"", t)                    # 10.5 pt of the normal body
        @test occursin("data-fg=\"$(RE.SLATE_PALETTES[pal].text)\"", t)
    finally
        rm(dir; recursive = true, force = true)
    end
end

# The exporter hook (`register_exporter!`). The outline exporter is the example of its docstring.
function _outline(deck)
    io = IOBuffer()
    nfig = 0
    w, h = deck["size"]
    println(io, "<!-- ", deck["ratio"], ", ", w, " × ", h, " u -->")
    isempty(deck["title"]) || println(io, "\n# ", deck["title"])
    for (i, s) in enumerate(deck["slides"])
        t = s["title"]
        println(io, "\n## ", i, ". ", t === nothing ? "(no title)" : t["text"])
        for b in s["blocks"]
            if b["kind"] == "figure"
                nfig += 1
                println(io, "\n[figure: ", join(first.(b["forms"]), ", "), "]")
            elseif b["markdown"] !== nothing
                println(io, "\n", strip(b["markdown"]))
            end
        end
        foreach(n -> println(io, "\n> Notes: ", strip(n)), s["notes"])
    end
    return take!(io), nfig == 0 ? String[] : ["The outline names $nfig figures but does not show them."]
end

# A tool type for `create_tools` that keeps what each tool was registered with.
struct _XTool; name::String; f::Any; timeout_ms::Any; end
_XTool(name, f; timeout_ms = nothing) = _XTool(String(name), f, timeout_ms)
_xwarns(r) = JSON.parse(NS.HTTP.header(r, "X-Slate-Warnings", "[]"))

const _XSRC = "#%% md id=xa\n## Intro\n\nOne paragraph and [a link][r].\n\n> A key message.\n\n[r]: https://example.com\n\n" *
              "#%% code id=xf\nFigHook.Two()\n\n#%% md id=xv\n{{ FigHook.Two() }}\n\n#%% md id=xn notes\nSay hi.\n\n" *
              "#%% md id=xb\n## Table\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"

# Only plain Base types: a `Dict` with string keys, vectors, tuples, named tuples, strings, symbols,
# numbers, `nothing` and bytes.
_plain(::Union{Nothing,Bool,Int,Float64,String,Symbol}) = true
_plain(::Vector{UInt8}) = true
_plain(x::Dict) = keytype(x) === String && all(_plain, values(x))
_plain(x::Union{Tuple,NamedTuple,Vector}) = all(_plain, x)
_plain(_) = false

@testset "exporter hook" begin
    SEB = RE.SlateExtensionsBase
    SEB.register_exporter!(_outline, "outline"; label = "Markdown outline", ext = "md", mime = "text/markdown",
                           figure_mimes = ["image/svg+xml", "image/png"])
    try
        nb = _hooknb(_XSRC)
        @testset "the outline round trip through the route and the gate" begin
            r = NS._exporter_response(nb, "outline", Dict("charttheme" => "daylight"))
            @test r.status == 200
            @test NS.HTTP.header(r, "Content-Type") == "text/markdown"
            @test NS.HTTP.header(r, "Content-Disposition") == "attachment; filename=\"slidetest.md\""
            md = String(r.body)
            @test startswith(md, "<!-- 16:9, 1920.0 × 1080.0 u -->")
            @test occursin("## 1. Intro", md) && occursin("## 2. Table", md) && occursin("> Notes: Say hi.", md)
            @test occursin("One paragraph and [a link][r].", md) && occursin("https://example.com", md)
            @test count("[figure: image/svg+xml, image/png]", md) == 2
            # The worker side of the gate refuses an unknown exporter and gives the reason.
            w = RE.exporter_wire("nope", Dict{String,Any}(), 1000)
            @test w.ok === false && occursin("no exporter", w.error)
            @test_throws ErrorException RE._gate_export(w, 1000)
            out = RE._gate_export(RE.exporter_wire("outline", NS.exporter_deck(nb), 10^6), 10^6)
            @test out.bytes isa Vector{UInt8} && out.warnings == ["The outline names 2 figures but does not show them."]
            # The dialog lists the exporter by its checked fields.
            @test NS.state_json(nb)["exporters"] == [Dict("name" => "outline", "label" => "Markdown outline", "ext" => "md")]
        end
        @testset "an unregistered name gives 404" begin
            @test NS._exporter_response(nb, "pptx", Dict()).status == 404
            @test NS._exporter_response(nb, "../outline", Dict()).status == 404
        end
        @testset "the warnings of an exporter reach the header and the tool answer" begin
            r = NS._exporter_response(nb, "outline", Dict())
            @test r.status == 200 && last(_xwarns(r)) == "The outline names 2 figures but does not show them."
            old = KaimonSlate._HUB[]
            KaimonSlate._HUB[] = NS.Hub(Dict("deck" => nb), nothing, "127.0.0.1", 0, ReentrantLock())
            try
                tool = only(t.f for t in KaimonSlate.create_tools(_XTool) if t.name == "export")
                path = tempname() * ".md"
                answer = tool("deck"; format = "outline", path)
                @test occursin("Wrote", answer) && isfile(path)
                @test occursin("⚠ The outline names 2 figures but does not show them.", answer)
                rm(path; force = true)
            finally
                KaimonSlate._HUB[] = old
            end
            # An exporter that gives only the bytes still works, and adds no warning.
            SEB.register_exporter!(d -> "plain text", "plain"; label = "Plain", ext = "txt", mime = "text/plain")
            try
                p = NS._exporter_response(nb, "plain", Dict())
                @test p.status == 200 && String(p.body) == "plain text"
                @test _xwarns(p) == _xwarns(r)[1:end-1]
            finally
                delete!(SEB._EXPORTERS, "plain")
            end
        end
        @testset "a bad name, ext or mime is dropped with a warning" begin
            ok = (; name = "good", label = "Good", ext = "md", mime = "text/markdown", figure_mimes = ["image/png"])
            m = (; exporters = [ok, merge(ok, (; name = "Bad Name")), merge(ok, (; name = "badext", ext = "m.d")),
                                merge(ok, (; name = "badmime", mime = "text")),
                                merge(ok, (; name = "badfig", figure_mimes = ["image/png\r\nX: y"]))])
            xnb = _mknb("#%% md id=a\nText.\n")
            @test_logs (:warn, r"Bad Name") (:warn, r"file extension \"m.d\"") (:warn, r"\"text\" is not a type/subtype") (:warn, r"figure MIME type") NS._merge_exporters!(xnb, m)
            @test [e.name for e in xnb.exporters] == ["good"]
            @test NS._merge_exporters!(xnb, (; frontend = [])) && isempty(xnb.exporters)   # an older SEB: none
        end
        @testset "the size cap holds" begin
            r = NS._exporter_response(nb, "outline", Dict(); maxbytes = 10)
            @test r.status == 500 && occursin("more than the limit of 10 bytes", String(r.body))
            @test_throws ErrorException RE._gate_export((; ok = true, bytes = zeros(UInt8, 11)), 10)   # the hub checks again
        end
        @testset "the deck value has plain Base types only and its blocks join the slide model" begin
            deck = NS.exporter_deck(nb; figure_mimes = ["image/svg+xml"], charttheme = "daylight")
            @test _plain(deck)
            @test deck["size"] == (1920.0, 1080.0) && deck["ratio"] == "16:9" && deck["title"] == ""
            @test deck["settings"]["slate_palette"] == "daylight" && startswith(deck["settings"]["roles"]["fg"], "#")
            s1, s2 = deck["slides"]
            @test s1["title"] == Dict{String,Any}("text" => "Intro", "depth" => 2, "cell" => "xa") && strip.(s1["notes"]) == ["Say hi."]
            @test [(r["name"], r["text"]) for r in s1["regions"]] == [("title", "Intro")]
            L = NS.slide_layout(nb)
            for (s, l) in zip(deck["slides"], L)
                @test [(b["kind"], b["cell"], b["frag"], b["index"], b["row"], b["column"]) for b in s["blocks"]] ==
                      [(b.kind, b.cell, b.frag, b.index, b.row, b.column) for b in l.blocks]
                @test all(b["box"]["y"] ≈ q.box.y && b["box"]["h"] ≈ q.box.h && b["size"] ≈ q.size for (b, q) in zip(s["blocks"], l.blocks))
            end
            @test [b["kind"] for b in s1["blocks"]] == ["prose", "key-message", "figure", "figure"]
            t = only(s2["blocks"])
            @test t["kind"] == "table" && length(t["cols"]) == 2 && length(t["rows"]) == 2
            @test !haskey(s1["blocks"][1], "forms") && !haskey(s1["blocks"][1], "cols")
            # Line heights in `u`: prose in the base rhythm has the CSS line height of the deck settings.
            @test all(b["lineheight"] isa Float64 && b["lineheight"] > 0 for s in deck["slides"] for b in s["blocks"])
            @test only(s1["regions"])["lineheight"] > 0
            p = s1["blocks"][1]
            @test p["lineheight"] ≈ deck["settings"]["text"]["line-height"] * p["size"]
            # A table has the line height of its cells (`table.line-height`), not of the body around it.
            @test t["lineheight"] ≈ deck["settings"]["table"]["line-height"] * t["size"]
            # The title of the base title slide has the line height of a heading (`HEAD-LH`, 1.1).
            c = first(NS.exporter_deck(_mknb("#%% md id=t title\n# The deck\n\n#%% md id=b\n## Body\n\nText.\n"))["slides"])
            ct = only(r for r in c["regions"] if r["name"] == "title")
            @test ct["lineheight"] ≈ 1.1 * ct["size"]
        end
        @testset "the deck title is the title of the front matter" begin
            tnb = _mknb("#%% md id=t title\n# The deck\n\n### A subtitle\n\n#%% md id=b\n## Body\n\nText.\n")
            deck = NS.exporter_deck(tnb)
            @test deck["title"] == "The deck"
            @test startswith(String(first(_outline(deck))), "<!-- 16:9, 1920.0 × 1080.0 u -->\n\n# The deck\n")
        end
        @testset "figure forms follow figure_mimes" begin
            forms(mimes) = [[f[1] for f in b["forms"]] for b in NS.exporter_deck(nb; figure_mimes = mimes)["slides"][1]["blocks"]
                            if b["kind"] == "figure"]
            @test forms(["image/png", "image/svg+xml"]) == [["image/png", "image/svg+xml"], ["image/png", "image/svg+xml"]]
            @test forms(["image/svg+xml"]) == [["image/svg+xml"], ["image/svg+xml"]]
            @test forms(["image/jpeg"]) == [String[], String[]]
            png = only(b for b in NS.exporter_deck(nb; figure_mimes = ["image/png"])["slides"][1]["blocks"] if b["cell"] == "xv")
            @test only(png["forms"]) == ("image/png", FigHook.PNG)
        end
    finally
        delete!(SEB._EXPORTERS, "outline")
    end
end
