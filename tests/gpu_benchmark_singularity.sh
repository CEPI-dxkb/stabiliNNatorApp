#!/bin/bash
#
# GPU Benchmarking Script for stabiliNNator using Singularity/Apptainer
# Issue #12: Phase 1 GPU Runtime Testing
#
# Usage: ./tests/gpu_benchmark_singularity.sh [--pull] [--cpu-only]
#
# Options:
#   --pull      Force re-pull of container image from Docker Hub
#   --cpu-only  Skip GPU tests (useful for CPU-only nodes)
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="${PROJECT_DIR}/container"
SIF_FILE="${IMAGE_DIR}/stabilinnator_latest-gpu.sif"
DOCKER_IMAGE="docker://dxkb/stabilinnator:latest-gpu"
TEST_DATA="${PROJECT_DIR}/test_data"
OUTPUT_DIR="${PROJECT_DIR}/benchmark_results"
LOG_FILE="${OUTPUT_DIR}/gpu_benchmark_$(date +%Y%m%d_%H%M%S).log"
RESULTS_CSV="${OUTPUT_DIR}/benchmark_results.csv"

# Parse arguments
FORCE_PULL=false
CPU_ONLY=false
for arg in "$@"; do
    case $arg in
        --pull) FORCE_PULL=true ;;
        --cpu-only) CPU_ONLY=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1" | tee -a "$LOG_FILE"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Initialize log
echo "========================================" | tee "$LOG_FILE"
echo "stabiliNNator GPU Benchmark - Singularity" | tee -a "$LOG_FILE"
echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Step 1: System Information
log "Capturing system information..."
{
    echo "=== System Information ==="
    echo "Hostname: $(hostname)"
    echo "Date: $(date)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo ""
    echo "=== Singularity/Apptainer Version ==="
    singularity --version 2>/dev/null || apptainer --version 2>/dev/null
    echo ""
    echo "=== GPU Information ==="
    nvidia-smi --query-gpu=index,name,memory.total,driver_version,compute_cap --format=csv 2>/dev/null || echo "No GPU available"
    echo ""
    echo "=== CPU Information ==="
    lscpu | grep -E "^(Model name|CPU\(s\)|Thread|Core|Socket)" || cat /proc/cpuinfo | grep "model name" | head -1
    echo ""
    echo "=== Memory ==="
    free -h
    echo ""
} | tee -a "$LOG_FILE"

# Step 2: Pull or verify container image
log "Checking container image..."
if [[ "$FORCE_PULL" == "true" ]] || [[ ! -f "$SIF_FILE" ]]; then
    log "Pulling container image from Docker Hub..."
    log "This may take several minutes on first run..."
    mkdir -p "$IMAGE_DIR"
    singularity pull --force "$SIF_FILE" "$DOCKER_IMAGE" 2>&1 | tee -a "$LOG_FILE"
    success "Container image pulled: $SIF_FILE"
else
    success "Using cached container image: $SIF_FILE"
fi

# Verify SIF file
if [[ ! -f "$SIF_FILE" ]]; then
    error "Container image not found: $SIF_FILE"
    exit 1
fi
log "Container size: $(du -h "$SIF_FILE" | cut -f1)"

# Step 3: Verify test data
log "Verifying test data..."
TEST_PROTEINS=("1crn_small.pdb" "3ft7.pdb" "3pgk_large.pdb")
for pdb in "${TEST_PROTEINS[@]}"; do
    if [[ ! -f "${TEST_DATA}/${pdb}" ]]; then
        error "Test protein not found: ${TEST_DATA}/${pdb}"
        exit 1
    fi
    residues=$(grep "^ATOM" "${TEST_DATA}/${pdb}" | cut -c22-26 | sort -u | wc -l)
    atoms=$(grep -c "^ATOM" "${TEST_DATA}/${pdb}")
    success "$pdb: $residues residues, $atoms atoms"
done

# Step 4: GPU availability check
GPU_AVAILABLE=false
if [[ "$CPU_ONLY" != "true" ]]; then
    if nvidia-smi &>/dev/null; then
        GPU_AVAILABLE=true
        success "GPU detected and available"
    else
        warn "No GPU detected, running CPU tests only"
    fi
else
    warn "CPU-only mode requested, skipping GPU tests"
fi

# Initialize CSV results
echo "protein,residues,atoms,tool,device,run,wall_time_sec,user_time_sec,sys_time_sec,max_memory_kb,exit_code" > "$RESULTS_CSV"

# Function to run a single benchmark
run_benchmark() {
    local pdb_file=$1
    local tool=$2
    local device=$3
    local run_num=$4

    local pdb_name=$(basename "$pdb_file" .pdb)
    local output_file="${OUTPUT_DIR}/${pdb_name}_${tool}_${device}_run${run_num}.pdb"
    local time_file="${OUTPUT_DIR}/.time_${pdb_name}_${tool}_${device}_run${run_num}.txt"

    # Get protein stats
    local residues=$(grep "^ATOM" "$pdb_file" | cut -c22-26 | sort -u | wc -l)
    local atoms=$(grep -c "^ATOM" "$pdb_file")

    # Build singularity command
    local sing_cmd="singularity exec"
    if [[ "$device" == "cuda" ]]; then
        sing_cmd="$sing_cmd --nv"
    fi
    sing_cmd="$sing_cmd -B ${TEST_DATA}:/data -B ${OUTPUT_DIR}:/output $SIF_FILE"

    # Build tool command
    local tool_cmd=""
    if [[ "$tool" == "prolinnator" ]]; then
        tool_cmd="prolinnator --pdb-path /data/$(basename "$pdb_file") --output-path /output/$(basename "$output_file") --device $device"
    else
        tool_cmd="disulfinnate --pdb-path /data/$(basename "$pdb_file") --output-path /output/$(basename "$output_file") --device $device"
    fi

    log "  Run $run_num: $pdb_name | $tool | $device"

    # Run with time measurement
    /usr/bin/time -v -o "$time_file" $sing_cmd $tool_cmd 2>&1 | tee -a "$LOG_FILE"
    local exit_code=$?

    # Parse time output
    local wall_time=$(grep "Elapsed (wall clock)" "$time_file" | sed 's/.*: //' | awk -F: '{if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1}')
    local user_time=$(grep "User time" "$time_file" | awk '{print $NF}')
    local sys_time=$(grep "System time" "$time_file" | awk '{print $NF}')
    local max_mem=$(grep "Maximum resident" "$time_file" | awk '{print $NF}')

    # Record to CSV
    echo "$pdb_name,$residues,$atoms,$tool,$device,$run_num,$wall_time,$user_time,$sys_time,$max_mem,$exit_code" >> "$RESULTS_CSV"

    # Validate output
    if [[ -f "$output_file" ]]; then
        local out_atoms=$(grep -c "^ATOM" "$output_file" 2>/dev/null || echo "0")
        local b_min=$(grep "^ATOM" "$output_file" | awk '{print substr($0, 61, 6)}' | tr -d ' ' | sort -n | head -1)
        local b_max=$(grep "^ATOM" "$output_file" | awk '{print substr($0, 61, 6)}' | tr -d ' ' | sort -n | tail -1)
        log "    Output: $out_atoms atoms, B-factor: $b_min - $b_max, Time: ${wall_time}s, Memory: $((max_mem / 1024))MB"
    else
        warn "    Output file not created!"
    fi

    rm -f "$time_file"
    return $exit_code
}

# Step 5: Run benchmarks
NUM_RUNS=3

echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Running Benchmarks ($NUM_RUNS runs each)" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"

# GPU Tests
if [[ "$GPU_AVAILABLE" == "true" ]]; then
    echo "" | tee -a "$LOG_FILE"
    log "=== proliNNator GPU Tests ==="
    for pdb in "${TEST_PROTEINS[@]}"; do
        for run in $(seq 1 $NUM_RUNS); do
            run_benchmark "${TEST_DATA}/${pdb}" "prolinnator" "cuda" "$run"
        done
    done

    echo "" | tee -a "$LOG_FILE"
    log "=== disulfiNNate GPU Tests ==="
    for pdb in "${TEST_PROTEINS[@]}"; do
        for run in $(seq 1 $NUM_RUNS); do
            run_benchmark "${TEST_DATA}/${pdb}" "disulfinnate" "cuda" "$run"
        done
    done
fi

# CPU Tests
echo "" | tee -a "$LOG_FILE"
log "=== proliNNator CPU Tests ==="
for pdb in "${TEST_PROTEINS[@]}"; do
    for run in $(seq 1 $NUM_RUNS); do
        run_benchmark "${TEST_DATA}/${pdb}" "prolinnator" "cpu" "$run"
    done
done

echo "" | tee -a "$LOG_FILE"
log "=== disulfiNNate CPU Tests ==="
for pdb in "${TEST_PROTEINS[@]}"; do
    for run in $(seq 1 $NUM_RUNS); do
        run_benchmark "${TEST_DATA}/${pdb}" "disulfinnate" "cpu" "$run"
    done
done

# Step 6: Generate summary
echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Benchmark Summary" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"

# Generate markdown table
{
    echo ""
    echo "### Results Table (for RUNTIME_METRICS.md)"
    echo ""
    echo "| Protein | Residues | proliNNator GPU | proliNNator CPU | disulfiNNate GPU | disulfiNNate CPU | Peak Memory |"
    echo "|---------|----------|-----------------|-----------------|------------------|------------------|-------------|"

    for pdb in "${TEST_PROTEINS[@]}"; do
        pdb_name=$(basename "$pdb" .pdb)
        residues=$(grep "^ATOM" "${TEST_DATA}/${pdb}" | cut -c22-26 | sort -u | wc -l)

        # Calculate averages from CSV
        pro_gpu=$(grep "^${pdb_name}," "$RESULTS_CSV" | grep ",prolinnator,cuda," | awk -F, '{sum+=$7; count++} END {if(count>0) printf "%.1fs", sum/count; else print "N/A"}')
        pro_cpu=$(grep "^${pdb_name}," "$RESULTS_CSV" | grep ",prolinnator,cpu," | awk -F, '{sum+=$7; count++} END {if(count>0) printf "%.1fs", sum/count; else print "N/A"}')
        dis_gpu=$(grep "^${pdb_name}," "$RESULTS_CSV" | grep ",disulfinnate,cuda," | awk -F, '{sum+=$7; count++} END {if(count>0) printf "%.1fs", sum/count; else print "N/A"}')
        dis_cpu=$(grep "^${pdb_name}," "$RESULTS_CSV" | grep ",disulfinnate,cpu," | awk -F, '{sum+=$7; count++} END {if(count>0) printf "%.1fs", sum/count; else print "N/A"}')
        max_mem=$(grep "^${pdb_name}," "$RESULTS_CSV" | awk -F, '{if($10>max) max=$10} END {printf "%d MB", max/1024}')

        echo "| ${pdb_name} | ${residues} | ${pro_gpu} | ${pro_cpu} | ${dis_gpu} | ${dis_cpu} | ${max_mem} |"
    done
    echo ""
} | tee -a "$LOG_FILE"

# Cleanup - remove output PDB files but keep logs
log "Cleaning up output PDB files..."
rm -f "${OUTPUT_DIR}"/*.pdb

echo "" | tee -a "$LOG_FILE"
success "Benchmark complete!"
echo "" | tee -a "$LOG_FILE"
echo "Results saved to:" | tee -a "$LOG_FILE"
echo "  Log file: $LOG_FILE" | tee -a "$LOG_FILE"
echo "  CSV data: $RESULTS_CSV" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
