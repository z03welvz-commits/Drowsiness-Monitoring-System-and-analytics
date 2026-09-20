# Architecture split options

A light look at what it would actually take to break `index.html` into
separate files, written because the question came up in a whole-system
audit — not because anyone has decided to do it. **No code changes in this
document; nothing below has been built.**

## Where things stand today

- `index.html` is 823KB: one inlined `<style>` block (~1,640 lines of CSS)
  and one inlined `<script>` block (~9,750 lines of JS), plus two external
  CDN scripts (`@supabase/supabase-js`, `xlsx`). No build step exists or is
  needed — GitHub Pages serves the file exactly as committed.
- `src/dds-state.js`, `dds-charts.js`, `dds-controls.js`, `dds-a11y.js`,
  and `dds-tokens.css` still exist in the repo, but **`index.html` does not
  load or reference any of them** — confirmed by grep, zero hits for
  `applySeverity`, `derive(`, or any of their other exports anywhere in
  `index.html`. They're a leftover from an earlier version of the app,
  before a full rewrite replaced that UI. `dds-state.js` is still exercised
  today, but only as the JS side of `test/parity.sh`'s JS/SQL comparison —
  a real, useful test, but not something the live app runs.
- The one earlier attempt to keep a split (`src/*.js`) in sync with the
  live file was abandoned — nothing enforced the sync, so it silently
  drifted until the two were computing different things (see this
  session's parity work, which found and excluded several fields
  `dds-state.js` computes that `index.html`/the SQL side never adopted).
  Any new split needs to avoid repeating exactly that failure.
- The JS is organized as many small, focused functions
  (`renderOverview`-style widget renderers, `loadX`/`renderX` pairs per
  table or chart — around 50 of them), not as seven cleanly separated
  page modules. There's no existing internal boundary that lines up with
  "this is the Overview page's code" vs. "this is Analytics' code."
- Cross-page coupling is real, not hypothetical: a single global `DDS`
  object, plus shared `window.__dds*` state (`__ddsPageLoad`,
  `__ddsCache`, `__ddsIsAdmin`, `__ddsSoundEnabled`, and the
  `__ddsOpenDriverStreaks`/`__ddsOpenAlertLogs` hooks the cross-reference
  links added in the redesign use to jump between pages with a filter
  already applied). Any split has to carry this shared state across
  whatever the new file boundaries are.

## What a real split would need

GitHub Pages only serves static files — it has no build step of its own.
That's fine for a single `index.html`, but multiple source files bundled
into one deployable page need *something* to do the bundling before
deploy. The options, roughly in order of how much they'd change:

1. **A minimal concatenation script** — glue the `src/*.js` files (once
   they're rewritten to match what `index.html` actually does today) and
   the page's own markup back into one `index.html` at build time, in a
   fixed order. Smallest possible build step; still no module system, no
   dependency graph, no dead-code elimination.
2. **A real bundler** (esbuild, Rollup, Vite) — proper ES modules,
   `import`/`export` between files, a dev server for local iteration,
   minification. More setup, but the standard way to do this and the
   easiest to keep working correctly over time.

Either way, the build has to run *before* the deployed page exists — the
natural place is a step in the CI workflow added this session
(`.github/workflows/ci.yml`), which could gain a `build` job whose output
gets published to Pages, rather than committing built output into the
repo by hand.

## What's actually separable, least risk first

- **Pure, stateless helpers** (formatting, date/shift-boundary math,
  `severityBadge()`-style classifiers, the CSS custom-property tokens)
  have no page-specific dependencies and no shared mutable state. These
  are the safest first candidates for pulling into their own file(s) —
  low risk, and exactly the kind of code the old `src/dds-tokens.css`
  and parts of `dds-state.js` were already trying to be.
- **Per-page render/load logic** is next, but it's coupled to the shared
  `DDS` object and the `window.__dds*` globals described above, so
  extracting one page means either carrying that shared state along as an
  explicit import (doable, but touches every page during the transition)
  or leaving it as ambient global state a while longer (defeats some of
  the point of splitting).
- **The 7 pages themselves** are the highest-risk, highest-effort target.
  Given how much of this session's own work has been fixing cross-page
  interactions (the Part 4 cross-reference links, the Part 5 page merge,
  the app-wide edit lock spanning all pages), splitting the pages apart
  is the part most likely to reintroduce exactly the kind of bug this
  year's audits keep finding — a behavior that's correct on one side of a
  boundary and silently wrong on the other.

## Rough estimate

Not a commitment, just a scale check: pulling out shared helpers is a
few hours of careful, low-risk work. Standing up a real bundler and CI
build step is a day or so of infrastructure work, separate from touching
any page logic. Actually separating the 7 pages into independent modules
— while keeping the shared edit-lock, filters, and cross-navigation
working exactly as they do now — is the largest piece by far, most
comparable in size to this year's multi-part redesign (PRs #79–82), and
carries real regression risk for a project that, today, has zero users
complaining that a single 823KB file is a problem. Nothing here argues
for doing it soon; it argues for knowing what it would cost if the file
ever does become the actual bottleneck.
