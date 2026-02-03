# Runtime Metrics for stabiliNNator

This document captures performance metrics for stabiliNNator tools to inform preflight resource allocation.

## Tool Overview

stabiliNNator consists of two GNN-based prediction tools:
- **proliNNator**: Predicts proline mutation probabilities at each residue position
- **disulfiNNate**: Predicts disulfide bond formation likelihood between cysteine pairs

Both tools use Graph Attention Networks (GAT) and are relatively lightweight compared to structure prediction tools.

## Resource Requirements

### Model Characteristics

| Tool | Model File | Size | Hidden Dim | Architecture |
|------|------------|------|------------|--------------|
| proliNNator | proline_gat.pt | 14 KB | 32 | GATConv + MLP |
| disulfiNNate | cys_gat.pt | 22 KB | 32 | GATv2Conv + MLP |

**Note**: Models use `hidden_dim=32` (not 128 as originally documented). The wrapper scripts default to this value.

## Actual Test Results

### Test Environment (Native x86_64 with GPU)

- **Platform**: Linux x86_64 (native)
- **Host**: lambda13 (AMD EPYC 9654 96-Core, 384 threads, 1.5TB RAM)
- **GPU**: 8x NVIDIA H100 NVL (95GB each)
- **Container Runtime**: Apptainer/Singularity 1.3.4
- **Container Image**: `dxkb/stabilinnator:latest-gpu` (4.2GB SIF)
- **Benchmark Date**: 2026-02-03

### Measured Performance (Native x86_64)

| Protein | PDB ID | Residues | Atoms | proliNNator GPU | proliNNator CPU | disulfiNNate GPU | disulfiNNate CPU |
|---------|--------|----------|-------|-----------------|-----------------|------------------|------------------|
| Small | 1CRN | 46 | 327 | 9.4s | 6.2s | 9.2s | 5.6s |
| Medium | 3FT7 | 90 | 736 | 9.5s | 5.6s | 9.6s | 5.5s |
| Large | 3PGK | 415 | 3145 | 9.3s | 5.4s | 9.3s | 5.2s |

**Key Finding: CPU mode is faster than GPU mode** for these lightweight models. CUDA initialization overhead (~3-4s) exceeds any compute savings from GPU acceleration.

### Memory Usage

| Device | Peak Memory | Notes |
|--------|-------------|-------|
| CPU | ~450-470 MB | Minimal memory footprint |
| GPU | ~780-810 MB | Higher due to CUDA libraries |

### Output Validation

All outputs validated successfully (3 runs each, consistent results):

| Protein | proliNNator B-factor | disulfiNNate B-factor |
|---------|---------------------|----------------------|
| 1CRN (small) | 0.00 - 0.97 | 0.00 - 1.00 |
| 3FT7 (medium) | 0.00 - 0.95 | 0.00 - 0.99 |
| 3PGK (large) | 0.00 - 1.00 | 0.00 - 0.98 |

### Performance Summary

| Protein Size | Residues | Recommended Device | Wall Time | Peak Memory |
|--------------|----------|-------------------|-----------|-------------|
| Small | ~50 | CPU | 5-6s | ~460 MB |
| Medium | ~100 | CPU | 5-6s | ~460 MB |
| Large | ~500 | CPU | 5-6s | ~470 MB |
| Very Large | ~1000+ | CPU (or GPU) | TBD | TBD |

**Recommendation**: Use CPU mode (`--device cpu`) for all protein sizes. GPU provides no benefit due to the small model size.

## Preflight Resource Defaults

Based on the benchmarks above, the recommended default resources for the BV-BRC app are:

```json
{
    "default_cpu": 4,
    "default_memory": "8G",
    "default_runtime": 600,
    "preflight": {
        "cpu": 4,
        "memory": "8G",
        "runtime": 600,
        "storage": "5G",
        "policy_data": {
            "gpu_count": 0
        }
    }
}
```

### Resource Scaling Logic

The preflight function scales resources based on input:

1. **CPU mode (recommended)**:
   - Base runtime: 30s (includes container startup)
   - Add 0.1s per residue for very large proteins (>500 residues)
   - Memory: 512MB base (sufficient for all tested sizes)
   - **Note**: CPU mode is faster than GPU for stabiliNNator's small models

2. **GPU mode (not recommended)**:
   - Base runtime: 30s
   - Minimal scaling with protein size
   - Requires `gpu_count: 1`
   - **Note**: CUDA initialization overhead makes GPU slower than CPU

3. **Analysis type**:
   - Single analysis (proline OR disulfide): use base times
   - Both analyses: multiply by 2x

### Example Preflight Calculation

For a 500-residue protein running both analyses on CPU:
- Base time: 60s
- Residue scaling: 500 * 0.5s = 250s
- Both analyses: (60 + 250) * 1.8 = 558s
- Recommended runtime: 600s (with buffer)
- Memory: 2GB (conservative)

## Comparison to Other BV-BRC Tools

| Tool | Typical Runtime | Memory | GPU Required |
|------|----------------|--------|--------------|
| **stabiliNNator** | **<1 min** | **1-2 GB** | **No** |
| Chai-Lab | 30-120 min | 64-96 GB | Yes (A100) |
| Boltz | 30-90 min | 64 GB | Yes (A100) |
| AlphaFold | 60-240 min | 64 GB | Yes (A100) |

stabiliNNator is **60-100x faster** and uses **30-60x less memory** than structure prediction tools, making it ideal for CPU-only deployments.

## Testing Commands

### Quick Test (CPU)

```bash
# Test proliNNator
time docker run --rm -v $(pwd)/test_data:/data \
    dxkb/stabilinnator:latest-gpu prolinnator \
    --pdb-path /data/test_protein.pdb \
    --output-path /data/output_proline.pdb \
    --device cpu

# Test disulfiNNate
time docker run --rm -v $(pwd)/test_data:/data \
    dxkb/stabilinnator:latest-gpu disulfinnate \
    --pdb-path /data/test_protein.pdb \
    --output-path /data/output_disulfide.pdb \
    --device cpu
```

### GPU Test

```bash
# Test with GPU
time docker run --rm --gpus all -v $(pwd)/test_data:/data \
    dxkb/stabilinnator:latest-gpu prolinnator \
    --pdb-path /data/test_protein.pdb \
    --output-path /data/output_proline.pdb \
    --device cuda
```

### Validate Output

```bash
# Check B-factor range (should be 0-1)
grep "^ATOM" output_proline.pdb | awk '{print substr($0, 61, 6)}' | sort -n | head -1
grep "^ATOM" output_proline.pdb | awk '{print substr($0, 61, 6)}' | sort -n | tail -1
```

## Test Proteins

Test proteins are included in the repository (`test_data/`):

| File | PDB ID | Residues | Description |
|------|--------|----------|-------------|
| 1crn_small.pdb | 1CRN | 46 | Crambin - small plant protein |
| 3ft7.pdb | 3FT7 | 90 | Medium test protein |
| 3pgk_large.pdb | 3PGK | 415 | Phosphoglycerate kinase - large enzyme |

### Obtaining Test Data

The test proteins are sourced from [RCSB Protein Data Bank](https://www.rcsb.org/). They are committed to the repository in `test_data/`, but can also be downloaded fresh:

```bash
# Download test proteins from RCSB PDB
cd test_data

# Small protein - Crambin (46 residues)
curl -O https://files.rcsb.org/download/1CRN.pdb
mv 1CRN.pdb 1crn_small.pdb

# Medium protein (90 residues)
curl -O https://files.rcsb.org/download/3FT7.pdb
mv 3FT7.pdb 3ft7.pdb

# Large protein - Phosphoglycerate kinase (415 residues)
curl -O https://files.rcsb.org/download/3PGK.pdb
mv 3PGK.pdb 3pgk_large.pdb
```

Or use the download script:

```bash
./test_data/download_test_proteins.sh
```

## Technical Notes

1. **Container startup dominates runtime** - Container initialization (~3-4s) is a significant portion of total runtime
2. **Model loading is fast** - Models are only 14-22KB, loading is sub-second
3. **CPU is faster than GPU** - CUDA initialization overhead (~3-4s) exceeds any compute savings for these tiny models
4. **Memory usage is minimal** - Peak memory ~450-800MB depending on device mode
5. **Protein size has minimal impact** - The GNN inference is so fast that runtime is dominated by container/library overhead
6. **disulfiNNate has O(n²) edge computation** - Builds spatial edges between all residue pairs within 6Å cutoff, but still fast

## Completed Benchmarking

- [x] Native x86_64 GPU benchmarks (Issue #12) - **CPU recommended over GPU**
- [x] Memory profiling with `/usr/bin/time -v` - ~450MB CPU, ~780MB GPU

## Pending Work

- [ ] Batch processing benchmarks
- [ ] Very large protein tests (>1000 residues)
