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

### Large Protein Benchmarks

Additional benchmarks with larger proteins (CPU mode):

| Protein | PDB ID | Residues | Atoms | proliNNator | disulfiNNate | Memory |
|---------|--------|----------|-------|-------------|--------------|--------|
| COVID protease | 6LU7 | 309 | 2,387 | 9.4s | 5.0s | 452 MB |
| Adenylate kinase | 4AKE | 428 | 3,312 | 6.1s | 5.9s | 454 MB |
| **GroEL complex** | **1AON** | **8,015** | **58,674** | **8.4s** | **18.6s** | **505 MB** |

**Key observations**:
- proliNNator scales well even to very large complexes (8,015 residues in 8.4s)
- disulfiNNate shows O(n²) scaling for large proteins due to spatial edge computation (18.6s for 1AON)
- Memory usage remains modest even for large complexes (~500 MB)

### Performance Summary

| Protein Size | Residues | Recommended Device | Wall Time | Peak Memory |
|--------------|----------|-------------------|-----------|-------------|
| Small | ~50 | CPU | 5-6s | ~460 MB |
| Medium | ~100 | CPU | 5-6s | ~460 MB |
| Large | ~500 | CPU | 5-6s | ~470 MB |
| Very Large | ~8,000 | CPU | 8-19s | ~505 MB |

**Recommendation**: Use CPU mode (`--device cpu`) for all protein sizes. GPU provides no benefit due to the small model size.

## Batch Processing

### Current Implementation

The native stabiliNNator tools (`proliNNator.py`, `predict_cysteine_probabilities.py`) accept only a single `--pdb-path` argument. Batch processing requires an external loop, which means:

1. **Container startup overhead per protein** (~3-4s each)
2. **PyTorch/model loading overhead per protein** (~2s each)
3. **Actual inference is sub-second** for most proteins

### Batch Benchmark Results

Sequential processing of 10 proteins (mixed sizes: 46-415 residues):

| Tool | Total Time | Avg per Protein | Throughput |
|------|------------|-----------------|------------|
| proliNNator | 56.9s | 5.7s | 10.2 proteins/min |
| disulfiNNate | 57.8s | 5.8s | 10.2 proteins/min |

### Potential Optimization

Native batch support in the upstream tool could significantly improve throughput:

| Scenario | Time per Protein | Improvement |
|----------|------------------|-------------|
| Current (external loop) | ~5.7s | baseline |
| Native batch (amortized startup) | ~0.5-1.0s | **5-10x faster** |

**Recommendation for upstream**: Adding `--pdb-dir` or `--pdb-list` arguments to proliNNator/disulfiNNate would:
- Load PyTorch and model once
- Process all proteins in a single container invocation
- Reduce per-protein overhead from ~5s to <1s
- Enable throughput of 60-120 proteins/minute

For BV-BRC, the current single-protein interface is sufficient since jobs typically process one structure at a time.

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
- Base time: 30s (container startup + model loading)
- Residue scaling: minimal for proteins <1000 residues
- Both analyses: 30s × 2 = 60s
- Recommended runtime: 120s (with 2x buffer)
- Memory: 1GB (conservative)

For very large proteins (e.g., 8,000 residues like GroEL):
- Base time: 30s
- Both analyses: ~30s (proliNNator: 8s, disulfiNNate: 19s)
- Recommended runtime: 120s
- Memory: 1GB

## Resource Comparison

stabiliNNator is a lightweight prediction tool that runs efficiently on CPU:
- **Runtime**: <1 min for typical proteins
- **Memory**: 500 MB - 1 GB
- **GPU**: Not required (CPU is actually faster due to CUDA overhead)

This makes stabiliNNator ideal for CPU-only deployments and batch processing scenarios.

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
- [x] Batch processing benchmarks - ~10 proteins/min with external loop
- [x] Very large protein tests - 1AON (8,015 residues) completes in 8-19s

## Pending Work

All critical benchmarks complete. Optional future work:

- [ ] Upstream feature request: native batch support (`--pdb-dir` or `--pdb-list`)
- [ ] Parallel batch processing (multiple containers simultaneously)

### Benchmark Scripts

Run on native x86_64 with Docker or Singularity:

```bash
# GPU/CPU comparison benchmark
./tests/gpu_benchmark_singularity.sh

# Batch and large protein benchmark
./tests/benchmark_batch_large.sh singularity  # or 'docker'
```
