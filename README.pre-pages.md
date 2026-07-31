# operator-pipeline

operator-pipeline is a local operator workbench for security-assessment discovery workflows.

It is not a scanner wrapper, and it is not an attempt to automate away operator judgment. The scanner is only one instrument inside the workflow. The product is the disciplined session lifecycle around the scan.

operator-pipeline exists for the parts of assessment work that can become stressful precisely because they are repetitive: remembering the baseline, changing identity state carefully, choosing a quiet first pass, preserving the right artifacts, restoring the environment, and knowing when the engagement is cleanly closed.

The operator still decides what to do.

The workbench carries the procedural burden.

---

## Field posture

At one point, I likened this to walking into a train station, taking a seat, and opening a fresh notebook that is unbranded and unknown by any onlookers where it could have been purchased.

Using a fresh pen.

Meticulously recording the trains passing through the station.

That is the posture operator-pipeline is trying to preserve: arrive cleanly, observe carefully, record what matters, and leave with the notes the engagement required.

---

## What the workbench does

The current workbench supports a verified end-to-end lifecycle:

1. capture the conductor baseline;
2. prepare a temporary conductor identity;
3. prepare a temporary collector identity;
4. run collector-side discovery;
5. preserve generated collection artifacts;
6. restore the collector;
7. restore the conductor;
8. record the completed session;
9. prepare a fresh baseline for the next engagement.

This turns a fragile sequence of terminal operations into a reversible, inspectable operator session.

---

## Why it exists

Assessment work often fails at the seams.

The scan command itself is rarely the whole problem. The harder parts are the state around the command:

- What identity was the conductor using before the session started?
- What identity was the collector using?
- Was discovery run from the intended endpoint?
- Was the first pass quiet enough for the engagement?
- Where did the output go?
- What still needs review?
- Was the collector restored?
- Was the conductor restored?
- Is the session actually complete?

operator-pipeline was built around those seams.

It gives the operator a workbench for moving through the engagement deliberately instead of carrying the whole procedure in terminal memory.

---

## Current repository state

This public repository contains the sanitized workbench foundation:

```text
operator-workbench.sh
assets/
demos/
log/
prompts/
scans/
vendor/
```

The main entrypoint is:

```sh
./operator-workbench.sh
```

The current public tree includes the workbench and helper components needed to express the implemented workflow, plus public-safe runtime placeholders and examples.

---

## Runtime layout

Generated runtime material is separated by purpose:

```text
log/
```

Generated operational records and state examples.

```text
scans/
```

Generated collection artifacts.

```text
prompts/
```

Review prompts used by enrichment and operator handoff components.

```text
demos/
```

Public-safe demonstrations that use synthetic data.

The public repository intentionally keeps `log/` and `scans/` mostly empty. Real assessment records do not belong in the public tree.

---

## Demo

The current demo is a non-network visual demonstration of the active inventory row:

```sh
./demos/inventory-active-row-demo.sh
```

It uses synthetic progress states. It does not run Nmap, read scan directories, or invoke a live workbench workflow.

This demo is not the full proof of the operator-pipeline lifecycle. It is a public-safe visual slice of one operator-facing surface.

---

## Implemented and verified

The private workbench environment has completed a verified lifecycle including:

- conductor baseline capture;
- conductor temporary identity;
- collector temporary identity;
- collector-side discovery;
- collector restoration;
- conductor restoration;
- completed-session recording;
- fresh baseline preparation.

Several implementation fixes came directly from exercising the real workflow:

- noninteractive collector SSH commands now avoid inheriting interactive `RemoteCommand` / TTY behavior from local SSH configuration;
- collector restore verification retries briefly after reconnect or address changes;
- completed-session UX clearly tells the operator when no immediate action is required;
- generated conductor runtime state uses flat files under `log/` rather than writing operational state into private reference directories.

---

## Public/private boundary

This repository is a public, sanitized release of the workbench foundation.

It intentionally excludes:

- real collector aliases;
- real conductor or collector hostnames;
- real MAC addresses;
- private usernames;
- local SSH configuration paths;
- real scan artifacts;
- generated runtime logs from real sessions;
- private notes;
- screenshots or terminal captures from private environments;
- credentials, tokens, keys, or secrets;
- personal, client, home, school, family, or engagement-specific material.

The public hostname-generation corpus is also intentionally demonstrative. It is not the private operational corpus used for real engagements.

---

## What this demonstrates

operator-pipeline demonstrates more than command automation.

It shows a way of treating assessment work as a stateful operator lifecycle:

- baseline before mutation;
- temporary posture before collection;
- quiet discovery before escalation;
- artifact capture before interpretation;
- restoration before closure;
- session records before walking away.

The goal is not to make the operator careless.

The goal is to let the operator reserve attention for judgment while the workbench carries the repeatable state-management burden.

---

## Roadmap

Future public work may include:

- a fuller deterministic lifecycle demo;
- diagrams of conductor / collector responsibilities;
- expanded runtime-layout documentation;
- public-safe screenshots or terminal recordings;
- clearer local configuration examples;
- normalized report artifacts;
- additional release-audit tooling.

Those items are not presented here as complete. The current public release is the sanitized workbench foundation and verified lifecycle story.
