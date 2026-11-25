// Asserts that `_markNatural` (slides.js) gives `--natw` to a markdown picture with a size of its own,
// and only to it. notebook.css draws such a picture at `--natw` × `--u`, so it takes the same share of
// the slide at each window size, as in the slides PDF. Without the mark a picture with a size of its
// own is that many screen px wide, so the live deck draws it larger than the PDF in a small window.
//
// The real `_markNatural` is extracted from slides.js and run on a model image: with no size rule
// (`width: auto`, `max-width: none`) a picture with a size of its own is `naturalWidth` wide and an
// SVG with only a `viewBox` fills its column, as in Chrome.
//
//   node test/js/deck_natural_img.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'slides.js'), 'utf8');
const m = src.match(/\n  function _markNatural\([\s\S]*?\n  \}/);
if (!m) { console.error('deck_natural_img: _markNatural is gone from slides.js'); process.exit(2); }
const markNatural = (0, eval)('(function () {' + m[0] + '\nreturn _markNatural; })')();

// A model `<img>`: `own` tells if it has a size of its own; `column` is the width of its column.
// `fitw` is the `--fitw` of an earlier fit, which caps the width with `!important` (notebook.css).
function img({ naturalWidth, own, column, width = '', natw = null, fitw = null }) {
  const f = { width, height: '', maxWidth: '', maxHeight: '' };
  const props = new Map([...(natw == null ? [] : [['--natw', String(natw)]]), ...(fitw == null ? [] : [['--fitw', fitw + 'px']])]);
  const style = {
    get cssText() { return JSON.stringify([f, [...props]]); },
    set cssText(t) { const [g, p] = JSON.parse(t); Object.assign(f, g); props.clear(); p.forEach(([k, v]) => props.set(k, v)); },
    setProperty: (k, v) => props.set(k, String(v)),
    removeProperty: k => props.delete(k),
    getPropertyValue: k => props.get(k) || '',
  };
  for (const k of Object.keys(f)) Object.defineProperty(style, k, { get: () => f[k], set: v => { f[k] = v; } });
  const free = () => f.width === 'auto' && f.maxWidth === 'none';
  return {
    tagName: 'IMG', naturalWidth, style,
    get offsetWidth() {
      const w = free() ? (own ? naturalWidth : column) : Math.min(own ? naturalWidth : column, column);
      return props.has('--fitw') ? Math.min(w, parseFloat(props.get('--fitw'))) : w;
    },
  };
}

let bad = 0;
const check = (what, e, want) => {
  const got = e.style.getPropertyValue('--natw');
  if (got !== want) { console.error('deck_natural_img: ' + what + ': --natw is ' + JSON.stringify(got) + ', not ' + JSON.stringify(want)); bad++; }
  if (e.style.width === 'auto' || e.style.maxWidth === 'none') { console.error('deck_natural_img: ' + what + ': the probe style stays'); bad++; }
};
const cases = [
  ['an SVG with width="560" in a wide column', img({ naturalWidth: 560, own: true, column: 1100 }), '560'],
  ['a PNG wider than its column', img({ naturalWidth: 1600, own: true, column: 900 }), '1600'],
  ['an SVG with only a viewBox', img({ naturalWidth: 250, own: false, column: 700 }), ''],
  ['a picture with {width=50%}', img({ naturalWidth: 560, own: true, column: 1100, width: '50%', natw: 560 }), ''],
  ['a picture that has not loaded', img({ naturalWidth: 0, own: true, column: 1100, natw: 560 }), ''],
  ['a picture that the last fit made narrower', img({ naturalWidth: 560, own: true, column: 1100, natw: 560, fitw: 495 }), '560'],
];
for (const [what, e, want] of cases) { markNatural(e); check(what, e, want); }
process.exit(bad ? 1 : 0);
