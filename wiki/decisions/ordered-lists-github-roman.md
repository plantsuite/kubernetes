# ADR: Ordered Lists in GitHub Bullets — type="1" for Decimal

## Status: Accepted

## Context
GitHub renders ordered lists nested inside bullets as Roman numerals (i. ii. iii.), not decimals (1. 2. 3.). Empirical testing via the GitHub Markdown API (`POST https://api.github.com/markdown`, mode=gfm) and visual confirmation on gist.github.com showed the HTML is always a decimal `<ol>`, but GitHub applies a descendant CSS rule (`ul ol, ol ol { list-style: lower-roman }`) that overrides the list style. Plain markdown `1. 2. 3.`, HTML `<ol><li>`, and escape `1\.` (renders as literal text, not a list) all fail or render as Roman inside bullets.

## Decision
Use `<ol type="1"><li>...</li></ol>` for ordered lists nested under bullets. The explicit `type="1"` attribute wins over the descendant CSS, producing decimal numbering while preserving list semantics. Minimal change from the previous `<ol>` convention.

## Consequences
- Decimal numbering preserved inside bullets across GitHub rendering
- List semantics retained (unlike `<p>` text alternative, which loses list structure)
- Structural alternatives rejected: `<p>` loses list semantics; `<details>` outside the bullet changes document structure
- Operational rule lives in `conventions/markdown-github.md`; this ADR preserves the rationale and evidence
- If GitHub changes the CSS or `type` attribute precedence, revisit this decision
