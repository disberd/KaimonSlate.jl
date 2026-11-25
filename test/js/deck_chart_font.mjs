// Asserts that the slide styling of a chart (`_presentOpts` in slides.js) gives a font stack with no
// double quote, for a chart with axis options of its own too.
//
// The export of the chart of a `{{ }}` value draws it with this styling and ECharts `renderToSVGString`
// (core.js `_renderInterpChartSvg`). That renderer writes the font stack into a double-quoted
// `style="…"` attribute without escaping. The deck setting `text.font` reaches the page as the
// computed `--deck-font`, which quotes family names with double quotes, so a double quote in the
// stack gives invalid SVG, and Typst stops the whole slides PDF.
//
//   node test/js/deck_chart_font.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'slides.js'), 'utf8');
const die = m => { console.error('deck_chart_font: ' + m); process.exit(2); };

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) die('could not locate ' + name);
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  die('unbalanced braces in ' + name);
}

const stack = '"Arial", "Liberation Sans", sans-serif';
const document = { querySelector: () => ({}), body: {} };
const getComputedStyle = () => ({ getPropertyValue: k => (k === '--deck-font' ? ' ' + stack : '') });
const presentOpts = new Function('document', 'getComputedStyle', sliceFn('_presentOpts') + '\nreturn _presentOpts;')(
  document, getComputedStyle);

let bad = 0;
const specs = {
  'an Express bar chart': { xAxis: { type: 'category', data: ['a', 'b'] }, yAxis: { type: 'value' }, series: [{ type: 'bar' }] },
  'a chart with its own xAxis': { xAxis: { type: 'category', data: ['a', 'b'], axisLabel: { interval: 0, rotate: 45 } },
                                  yAxis: {}, series: [{ type: 'bar', data: [1, 2] }] },
};
for (const [what, spec] of Object.entries(specs)) {
  const f = presentOpts(spec, 1).textStyle.fontFamily;
  if (typeof f !== 'string' || f.includes('"') || f !== stack.replace(/"/g, "'")) {
    console.error('deck_chart_font: ' + what + ' has the font stack ' + JSON.stringify(f));
    bad++;
  }
}
process.exit(bad ? 1 : 0);
