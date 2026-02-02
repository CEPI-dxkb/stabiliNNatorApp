# Input Formats for stabiliNNator

stabiliNNator accepts protein structure files in PDB or mmCIF format.

## Supported Formats

### PDB Format

Standard Protein Data Bank format with ATOM/HETATM records.

**File extensions**: `.pdb`, `.ent`

**Example**:
```
HEADER    PLANT PROTEIN                           12-JAN-81   1CRN
TITLE     WATER STRUCTURE OF A HYDROPHOBIC PROTEIN
ATOM      1  N   THR A   1       9.848  13.298   8.683  1.00 13.04           N
ATOM      2  CA  THR A   1      10.837  12.292   8.318  1.00 11.04           C
ATOM      3  C   THR A   1      11.849  12.877   7.335  1.00  8.38           C
ATOM      4  O   THR A   1      11.512  13.765   6.539  1.00  9.85           O
...
END
```

### mmCIF Format (PDBx)

Macromolecular Crystallographic Information File format.

**File extensions**: `.cif`, `.mmcif`

**Example**:
```
data_1CRN
#
_entry.id   1CRN
#
loop_
_atom_site.group_PDB
_atom_site.id
_atom_site.type_symbol
_atom_site.label_atom_id
_atom_site.label_alt_id
_atom_site.label_comp_id
_atom_site.label_asym_id
_atom_site.label_entity_id
_atom_site.label_seq_id
_atom_site.pdbx_PDB_ins_code
_atom_site.Cartn_x
_atom_site.Cartn_y
_atom_site.Cartn_z
_atom_site.occupancy
_atom_site.B_iso_or_equiv
_atom_site.pdbx_formal_charge
_atom_site.auth_seq_id
_atom_site.auth_comp_id
_atom_site.auth_asym_id
_atom_site.auth_atom_id
_atom_site.pdbx_PDB_model_num
ATOM   1    N  N   . THR A 1 1   ? 9.848   13.298  8.683   1.00 13.04  ? 1   THR A N   1
...
```

## Requirements

### For All Analyses

1. **Standard amino acids**: Structure must contain standard amino acids (20 canonical residues)
2. **CA atoms**: Each residue must have a CA (alpha carbon) atom
3. **Valid coordinates**: Atom coordinates must be numeric and reasonable

### For proliNNator (Proline Analysis)

- **Backbone atoms**: N, CA, C atoms for torsion angle calculation
- **Neighboring residues**: Better predictions when residues have sequential neighbors

### For disulfiNNate (Disulfide Analysis)

- **Cysteine residues**: Must have CYS or CYX residues for meaningful output
- **SG atoms**: Cysteine residues should have SG (sulfur gamma) atoms
- **CB atoms**: Recommended for accurate edge distance features

## Input Validation

The service script performs the following validation:

1. **Format detection**: Checks for PDB (ATOM records) or mmCIF (data_/loop_ headers)
2. **Structure parsing**: Validates that the file can be parsed by BioPython
3. **Residue check**: Ensures at least one residue with CA atom exists

## Preparing Input Files

### From AlphaFold/Boltz Output

AlphaFold and Boltz output files are directly compatible:

```bash
# AlphaFold output
stabiliNNator --pdb-path ranked_0.pdb --output-path ranked_0_proline.pdb

# Boltz output
stabiliNNator --pdb-path predictions/model_0.cif --output-path model_0_proline.pdb
```

### From Experimental Structures

PDB entries can be used directly:

```bash
# Download from RCSB
wget https://files.rcsb.org/download/1CRN.pdb

# Run analysis
stabiliNNator --pdb-path 1CRN.pdb --output-path 1CRN_proline.pdb
```

### Multi-Model Files

If the input contains multiple models (NMR ensembles), only the first model is used.

### Multi-Chain Structures

All chains in the structure are analyzed. Probabilities are computed independently per chain but edges can connect residues within spatial proximity across chains.

## Common Issues

### Missing CA Atoms

**Symptom**: "No residues with CA atoms found"

**Cause**: Input may contain only heteroatoms, ligands, or non-standard residues

**Solution**: Ensure structure contains standard amino acid residues

### Invalid Format

**Symptom**: "Input file does not appear to be in PDB or mmCIF format"

**Cause**: File is corrupted, compressed, or in an unsupported format

**Solution**:
- Decompress if needed (`.pdb.gz` → `.pdb`)
- Check file contents are valid PDB/mmCIF text

### Large Structures

**Symptom**: High memory usage or slow processing

**Cause**: Very large proteins (>1000 residues) require more resources

**Solution**:
- Increase memory allocation
- Consider splitting chains into separate files
- Use GPU acceleration

## Output Format

Output files are PDB format with probabilities in the B-factor column:

```
ATOM      1  N   THR A   1       9.848  13.298   8.683  1.00  0.23           N
                                                              ^^^^
                                                        Probability (0-1)
```

All atoms in a residue share the same probability value (per-residue prediction).
