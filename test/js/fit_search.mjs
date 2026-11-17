// The live deck and the PDF deck fit a slide with one search: the text scale `s` first, then the
// figure scale `f`, with `f >= (1 + s) / 2` above the text floor. The real `FIT` and `_fitSearch`
// are extracted from slides.js and run on a model slide, and `FIT` is compared with the numbers of
// the Typst `fit` (export_typst.jl `_FIT_TYPST`).
//
//   node test/js/fit_search.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'slides.js'), 'utf8');
const typ = readFileSync(join(here, '..', '..', 'src', 'export_typst.jl'), 'utf8');

let bad = 0;
const ok = (cond, m) => { if (!cond) { console.error('fit_search: ' + m); bad++; } };
const grab = (s, re, where) => { const m = s.match(re); if (!m) { console.error('fit_search: ' + re + ' is gone from ' + where); process.exit(2); } return m; };

const code = grab(src, /\n  const FIT = [^\n]*/, 'slides.js')[0] + grab(src, /\n  function _fitSearch\([\s\S]*?\n  \}/, 'slides.js')[0];
const { FIT, _fitSearch } = (0, eval)('(function () {' + code + '\nreturn { FIT, _fitSearch }; })')();

// ── the same numbers as the PDF deck ──
const t = grab(typ, /_FIT_TYPST = "\(text-floor: ([\d.]+), fig-floor: ([\d.]+), fig-cap: ([\d.]+), math-floor: ([\d.]+)\)"/, 'export_typst.jl');
ok(+t[1] === FIT.textFloor && +t[2] === FIT.figFloor && +t[3] === FIT.figCap && +t[4] === FIT.mathFloor,
   'FIT differs from _FIT_TYPST: ' + JSON.stringify(FIT) + ' vs ' + t.slice(1).join(', '));

// A model slide: text `T` tall at s = 1 and figures `F` tall at f = 1, stacked (or side by side) in
// a body `R` tall. `over` returns the overflow, as `_fitBody` does.
const stacked = (T, F, R) => (s, f) => T * s + F * f - R;
const beside = (T, F, R) => (s, f) => Math.max(T * s, F * f) - R;
const tie = s => (1 + s) / 2;

let r = _fitSearch(stacked(500, 300, 900));
ok(r.s === 1 && r.f === 1 && !r.atFloor, 'a slide that fits keeps full size: ' + JSON.stringify(r));

const tall = stacked(600, 600, 900);
r = _fitSearch(tall);
ok(r.s >= FIT.textFloor && r.s < 1 && r.f >= tie(r.s) && !r.atFloor, 'a tall slide shrinks above the floor: ' + JSON.stringify(r));
ok(tall(r.s, r.f) <= 1, 'the result fits');
ok(tall(r.s + 0.01, tie(r.s + 0.01)) > 1, 'the text scale is the largest that fits (6 steps): ' + r.s);

r = _fitSearch(stacked(600, 1200, 900));
ok(r.s === FIT.textFloor && r.f < tie(r.s) && r.f >= FIT.figFloor && !r.atFloor,
   'at the text floor the figures shrink below the tie: ' + JSON.stringify(r));

r = _fitSearch(stacked(1600, 400, 900));
ok(r.s === FIT.textFloor && r.f === FIT.figFloor && r.atFloor, 'a slide that cannot fit is at the floor: ' + JSON.stringify(r));

r = _fitSearch(stacked(2000, 0, 900));
ok(r.atFloor && r.f === 1, 'at the floor, figures that gain nothing keep full size: ' + JSON.stringify(r));

r = _fitSearch(beside(1200, 500, 900));
ok(r.s < 1 && r.f === 1 && !r.atFloor, 'a figure beside a taller column of text keeps full size: ' + JSON.stringify(r));

if (bad) process.exit(1);
console.log('fit_search: ok');
