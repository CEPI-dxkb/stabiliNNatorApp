# Handoff Document: Deployment Team

This document provides information needed for deploying stabiliNNator to the BV-BRC production environment.

## Container Images

### Production Images

| Image | Tag | Purpose |
|-------|-----|---------|
| `dxkb/stabilinnator` | `latest-gpu` | Base image with PyTorch + stabiliNNator |
| `dxkb/stabilinnator-bvbrc` | `latest-gpu` | BV-BRC integrated image (deploy this) |

### Image Registry

Images are hosted on DockerHub:
- https://hub.docker.com/r/dxkb/stabilinnator
- https://hub.docker.com/r/dxkb/stabilinnator-bvbrc

### Building Images

```bash
cd container/

# Build base image (requires stabiliNNator source code)
./build.sh --base --stabilinnator-src /path/to/stabiliNNator

# Build BV-BRC integrated image
./build.sh --bvbrc

# Build and push to registry
./build.sh --all --push
```

### Image Layers

```
┌─────────────────────────────────────────────────────────┐
│  dxkb/stabilinnator-bvbrc:latest-gpu                    │
│  - BV-BRC Perl runtime                                  │
│  - App-StabiliNNator.pl service script                  │
│  - app_specs/StabiliNNator.json                         │
├─────────────────────────────────────────────────────────┤
│  dxkb/stabilinnator:latest-gpu                          │
│  - PyTorch 2.1.0 + CUDA 11.8                           │
│  - PyTorch Geometric 2.4.0                              │
│  - BioPython, NumPy, etc.                               │
│  - stabiliNNator source + pre-trained models            │
├─────────────────────────────────────────────────────────┤
│  nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04          │
└─────────────────────────────────────────────────────────┘
```

## Resource Requirements

### Default Allocation

Based on actual benchmarks (see [RUNTIME_METRICS.md](RUNTIME_METRICS.md)):

```json
{
    "default_cpu": 2,
    "default_memory": "1G",
    "default_runtime": 120,
    "preflight": {
        "cpu": 2,
        "memory": "1G",
        "runtime": 120,
        "storage": "1G",
        "policy_data": {
            "gpu_count": 0,
            "partition": "normal"
        }
    }
}
```

### Scaling Notes

- **Memory**: 1GB sufficient for all proteins tested (up to 8,015 residues); actual usage ~500MB
- **CPU**: 2 cores is sufficient; these are small GNN models (~14-22KB)
- **GPU**: **Not recommended** - CPU is actually faster due to CUDA initialization overhead
- **Storage**: 1GB is generous; actual disk usage is minimal (<50MB)

### Comparison to Other Apps

| App | CPU | Memory | GPU Required | Typical Runtime |
|-----|-----|--------|--------------|-----------------|
| stabiliNNator | 2 | 1GB | No (CPU faster) | 5-60 sec |
| Chai-Lab | 8 | 64GB | Yes (A100) | 30-120 min |
| Boltz | 8 | 64GB | Yes (A100) | 30-90 min |
| AlphaFold | 8 | 64GB | Yes (A100) | 60-240 min |

stabiliNNator is **significantly lighter** than structure prediction tools:
- ~60x less memory than Chai/Boltz/AlphaFold
- ~100x faster runtime
- No GPU required (CPU is actually faster for these small models)

## Deployment Steps

### 1. Pull Images

```bash
docker pull dxkb/stabilinnator-bvbrc:latest-gpu
```

### 2. Deploy App Spec

```bash
# Copy app spec to app_service directory
cp app_specs/StabiliNNator.json \
    /kb/deployment/services/app_service/app_specs/

# Restart app service to pick up new spec
systemctl restart app_service
```

### 3. Verify Deployment

```bash
# Check app is registered
curl -s https://p3.theseed.org/services/app_service/app | jq '.[] | select(.id=="StabiliNNator")'

# Test dry run
docker run -v $(pwd)/test:/data dxkb/stabilinnator-bvbrc:latest-gpu \
    App-StabiliNNator '{"input_file":"/data/test.pdb","output_path":"/data/output","dry_run":true}'
```

## Workspace Integration Testing

### Authentication

To test with real BV-BRC workspace, you need a valid PATRIC token:

```bash
# 1. Login to BV-BRC (creates ~/.patric_token)
p3-login your_username

# 2. Verify login status
p3-login --status

# 3. Export token as environment variable
export P3_AUTH_TOKEN=$(cat ~/.patric_token)
```

### Testing with Workspace Files

```bash
# Pass token to container via environment variable
docker run --rm \
    -e "P3_AUTH_TOKEN=$P3_AUTH_TOKEN" \
    dxkb/stabilinnator-bvbrc:latest-gpu \
    p3-ls /your_user@bvbrc/home/

# Test full workspace integration
docker run --rm \
    -e "P3_AUTH_TOKEN=$P3_AUTH_TOKEN" \
    -v /path/to/app:/app:ro \
    dxkb/stabilinnator-bvbrc:latest-gpu \
    perl /app/service-scripts/App-StabiliNNator.pl \
        http://localhost \
        /app/app_specs/StabiliNNator.json \
        /app/tests/workspace_test.json
```

### Test Parameters (tests/workspace_test.json)

```json
{
    "input_file": "/your_user@bvbrc/home/path/to/protein.pdb",
    "analysis_type": "both",
    "output_path": "/your_user@bvbrc/home/path/to/output"
}
```

### Token Location

The PATRIC token is stored at `~/.patric_token` after running `p3-login`. The token format is:
```
un=user@bvbrc|tokenid=...|expiry=...|client_id=...|token_type=Bearer|...
```

### Important Notes

1. **Token Expiry**: Tokens expire; check `expiry` field in token string
2. **Shock Files**: Workspace files are stored in Shock; the service script uses `use_shock=1` parameter to download actual content
3. **Alternative**: You can also mount the token file directly:
   ```bash
   docker run -v ~/.patric_token:/root/.patric_token:ro ...
   ```
   However, `P3_AUTH_TOKEN` environment variable is preferred for production.
4. **Valid workspace object types**: `save_file_to_file` rejects unknown
   types with `_ERROR_Invalid type submitted!_` and nothing is uploaded.
   Output PDBs must use type **`pdb`** (not `structure`, which is invalid).
   Other verified-valid types: `unspecified`, `txt`, `contigs`, `json`.
5. **job_result folder quirk (local testing only)**: When running the
   AppScript directly (outside the real AppService) into a pre-existing
   output folder, the framework's `job_result` write logs
   `_ERROR_Cannot overwrite directory <output>/ on save!_`. This is the
   framework writing task metadata, not the data upload — the result PDBs
   still upload correctly. In production the AppService creates a fresh
   output folder per task, so this does not occur.

## Container Entry Points

### BV-BRC AppService

```bash
docker run dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator params.json
docker run dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator --preflight params.json
```

### Native Tool Access

```bash
docker run dxkb/stabilinnator-bvbrc:latest-gpu stabilinnator proline [options]
docker run dxkb/stabilinnator-bvbrc:latest-gpu stabilinnator disulfide [options]
docker run dxkb/stabilinnator-bvbrc:latest-gpu prolinnator [options]
docker run dxkb/stabilinnator-bvbrc:latest-gpu disulfinnate [options]
```

### Interactive Shell

```bash
docker run -it dxkb/stabilinnator-bvbrc:latest-gpu bash
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STABILINNATOR_DIR` | `/opt/stabilinnator` | stabiliNNator installation |
| `PROLINNATOR_MODEL` | `.../proline_gat.pt` | proliNNator model file |
| `DISULFINNATE_MODEL` | `.../cys_gat.pt` | disulfiNNate model file |
| `P3_LOG_LEVEL` | `INFO` | Logging verbosity |
| `P3_WORKDIR` | `/tmp` | Working directory |

## Storage and Caching

### Model Files

Pre-trained models are embedded in the container:
- `/opt/stabilinnator/proliNNator/models/proline_gat.pt` (14KB)
- `/opt/stabilinnator/disulfiNNate/models/cys_gat.pt` (22KB)

No external downloads required during runtime.

### Cache Directory

No persistent cache required. Each job is independent.

### Temporary Storage

Jobs create temporary files in `$P3_WORKDIR`:
- Input files downloaded from workspace
- Output files before upload

Typical disk usage: <50MB per job.

## GPU Configuration

### CPU Recommended

Unlike Chai/Boltz/AlphaFold, stabiliNNator **should use CPU**:

```bash
# CPU mode (default, recommended)
docker run dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator params.json

# GPU mode (available but NOT recommended)
docker run --gpus all dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator params.json
```

**Why CPU is faster**: The GNN models are very small (~14-22KB). CUDA initialization overhead (~3-5 seconds) exceeds the actual inference time on GPU, making CPU faster for typical workloads.

### CUDA Requirements

If GPU is used (not recommended):
- CUDA 11.8+ compatible driver
- cuDNN 8.x
- NVIDIA GPU with compute capability 3.5+

## Health Checks

### Container Health

```bash
# Verify Python environment
docker run dxkb/stabilinnator-bvbrc:latest-gpu python -c "import torch; print(f'PyTorch {torch.__version__}')"

# Verify PyTorch Geometric
docker run dxkb/stabilinnator-bvbrc:latest-gpu python -c "import torch_geometric; print(f'PyG {torch_geometric.__version__}')"

# Verify CUDA (optional)
docker run --gpus all dxkb/stabilinnator-bvbrc:latest-gpu python -c "import torch; print(f'CUDA available: {torch.cuda.is_available()}')"
```

### Service Health

```bash
# Verify Perl runtime
docker run dxkb/stabilinnator-bvbrc:latest-gpu perl -e 'use Bio::KBase::AppService::AppScript; print "AppScript OK\n"'

# Verify service script
docker run dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator --help
```

## Logging

### Log Locations

- stdout: Main execution log
- stderr: Debug/error messages (when `P3_DEBUG=1`)

### Log Levels

Set via `P3_LOG_LEVEL`:
- `ERROR`: Errors only
- `WARNING`: Warnings and errors
- `INFO`: Normal operation (default)
- `DEBUG`: Verbose debugging

## Troubleshooting

### Common Issues

**Issue**: "No module named torch_geometric"
**Solution**: Use the correct image tag (`latest-gpu`)

**Issue**: "CUDA out of memory"
**Solution**: Not expected (models are small); check for other processes using GPU

**Issue**: "No residues with CA atoms found"
**Solution**: Input file issue; validate PDB format

**Issue**: Slow performance
**Solution**: Expected on CPU; GPU optional but faster

### Debug Mode

```bash
docker run -e P3_DEBUG=1 -e P3_LOG_LEVEL=DEBUG \
    dxkb/stabilinnator-bvbrc:latest-gpu \
    App-StabiliNNator params.json
```

## Maintenance

### Updating Models

1. Build new base image with updated models
2. Rebuild BV-BRC image
3. Push to registry
4. Pull on deployment servers

### Security Updates

Base image updates:
```bash
# Rebuild with latest base
docker pull nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
./build.sh --all --push
```

## Contact

For deployment issues:
- GitHub: https://github.com/CEPI-dxkb/stabiliNNatorApp/issues
- BV-BRC Help: help@bv-brc.org
