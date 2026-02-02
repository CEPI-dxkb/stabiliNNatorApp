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
| proliNNator | proline_gat.pt | 14 KB | 128 (default) | GATConv + MLP |
| disulfiNNate | cys_gat.pt | 22 KB | 32 (default) | GATv2Conv + MLP |

### Performance Benchmarks

**Note:** These are estimated values. Update after actual testing.

#### proliNNator

| Protein Size | Residues | GPU Time | CPU Time | Peak Memory |
|-------------|----------|----------|----------|-------------|
| Small | ~50 | <1s | 1-2s | 512 MB |
| Medium | ~200 | 1-2s | 3-5s | 1 GB |
| Large | ~500 | 2-5s | 10-15s | 2 GB |
| Very Large | ~1000 | 5-10s | 30-60s | 4 GB |

#### disulfiNNate

| Protein Size | Residues | GPU Time | CPU Time | Peak Memory |
|-------------|----------|----------|----------|-------------|
| Small | ~50 | <1s | 1-2s | 512 MB |
| Medium | ~200 | 1-2s | 4-6s | 1 GB |
| Large | ~500 | 3-6s | 15-20s | 2 GB |
| Very Large | ~1000 | 8-15s | 45-90s | 4 GB |

#### Combined Analysis (Both Tools)

| Protein Size | Residues | GPU Time | CPU Time | Peak Memory |
|-------------|----------|----------|----------|-------------|
| Small | ~50 | 1-2s | 3-5s | 1 GB |
| Medium | ~200 | 3-5s | 8-12s | 2 GB |
| Large | ~500 | 6-12s | 25-40s | 4 GB |
| Very Large | ~1000 | 15-30s | 75-150s | 6 GB |

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

The preflight function should scale resources based on input:

1. **CPU-only mode (default)**:
   - Base runtime: 120s for small proteins
   - Add 1s per residue for medium/large
   - Memory: 2GB base + 4MB per residue

2. **GPU mode (optional)**:
   - Base runtime: 30s for small proteins
   - Add 0.05s per residue
   - Requires `gpu_count: 1`

3. **Analysis type**:
   - Single analysis (proline OR disulfide): use base times
   - Both analyses: multiply by 1.8x

### Example Preflight Calculation

For a 300-residue protein running both analyses on CPU:
- Base time: 120s
- Residue scaling: 300 * 1s = 300s
- Both analyses: (120 + 300) * 1.8 = 756s
- Recommended runtime: 900s (with buffer)
- Memory: 2GB + (300 * 4MB) = 3.2GB
- Recommended memory: 4GB

## Comparison to Other BV-BRC Tools

| Tool | Typical Runtime | Memory | GPU Required |
|------|----------------|--------|--------------|
| stabiliNNator | 1-10 min | 2-8 GB | No (optional) |
| Chai-Lab | 30-120 min | 64-96 GB | Yes (A100) |
| Boltz | 30-90 min | 64 GB | Yes (A100) |
| AlphaFold | 60-240 min | 64 GB | Yes (A100) |

stabiliNNator is significantly lighter than structure prediction tools, making it suitable for CPU-only deployments.

## Testing Commands

To validate these metrics on your hardware:

```bash
# Test proliNNator with timing
time docker run --gpus all -v /path/to/test_data:/data \
    dxkb/stabilinnator:latest-gpu prolinnator \
    --model-path /opt/stabilinnator/proliNNator/models/proline_gat.pt \
    --pdb-path /data/test_protein.pdb \
    --output-path /data/output_proline.pdb \
    --device cuda

# Test CPU mode
time docker run -v /path/to/test_data:/data \
    dxkb/stabilinnator:latest-gpu prolinnator \
    --model-path /opt/stabilinnator/proliNNator/models/proline_gat.pt \
    --pdb-path /data/test_protein.pdb \
    --output-path /data/output_proline.pdb \
    --device cpu
```

## Test Proteins

Recommended test proteins by size category:

| Category | PDB ID | Residues | Description |
|----------|--------|----------|-------------|
| Small | 1CRN | 46 | Crambin |
| Medium | 1UBQ | 76 | Ubiquitin |
| Medium-Large | 1HHO | 287 | Hemoglobin (single chain) |
| Large | 3J3Q | ~500 | Various sizes available |

## Notes

1. Model loading is a one-time cost (~1-2s) that gets amortized for batch processing
2. GPU memory usage is minimal (~500MB) since models are small
3. Main bottleneck is graph construction from PDB, not inference
4. disulfiNNate is slightly slower due to spatial edge computation (O(n^2) pairwise distances)
