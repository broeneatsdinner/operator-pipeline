---
title: Interface and Demo
summary: The workbench should reduce uncertainty before it asks the operator to act.
layout: reference
permalink: /interface-and-demo/
---

The workbench is meant to feel like a calm handoff from an experienced operator
who has stayed with the engagement—not a menu that forgets what happened as
soon as it returns to the prompt.

## A briefing before a request

Before asking for an action, an operator-facing screen should make four things
legible:

1. Where are we?
2. What has already become durable?
3. What remains to be done?
4. Why is the next action necessary?

This is not ornamental UX. In a stateful workflow, context prevents the user
from having to infer whether a routine-looking action will repeat work, skip a
recovery step, or alter a machine that still carries an obligation.

## Public synthetic demo

The repository includes a visual demonstration of an active inventory row:

```sh
./demos/inventory-active-row-demo.sh
```

It uses synthetic hosts, services, and progress states. It does not invoke the
workbench, read collection artifacts, or perform network activity. The demo is
a public-safe slice of the operator-facing surface, not proof of a full live
engagement.

## What the interface preserves

The interface should preserve a broad field of view. Review can organize
evidence, but it must not make lower-priority or uncertain hosts invisible.
That decision is described in [Priority Review](priority-review.md).

The same principle applies to lifecycle state: a completed step should be
visible as completed, and an incomplete restoration should remain visible as an
obligation. Quiet interfaces can still carry hard boundaries.
