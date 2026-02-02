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
            "gpu_count": 0,
            "partition": "normal"
        }
    }
}
```

### Scaling Notes

- **Memory**: 8GB sufficient for most proteins; large proteins (>1000 residues) may need 16GB
- **CPU**: 4 cores is optimal; more cores don't significantly improve performance
- **GPU**: Optional; provides ~3x speedup but CPU is acceptable
- **Storage**: 5GB is generous; actual disk usage is minimal (<100MB)

### Comparison to Other Apps

| App | CPU | Memory | GPU Required | Typical Runtime |
|-----|-----|--------|--------------|-----------------|
| stabiliNNator | 4 | 8GB | No | 1-10 min |
| Chai-Lab | 8 | 64GB | Yes (A100) | 30-120 min |
| Boltz | 8 | 64GB | Yes (A100) | 30-90 min |
| AlphaFold | 8 | 64GB | Yes (A100) | 60-240 min |

stabiliNNator is significantly lighter and can run on the `normal` partition.

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

### GPU Optional

Unlike Chai/Boltz/AlphaFold, stabiliNNator does **not require** GPU:

```bash
# CPU mode (default)
docker run dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator params.json

# GPU mode (optional, ~3x faster)
docker run --gpus all dxkb/stabilinnator-bvbrc:latest-gpu App-StabiliNNator params.json
```

### CUDA Requirements

If GPU is used:
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
