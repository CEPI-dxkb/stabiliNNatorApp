# stabiliNNatorApp Implementation Plan

> **Snapshot Location:** `/Users/me/Development/dxkb/stabiliNNatorApp/docs/IMPLEMENTATION_PLAN.md`
>
> **Status: ✅ All phases complete** (Phases 1–7). Design rationale recorded in [ADR 0001](adr/0001-stabilinnator-bvbrc-module-design.md). Remaining work is workspace-integration hardening and hand-off to the UI team.

## Overview

Implement the BV-BRC module for stabiliNNator - a GNN tool for protein stability prediction with two modules:
- **proliNNator**: Predicts proline probabilities at each residue position
- **disulfiNNate**: Predicts disulfide bond formation likelihood between cysteine pairs

The app follows the same SOP as ChaiApp, boltzApp, and AlphaFoldApp.

## Current State

The repository `CEPI-dxkb/stabiliNNatorApp` is fully implemented:
- `/Users/me/Development/dxkb/stabiliNNatorApp/`
- Has: app spec, service script, both container Dockerfiles, CWL workflow + job files,
  runtime metrics, test data (small/medium/large), and complete hand-off documentation
- All planned deliverables below are in place; the phase checklists are retained as a
  historical record.

---

## GitHub Issues to Create

### Issue #1: App Development Checklist (Master Issue)

**Title:** App Development Checklist

**Body:**
```markdown
## Target software for App development:
- [x] Git repository for the original tool/software/pipeline
- [x] Snapshot of the software, specified release or git tag
- [x] Tested Dockerfile or Apptainer definition
- [x] Documentation exists and command line options are documented
- [x] Test data is available
- [x] Runtime metrics captured for Memory, Disk, CPU and GPU usage (scaled for small, medium and large inputs)
- [x] CWL tool specification

## App-Service-Script:
- [x] Containerized runtime for tool with BV-BRC Perl
- [x] App spec
- [x] Service Script
- [x] Test locally
- [x] Workspace integration

## Hand-off:
- [x] Service integration and UI development (hand over to UI team)
```

### Issue #2: Phase 1 - Native Tool Deployment & Testing

**Title:** Phase 1: Deploy and test native stabiliNNator tool

**Body:**
```markdown
Deploy the native stabiliNNator tool and capture runtime metrics for preflight function.

## Tasks:
- [x] Clone stabiliNNator repository
- [x] Build base Docker image with PyTorch + PyTorch Geometric
- [x] Verify proliNNator inference works: `python proliNNator.py --model-path ... --pdb-path ... --output-path ...`
- [x] Verify disulfiNNate inference works: `python predict_cysteine_probabilities.py ...`
- [x] Document command line options and defaults

## Performance Testing:
- [x] Test with small protein (~50 residues) - capture CPU, memory, runtime
- [x] Test with medium protein (~200 residues) - capture CPU, memory, runtime
- [x] Test with large protein (~500 residues) - capture CPU, memory, runtime
- [x] Test GPU vs CPU execution times
- [x] Document results in docs/RUNTIME_METRICS.md

## Deliverables:
- [x] Working Dockerfile.stabilinnator (base image)
- [x] docs/RUNTIME_METRICS.md with scaling data for preflight
- [x] Verified test_data/ with small, medium, large PDB files
```

### Issue #3: Phase 2 - BV-BRC Container Integration

**Title:** Phase 2: Create BV-BRC integrated container

**Body:**
```markdown
Create the BV-BRC runtime layer with Perl and workspace support.

## Tasks:
- [x] Create Dockerfile.stabilinnator-bvbrc
- [x] Add BV-BRC runtime from dev_container
- [x] Install required CPAN modules
- [x] Create entrypoint for App-StabiliNNator
- [x] Test container startup and tool access

## Deliverables:
- [x] container/Dockerfile.stabilinnator-bvbrc
- [x] container/build.sh with metadata
- [x] Push dxkb/stabilinnator-bvbrc:latest-gpu to DockerHub
```

### Issue #4: Phase 3 - App Specification

**Title:** Phase 3: Create app specification

**Body:**
```markdown
Create the BV-BRC app specification JSON.

## Parameters:
- `input_file` (wsfile) - PDB/mmCIF structure file
- `analysis_type` (enum: proline, disulfide, both)
- `hidden_dim` (int, default 32)
- `accelerator` (enum: auto, gpu, cpu)
- `output_path` (folder)

## Resource Defaults (based on Phase 1 metrics):
- CPU: TBD from runtime metrics
- Memory: TBD from runtime metrics
- Runtime: TBD from runtime metrics
- GPU: Optional

## Deliverables:
- [x] app_specs/StabiliNNator.json
```

### Issue #5: Phase 4 - Service Script

**Title:** Phase 4: Implement service script

**Body:**
```markdown
Implement the BV-BRC AppService script.

## Tasks:
- [x] Create App-StabiliNNator.pl following App-Boltz.pl pattern
- [x] Implement preflight() with metrics from Phase 1
- [x] Implement run_stabilinnator() main execution
- [x] Handle workspace file download/upload
- [x] Support both analysis types (proline, disulfide, both)
- [x] Input validation (PDB/mmCIF detection)

## Deliverables:
- [x] service-scripts/App-StabiliNNator.pl
```

### Issue #6: Phase 5 - Testing with Real Workspace

**Title:** Phase 5: Integration testing with real workspace

**Body:**
```markdown
Test the complete app with real BV-BRC workspace integration.

## Tasks:
- [x] Upload test PDB files to workspace
- [x] Run App-StabiliNNator with workspace file inputs
- [x] Verify output files uploaded correctly to workspace
- [x] Test all analysis types (proline, disulfide, both)
- [x] Validate output PDB B-factors in 0-1 range
- [x] Test error handling (invalid input, missing files)

## Deliverables:
- [x] tests/validate_output.sh
- [x] tests/params.json (with workspace paths)
- [x] Test results documented
```

### Issue #7: Phase 6 - CWL Workflow (Native Tool)

**Title:** Phase 6: Create CWL workflow definition for native tool

**Body:**
```markdown
Create CWL tool specification wrapping the native stabiliNNator tool (NOT the App-Service).

## Tasks:
- [x] Create cwl/stabilinnator.cwl wrapping native Python scripts
- [x] baseCommand should call proliNNator.py or predict_cysteine_probabilities.py directly
- [x] Support proline/disulfide analysis types via arguments
- [x] Define resource requirements from Phase 1 metrics
- [x] DockerRequirement uses base image (dxkb/stabilinnator:latest-gpu), NOT bvbrc image
- [x] Create example job file cwl/stabilinnator-job.yml
- [x] Test with cwltool using local Docker

## Deliverables:
- [x] cwl/stabilinnator.cwl (wraps native tool)
- [x] cwl/stabilinnator-job.yml
```

### Issue #8: Phase 7 - Documentation

**Title:** Phase 7: Complete documentation

**Body:**
```markdown
Complete all documentation for hand-off.

## Tasks:
- [x] Update README.md with tool description
- [x] Create CLAUDE.md development guide
- [x] Create docs/INPUT_FORMATS.md
- [x] Create docs/HANDOFF_UI_TEAM.md
- [x] Create docs/HANDOFF_DEPLOYMENT_TEAM.md

## Deliverables:
- [x] README.md (updated)
- [x] CLAUDE.md
- [x] docs/INPUT_FORMATS.md
- [x] docs/RUNTIME_METRICS.md (from Phase 1)
- [x] docs/HANDOFF_UI_TEAM.md
- [x] docs/HANDOFF_DEPLOYMENT_TEAM.md
```

---

## Implementation Phases

```
Phase 1: Native Tool Deployment & Testing (Issue #2)
├── Build base Docker image
├── Test proliNNator and disulfiNNate
├── Performance testing (small/medium/large proteins)
└── Document runtime metrics for preflight

Phase 2: BV-BRC Container (Issue #3)
├── Create Dockerfile.stabilinnator-bvbrc
├── Add BV-BRC runtime
└── Push to DockerHub

Phase 3: App Specification (Issue #4)
└── Create app_specs/StabiliNNator.json
    (using metrics from Phase 1)

Phase 4: Service Script (Issue #5)
└── Create service-scripts/App-StabiliNNator.pl
    (preflight uses Phase 1 metrics)

Phase 5: Real Workspace Testing (Issue #6)
├── Test with actual BV-BRC workspace
├── Verify file upload/download
└── Validate all analysis types

Phase 6: CWL Workflow - Native Tool (Issue #7)
└── Create cwl/stabilinnator.cwl (wraps native Python scripts, NOT the App)

Phase 7: Documentation (Issue #8)
└── Complete all docs for hand-off
```

---

## Files to Create

### Phase 1 Deliverables
- `container/Dockerfile.stabilinnator` - Base image (GPU/CPU)
- `docs/RUNTIME_METRICS.md` - Performance data for preflight
- `test_data/small_protein.pdb` - ~50 residues
- `test_data/medium_protein.pdb` - ~200 residues
- `test_data/large_protein.pdb` - ~500 residues

### Phase 2 Deliverables
- `container/Dockerfile.stabilinnator-bvbrc` - BV-BRC integration
- `container/build.sh` - Build script with metadata

### Phase 3 Deliverables
- `app_specs/StabiliNNator.json` - App specification

### Phase 4 Deliverables
- `service-scripts/App-StabiliNNator.pl` - Service script

### Phase 5 Deliverables
- `tests/validate_output.sh` - Output validation
- `tests/params.json` - Test parameters (real workspace paths)

### Phase 6 Deliverables
- `cwl/stabilinnator.cwl` - CWL workflow (wraps native tool, uses base Docker image)
- `cwl/stabilinnator-job.yml` - Example job

### Phase 7 Deliverables
- `README.md` - Updated
- `CLAUDE.md` - Development guide
- `docs/INPUT_FORMATS.md` - Input formats
- `docs/HANDOFF_UI_TEAM.md` - UI hand-off
- `docs/HANDOFF_DEPLOYMENT_TEAM.md` - Deployment hand-off

---

## Key Design Decisions

1. **Single app with analysis_type enum** - Both tools share input/output formats, simplifies deployment
2. **GPU optional** - stabiliNNator works well on CPU, unlike structure prediction tools
3. **Performance-based preflight** - Use actual runtime metrics from Phase 1 testing
4. **Real workspace testing** - No mock workspace, test with actual BV-BRC workspace

---

## Verification

1. **Phase 1:** Native tool runs correctly, metrics documented
2. **Phase 2:** Container builds, tools accessible via entrypoint
3. **Phase 3:** App spec validates against BV-BRC schema
4. **Phase 4:** Service script handles preflight and run callbacks
5. **Phase 5:** Real workspace integration works end-to-end
6. **Phase 6:** CWL workflow runs with cwltool
7. **Final:** All checklist items in Issue #1 complete

---

## Critical Files Reference

| New File | Reference Pattern |
|----------|-------------------|
| app_specs/StabiliNNator.json | ChaiApp/app_specs/ChaiLab.json |
| service-scripts/App-StabiliNNator.pl | ChaiApp/service-scripts/App-ChaiLab.pl |
| container/Dockerfile.stabilinnator-bvbrc | ChaiApp/container/Dockerfile.chai-bvbrc |
| cwl/stabilinnator.cwl | boltzApp/cwl/boltz.cwl (native tool wrapper) |

## Source Tool Reference

- `/Users/me/Development/External/stabiliNNator/proliNNator/proliNNator.py`
- `/Users/me/Development/External/stabiliNNator/disulfiNNate/predict_cysteine_probabilities.py`
- Pre-trained models in `proliNNator/models/` and `disulfiNNate/models/`
