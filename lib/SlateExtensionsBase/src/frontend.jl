# ── Auto-registered front-end (no boot cell) ──────────────────────────────────
# A package declares its front-end from `__init__` instead of a notebook calling a boot function in a
# cell above the bind. The declaration is recorded in a process-global registry ([`frontend_scripts`](@ref)
# / [`extension_manifest`](@ref)); Slate PULLS that registry once per run drain and injects each script
# into the page — live and in a static export, deduped by id. Order-independent, no boot cell. A script
# may be a classic `<script>` (`register_widget!`) or an ES module (`register_component!`, the blessed
# path — it `import`s the Slate widget SDK and uses signals/htm).

# id => (; js, esm, kind): the front-end script, whether it's an ES module, and — for a COMPONENT —
# the widget kind whose default export Slate wraps + registers (`""` for a self-registering script).
# Process-global; a re-register by the same id REPLACES (a reload doesn't stack duplicates).
const _FRONTEND = Dict{String,@NamedTuple{js::String, esm::Bool, kind::String}}()
# id => (; path, mtime) for entries registered from a file ([`PkgAsset`](@ref)): the registry re-reads
# `path` when its mtime moves, so readers always see the file as it is on disk.
const _FRONTEND_FILES = Dict{String,@NamedTuple{path::String, mtime::Float64}}()
# Guarded: a widget's front-end can be registered from the CONCURRENT `@bind`/display path (via
# `ensure_widget_assets!`), while the run drain reads the registry — writes and the reader iteration
# must not race (`Multiple concurrent writes to Dict detected!`).
const _FRONTEND_LOCK = ReentrantLock()

"""
    provide_frontend!(js; id="", esm=false, kind="")

Declare a front-end `<script>` to be injected into the page whenever this package is active in a
notebook — call it from your module's `__init__`. `id` dedups re-registration (a reload replaces the
entry rather than stacking duplicates); omit it to key on the script's content. `esm=true` marks `js`
an ES module. `kind` (non-empty) marks `js` a COMPONENT module: Slate wraps its `export default` and
registers it under `kind` (see [`register_component!`](@ref)); `""` ⇒ inject the script as-is (it
self-registers). The general form behind [`register_widget!`](@ref) / [`register_component!`](@ref).
Live and in a static export; no boot cell, no ordering.
"""
function provide_frontend!(js::AbstractString; id::AbstractString = "", esm::Bool = false,
                           kind::AbstractString = "")
    key = isempty(id) ? "fe:" * string(hash(js); base = 16) : String(id)
    lock(_FRONTEND_LOCK) do
        _FRONTEND[key] = (js = String(js), esm = esm, kind = String(kind))
        if js isa PkgAsset
            _FRONTEND_FILES[key] = (path = js.path, mtime = mtime(js.path))
        else
            delete!(_FRONTEND_FILES, key)
        end
    end
    return nothing
end

# Re-read every file-backed entry whose file changed since it was read. Call under `_FRONTEND_LOCK`.
# A file that has gone missing keeps its last text: a half-saved or moved asset must not blank the page.
function _refresh_frontend_files!()
    for (key, f) in _FRONTEND_FILES
        haskey(_FRONTEND, key) || continue
        t = mtime(f.path)
        (t == 0 || t == f.mtime) && continue
        js = try
            read(f.path, String)
        catch
            continue
        end
        _FRONTEND[key] = merge(_FRONTEND[key], (; js))
        _FRONTEND_FILES[key] = (path = f.path, mtime = t)
    end
end

"""
    register_widget!(kind, js)

Auto-register a CLASSIC-script front-end renderer for a widget `kind` — call it from your module's
`__init__`; `js` should call `window.slateRegisterWidget("<kind>", …)`. For the higher-level, signals-
based component pattern, prefer [`register_component!`](@ref).
"""
register_widget!(kind::AbstractString, js::AbstractString) =
    provide_frontend!(js; id = "widget:" * String(kind), esm = false, kind = "")

"""
    register_component!(T::Type, js)
    register_component!(kind::AbstractString, js)

Auto-register a widget's front-end as a signals-based **component module** — the blessed authoring
pattern. Prefer the **type** form: the kind is derived from `T` (`SlateExtensionsBase.kind_for`), so
it's namespaced by your package and can't collide with another package's widget — and there's no kind
string to keep in sync with `to_widget`. `js` is a module that just `export default`s the component:

```js
import { html, useSignal } from "@slate/widget";
export default ({ value, set, params }) => html`…`;      // no kind string anywhere
```

Ship it as a file and read it with [`@pkg_asset`](@ref) so the JS lives in a real `.js`:

```julia
SlateExtensionsBase.to_widget(s::Stars) = Widget(Stars, s.default; max = s.max)
function __init__()
    register_component!(Stars, @pkg_asset("assets/stars.js"))
end
```

Slate injects `<script type="module">`, imports the module, and registers its default export under the
kind; `import`s resolve against the page's import map (Preact/htm/signals + `@slate/widget` are served,
offline-pinned). Live and in a static export. The string form takes an explicit (un-namespaced) kind —
an escape hatch.
"""
register_component!(kind::AbstractString, js::AbstractString) =
    provide_frontend!(js; id = "widget:" * String(kind), esm = true, kind = String(kind))
register_component!(::Type{T}, js::AbstractString) where {T} = register_component!(kind_for(T), js)

"""
    required_assets(::Type{W}) -> js | nothing

The front-end a widget TYPE `W` needs — return its component module JS (typically
`@pkg_asset("assets/x.js")`), or `nothing` (the default) for a type with no front-end. Slate calls this
**lazily**, the first time a `W` is bound or displayed, and registers the module under `kind_for(W)`:

```julia
SlateExtensionsBase.required_assets(::Type{Stars}) = @pkg_asset("assets/stars.js")
```

So a package needs **no `__init__`** — declaring the widget is pure dispatch (`to_widget` +
`required_assets`), and only widgets a notebook actually uses load their JS. A type with no method
contributes nothing, so this doubles as extension-detection.
"""
required_assets(::Type) = nothing

# Widget types whose assets we've already resolved this process (loaded, or confirmed none) — so the
# per-bind check is a set lookup and `required_assets` (which may read a file) runs once per type ever.
# Guarded: `@bind`/display cells run CONCURRENTLY (a parallel batch), so the set would otherwise be
# mutated from several tasks at once (`Multiple concurrent writes to Dict detected!`).
const _ASSET_CHECKED = Set{Any}()
const _ASSET_LOCK = ReentrantLock()

"""
    ensure_widget_assets!(::Type{W})

Lazily load `W`'s front-end into the registry (once per process): the first time it's seen, call
[`required_assets`](@ref) and, if it returns a module, register it as a component under `kind_for(W)`.
Slate calls this from the `@bind`/display path — a no-op for built-ins and any type without a method.
"""
function ensure_widget_assets!(::Type{T}) where {T}
    # Claim the type atomically: only the task that first adds it proceeds to resolve/register, so the
    # (possibly file-reading) `required_assets` + registration runs exactly once even under a parallel
    # bind batch. Kept OUTSIDE the lock so a slow `required_assets` doesn't serialise unrelated binds.
    newly = lock(_ASSET_LOCK) do
        (T in _ASSET_CHECKED) ? false : (push!(_ASSET_CHECKED, T); true)
    end
    newly || return nothing
    js = required_assets(T)
    js === nothing || register_component!(T, js)
    return nothing
end

# ── Package-global front-end (no bind to trigger it) ──────────────────────────
# Some front-end an extension ships isn't tied to any single widget bind — an EDITOR extension
# (`slateRegisterEditorExtension`, e.g. inline-math rendering in cells) and JS→Julia RPC HANDLERS
# (`slate_on(channel) do … end`) fire on "this package is in use in the notebook", not on a `@bind`.
# A package declares them from a named convention hook, `MyPkg.__slate_frontend(slate_on)`, instead of
# an `__init__` + a boot cell:
#
#   function GiacSlate.__slate_frontend(slate_on)
#       provide_frontend!(@pkg_asset("assets/inline_math_editor.js"); id = "GiacSlate.inline_math")
#       slate_on("giac_tex", a -> Dict("latex" => giac_src_to_tex(String(a.src))))
#       slate_on("giac_src", a -> Dict("src"   => mathjson_to_giac_src(String(a.mj))))
#   end
#
# Slate invokes it once per drain per loaded module (see `ensure_module_frontends!`), handing it the
# notebook's injected `slate_on` — so the FRONT-END side lands in the process-global `_FRONTEND` registry
# (pulled by the manifest) and the HANDLER side lands in THAT notebook's `__slate_handlers`. The hook must
# be cheap + idempotent: `provide_frontend!` dedups by id and `slate_on` replaces by channel, so re-running
# it each drain is a no-op that also self-heals a namespace rebuild (the handlers get re-installed).

# `(objectid(slate_on), module)` pairs whose hook has already run — so a package's `__slate_frontend`
# fires ONCE per notebook-namespace generation, even though Slate rescans loaded modules every drain (to
# catch a package a later cell `using`s). The scan is cheap; this guards the actual WORK (a file read +
# registration). Keyed on the namespace's injected `slate_on`, which is stable within a generation and
# FRESH after a rebuild — so a namespace reset (new `slate_on`) re-fires the hook, re-installing its
# handlers into the new `__slate_handlers`. (Contrast `_ASSET_CHECKED`: a widget's JS is process-global,
# so it's once-EVER; a module hook's handlers are per-namespace, so it's once-per-GENERATION.)
const _MODULE_FRONTEND_DONE = Set{Tuple{UInt,Module}}()

"""
    ensure_module_frontend!(m::Module, slate_on) -> Bool

Invoke module `m`'s package-global front-end hook, `m.__slate_frontend(slate_on)`, if it defines one and
it hasn't already run for this notebook-namespace generation (see [`ensure_module_frontends!`](@ref));
return whether the module *has* such a hook. A module without the method contributes nothing (returns
`false`), so — like [`required_assets`](@ref) — the method's presence doubles as extension-detection. A
throwing hook is isolated (caught) so one bad package can't break the manifest pull for the rest.
"""
function ensure_module_frontend!(m::Module, slate_on)
    Base.invokelatest(isdefined, m, :__slate_frontend) || return false
    key = (objectid(slate_on), m)
    key in _MODULE_FRONTEND_DONE && return true          # already wired for this namespace generation
    push!(_MODULE_FRONTEND_DONE, key)
    try
        # The READ must itself run at the latest world, not just the call: `m` is loaded after this
        # method was compiled, so a bare `getglobal` here trips Julia 1.12's binding world-age warning.
        Base.invokelatest(() -> getglobal(m, :__slate_frontend)(slate_on))
    catch
        # A misbehaving package hook must not poison the whole manifest pull.
    end
    return true
end

"""
    ensure_module_frontends!(slate_on)

Invoke every loaded module's package-global front-end hook (see [`ensure_module_frontend!`](@ref)) — Slate
calls this once per run drain, handing it the notebook namespace's injected `slate_on` so a hook can
register both front-end scripts (via [`provide_frontend!`](@ref)) and JS→Julia handlers (via `slate_on`).
Hooks must be idempotent (they run every drain).
"""
function ensure_module_frontends!(slate_on)
    for m in Base.loaded_modules_array()
        ensure_module_frontend!(m, slate_on)
    end
    return nothing
end

# ── Package-served byte assets (content-addressed) ────────────────────────────
# A registry insert (like `_FRONTEND`) — NOT a task-local effect — so an extension can register bytes to
# be SERVED at a stable URL from ANYWHERE, including from inside a value's `show` (where the cell-effect /
# `save_asset` sinks are already harvested and gone). The bytes stay in the worker; the hub fetches them
# lazily by hash (over the gate) the first time a browser requests the URL, caches, and serves them
# immutable (content-addressed → safe). This is how BonitoSlate serves the ~3.5 MB Bonito JS runtime ONCE
# per page instead of re-inlining it into every figure. Keyed by content hash → automatic dedup.
const _SERVED_ASSETS = Dict{String,@NamedTuple{mime::String, bytes::Vector{UInt8}}}()

"""
    provide_served_asset!(bytes; mime="application/octet-stream") -> String

Register `bytes` to be served by Slate at a stable, content-addressed, immutably-cacheable URL, and
return that URL PATH (root-relative, e.g. `/served/<hash>`). Registering the same bytes again returns the
same path (dedup). The bytes live in the worker; the hub fetches them lazily by hash and caches — so this
is safe to call from a hot render path (it's just a `Dict` insert). Use for a large shared runtime a page
loads once (a WASM blob, a JS bundle) rather than re-inlining it per output.

!!! warning "Live only — no export path"
    That URL is answered by the RUNNING hub, out of the LIVE worker's memory. A static export has
    neither, so a served URL 404s in an exported or published page — and unlike [`provide_assets!`](@ref)
    (page-local siblings for a site, `data:` for a standalone) nothing rewrites it.

    This suits its intended user, a session-bound output ([`slate_live_render`](@ref)), which is
    re-rendered per browser connection and never replayed into a static page regardless. For bytes a
    SELF-CONTAINED output needs to keep after export, use `provide_assets!` instead.

    Note also that this registry is filled at RENDER time, not at load time: unlike the `__init__` /
    `__slate_frontend` registrations, it does not survive a worker restart until the cell that produced
    the bytes runs again.
"""
function provide_served_asset!(bytes::AbstractVector{UInt8}; mime::AbstractString = "application/octet-stream")
    data = Vector{UInt8}(bytes)
    hash = string(Base.hash(data); base = 16)
    get!(_SERVED_ASSETS, hash, (mime = String(mime), bytes = data))
    return "/served/" * hash
end

"""
    served_asset(hash) -> (; mime, bytes) | nothing

Look up bytes registered by [`provide_served_asset!`](@ref) by content hash — the hub calls this (over the
gate) to fetch a served asset the first time a browser requests it. `nothing` if unknown.
"""
served_asset(hash::AbstractString) = get(_SERVED_ASSETS, String(hash), nothing)

# Callbacks an extension registers to run just BEFORE a browser (re)connect re-renders live outputs — the
# hook to reset per-page runtime state so each new page gets a fresh session tree (e.g. BonitoSlate drops
# its Bonito page-root + clears CURRENT_SESSION). Process-global; deduped by identity.
const _LIVE_RESETS = Vector{Any}()

"""
    on_live_reset(f)

Register a zero-arg callback `f` run right before live outputs are re-rendered for a freshly-connected
browser page (see [`slate_live_render`]). Use it to reset per-page runtime state so the re-render starts
clean. Deduped by identity — safe to call every time an extension is enabled.
"""
on_live_reset(f) = (f in _LIVE_RESETS || push!(_LIVE_RESETS, f); nothing)

# Run every hook in `hooks`, isolating them from each other so one bad extension can't stop the rest — but
# SURFACING failures. A silently-swallowed lifecycle hook is a debugging trap: the page then misbehaves in
# a way that looks like a transport or rendering bug, with nothing anywhere saying the reset never ran.
function _run_hooks(hooks, what::AbstractString)
    for f in hooks
        try
            Base.invokelatest(f)
        catch e
            @error "SlateExtensionsBase: $what hook failed" hook = f exception = (e, catch_backtrace())
        end
    end
    return nothing
end

"Run every [`on_live_reset`](@ref) callback (isolated). Called by the worker before re-rendering live outputs."
run_live_resets() = _run_hooks(_LIVE_RESETS, "on_live_reset")

# Callbacks run when the WORKER this extension was set up in has been replaced — a restart, or a rebuild
# into a fresh namespace. Distinct from `on_live_reset` (a new browser PAGE attached to the same worker):
# here the page is unchanged and the Julia side underneath it is new.
const _WORKER_RESETS = Vector{Any}()

"""
    on_worker_reset(f)

Register a zero-arg callback `f` run when this notebook's worker has been replaced — restarted, or its
namespace rebuilt. Anything the extension established in the OLD worker is gone: sessions it owned, handlers
it registered in the namespace, resources tied to that process. Use it to rebuild or drop that state.

This is the Julia half; its browser counterpart is `slateOnWorkerReset` (see assets/js/panels.js), for state
the extension put in the PAGE on the old worker's behalf — which only the page can discard, since the
process that owned it is the one that died. Deduped by identity, so re-registering on enable is harmless.
"""
on_worker_reset(f) = (f in _WORKER_RESETS || push!(_WORKER_RESETS, f); nothing)

"Run every [`on_worker_reset`](@ref) callback (isolated). Called by Slate when the namespace is re-established."
run_worker_resets() = _run_hooks(_WORKER_RESETS, "on_worker_reset")

"""
    PkgAsset <: AbstractString

A package file's text that remembers where it came from — what [`@pkg_asset`](@ref) returns. It is a
string (interpolate it, concatenate it, pass it anywhere a `String` goes), holding the contents read when
it was made. The front-end registry ([`provide_frontend!`](@ref) and the widget forms) keeps the `path`
and re-reads the file when its mtime changes, so an edit to a registered `.js` reaches the page on the
next manifest pull without restarting the worker.
"""
struct PkgAsset <: AbstractString
    path::String
    text::String
end
PkgAsset(path::AbstractString) = PkgAsset(String(path), read(path, String))

Base.String(a::PkgAsset) = a.text
Base.ncodeunits(a::PkgAsset) = ncodeunits(a.text)
Base.codeunit(a::PkgAsset) = codeunit(a.text)
Base.codeunit(a::PkgAsset, i::Integer) = codeunit(a.text, i)
Base.isvalid(a::PkgAsset, i::Integer) = isvalid(a.text, i)
Base.iterate(a::PkgAsset, i::Integer = 1) = iterate(a.text, i)
Base.pointer(a::PkgAsset) = pointer(a.text)
Base.hash(a::PkgAsset, h::UInt) = hash(a.text, h)

"""
    @pkg_asset(path) -> PkgAsset

Read a file bundled in the CALLING package, resolved relative to its package root (`pkgdir`). The result
is a string ([`PkgAsset`](@ref)) that also carries the file's path, so a front-end registered from it
follows edits to the file: `register_component!(Stars, @pkg_asset("assets/stars.js"))`.
"""
macro pkg_asset(path)
    :(PkgAsset(joinpath(pkgdir($(__module__)), $(esc(path)))))
end

# ── Package-vendored asset DIRECTORIES (served from disk, not inlined) ─────────
# `provide_frontend!` inlines ONE script's text into the page — fine for a component module, useless
# for a multi-file front-end library that can't be reduced to a single string (Cesium's Workers/Assets,
# echarts-gl, a lib that ships fonts/wasm). Such a library must be SERVED from disk: a package declares a
# directory, Slate serves its files from a stable package-scoped route (`/ext-assets/<pkg>/<sub>`) while
# the package is loaded, and the tree travels in a static export. Offline + pinned, no fork of Slate's
# `vendor.json`. The registry carries a package NAME → an ABSOLUTE dir on disk (the worker and the hub
# are co-located, so the hub reads the path directly; remote-worker file-shipping is a later seam).
const _ASSETS = Dict{String,String}()

# The package-scoped route prefix Slate serves vendored asset dirs under. This is the SDK-owned end of
# the CONTRACT — Slate's hub router (`/ext-assets/**`) and its static-export URL rewriter MUST match it.
const EXT_ASSET_PREFIX = "/ext-assets/"

"""
    pkg_key(m::Module) -> String

The stable, package-scoped key for a MODULE — its package root's name (e.g. `"GlobeSlate"`). The asset
analogue of [`kind_for`](@ref) for a widget type: a module-derived identity an author never hand-types
(and so never drifts on, nor clashes with another package's bare string). It's what a package's vendored
assets are served under — `/ext-assets/<pkg_key>/…`. Two packages can't share a name in one session, so
the key is unique per process. Pass `@__MODULE__` to [`provide_assets!`](@ref) / [`ext_asset_url`](@ref).
"""
pkg_key(m::Module) = string(nameof(Base.moduleroot(m)))

"""
    ext_asset_url(mod_or_pkg, sub = "") -> String

The URL a package-vendored asset (declared with [`provide_assets!`](@ref)) is served at:
`/ext-assets/<pkg>/<sub>`. Prefer the MODULE form — pass `@__MODULE__` and the package key is derived
([`pkg_key`](@ref)), so it can't drift from the string you passed to `provide_assets!`. The prefix is
owned by the SDK (Slate rewrites it to a page-local sibling in a static export); `sub=""` gives the base
URL for the package's tree.

```julia
_gl = ext_asset_url(@__MODULE__, "echarts-gl.min.js")   # "/ext-assets/GlobeSlate/echarts-gl.min.js"
```
"""
ext_asset_url(pkg::AbstractString, sub::AbstractString = "") =
    EXT_ASSET_PREFIX * String(pkg) * "/" * lstrip(String(sub), '/')
ext_asset_url(m::Module, sub::AbstractString = "") = ext_asset_url(pkg_key(m), sub)

"""
    provide_assets!(mod_or_pkg, dir) -> String

Declare a directory of front-end assets that Slate should SERVE while this package is loaded — call it
from your module's `__slate_frontend` hook (or `__init__`). Prefer the MODULE form: pass `@__MODULE__`
and the package key is derived ([`pkg_key`](@ref)) — the same module-scoped identity `kind_for` gives a
widget type — so there's no hand-typed string to keep in sync with your [`ext_asset_url`](@ref) calls.
The files are served at `/ext-assets/<pkg>/<subpath>` live and copied into a static export; `dir` is an
absolute directory, typically [`@pkg_dir`](@ref). Returns the package's base URL:

```julia
function __slate_frontend(slate_on)
    provide_assets!(@__MODULE__, @pkg_dir("assets"))
    # build urls with ext_asset_url(@__MODULE__, "echarts-gl/echarts-gl.min.js")
end
```

For a front-end LIBRARY too large or multi-file to inline as a `provide_frontend!` string (Cesium,
echarts-gl, anything shipping fonts/workers/wasm). A re-declaration of the same package replaces the dir.
The served files are pinned + offline-capable and travel in a static export. To inject a *single* script,
prefer [`provide_frontend!`](@ref)/[`register_component!`](@ref); use this to serve the files that script
(or a widget) then `fetch`es / `import`s / `<script src=>`s from `/ext-assets/<pkg>/…`.
"""
function provide_assets!(pkg::AbstractString, dir::AbstractString)
    _ASSETS[String(pkg)] = abspath(String(dir))
    return ext_asset_url(pkg)
end
provide_assets!(m::Module, dir::AbstractString) = provide_assets!(pkg_key(m), dir)

"""
    @provide_assets!(dir) -> String

[`provide_assets!`](@ref) for the CALLING package — the key is derived from the enclosing module
([`pkg_key`](@ref)), so there's no `@__MODULE__` to write and no string to keep in sync. Pair it with
[`@pkg_dir`](@ref) (or an `Artifacts`/`Scratch` dir):

```julia
@provide_assets!(@pkg_dir("assets"))
```
"""
macro provide_assets!(dir)
    :(provide_assets!($(__module__), $(esc(dir))))
end

"""
    @ext_asset_url(sub = "") -> String

[`ext_asset_url`](@ref) for the CALLING package — the key is derived from the enclosing module, so a
package builds its served-asset URLs with just the subpath, no key at all:

```julia
@ext_asset_url("echarts-gl/echarts-gl.min.js")   # "/ext-assets/GlobeSlate/echarts-gl/echarts-gl.min.js"
```
"""
macro ext_asset_url(sub = "")
    :(ext_asset_url($(__module__), $(esc(sub))))
end

"""
    @pkg_dir(path) -> String

Absolute path to a directory bundled in the CALLING package, resolved against its package root
(`pkgdir`) — the directory analogue of [`@pkg_asset`](@ref). For declaring a vendored asset tree:
`provide_assets!("GlobeSlate", @pkg_dir("assets/echarts-gl"))`.
"""
macro pkg_dir(path)
    :(abspath(joinpath(pkgdir($(__module__)), $(esc(path)))))
end

"""
    js_bundle(key, entry; deps, dir, minify=true) -> String | Nothing

Build a JavaScript bundle from an ES-module `entry` and npm `deps`, returning the built file's path — or
`nothing` when it can't be built, so a caller always has to have a fallback.

The point is TREE-SHAKING. A vendored front-end library is the largest thing in a self-contained export,
and the published "dist" builds are deliberately everything-inclusive: plotly.js ships 3D, geo, mapbox
and finance whether a notebook draws a scatter plot or not. An extension that knows which parts it
actually needs can say so, and get a bundle containing only those:

```julia
js_bundle("plotly-\$(join(sort(traces), '-'))", \"\"\"
             import Plotly from 'plotly.js/lib/core';
             import scatter from 'plotly.js/lib/scatter';
             Plotly.register([scatter]);
             window.Plotly = Plotly;
         \"\"\";
         deps = Dict("plotly.js" => "2.35.2"), dir = my_cache_dir())
```

Nothing about this is specific to any library: the caller supplies the entry module and the packages it
imports, and gets back whatever the bundler produces.

Requires `node` and `npx` on PATH; the bundler is esbuild, fetched by `npx` on first use. **Every failure
returns `nothing`** — no node, no network, a bad entry, a bundler error. Building a smaller asset is an
optimisation, and an export must never fail because an optimisation was unavailable; the caller falls
back to whatever it vendors normally.

Cached under `dir` keyed by a hash of `key`, the entry source and the deps, so a rebuild happens only
when one of those actually changes. `key` is a readable prefix on the filename, nothing more.
"""
function js_bundle(key::AbstractString, entry::AbstractString;
                   deps::AbstractDict = Dict{String,String}(), dir::AbstractString,
                   minify::Bool = true)
    # `--platform=browser` picks browser-conditional exports; `global` still has to be shimmed, because
    # npm packages that also target Node reference it directly and it does not exist in a browser.
    # Without it a bundle throws `global is not defined` on its first line, and every consumer reports a
    # missing API rather than the real cause.
    args = ["entry.js", "--bundle", "--format=iife", "--platform=browser",
            "--define:global=globalThis", "--outfile=bundle.js"]
    minify && push!(args, "--minify")
    # The build FLAGS are part of the identity. Hashing only the sources means a changed flag silently
    # reuses the previous artifact — the build looks like it took effect and did not.
    stamp = string(hash((String(entry), sort!(["$k@$v" for (k, v) in deps]), args)); base = 16)
    out = joinpath(String(dir), string(_bundle_stem(key), "-", stamp, ".js"))
    isfile(out) && filesize(out) > 0 && return out
    (Sys.which("node") === nothing || Sys.which("npx") === nothing) && return nothing
    work = mktempdir()
    try
        write(joinpath(work, "entry.js"), String(entry))
        if !isempty(deps)
            specs = ["$k@$v" for (k, v) in deps]
            # `--no-save --no-audit --no-fund`: a throwaway tree, so npm's bookkeeping is pure latency.
            run(pipeline(Cmd(`npm install --no-save --no-audit --no-fund --loglevel=error $specs`;
                             dir = work); stdout = devnull, stderr = devnull))
        end
        run(pipeline(Cmd(`npx --yes esbuild $args`; dir = work); stdout = devnull, stderr = devnull))
        built = joinpath(work, "bundle.js")
        (isfile(built) && filesize(built) > 0) || return nothing
        mkpath(String(dir))
        # Move via a temp name in the DESTINATION so a concurrent build can't publish a partial file.
        tmp = out * ".part"
        cp(built, tmp; force = true)
        mv(tmp, out; force = true)
        return out
    catch
        return nothing
    finally
        rm(work; recursive = true, force = true)
    end
end

_bundle_stem(k) = replace(String(k), r"[^A-Za-z0-9._-]" => "_")

"""
    asset_dirs() -> Dict{String,String}

Every package-vendored asset directory declared by the loaded packages (`pkg => absolute dir`) — a copy,
so callers can't mutate the registry. See [`extension_manifest`](@ref) for what Slate pulls.
"""
asset_dirs() = copy(_ASSETS)

# ── Package-declared ES module imports ────────────────────────────────────────
# The package-level counterpart of a notebook's `@use`: an extension that ships front-end code
# importing a third-party module declares the specifier ONCE here, instead of every notebook author
# writing the same `@use` line. Merged UNDER the notebook's own `@use` map, so an author can always
# pin a different build of the same specifier.
const _IMPORTS_LOCK = ReentrantLock()
const _IMPORTS = Dict{String,String}()   # bare specifier => url

"""
    provide_import!(spec, url) -> url

Declare a browser ES-module import for every notebook that loads this package — the package-level
counterpart of a notebook's `@use`. Front-end code the extension ships (a component module, a
[`provide_frontend!`](@ref) script) can then `import` the bare `spec` both live and in an export,
with nothing declared in the notebook.

Last-wins and idempotent, so it belongs in `__init__` or the per-notebook `__slate_frontend` hook. A
notebook's own `@use` of the same specifier WINS, so an author can always override the build.

A specifier declared here works in the session that loaded the package — the page extends its import
map with any specifier it doesn't yet declare, the same way it injects a front-end script. So a
`using YourExtension` in an open notebook makes `import "spec"` resolve without a reload. Re-pointing
a specifier the page ALREADY declares is the one case that needs one, since a document can't redefine
a specifier something may already have resolved.

Pin an exact version rather than a range: an export resolves the URL to bytes, and a moving target
means two exports of the same notebook can ship different libraries.

```julia
provide_import!("mermaid", "https://esm.sh/mermaid@12.3.0")
```
"""
function provide_import!(spec::AbstractString, url::AbstractString)
    s, u = String(strip(spec)), String(strip(url))
    (isempty(s) || isempty(u)) &&
        throw(ArgumentError("provide_import!: specifier and url must both be non-empty"))
    lock(_IMPORTS_LOCK) do
        _IMPORTS[s] = u
    end
    return u
end

"""
    package_imports() -> Dict{String,String}

Every package-declared ES-module import (`specifier => url`) — a copy, so callers can't mutate the
registry. Carried in [`extension_manifest`](@ref); see [`provide_import!`](@ref).
"""
package_imports() = lock(_IMPORTS_LOCK) do
    copy(_IMPORTS)
end

# ── Package-declared deck template ────────────────────────────────────────────
# A Typst template for the slide deck, held as bytes so the hub never reads a path the worker names.
# The manifest carries only the hash; the hub pulls the bytes when the hash changes.
const _DECK_TEMPLATE_LOCK = ReentrantLock()
const _DeckTemplate = @NamedTuple{hash::String, source::String, settings::String,
                                  files::Dict{String,Vector{UInt8}}, body_width::Union{Nothing,Float64}}
const _DECK_TEMPLATE = Ref{Union{Nothing,_DeckTemplate}}(nothing)
# (; path, mtime) of each part that came from a file ([`PkgAsset`](@ref)), under the key `"source"`,
# `"settings"` or `"files/<name>"`. [`deck_template`](@ref) reads a part again when its mtime moves, as
# the front-end registry does.
const _DECK_TEMPLATE_FILES = Dict{String,@NamedTuple{path::String, mtime::Float64}}()

# A file name is a relative POSIX path: no drive, no backslash, no NUL, and no empty, `.` or `..` segment.
_template_path_ok(name::AbstractString) =
    !isempty(name) && !startswith(name, '/') && !occursin(r"^[A-Za-z]:|[\\\0]", name) &&
    all(s -> !isempty(s) && s != "." && s != "..", split(name, '/'))

# SHA-256 over the source, the settings, the (name, bytes) pairs in name order and the body width when
# the template gives one. Each part carries its length, so two different splits of the same bytes give
# two different hashes.
function _template_hash(source::AbstractString, settings::AbstractString, files::AbstractDict,
                        body_width::Union{Nothing,Float64} = nothing)
    ctx = SHA.SHA2_256_CTX()
    part(b) = (SHA.update!(ctx, codeunits("$(length(b)):")); SHA.update!(ctx, b))
    part(codeunits(source))
    part(codeunits(settings))
    for name in sort!(collect(keys(files)))
        part(codeunits(name)); part(files[name])
    end
    body_width === nothing || part(codeunits("body_width=$body_width"))
    return bytes2hex(SHA.digest!(ctx))
end

_template_text(x::AbstractString) = String(x)
_template_text(x::AbstractVector{UInt8}) = String(copy(x))
_template_bytes(x::AbstractString) = Vector{UInt8}(codeunits(String(x)))
_template_bytes(x::AbstractVector{UInt8}) = Vector{UInt8}(x)

"""
    provide_deck_template!(source; settings = nothing, files = Dict{String,Vector{UInt8}}(),
                           body_width = nothing) -> Nothing

Declare a Typst deck template for every notebook that loads this package. `source` is the `.typ` text.

`settings` is the partial deck-settings file of the template: TOML text or bytes. Slate merges it on its
base settings key by key, and the notebook setting `decksettings` on top. Slate checks each key and
value; its base file `src/assets/deck-settings.toml` lists every key with its unit and base value. On
the live deck each value is a `--deck-*` custom property.
The colour roles (`--deck-fg`, …), `--deck-font` and the palette are on the deck root (`.deck`); every
other value is on each slide, so a CSS rule that overrides one must match `.deck-slide`, not `.deck`.

`files` maps a file name to its bytes: the layout catalogue, art and fonts that `source` uses. Put fonts
under `fonts/`.

`body_width` is the width of the content body of the template's slides, in slide units `u` (the slide
is 1920 u wide at 16:9 and 16:10, 1440 u at 4:3). Slate computes the width of the column of a figure
from it and from the columns of the slide, for [`FigureContext`](@ref). The default `nothing` is the
width of the base body: the slide width less 240 u. A value that is not a number in (0, 10000] throws
an `ArgumentError`.

`source`, `settings` and each value of `files` can be a [`PkgAsset`](@ref)
(`@pkg_asset("typst/deck.typ")`). Then the registry keeps its path and reads the file again when its
mtime changes, so an edit reaches the next export without a worker restart.

A file name must be a relative POSIX path, such as `layouts/title.typ`. A name that is absolute or has a
`..` segment throws an `ArgumentError`. The slides export refuses the names of the files that Slate
writes into the project (`doc.typ`, `deck-settings.typ`, `media.json`, `code-dark.tmTheme`). Call this
from `__init__`. A later call replaces the template.

The manifest carries a hash of the template, settings included ([`extension_manifest`](@ref)). Slate
pulls the bytes only when the hash changes.
"""
function provide_deck_template!(source::AbstractString;
                                settings::Union{Nothing,AbstractString,AbstractVector{UInt8}} = nothing,
                                files::AbstractDict = Dict{String,Vector{UInt8}}(),
                                body_width::Union{Nothing,Real} = nothing)
    body_width === nothing || (!(body_width isa Bool) && isfinite(body_width) && 0 < body_width <= 10000) ||
        throw(ArgumentError("provide_deck_template!: body_width must be a number of slide units in (0, 10000], " *
                            "not $(repr(body_width))"))
    bw = body_width === nothing ? nothing : Float64(body_width)
    copied = Dict{String,Vector{UInt8}}()
    paths = Dict{String,@NamedTuple{path::String, mtime::Float64}}()
    follow(key, x) = x isa PkgAsset && (paths[key] = (path = x.path, mtime = mtime(x.path)))
    for (name, bytes) in files
        _template_path_ok(name) ||
            throw(ArgumentError("provide_deck_template!: file name `$name` must be a relative POSIX path " *
                                "without a `..` segment"))
        copied[String(name)] = _template_bytes(bytes)
        follow("files/" * name, bytes)
    end
    src = String(source)
    set = settings === nothing ? "" : _template_text(settings)
    follow("source", source)
    settings === nothing || follow("settings", settings)
    t = (; hash = _template_hash(src, set, copied, bw), source = src, settings = set, files = copied, body_width = bw)
    lock(_DECK_TEMPLATE_LOCK) do
        _DECK_TEMPLATE[] = t
        empty!(_DECK_TEMPLATE_FILES)
        merge!(_DECK_TEMPLATE_FILES, paths)
    end
    return nothing
end

# Read each file-backed part again when its file changed. Call under `_DECK_TEMPLATE_LOCK`. A file that
# has gone missing or cannot be read keeps the last value: a half-saved file must not drop the template.
function _refresh_deck_template_files!()
    cur = _DECK_TEMPLATE[]
    cur === nothing && return
    (; source, settings, files, body_width) = cur
    changed = false
    for (key, f) in collect(_DECK_TEMPLATE_FILES)
        t = mtime(f.path)
        (t == 0 || t == f.mtime) && continue
        bytes = try
            read(f.path)
        catch
            continue
        end
        changed || (files = copy(files))
        changed = true
        key == "source" ? (source = String(bytes)) :
        key == "settings" ? (settings = String(bytes)) : (files[chopprefix(key, "files/")] = bytes)
        _DECK_TEMPLATE_FILES[key] = (path = f.path, mtime = t)
    end
    changed && (_DECK_TEMPLATE[] = (; hash = _template_hash(source, settings, files, body_width), source, settings,
                                    files, body_width))
    return
end

"""
    deck_template() -> Union{Nothing,NamedTuple}

The template that [`provide_deck_template!`](@ref) declared, as `(; hash, source, settings, files, body_width)`,
or `nothing`. `settings` is the TOML text, `""` when the template gives none. `body_width` is a `Float64` in
slide units, or `nothing`. The hash is a hex SHA-256
string. A later `provide_deck_template!`, or an edit to a file-backed part, replaces the template and
leaves the returned value as it was.
"""
deck_template() = lock(_DECK_TEMPLATE_LOCK) do
    _refresh_deck_template_files!()
    _DECK_TEMPLATE[]
end

# ── Package-declared exporters ────────────────────────────────────────────────
# An export format of a slide deck. The function runs on the worker; the manifest carries the rest.
const _EXPORTERS_LOCK = ReentrantLock()
const _EXPORTERS = Dict{String,@NamedTuple{f::Any, label::String, ext::String, mime::String,
                                           figure_mimes::Vector{String}}}()

"""
    register_exporter!(f, name; label, ext, mime, figure_mimes = ["image/png"]) -> Nothing

Declare an export format of a slide deck for every notebook that loads this package. The export
dialog of Slate shows `label` next to its own formats, the route `/api/<notebook>/export/<name>` gives
the file, and so does the tool `export(notebook; format = name)`. On an export, Slate builds the deck
value on the hub and calls `f(deck)` on the worker of the notebook. `f` gives the bytes of the file, as
a `Vector{UInt8}` or a `String`. The file name ends in `.<ext>`, and the hub sends it as `mime`.

`f` can also give the tuple `(bytes, warnings)`, where `warnings` is a `Vector{String}` with one line
for each export warning, for example for content that the format cannot show. Slate adds them after
the export warnings of the slides PDF: the export dialog shows them, the route sends them in the
header `X-Slate-Warnings`, and the tool lists them in its answer. The file is written all the same.

- `name`: 1 to 32 lowercase letters, digits and `-`. The first is a letter or a digit.
- `label`: the text of the entry in the export dialog.
- `ext`: 1 to 8 lowercase letters or digits, with no dot.
- `mime`: a `type/subtype` MIME type.
- `figure_mimes`: the MIME types of the figure pictures that `f` can use, in preference order. A video
  or audio type (`"video/mp4"`, `"audio/mpeg"`, …) asks for the video and audio files of markdown.

The hub checks `name`, `ext`, `mime` and each of `figure_mimes`, and drops an exporter that fails, with
a warning in its log. Call this from `__init__`. A later call with the same `name` replaces the
exporter. `f` gets no options: it reads its other options from the state of its package.

# The deck value

`deck` is a `Dict{String,Any}` with string keys. Its values are plain Base types: `Dict{String,Any}`,
`Vector`, `Tuple`, `NamedTuple`, `String`, `Symbol`, `Float64`, `Int`, `Bool`, `nothing` and
`Vector{UInt8}`. A length is in the slide unit `u`: the slide is 1920 u wide at 16:9 and 16:10, 1440 u
at 4:3. A box is a `Dict` with the keys `"x"`, `"y"`, `"w"` and `"h"`, in `u` from the top left corner
of the slide. The boxes, the text sizes and the line heights come from the slides PDF of the notebook.
A line height is the line pitch of the text in `u`, from the top of a line to the top of the next line:
divide it by the text size to get the line height as a ratio. A later Slate can add keys, so an
exporter must not fail on a key that it does not know.

| Key | Value |
|:----|:------|
| `"title"` | The title of the deck: the title of the front matter (the `title` cell, else the first level-1 heading), as a `String`; `""` when there is none. |
| `"size"` | `(w, h)`, the size of the slide in `u`, as `Float64`s. |
| `"ratio"` | The slide ratio: `"16:9"`, `"16:10"` or `"4:3"`. |
| `"settings"` | The merged deck settings, one `Dict` for each group (`"text"`, `"roles"`, `"table"`, …). A length is `(value = 34.0, unit = :u)`, a ratio is a `Float64`, a colour is a hex string; the colour roles are hex. `"slate_palette"` is the name of the Slate palette of the figures; the Theme picker of the export dialog sets it. |
| `"slides"` | A `Vector` with one `Dict` for each slide, in order. |

Each slide:

| Key | Value |
|:----|:------|
| `"layout"` | The `layout=` tag of the slide, or `nothing`. |
| `"title"` | `nothing`, or a `Dict` for the heading that the slide starts with: `"text"` (its markdown), `"depth"` (its level, an `Int`) and `"cell"` (the id of its cell). The heading is not a block. |
| `"notes"` | A `Vector{String}`: the markdown of each `notes` cell of the slide, as the author wrote it. |
| `"transition"`, `"auto"` | The values of the `transition=` and `auto=` tags of the slide, or `nothing`. |
| `"regions"` | A `Vector` of `Dict`s, one for each region that the slides PDF draws from notebook content and marks (see below): `"name"` (`"title"`, `"subtitle"`, `"byline"` or `"abstract"`), `"text"` (its markdown), `"box"`, `"size"` (its text size in `u`) and `"lineheight"` (its line height in `u`). |
| `"blocks"` | A `Vector` of `Dict`s, one for each block of the body, in reading order. |

Each block:

| Key | Value |
|:----|:------|
| `"kind"` | `"prose"`, `"key-message"`, `"caption"`, `"admonition"`, `"code"`, `"figure"` or `"table"`. |
| `"cell"` | The id of its cell. |
| `"frag"` | The number of its cell fragment on the slide, from 1; 0 for the lines of a `title` cell that are not a region. |
| `"index"` | Its number in the fragment, from 1, in reading order. The blocks of the first container (a `::: column`) of a group come before those of the second. |
| `"row"`, `"column"` | The row of cells of the slide that holds it, from 1, and the `column=` value of its cell. |
| `"path"` | Its place among the groups (`:::: columns`), outermost first: a `Vector` of `[group, container]` pairs, where `group` is the number of the group in its container and `container` the number of the column in the group, both from 1. Empty outside a group. |
| `"markdown"` | Its markdown, with `{{ }}` values resolved and each block of a kind in its `<slate-<kind>>` element. An output of a code cell has `nothing`, with two exceptions: a markdown output splits into blocks as a markdown cell does, and the `text/plain` value of the cell is a fenced code block of its text. |
| `"box"`, `"size"`, `"lineheight"` | Its box, its text size in `u` and its line height in `u`; `nothing` when the slides PDF does not draw it. The box of a figure is the picture, the box of a table is the table, the box of each other block is as wide as its column. The text size and the line height of a table are those of its cells, and those of a code block are those of its code text. |
| `"cols"`, `"rows"` | Only on a table: the widths of its columns and the heights of its rows in `u`, a `Vector{Float64}`. |
| `"forms"` | Only on a figure: a `Vector` of `(mime, bytes)` pairs, in the order of `figure_mimes`, one for each MIME type that Slate has a picture of. It can be empty. A markdown video or audio file of the project (`![a clip](clip.mp4)`) gives a figure with one form: the bytes of the file under the MIME type of its extension (`video/mp4`, `audio/mpeg`, `audio/mp4` for `.m4a`, `audio/wav`, …), when `figure_mimes` has that type. Its `"markdown"` holds its alt text, and its `"box"` is the box that the live deck gives the clip: a video at its natural size under the width rule and the figure cap of a picture, an audio file 300 × 54 u. A file larger than 256 MiB gives no form and an export warning. |

A region, and so its text, is in the deck value only where the Typst source calls `region(name, body)`
of the slides preamble. The base deck calls it for the regions of its title slide and for the title of
each slide. A deck template ([`provide_deck_template!`](@ref)) that draws its own layout (its own
`#let slide` or `#let metablock`) must put each region that it draws from notebook content in
`region()`. Else an exporter gets no region for it: for example, no title and no subtitle on the cover.

# Example

A Markdown outline of the deck, with one export warning when the deck has figures:

```julia
register_exporter!("outline"; label = "Markdown outline", ext = "md", mime = "text/markdown",
                   figure_mimes = ["image/svg+xml", "image/png"]) do deck
    io = IOBuffer()
    nfig = 0
    w, h = deck["size"]
    println(io, "<!-- ", deck["ratio"], ", ", w, " × ", h, " u -->")
    isempty(deck["title"]) || println(io, "\\n# ", deck["title"])
    for (i, s) in enumerate(deck["slides"])
        t = s["title"]
        println(io, "\\n## ", i, ". ", t === nothing ? "(no title)" : t["text"])
        for b in s["blocks"]
            if b["kind"] == "figure"
                nfig += 1
                println(io, "\\n[figure: ", join(first.(b["forms"]), ", "), "]")
            elseif b["markdown"] !== nothing
                println(io, "\\n", strip(b["markdown"]))
            end
        end
        foreach(n -> println(io, "\\n> Notes: ", strip(n)), s["notes"])
    end
    return take!(io), nfig == 0 ? String[] : ["The outline names \$nfig figures but does not show them."]
end
```
"""
function register_exporter!(f, name; label, ext, mime, figure_mimes = ["image/png"])
    lock(_EXPORTERS_LOCK) do
        _EXPORTERS[String(name)] = (; f, label = String(label), ext = String(ext), mime = String(mime),
                                    figure_mimes = String[String(m) for m in figure_mimes])
    end
    return nothing
end

# The file that the exporter `name` makes of `deck`, as `(; bytes, warnings)`. Slate calls this on the
# worker.
function run_exporter(name, deck)
    e = lock(() -> get(_EXPORTERS, String(name), nothing), _EXPORTERS_LOCK)
    e === nothing && throw(ArgumentError("no exporter is registered with the name `$name`"))
    out = Base.invokelatest(e.f, deck)
    file, warnings = out isa Tuple{Any,Any} ? out : (out, String[])
    return (; bytes = file isa AbstractString ? Vector{UInt8}(codeunits(file)) : Vector{UInt8}(file),
            warnings = String[String(w) for w in warnings])
end

"""
    frontend_scripts() -> Dict{String,String}

Every front-end script declared by the loaded packages (`id => js`) — a copy, so callers can't mutate
the registry. See [`extension_manifest`](@ref) for the full record (incl. module-ness) that Slate pulls.
"""
frontend_scripts() = lock(_FRONTEND_LOCK) do
    _refresh_frontend_files!()
    Dict{String,String}(k => v.js for (k, v) in _FRONTEND)
end

"""
    extension_manifest() -> NamedTuple

Everything this process's loaded packages have registered with Slate that the hub must mirror into the
page — Slate pulls it once per run drain and merges it into the notebook. Fields:
- `frontend`: the front-end scripts (`(; id, js, esm, kind)` each) from [`provide_frontend!`](@ref) /
  [`register_widget!`](@ref) / [`register_component!`](@ref). `esm=true` ⇒ inject as an ES module;
  a non-empty `kind` ⇒ a component (Slate wraps its `export default` and registers it under `kind`).
- `assets`: the package-vendored asset DIRECTORIES (`(; pkg, dir)` each) from [`provide_assets!`](@ref) —
  Slate serves each `dir` at `/ext-assets/<pkg>/…` while the package is loaded and copies it into a
  static export.
- `imports`: the ES-module import-map entries (`(; spec, url)` each) from [`provide_import!`](@ref).
  Slate merges them UNDER the notebook's own `@use` declarations, live and in an export.
- `fences`: the markdown fence languages claimed via [`register_fence_renderer!`](@ref). Slate does not
  need these to ROUTE a fence — it rewrites every tagged fence and lets the worker answer — but it does
  need them to INVALIDATE: a markdown cell caches its interpolation results, so a block rendered before
  an extension was loaded keeps its plain-code fallback until something restales the cell.
- `deck_template_hash`: the hash of the deck template from [`provide_deck_template!`](@ref), a string.
  The field is absent when no package declares a template. It carries no bytes: Slate pulls them in a
  separate call, and only when the hash changes.
- `exporters`: the exporters from [`register_exporter!`](@ref), in name order, as
  `(; name, label, ext, mime, figure_mimes)` each. The functions stay in this process.

Extensible: a new kind of package registration surfaces as another field here, carried by the same
query — no new transport per feature.
"""
function extension_manifest()
    m = (; frontend = lock(_FRONTEND_LOCK) do
             _refresh_frontend_files!()
             [(; id = k, js = v.js, esm = v.esm, kind = v.kind) for (k, v) in _FRONTEND]
         end,
         assets = [(; pkg = k, dir = v) for (k, v) in _ASSETS],
         imports = [(; spec = k, url = v) for (k, v) in package_imports()],
         fences = fence_languages(),
         exporters = lock(_EXPORTERS_LOCK) do
             [(; name = k, v.label, v.ext, v.mime, figure_mimes = copy(v.figure_mimes))
              for (k, v) in sort!(collect(_EXPORTERS); by = first)]
         end)
    t = deck_template()
    return t === nothing ? m : merge(m, (; deck_template_hash = t.hash))
end
