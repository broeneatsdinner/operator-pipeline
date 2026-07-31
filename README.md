# operator-pipeline

operator-pipeline is a local operator workbench for authorized security-assessment discovery workflows.

It is not a scanner wrapper, and it is not an attempt to automate away operator judgment. The scanner is one instrument inside the workflow. The product is the disciplined session lifecycle around the scan: arrive with a baseline, observe carefully, preserve what matters, restore the environment, and know when the engagement is actually closed.

The operator still decides what to do.

The workbench carries the procedural burden.

**[Read the Operator Pipeline manual →](docs/index.md)**

## Field posture

Think of arriving at a train station with a fresh notebook and a fresh pen:
unbranded, unknown to the room, and ready to record the trains that pass
through. That is the posture this project tries to preserve—arrive cleanly,
observe carefully, record what matters, and leave with the notes the engagement
required.

## What is here

The public workbench foundation includes a stateful operator console, public-safe
helpers, review prompts, a synthetic interface demo, and placeholders for the
runtime material that must remain local.

```text
operator-workbench.sh  # lifecycle entrypoint
assets/                # focused helpers
demos/                 # synthetic, non-network demonstrations
docs/                  # canonical manual and Pages source
log/                   # ignored runtime records; one sanitized example
scans/                 # ignored collection artifacts
prompts/               # review instructions
```

Start with the manual’s [lifecycle](docs/lifecycle.md), then read the
[priority-review boundary](docs/priority-review.md). To see one public-safe
interface slice, run:

```sh
./demos/inventory-active-row-demo.sh
```

It uses synthetic progress states. It does not run Nmap, read scan directories,
or invoke a live workbench workflow.

## Public boundary

This is a sanitized public foundation, not an engagement archive or a map of a
real environment. Real hosts, identities, network details, scan artifacts,
runtime logs, private notes, terminal captures, credentials, and secrets do not
belong here. The manual explains the project’s [scope and evidence boundary](docs/scope-and-evidence.md).

## Status

The public code expresses an implemented workbench lifecycle and public-safe
helpers. The project has also exercised a complete lifecycle in a separate
private working environment; that evidence does not make private artifacts or
topology public. Read the [manual’s evidence notes](docs/scope-and-evidence.md)
for the distinction between implemented behavior, the synthetic demo, and future work.
