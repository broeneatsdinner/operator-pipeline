---
title: Artifacts and Closure
summary: Collection output, review material, and restoration records make an engagement legible after the terminal scrolls away.
layout: reference
permalink: /artifacts-and-closure/
---

Collection produces more than an answer on screen. It produces material that
must be preserved, reviewed, and separated from the public project.

## Runtime layout

| Location | Purpose | Public treatment |
| --- | --- | --- |
| `scans/` | Generated collection artifacts and review material. | Kept empty except for its placeholder. |
| `log/` | Generated operational records and state. | Ignored; one sanitized example is retained. |
| `prompts/` | Review instructions used by public helpers. | Versioned source material. |
| `demos/` | Synthetic interface demonstrations. | Versioned public-safe material. |

Real records do not belong in the repository. A clean tree is not evidence that
an engagement is complete; it is only a publication boundary.

## Closure is a technical state

The workbench models closure as work: restore the collector, restore the
conductor, record the completed session, then prepare a fresh baseline. A scan
result alone does not close the loop.

This order leaves a useful trail for the operator while avoiding an easy error:
treating an interesting collection result as permission to forget what was
changed to obtain it.

## Review without delegation of authority

The review handoff can help organize discovered terrain. It does not authorize
the model to choose the working set or turn a ranking into a permission system.
Read [Priority Review](priority-review.md) for the interface boundary.
