#!/bin/bash
# Validate stabiliNNator output files
# Checks that B-factor values are in expected range and structure is valid

set -e

usage() {
    echo "Usage: $0 <output_dir> [analysis_type]"
    echo ""
    echo "Arguments:"
    echo "  output_dir     Directory containing stabiliNNator output files"
    echo "  analysis_type  Optional: 'proline', 'disulfide', or 'both' (default: both)"
    echo ""
    echo "Validates:"
    echo "  - Output PDB files exist"
    echo "  - B-factor values are in 0-1 range"
    echo "  - Structure contains expected atom records"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

OUTPUT_DIR="$1"
ANALYSIS_TYPE="${2:-both}"

if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory not found: $OUTPUT_DIR"
    exit 1
fi

ERRORS=0

# Check for expected output files
check_file_exists() {
    local pattern="$1"
    local desc="$2"

    local files=$(find "$OUTPUT_DIR" -name "$pattern" -type f 2>/dev/null)
    if [ -z "$files" ]; then
        echo "FAIL: No $desc files found matching pattern: $pattern"
        ERRORS=$((ERRORS + 1))
        return 1
    else
        echo "OK: Found $desc file(s):"
        echo "$files" | while read f; do echo "    $f"; done
        return 0
    fi
}

# Validate B-factors are in 0-1 range
validate_bfactors() {
    local pdb_file="$1"

    if [ ! -f "$pdb_file" ]; then
        echo "FAIL: File not found: $pdb_file"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    # Extract B-factor values from ATOM/HETATM records (columns 61-66)
    local bfactors=$(grep -E "^(ATOM|HETATM)" "$pdb_file" | awk '{print substr($0, 61, 6)}' | tr -d ' ')

    if [ -z "$bfactors" ]; then
        echo "FAIL: No ATOM/HETATM records found in $pdb_file"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    local count=0
    local out_of_range=0
    local min_val=999
    local max_val=-999

    for bf in $bfactors; do
        count=$((count + 1))

        # Check if numeric
        if ! [[ "$bf" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            continue
        fi

        # Check range using bc for floating point comparison
        local is_below=$(echo "$bf < 0" | bc -l 2>/dev/null || echo "0")
        local is_above=$(echo "$bf > 1" | bc -l 2>/dev/null || echo "0")

        if [ "$is_below" = "1" ] || [ "$is_above" = "1" ]; then
            out_of_range=$((out_of_range + 1))
        fi

        # Track min/max
        local is_new_min=$(echo "$bf < $min_val" | bc -l 2>/dev/null || echo "0")
        local is_new_max=$(echo "$bf > $max_val" | bc -l 2>/dev/null || echo "0")

        [ "$is_new_min" = "1" ] && min_val="$bf"
        [ "$is_new_max" = "1" ] && max_val="$bf"
    done

    if [ $out_of_range -gt 0 ]; then
        echo "WARN: $out_of_range B-factor values out of 0-1 range in $pdb_file"
        echo "      Range: $min_val - $max_val"
    else
        echo "OK: All B-factor values in 0-1 range in $pdb_file"
        echo "    Range: $min_val - $max_val, Count: $count"
    fi

    return 0
}

# Validate PDB structure has required records
validate_structure() {
    local pdb_file="$1"

    if [ ! -f "$pdb_file" ]; then
        return 1
    fi

    # Check for ATOM records
    local atom_count=$(grep -c "^ATOM" "$pdb_file" 2>/dev/null || echo "0")
    if [ "$atom_count" -eq 0 ]; then
        echo "FAIL: No ATOM records in $pdb_file"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    echo "OK: Structure contains $atom_count ATOM records"

    # Check for CA atoms (required for graph construction)
    local ca_count=$(grep "^ATOM" "$pdb_file" | grep -c " CA " 2>/dev/null || echo "0")
    if [ "$ca_count" -eq 0 ]; then
        echo "WARN: No CA atoms found in $pdb_file"
    else
        echo "OK: Found $ca_count CA atoms (residues)"
    fi

    return 0
}

echo "=============================================="
echo "stabiliNNator Output Validation"
echo "=============================================="
echo "Output directory: $OUTPUT_DIR"
echo "Analysis type: $ANALYSIS_TYPE"
echo ""

# Validate based on analysis type
if [ "$ANALYSIS_TYPE" = "proline" ] || [ "$ANALYSIS_TYPE" = "both" ]; then
    echo "--- Validating proliNNator output ---"
    if check_file_exists "*_proline.pdb" "proline prediction"; then
        for f in $(find "$OUTPUT_DIR" -name "*_proline.pdb" -type f 2>/dev/null); do
            validate_structure "$f"
            validate_bfactors "$f"
        done
    fi
    echo ""
fi

if [ "$ANALYSIS_TYPE" = "disulfide" ] || [ "$ANALYSIS_TYPE" = "both" ]; then
    echo "--- Validating disulfiNNate output ---"
    if check_file_exists "*_disulfide.pdb" "disulfide prediction"; then
        for f in $(find "$OUTPUT_DIR" -name "*_disulfide.pdb" -type f 2>/dev/null); do
            validate_structure "$f"
            validate_bfactors "$f"
        done
    fi
    echo ""
fi

echo "=============================================="
if [ $ERRORS -gt 0 ]; then
    echo "Validation FAILED with $ERRORS error(s)"
    exit 1
else
    echo "Validation PASSED"
    exit 0
fi
