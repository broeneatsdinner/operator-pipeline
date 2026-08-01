---
title: Public Architecture
summary: Focused helpers remain independently understandable; the workbench supplies the lifecycle around them.
layout: reference
permalink: /architecture/
---

The public repository exposes the shape of the system without exposing a real
environment.

```text
operator-workbench.sh
├── conductor identity helper
├── collector verification and OPSEC helper
├── collector-side discovery helper
├── review, selection, and inventory helpers
└── runtime records under log/ and scans/
```

## Workbench and helpers

The workbench is the lifecycle entrypoint. It can report current state, show a
next safe action, archive a completed session, and enter host inventory.

Focused helpers own their individual responsibilities: identity checks,
collector-side discovery, review handoff, host selection, and restrained
inventory. Keeping these boundaries explicit makes high-impact behavior easier
to inspect and test. The workbench composes them; it does not erase their
responsibility.

## Public configuration boundary

The source includes generic defaults and environment-variable overrides for
local setup. It deliberately does not include a real machine inventory, network
map, SSH configuration, or runtime history. A reader evaluating the design can
see the interfaces without receiving another operator’s environment.

## Design constraints

- The scanner is an instrument, not the product.
- State is durable enough to support recovery.
- Review assists organization, not authority transfer.
- Runtime artifacts stay local.
- Restoration remains visible until it is complete.
