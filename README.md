# stabiliNNatorApp

BV-BRC AppService module for stabiliNNator - GNN-based protein stability prediction.

## Overview

stabiliNNator uses Graph Neural Networks to predict protein stability improvements through two complementary analyses:

- **proliNNator**: Predicts favorable sites for proline mutations based on backbone torsion angles
- **disulfiNNate**: Predicts favorable sites for disulfide bond formation between cysteine pairs

Both tools output PDB files with probabilities (0-1) encoded in the B-factor column, allowing easy visualization in molecular viewers.

## Quick Start

### Using Docker

```bash
# Run proline analysis
docker run --gpus all -v $(pwd)/data:/data dxkb/stabilinnator-bvbrc:latest-gpu \
    stabilinnator proline \
    --model-path /opt/stabilinnator/proliNNator/models/proline_gat.pt \
    --pdb-path /data/input.pdb \
    --output-path /data/output_proline.pdb

# Run disulfide analysis
docker run --gpus all -v $(pwd)/data:/data dxkb/stabilinnator-bvbrc:latest-gpu \
    stabilinnator disulfide \
    --model-path /opt/stabilinnator/disulfiNNate/models/cys_gat.pt \
    --pdb-path /data/input.pdb \
    --output-path /data/output_disulfide.pdb
```

### Using CWL

```bash
cwltool cwl/stabilinnator.cwl cwl/stabilinnator-job.yml
```

### Using BV-BRC AppService

```bash
docker run --gpus all -v $(pwd)/data:/data dxkb/stabilinnator-bvbrc:latest-gpu \
    App-StabiliNNator params.json
```

## Input Format

- **PDB files**: Standard PDB format with ATOM records
- **mmCIF files**: Standard mmCIF/PDBx format

Requirements:
- Structure must contain standard amino acids
- Residues must have CA (alpha carbon) atoms
- For disulfide analysis, cysteine residues with SG atoms are required

## Output Format

Output PDB files contain the original structure with B-factors replaced by prediction probabilities:

- **Range**: 0.0 to 1.0
- **Proline predictions**: Higher values indicate residues more favorable for proline substitution
- **Disulfide predictions**: Higher values on cysteines indicate higher likelihood of disulfide bond participation

### Visualization

In PyMOL:
```python
load output_proline.pdb
spectrum b, blue_white_red, minimum=0, maximum=1
```

In ChimeraX:
```
open output_proline.pdb
color byattribute bfactor palette blue:white:red range 0,1
```

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

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `input_file` | file | required | PDB/mmCIF structure file |
| `analysis_type` | enum | both | proline, disulfide, or both |
| `hidden_dim` | int | varies | Neural network hidden dimension |
| `accelerator` | enum | auto | auto, gpu, or cpu |
| `output_path` | folder | required | Output workspace folder |

## Resource Requirements

stabiliNNator is lightweight compared to structure prediction tools:

| Resource | Default | Notes |
|----------|---------|-------|
| CPU | 4 cores | Sufficient for most proteins |
| Memory | 8 GB | Increases with protein size |
| Runtime | 5-10 min | Both analyses on large proteins |
| GPU | Optional | ~3x faster but not required |

See [docs/RUNTIME_METRICS.md](docs/RUNTIME_METRICS.md) for detailed benchmarks.

## Directory Structure

```
stabiliNNatorApp/
├── app_specs/
│   └── StabiliNNator.json    # BV-BRC app specification
├── container/
│   ├── Dockerfile.stabilinnator       # Base image
│   ├── Dockerfile.stabilinnator-bvbrc # BV-BRC integrated image
│   └── build.sh                       # Build script
├── cwl/
│   ├── stabilinnator.cwl     # CWL workflow definition
│   └── stabilinnator-job.yml # Example job file
├── docs/
│   ├── IMPLEMENTATION_PLAN.md
│   ├── INPUT_FORMATS.md
│   ├── RUNTIME_METRICS.md
│   ├── HANDOFF_UI_TEAM.md
│   └── HANDOFF_DEPLOYMENT_TEAM.md
├── service-scripts/
│   └── App-StabiliNNator.pl  # BV-BRC AppService script
├── tests/
│   ├── validate_output.sh    # Output validation
│   └── params.json           # Test parameters
├── lib/                      # Perl modules
├── scripts/                  # Utility scripts
├── CLAUDE.md                 # Development guide
└── README.md                 # This file
```

## Building

```bash
# Build base image (requires stabiliNNator source)
cd container
./build.sh --base --stabilinnator-src /path/to/stabiliNNator

# Build BV-BRC integrated image
./build.sh --bvbrc

# Build all and push to registry
./build.sh --all --push
```

## Testing

```bash
# Validate output files
./tests/validate_output.sh /path/to/output

# Test with local Docker
docker run --gpus all -v $(pwd)/test_data:/data -v $(pwd)/output:/output \
    dxkb/stabilinnator:latest-gpu prolinnator \
    --model-path /opt/stabilinnator/proliNNator/models/proline_gat.pt \
    --pdb-path /data/test_protein.pdb \
    --output-path /output/test_proline.pdb \
    --device cpu
```

## References

- stabiliNNator: https://github.com/jakobriccabona/stabiliNNator
- BV-BRC: https://www.bv-brc.org/
- PyTorch Geometric: https://pytorch-geometric.readthedocs.io/

## License

MIT License (following stabiliNNator licensing)

## About this module

This module is a component of the BV-BRC build system. It is designed to fit into the
`dev_container` infrastructure which manages development and production deployment of
the components of the BV-BRC. More documentation is available [here](https://github.com/BV-BRC/dev_container/tree/master/README.md).
