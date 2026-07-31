---
title: Priority Review
summary: The model classifies discovered terrain; the operator retains the authority to choose the working set.
layout: reference
permalink: /priority-review/
---

`operator-pipeline` uses the review step to organize discovered hosts without giving the model authority over what the operator is allowed to inspect.

The model classifies the terrain. The operator chooses the working set.

That distinction matters.

A person can technically be present in a workflow while the software still narrows the visible world so aggressively that the person only sees what the model decided was worth seeing. That is not the authority boundary this workbench is trying to create.

Priority review exists so the model can help sort the room without deciding which doors the operator is allowed to see.

## Why this exists

Earlier review workflows can drift toward a shortlist model:

```text
LLM review -> interesting hosts -> operator works from the model-selected list
```

That can be useful, but it creates the wrong failure mode. Hosts outside the shortlist may still exist in the scan results, but they disappear from the operator's immediate working surface.

In an assessment workflow, that is a subtle but important shift in authority.

The operator may still be present. The operator may still press the keys. But the interface has already shaped the field of view.

Priority review keeps that boundary cleaner:

```text
LLM review -> priority groups -> operator chooses a set -> host selector opens for that set
```

The model helps organize evidence.

The operator decides where to look next.

## The authority boundary

Human presence is not human authority.

The review response classifies discovered hosts into four groups:

```text
high
medium
low
tricky to know
```

Those groups are not permissions. They are not a verdict. They are not a replacement for operator judgment.

They are a way to make the discovered terrain easier to approach while preserving access to the whole environment.

No discovered host should be hidden behind "interesting."

That is the core interface decision. The model can assist prioritization, but it should not quietly decide which hosts disappear from view.

## Priority groups

### high

Hosts that appear most likely to deserve early operator attention based on the scan evidence.

A high-priority host may expose services, naming, metadata, or other signals that suggest it is worth inspecting early.

### medium

Hosts with some interesting or potentially useful signals, but less urgency than the high-priority group.

Medium does not mean unimportant. It means the first-pass evidence suggests a measured next step rather than immediate focus.

### low

Hosts that appear routine, quiet, expected, or lower-value based on the available scan evidence.

Low does not mean irrelevant. It means the scan evidence does not currently suggest that the host should shape the next move.

The operator can still choose this group.

### tricky to know

Hosts where the scan does not provide enough information to make a confident priority judgment.

"Tricky to know" is not a synonym for low. It is the uncertainty bucket.

A host may be tricky to know because it exposes little information, has ambiguous service data, lacks clear role indicators, or otherwise cannot be confidently prioritized from the first-pass scan alone.

The operator can choose this group too.

## What the interface preserves

The priority review screen shows all four groups, including groups that are already fully inventoried.

After the operator chooses a priority group, the existing host selector opens scoped to that group.

The workflow preserves access to:

```text
high hosts
medium hosts
low hosts
tricky-to-know hosts
unclassified discovered hosts
```

Unclassified discovered hosts default to `tricky to know`.

That default is intentional. Missing classification should not cause a discovered host to vanish from the workflow.

## What this demonstrates

This feature is a small interface decision with a larger design purpose.

It shows that `operator-pipeline` is not just trying to automate command execution. It is trying to preserve a disciplined operator workflow around collection, review, judgment, and follow-up.

The workbench may carry procedural burden.

It should not take authority away from the operator.
