---
title: Lifecycle
summary: The session shape that turns scattered terminal operations into a reversible, inspectable operator workflow.
layout: reference
permalink: /lifecycle/
---

The scan command is rarely the whole problem. The harder parts are the state
around it: what identity was present before the session, where the output went,
what remains to review, and whether the environment was actually restored.

Operator Pipeline treats those seams as first-class work.

## The public workflow

1. Capture a baseline.
2. Prepare temporary conductor posture.
3. Prepare or verify temporary collector posture.
4. Run collector-side discovery.
5. Preserve the generated collection artifacts.
6. Restore the collector.
7. Restore the conductor.
8. Record the completed session.
9. Prepare a fresh baseline for the next engagement.

The sequence is not a claim that every engagement is identical. It is a
recovery shape: mutation has a baseline, observation leaves an artifact, and
closure requires restoration rather than wishful thinking.

## Durable state, not terminal memory

An operator should not have to reconstruct the past before deciding what to do
next. The workbench records enough session state to answer a small set of
practical questions:

- What has already become durable?
- What restoration obligation remains?
- What is the next safe action?
- What can wait until review?

This is why the workbench is more than a launcher for helper scripts. Helpers
perform focused work. The workbench provides the order, context, and recovery
surface around them.

## Evidence boundary

The lifecycle has been exercised in a separate private working environment.
The public repository exposes only a sanitized foundation and does not include
the source environment, its artifacts, or its identifying topology. See
[Scope and Evidence](scope-and-evidence.md) for the exact public boundary.
