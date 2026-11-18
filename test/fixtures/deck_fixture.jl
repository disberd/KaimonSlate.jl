try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=cover title layout=title
@md"""
# Fixture deck

### Every block kind on the base deck

Slate test suite · deck parity fixture
"""

#%% md id=prose
@md"""
## Prose and nested lists

A slide of plain prose with **strong** text, *emphasis* and `inline code`. The text runs to two lines
on a 16:9 slide, so the line height shows in the measure.

- A first item at the top level
    - A nested item under the first
    - A second nested item
- A second item at the top level
    1. A numbered nested item
    2. A second numbered item
- A last item
"""

#%% md id=keymsg
@md"""
## Key message

> **The key message is a blockquote that holds one strong sentence.**

The prose under the key message gives the detail. It is one paragraph of ordinary body text.
"""

#%% md id=fighead
@md"""
## Static figure with a caption
"""

#%% code id=figure
# A small SVG with no text, drawn with no package: a static figure on the slide and in the PDF.
struct FixtureBars
    h::Vector{Int}
end
function Base.show(io::IO, ::MIME"image/svg+xml", b::FixtureBars)
    w = 60
    print(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$(w * length(b.h) + 40)" height="320" viewBox="0 0 $(w * length(b.h) + 40) 320">""")
    print(io, """<line x1="20" y1="300" x2="$(w * length(b.h) + 20)" y2="300" stroke="#555" stroke-width="2"/>""")
    for (i, v) in enumerate(b.h)
        print(io, """<rect x="$(20 + (i - 1) * w + 8)" y="$(300 - v)" width="$(w - 16)" height="$v" fill="#2b63b0"/>""")
    end
    print(io, "</svg>")
end
FixtureBars([120, 200, 160, 260, 90, 220, 180])

#%% md id=caption
@md"""
*Figure 1: seven bars drawn as SVG by a code cell. This paragraph is all emphasis, so it is a caption.*
"""

#%% md id=part2 layout=section
@md"""
## Part two

### Admonitions, code, tables and math
"""

#%% md id=admon
@md"""
## Admonitions

!!! note "Note"
    A note admonition with one sentence of body text.

!!! tip "Tip"
    A tip admonition with one sentence of body text.

!!! warning "Warning"
    A warning admonition with one sentence of body text.
"""

#%% md id=code
@md"""
## Code block

A fenced code block in a markdown cell:

```julia
function step(x, v; dt = 0.01, k = 2.0)
    a = -k * x
    return x + v * dt, v + a * dt
end
```
"""

#%% md id=table
@md"""
## Table

| Block | Live | PDF |
|:------|-----:|----:|
| Prose | 1.00 | 1.00 |
| Key message | 1.00 | 1.00 |
| Caption | 0.80 | 0.80 |
| Table | 0.80 | 0.80 |
"""

#%% md id=columns
@md"""
## Columns

:::: columns
::: {.column width="40%"}
The left column is 40 % wide. It holds a short paragraph of text.
:::
::: column
The right column takes the rest:

- one item
- two items
- three items
:::
::::
"""

#%% md id=rowhead
@md"""
## A row of two cells

The cell on the right sits beside this one, with the `column=2` tag.
"""

#%% code id=rowcode column=2
# A light code cell: its value is the output on the slide.
sum(abs2, 1:10)

#%% md id=math
@md"""
## Math

Inline math $e^{i\pi} + 1 = 0$ sits in a sentence, and display math stands on its own line:

$$\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$$

$$m\ddot x + c\,\dot x + k\,x = 0$$
"""

#%% md id=tall
@md"""
## A tall slide that must shrink

This slide holds more text than fits at full size, so the fit makes the text smaller. It stays above
the floor.

- The first item of a list that is longer than one slide holds at full size
- The second item of the list
- The third item of the list
- The fourth item of the list
- The fifth item of the list
- The sixth item of the list
- The seventh item of the list
- The eighth item of the list
- The ninth item of the list
- The tenth item of the list
- The eleventh item of the list
- The twelfth item of the list
"""

#%% md id=floor
@md"""
## A slide that cannot fit at the floor

This slide holds more text than fits at the text floor, so the live body scrolls and the PDF meets its
own floor.

- Item 1 of a list that is too long
- Item 2 of a list that is too long
- Item 3 of a list that is too long
- Item 4 of a list that is too long
- Item 5 of a list that is too long
- Item 6 of a list that is too long
- Item 7 of a list that is too long
- Item 8 of a list that is too long
- Item 9 of a list that is too long
- Item 10 of a list that is too long
- Item 11 of a list that is too long
- Item 12 of a list that is too long
- Item 13 of a list that is too long
- Item 14 of a list that is too long
- Item 15 of a list that is too long
- Item 16 of a list that is too long
- Item 17 of a list that is too long
- Item 18 of a list that is too long
- Item 19 of a list that is too long
- Item 20 of a list that is too long
- Item 21 of a list that is too long
- Item 22 of a list that is too long
- Item 23 of a list that is too long
- Item 24 of a list that is too long
- Item 25 of a list that is too long
- Item 26 of a list that is too long
- Item 27 of a list that is too long
- Item 28 of a list that is too long
- Item 29 of a list that is too long
- Item 30 of a list that is too long
- Item 31 of a list that is too long
- Item 32 of a list that is too long
- Item 33 of a list that is too long
- Item 34 of a list that is too long
- Item 35 of a list that is too long
- Item 36 of a list that is too long
"""

#%% md id=keyend
@md"""
## A key message at the end of a cell

The key message is the last block of this cell. The band has no space of its own below it there.

> **The next cell starts one cell gap below the band.**
"""

#%% md id=keyend2
@md"""
This paragraph is the next cell of the slide.
"""

#%% md id=tableend
@md"""
## A table at the end of a cell

| Block at the end of a cell | Space below it |
|:---------------------------|---------------:|
| Paragraph | 0.55 em |
| Key message | none |
| Table | none |
"""

#%% md id=tableend2
@md"""
This paragraph is the next cell of the slide. It starts one cell gap below the table.
"""

#%% md id=thanks layout=section
@md"""
## Thanks
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 5d1f7c2e-3b8a-4e61-9f0d-7a2c4b6e8d13
#   format = 2
# ╚═╡
