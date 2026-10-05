# Vendored mermaid

`mermaid.min.js` is an unmodified copy of mermaid's prebuilt browser bundle
(MIT), taken from the repo's own dependency so the app draws the same diagrams
the web UI does:

```sh
cp node_modules/mermaid/dist/mermaid.min.js packages/clients/ios/Resources/mermaid/
```

Re-run that after a mermaid upgrade in `package.json` — nothing checks the two
copies against each other, and a stale bundle is invisible until someone sends
a diagram using new syntax.

It is a single self-contained IIFE (no dynamic imports, every diagram type
included), which is why it can be loaded from a `file://` page with one script
tag. The ESM entry points in `dist/` cannot: they lazy-load their diagram
chunks over the network.

`host.html` is ours — the offscreen page `MermaidRenderer` drives. Both files
ship as bundle resources for the iOS and macOS targets.

When source does not parse, `host.html` tries it once more with the repaired
text `MermaidRenderer` passes in (`OS1/Mermaid/MermaidRepair.swift`, a port of
the ER half of the web's `src/frontend/lib/mermaid-repair.ts`). Keep the two
in step.
