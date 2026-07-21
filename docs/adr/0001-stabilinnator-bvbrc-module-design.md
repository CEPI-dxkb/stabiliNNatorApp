# ADR 0001: stabiliNNator BV-BRC Module Design

- **Status:** Accepted
- **Date:** 2026-02-05
- **Deciders:** dxkb team
- **Supersedes:** —
- **Context source:** derived from `docs/IMPLEMENTATION_PLAN.md`

## Context

stabiliNNator is a GNN-based protein stability tool with two independent
modules — **proliNNator** (per-residue proline probabilities) and
**disulfiNNate** (cysteine-pair disulfide-bond likelihood). We need to expose
it through the BV-BRC ecosystem following the same SOP already established by
ChaiApp, boltzApp, and AlphaFoldApp (three-layer container, app spec, service
script, CWL wrapper).

Several design questions had to be settled before implementation: whether to
ship one app or two, how to treat GPU, how to size preflight resource requests,
and how to test workspace integration. This ADR records those decisions and
their rationale so the reasoning survives independently of the phase-tracking
plan document.

## Decisions

### 1. Single app with an `analysis_type` enum (not two separate apps)

proliNNator and disulfiNNate share the same input format (PDB/mmCIF), the same
output format (PDB with per-position probabilities written to the B-factor
column), and the same runtime container. Exposing them as one app with an
`analysis_type` enum (`proline` | `disulfide` | `both`) keeps a single app spec,
service script, and container to maintain, and lets a user request both analyses
in one job.

- **Alternative rejected:** two independent apps — doubles the surface area
  (specs, scripts, deployment, UI entries) for tools that differ only in which
  model checkpoint they load.

### 2. GPU is optional, CPU is the default expectation

Unlike the structure-prediction tools in this workspace (Boltz, Chai,
AlphaFold), stabiliNNator runs comfortably on CPU. GPU gives roughly a 3×
speedup but is not required, and for small inputs CPU can be faster once GPU
startup overhead is counted. The app therefore treats GPU as optional
(`accelerator: auto | gpu | cpu`) rather than a hard scheduling constraint.

- **Consequence:** the preflight must not demand a GPU partition; jobs schedule
  on CPU nodes by default.

### 3. Preflight resource requests are driven by measured benchmarks

Rather than guess CPU/memory/runtime, Phase 1 captured runtime metrics across
small/medium/large proteins (see `docs/RUNTIME_METRICS.md`), and those numbers
back the defaults in `app_specs/StabiliNNator.json` and the `preflight()`
function in `service-scripts/App-StabiliNNator.pl`.

- **Consequence:** resource values in the spec and CWL are traceable to
  measurements, not folklore; re-benchmark when the model or container changes.

### 4. Integration is tested against a real BV-BRC workspace (no mock)

Workspace file download/upload is the part of BV-BRC integration most likely to
break in subtle ways (Shock-backed storage, `use_shock=1`, `save_file_to_file`
params, auth). We validate end-to-end against an actual workspace rather than a
mock, so those edge cases surface during development.

- **Consequence:** integration tests require workspace credentials; they are not
  fully hermetic.

## Consequences

- One app spec / service script / container to maintain; both analyses share a
  code path parameterized by `analysis_type`.
- Jobs are schedulable without GPU, widening where they can run.
- Preflight estimates stay honest as long as `RUNTIME_METRICS.md` is kept
  current.
- CI cannot run the workspace integration tests without credentials.

## Related

- `docs/IMPLEMENTATION_PLAN.md` — phase breakdown and deliverable checklist
- `docs/RUNTIME_METRICS.md` — benchmarks backing decision 3
- `docs/HANDOFF_UI_TEAM.md`, `docs/HANDOFF_DEPLOYMENT_TEAM.md`
