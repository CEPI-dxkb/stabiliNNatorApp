# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

stabiliNNatorApp is a BV-BRC module that integrates stabiliNNator (GNN-based protein stability prediction) into the BV-BRC ecosystem. It follows the `dev_container` infrastructure pattern used across BV-BRC components.

stabiliNNator includes two complementary tools:
- **proliNNator**: Predicts favorable proline mutation sites
- **disulfiNNate**: Predicts favorable disulfide bond formation sites

## Build Commands

```bash
# Build binaries (compiles Perl scripts from scripts/ and service-scripts/)
make all

# Deploy client components (libs, scripts, docs)
make deploy-client

# Deploy service components (includes app_specs)
make deploy-service

# Full deployment
make deploy
```

The build system expects `TOP_DIR` to point to the dev_container root (defaults to `../..`) and uses common rules from `$(TOP_DIR)/tools/Makefile.common`.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3: dxkb/stabilinnator-bvbrc:latest-gpu           │
│           (BV-BRC runtime + Perl modules)               │
├─────────────────────────────────────────────────────────┤
│  Layer 2: dxkb/stabilinnator:latest-gpu                 │
│           (PyTorch + PyTorch Geometric + stabiliNNator) │
├─────────────────────────────────────────────────────────┤
│  Layer 1: nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 │
└─────────────────────────────────────────────────────────┘
```

Key components:
- **app_specs/**: Application specification files for the BV-BRC app service
- **scripts/**: Client-side Perl scripts (`.pl` files compiled to `$(BIN_DIR)`)
- **service-scripts/**: Backend/server-side Perl scripts (App-StabiliNNator.pl)
- **lib/**: Perl modules
- **container/**: Docker build files for stabiliNNator environment
  - `Dockerfile.stabilinnator`: Base image with PyTorch and stabiliNNator
  - `Dockerfile.stabilinnator-bvbrc`: BV-BRC runtime layer
  - `build.sh`: Build script with metadata capture
- **cwl/**: CWL workflow definition for native tool

## Container Build

```bash
# Build base GPU-enabled container (requires stabiliNNator source)
cd container
./build.sh --base --stabilinnator-src /path/to/stabiliNNator

# Build BV-BRC integrated container
./build.sh --bvbrc

# Build and push all
./build.sh --all --push
```

## Key Files

| File | Purpose |
|------|---------|
| `app_specs/StabiliNNator.json` | BV-BRC app specification |
| `service-scripts/App-StabiliNNator.pl` | Main service script with preflight/run |
| `container/Dockerfile.stabilinnator` | Base Docker image |
| `container/Dockerfile.stabilinnator-bvbrc` | BV-BRC integrated image |
| `cwl/stabilinnator.cwl` | CWL workflow (wraps native tool) |

## Testing

```bash
# Validate output files
./tests/validate_output.sh /path/to/output

# Test with local Docker
docker run -v $(pwd)/test_data:/data dxkb/stabilinnator:latest-gpu \
    prolinnator \
    --model-path /opt/stabilinnator/proliNNator/models/proline_gat.pt \
    --pdb-path /data/test_protein.pdb \
    --output-path /data/output.pdb \
    --device cpu
```

Test files follow BV-BRC conventions:
- `t/client-tests/*.t` - Client-side tests
- `t/server-tests/*.t` - Server-side tests
- `t/prod-tests/*.t` - Production tests

## Deployment Paths

- Runtime: `/kb/runtime` (configurable via `DEPLOY_RUNTIME`)
- Target: `/kb/deployment` (configurable via `TARGET`)
- App specs deploy to: `$(TARGET)/services/app_service/app_specs`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STABILINNATOR_DIR` | `/opt/stabilinnator` | Root directory for stabiliNNator code |
| `PROLINNATOR_MODEL` | `$STABILINNATOR_DIR/proliNNator/models/proline_gat.pt` | proliNNator model |
| `DISULFINNATE_MODEL` | `$STABILINNATOR_DIR/disulfiNNate/models/cys_gat.pt` | disulfiNNate model |
| `P3_LOG_LEVEL` | `INFO` | Logging level |
| `P3_DEBUG` | - | Enable debug output |

## Source Tool Reference

The native stabiliNNator tool is located at:
- proliNNator: `/opt/stabilinnator/proliNNator/proliNNator.py`
- disulfiNNate: `/opt/stabilinnator/disulfiNNate/predict_cysteine_probabilities.py`

Command line options:

```bash
# proliNNator
python proliNNator.py \
    --model-path PATH       # Required: path to trained model (.pt)
    --pdb-path PATH         # Required: input PDB file
    --output-path PATH      # Required: output PDB with B-factor probabilities
    --hidden-dim INT        # Optional: hidden dimension (default: 128)
    --device STRING         # Optional: cuda or cpu (default: cuda)

# disulfiNNate
python predict_cysteine_probabilities.py \
    --model-path PATH       # Required: path to trained model (.pt)
    --pdb-path PATH         # Required: input PDB file
    --output-path PATH      # Required: output PDB with B-factor probabilities
    --hidden-dim INT        # Optional: hidden dimension (default: 32)
    --device STRING         # Optional: cuda or cpu (default: cuda)
```

## Resource Requirements

stabiliNNator is lightweight compared to structure prediction tools:

| Resource | Default | Notes |
|----------|---------|-------|
| CPU | 4 cores | Sufficient for most proteins |
| Memory | 8 GB | Increases with protein size |
| Runtime | 5-10 min | Both analyses |
| GPU | Optional | ~3x faster but not required |

See `docs/RUNTIME_METRICS.md` for detailed benchmarks.

## Common Development Tasks

### Adding a new analysis type

1. Add the analysis to the `analysis_type` enum in `app_specs/StabiliNNator.json`
2. Update the `run_stabilinnator()` function in `service-scripts/App-StabiliNNator.pl`
3. Update the CWL workflow in `cwl/stabilinnator.cwl`
4. Update documentation

### Updating the model

1. Replace model files in the container build
2. Update hidden_dim defaults if changed
3. Test with validation script

### Debugging

```bash
# Enable debug mode
export P3_DEBUG=1
export P3_LOG_LEVEL=DEBUG

# Test service script directly
perl service-scripts/App-StabiliNNator.pl tests/params.json

# Test container interactively
docker run -it --gpus all -v $(pwd):/data dxkb/stabilinnator-bvbrc:latest-gpu bash
```
