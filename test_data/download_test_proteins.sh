#!/bin/bash
# Download test proteins from RCSB Protein Data Bank
# These are the standard test proteins used for stabiliNNator benchmarking

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Downloading test proteins from RCSB PDB..."

# Small protein - Crambin (46 residues)
# A small plant protein, good for quick validation tests
echo "Downloading 1CRN (Crambin - 46 residues)..."
curl -sS -O https://files.rcsb.org/download/1CRN.pdb
mv 1CRN.pdb 1crn_small.pdb
echo "  -> 1crn_small.pdb"

# Medium protein (90 residues)
# Good for typical use case testing
echo "Downloading 3FT7 (90 residues)..."
curl -sS -O https://files.rcsb.org/download/3FT7.pdb
mv 3FT7.pdb 3ft7.pdb
echo "  -> 3ft7.pdb"

# Large protein - Phosphoglycerate kinase (415 residues)
# Tests performance scaling with larger proteins
echo "Downloading 3PGK (Phosphoglycerate kinase - 415 residues)..."
curl -sS -O https://files.rcsb.org/download/3PGK.pdb
mv 3PGK.pdb 3pgk_large.pdb
echo "  -> 3pgk_large.pdb"

echo ""
echo "Download complete. Test proteins:"
ls -la *.pdb | grep -v "_proline\|_disulfide"

echo ""
echo "To run tests:"
echo "  docker run --rm -v \$(pwd):/data dxkb/stabilinnator:latest-gpu prolinnator \\"
echo "      --pdb-path /data/1crn_small.pdb --output-path /data/1crn_proline.pdb --device cpu"
