#!/bin/bash
# Benchmark script for batch processing and large proteins
# Run this on a native x86_64 machine with Docker or Singularity
#
# Usage: ./benchmark_batch_large.sh [docker|singularity]

set -e

RUNTIME="${1:-docker}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DATA="$SCRIPT_DIR/../test_data"
RESULTS_FILE="$SCRIPT_DIR/benchmark_results_$(date +%Y%m%d_%H%M%S).log"

echo "=== stabiliNNator Batch & Large Protein Benchmark ===" | tee "$RESULTS_FILE"
echo "Date: $(date)" | tee -a "$RESULTS_FILE"
echo "Runtime: $RUNTIME" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Create output directory
mkdir -p "$TEST_DATA/benchmark_output"

#######################################
# SECTION 1: Download Large Test Proteins
#######################################

echo "=== Downloading Large Test Proteins ===" | tee -a "$RESULTS_FILE"

# Large proteins from RCSB PDB
declare -A LARGE_PROTEINS=(
    # [filename]="PDB_ID|expected_residues|description"
    ["4ake_medium.pdb"]="4AKE|214|Adenylate kinase"
    ["1aon_large.pdb"]="1AON|524|GroEL chaperonin (chain A)"
    ["3j3q_xlarge.pdb"]="3J3Q|1542|Dynein motor domain"
    ["6lu7_covid.pdb"]="6LU7|306|SARS-CoV-2 main protease"
)

cd "$TEST_DATA"

for filename in "${!LARGE_PROTEINS[@]}"; do
    IFS='|' read -r pdb_id expected_res description <<< "${LARGE_PROTEINS[$filename]}"

    if [ ! -f "$filename" ]; then
        echo "Downloading $pdb_id ($description)..." | tee -a "$RESULTS_FILE"
        curl -sS -o "$filename" "https://files.rcsb.org/download/${pdb_id}.pdb"

        # Count residues
        residues=$(grep "^ATOM" "$filename" | cut -c22-26 | sort -u | wc -l | tr -d ' ')
        atoms=$(grep -c "^ATOM" "$filename" || echo "0")
        echo "  -> $filename: $residues residues, $atoms atoms" | tee -a "$RESULTS_FILE"
    else
        residues=$(grep "^ATOM" "$filename" | cut -c22-26 | sort -u | wc -l | tr -d ' ')
        atoms=$(grep -c "^ATOM" "$filename" || echo "0")
        echo "Already exists: $filename ($residues residues, $atoms atoms)" | tee -a "$RESULTS_FILE"
    fi
done

cd "$SCRIPT_DIR/.."
echo "" | tee -a "$RESULTS_FILE"

#######################################
# SECTION 2: Helper Functions
#######################################

run_prolinnator() {
    local input="$1"
    local output="$2"
    local device="${3:-cpu}"

    if [ "$RUNTIME" = "singularity" ]; then
        singularity exec --nv docker://dxkb/stabilinnator:latest-gpu \
            prolinnator --pdb-path "$input" --output-path "$output" --device "$device"
    else
        docker run --rm --gpus all -v "$(pwd)":/data dxkb/stabilinnator:latest-gpu \
            prolinnator --pdb-path "/data/$input" --output-path "/data/$output" --device "$device"
    fi
}

run_disulfinnate() {
    local input="$1"
    local output="$2"
    local device="${3:-cpu}"

    if [ "$RUNTIME" = "singularity" ]; then
        singularity exec --nv docker://dxkb/stabilinnator:latest-gpu \
            disulfinnate --pdb-path "$input" --output-path "$output" --device "$device"
    else
        docker run --rm --gpus all -v "$(pwd)":/data dxkb/stabilinnator:latest-gpu \
            disulfinnate --pdb-path "/data/$input" --output-path "/data/$output" --device "$device"
    fi
}

#######################################
# SECTION 3: Large Protein Benchmarks
#######################################

echo "=== Large Protein Benchmarks (CPU mode) ===" | tee -a "$RESULTS_FILE"

# List of all test proteins (small to very large)
TEST_PROTEINS=(
    "test_data/1crn_small.pdb"      # 46 residues
    "test_data/3ft7.pdb"            # 90 residues
    "test_data/3pgk_large.pdb"      # 415 residues
    "test_data/4ake_medium.pdb"     # 214 residues
    "test_data/1aon_large.pdb"      # 524 residues
    "test_data/6lu7_covid.pdb"      # 306 residues
    "test_data/3j3q_xlarge.pdb"     # 1542 residues
)

echo "" | tee -a "$RESULTS_FILE"
echo "| Protein | Residues | Atoms | proliNNator | disulfiNNate | Memory |" | tee -a "$RESULTS_FILE"
echo "|---------|----------|-------|-------------|--------------|--------|" | tee -a "$RESULTS_FILE"

for pdb in "${TEST_PROTEINS[@]}"; do
    if [ ! -f "$pdb" ]; then
        echo "Skipping $pdb (not found)" | tee -a "$RESULTS_FILE"
        continue
    fi

    name=$(basename "$pdb" .pdb)
    residues=$(grep "^ATOM" "$pdb" | cut -c22-26 | sort -u | wc -l | tr -d ' ')
    atoms=$(grep -c "^ATOM" "$pdb" || echo "0")

    # proliNNator benchmark
    output_pro="test_data/benchmark_output/${name}_proline.pdb"
    start_pro=$(date +%s.%N)
    if [ "$RUNTIME" = "singularity" ]; then
        mem_pro=$( { /usr/bin/time -v singularity exec docker://dxkb/stabilinnator:latest-gpu \
            prolinnator --pdb-path "$pdb" --output-path "$output_pro" --device cpu; } 2>&1 | grep "Maximum resident" | awk '{print $6}')
    else
        mem_pro=$( { /usr/bin/time -v docker run --rm -v "$(pwd)":/data dxkb/stabilinnator:latest-gpu \
            prolinnator --pdb-path "/data/$pdb" --output-path "/data/$output_pro" --device cpu; } 2>&1 | grep "Maximum resident" | awk '{print $6}')
    fi
    end_pro=$(date +%s.%N)
    time_pro=$(echo "$end_pro - $start_pro" | bc)

    # disulfiNNate benchmark
    output_dis="test_data/benchmark_output/${name}_disulfide.pdb"
    start_dis=$(date +%s.%N)
    if [ "$RUNTIME" = "singularity" ]; then
        mem_dis=$( { /usr/bin/time -v singularity exec docker://dxkb/stabilinnator:latest-gpu \
            disulfinnate --pdb-path "$pdb" --output-path "$output_dis" --device cpu; } 2>&1 | grep "Maximum resident" | awk '{print $6}')
    else
        mem_dis=$( { /usr/bin/time -v docker run --rm -v "$(pwd)":/data dxkb/stabilinnator:latest-gpu \
            disulfinnate --pdb-path "/data/$pdb" --output-path "/data/$output_dis" --device cpu; } 2>&1 | grep "Maximum resident" | awk '{print $6}')
    fi
    end_dis=$(date +%s.%N)
    time_dis=$(echo "$end_dis - $start_dis" | bc)

    # Convert memory to MB
    mem_mb=$(echo "scale=0; ${mem_pro:-0} / 1024" | bc)

    printf "| %s | %s | %s | %.1fs | %.1fs | %sMB |\n" \
        "$name" "$residues" "$atoms" "$time_pro" "$time_dis" "$mem_mb" | tee -a "$RESULTS_FILE"
done

echo "" | tee -a "$RESULTS_FILE"

#######################################
# SECTION 4: Batch Processing Benchmark
#######################################

echo "=== Batch Processing Benchmark ===" | tee -a "$RESULTS_FILE"
echo "Testing sequential processing of multiple files..." | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Batch of 10 proteins (using existing test files multiple times)
BATCH_FILES=(
    "test_data/1crn_small.pdb"
    "test_data/3ft7.pdb"
    "test_data/3pgk_large.pdb"
    "test_data/1crn_small.pdb"
    "test_data/3ft7.pdb"
    "test_data/3pgk_large.pdb"
    "test_data/1crn_small.pdb"
    "test_data/3ft7.pdb"
    "test_data/3pgk_large.pdb"
    "test_data/1crn_small.pdb"
)

echo "Batch size: ${#BATCH_FILES[@]} proteins" | tee -a "$RESULTS_FILE"

# Cold start (first run includes container pull/cache)
echo "" | tee -a "$RESULTS_FILE"
echo "### Batch proliNNator (sequential, CPU mode)" | tee -a "$RESULTS_FILE"
batch_start=$(date +%s.%N)

for i in "${!BATCH_FILES[@]}"; do
    pdb="${BATCH_FILES[$i]}"
    name=$(basename "$pdb" .pdb)
    output="test_data/benchmark_output/batch_${i}_${name}_proline.pdb"

    if [ "$RUNTIME" = "singularity" ]; then
        singularity exec docker://dxkb/stabilinnator:latest-gpu \
            prolinnator --pdb-path "$pdb" --output-path "$output" --device cpu > /dev/null 2>&1
    else
        docker run --rm -v "$(pwd)":/data dxkb/stabilinnator:latest-gpu \
            prolinnator --pdb-path "/data/$pdb" --output-path "/data/$output" --device cpu > /dev/null 2>&1
    fi
    echo -n "."
done
echo ""

batch_end=$(date +%s.%N)
batch_total=$(echo "$batch_end - $batch_start" | bc)
batch_avg=$(echo "scale=2; $batch_total / ${#BATCH_FILES[@]}" | bc)

echo "Total time: ${batch_total}s" | tee -a "$RESULTS_FILE"
echo "Average per protein: ${batch_avg}s" | tee -a "$RESULTS_FILE"
echo "Throughput: $(echo "scale=2; ${#BATCH_FILES[@]} / $batch_total * 60" | bc) proteins/minute" | tee -a "$RESULTS_FILE"

echo "" | tee -a "$RESULTS_FILE"
echo "### Batch disulfiNNate (sequential, CPU mode)" | tee -a "$RESULTS_FILE"
batch_start=$(date +%s.%N)

for i in "${!BATCH_FILES[@]}"; do
    pdb="${BATCH_FILES[$i]}"
    name=$(basename "$pdb" .pdb)
    output="test_data/benchmark_output/batch_${i}_${name}_disulfide.pdb"

    if [ "$RUNTIME" = "singularity" ]; then
        singularity exec docker://dxkb/stabilinnator:latest-gpu \
            disulfinnate --pdb-path "$pdb" --output-path "$output" --device cpu > /dev/null 2>&1
    else
        docker run --rm -v "$(pwd)":/data dxkb/stabilinnator:latest-gpu \
            disulfinnate --pdb-path "/data/$pdb" --output-path "/data/$output" --device cpu > /dev/null 2>&1
    fi
    echo -n "."
done
echo ""

batch_end=$(date +%s.%N)
batch_total=$(echo "$batch_end - $batch_start" | bc)
batch_avg=$(echo "scale=2; $batch_total / ${#BATCH_FILES[@]}" | bc)

echo "Total time: ${batch_total}s" | tee -a "$RESULTS_FILE"
echo "Average per protein: ${batch_avg}s" | tee -a "$RESULTS_FILE"
echo "Throughput: $(echo "scale=2; ${#BATCH_FILES[@]} / $batch_total * 60" | bc) proteins/minute" | tee -a "$RESULTS_FILE"

#######################################
# SECTION 5: Output Validation
#######################################

echo "" | tee -a "$RESULTS_FILE"
echo "=== Output Validation ===" | tee -a "$RESULTS_FILE"

for f in test_data/benchmark_output/*.pdb; do
    if [ -f "$f" ]; then
        atoms=$(grep -c "^ATOM" "$f" 2>/dev/null || echo "0")
        if [ "$atoms" -gt 0 ]; then
            min=$(grep "^ATOM" "$f" | awk '{print substr($0, 61, 6)}' | tr -d ' ' | sort -n | head -1)
            max=$(grep "^ATOM" "$f" | awk '{print substr($0, 61, 6)}' | tr -d ' ' | sort -n | tail -1)
            name=$(basename "$f")

            # Check if B-factors are in valid range
            if (( $(echo "$min >= 0" | bc -l) )) && (( $(echo "$max <= 1" | bc -l) )); then
                echo "OK: $name (B-factor: $min - $max)" | tee -a "$RESULTS_FILE"
            else
                echo "WARN: $name (B-factor: $min - $max) - outside 0-1 range!" | tee -a "$RESULTS_FILE"
            fi
        fi
    fi
done

#######################################
# SECTION 6: System Info
#######################################

echo "" | tee -a "$RESULTS_FILE"
echo "=== System Information ===" | tee -a "$RESULTS_FILE"
echo "Hostname: $(hostname)" | tee -a "$RESULTS_FILE"
uname -a | tee -a "$RESULTS_FILE"
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv 2>/dev/null | tee -a "$RESULTS_FILE"
fi

echo "" | tee -a "$RESULTS_FILE"
echo "=== Benchmark Complete ===" | tee -a "$RESULTS_FILE"
echo "Results saved to: $RESULTS_FILE" | tee -a "$RESULTS_FILE"
