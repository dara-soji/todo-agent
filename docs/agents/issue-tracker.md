# Issue tracker: local markdown

This repo tracks issues as markdown files under `issues/`. No external tracker.

## Issue file format

One file per issue, named `NNNN-<slug>.md`. The 4-digit number is the issue id, unique across the repo. Frontmatter:

```yaml
---
id: 3
title: Pick the build platform
labels: [wayfinder:grilling]
status: open          # open | closed
assignee:             # empty = unclaimed
parent: 1             # id of the map, for child tickets
blocked_by: [2, 4]    # ids of issues that must close first
---
```

Body follows the frontmatter. Comments are appended under a `## Comments` heading, each starting `### <date> — <author>`.

## Wayfinding operations

- **Map**: an issue labelled `wayfinder:map`. Its tickets live in a folder named after the map (`issues/<map-slug>/`), next to the map file.
- **Child ticket**: `parent: <map id>` in the frontmatter.
- **Blocking**: `blocked_by: [...]`. There's no native blocking, so the frontmatter is the convention.
- **Claim**: set `assignee:` to the driving dev before any work.
- **Frontier query**: files under the map folder with `status: open`, empty `assignee`, and every `blocked_by` id closed.
- **Resolve**: append a resolution comment, set `status: closed`, and add a line to the map's *Decisions so far*.
- **Research findings**: committed on a `research/<slug>` branch; the ticket links the branch and file.
