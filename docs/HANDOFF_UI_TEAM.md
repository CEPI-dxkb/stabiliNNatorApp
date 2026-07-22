# Handoff Document: UI Team

This document provides information needed for the UI team to integrate stabiliNNator into the BV-BRC web interface.

## App Overview

**App ID**: `StabiliNNator`
**App Label**: "Protein Stability Prediction (stabiliNNator)"

stabiliNNator predicts protein stability improvements using Graph Neural Networks:
- **proliNNator**: Identifies favorable sites for proline mutations
- **disulfiNNate**: Identifies favorable sites for disulfide bond formation

## Parameter Specification

See `app_specs/StabiliNNator.json` for the complete specification.

### Required Parameters

| Parameter | Type | Label | Notes |
|-----------|------|-------|-------|
| `input_file` | wsfile | Input Structure File | PDB or mmCIF format |
| `output_path` | folder | Output Folder | Where results are saved |

### Optional Parameters

| Parameter | Type | Default | Label | Notes |
|-----------|------|---------|-------|-------|
| `analysis_type` | enum | both | Analysis Type | proline/disulfide/both |
| `hidden_dim` | int | 32 | Hidden Dimension | Advanced users only |
| `accelerator` | enum | auto | Compute Device | auto/gpu/cpu |
| `dry_run` | bool | false | Dry Run | For testing |

### Enum Values

**analysis_type**:
- `proline` - Proline mutation analysis only
- `disulfide` - Disulfide bond analysis only
- `both` - Run both analyses (default)

**accelerator**:
- `auto` - Automatically detect GPU, fall back to CPU (default)
- `gpu` - Force GPU usage (fails if unavailable)
- `cpu` - Force CPU usage

## Input Requirements

### Accepted File Types
- PDB files (`.pdb`, `.ent`)
- mmCIF files (`.cif`, `.mmcif`)

### File Type Hints
```json
{
    "input_file": {
        "type": "wsfile",
        "fileTypes": ["pdb", "cif", "mmcif", "ent"],
        "description": "Protein structure file"
    }
}
```

### Validation Notes
- Files should contain standard amino acid residues
- Structure must have CA atoms (all standard protein structures do)
- Both experimental and predicted structures work

## Output Files

### File Naming Convention
Output files follow this pattern:
- `{input_basename}_proline.pdb` - Proline analysis results (annotated structure)
- `{input_basename}_disulfide.pdb` - Disulfide analysis results (annotated structure)
- `{input_basename}_proline_summary.tsv` - Ranked proline substitution sites
- `{input_basename}_disulfide_summary.tsv` - Ranked cysteine (disulfide) sites
- `{input_basename}_summary.json` - Combined structured summary (for the UI)
- `{input_basename}_report.html` - **Self-contained HTML report** (workspace type `html`)

### HTML report (rendered in the portal)
Every run also produces a single self-contained `*_report.html` uploaded with
workspace type `html`, so the BV-BRC portal can render it directly. It describes
the input structure, the models run (with commands), a ranked summary, per-residue
visualizations (sequence stability track, ranked bars, geometrically-detected
disulfide bonds), and a downloads section linking to the sibling data files. The
UI can surface this as the primary "view results" target. It is generated from a
template (`report/report_template.html`) — restyle there without touching the
service logic.

### Annotated PDBs (B-factor encoding)
The `*_proline.pdb` / `*_disulfide.pdb` files carry the per-residue probability
in the B-factor column (workspace type `pdb`, value range 0.0-1.0). Best viewed
in a molecular viewer colored by B-factor.

### Ranked summaries (recommended for the UI)
The app also generates **human- and UI-friendly ranked summaries** so the UI can
show "top sites" without parsing PDB B-factors.

**`*_summary.tsv`** (tab-separated, one per analysis, sorted by probability
descending; full residue list):

- proline columns: `rank, chain, pos, residue, probability, note`
  (`note` = `already PRO` for residues that are already proline — not
  substitution candidates)
- disulfide columns: `rank, chain, pos, residue, probability`
  (**cysteine residues only** — CYS/CYX)

**`{input_basename}_summary.json`** — the structured form to drive the results
table. Only the analyses that ran are present. Site lists are capped at the top
25 for compactness (the TSV keeps the full ranking):

```json
{
  "input": "myprotein.pdb",
  "analysis_type": "both",
  "proline":   { "top_sites": [
    { "rank": 1, "chain": "A", "pos": 21, "icode": "", "residue": "THR", "probability": 0.97 }
  ] },
  "disulfide": { "cys_sites": [
    { "rank": 1, "chain": "A", "pos": 3, "icode": "", "residue": "CYS", "probability": 1.0 }
  ] }
}
```

Proline `top_sites` entries that are already proline additionally carry
`"note": "already PRO"`.

## UI Recommendations

### Form Layout

```
┌─────────────────────────────────────────────────────────────┐
│ Protein Stability Prediction (stabiliNNator)                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ Input Structure File*                    [Browse...]        │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ Select PDB or mmCIF file                             │    │
│ └─────────────────────────────────────────────────────┘    │
│                                                             │
│ Analysis Type*                                              │
│ ○ Proline mutations                                         │
│ ○ Disulfide bonds                                           │
│ ● Both analyses (recommended)                               │
│                                                             │
│ Output Folder*                           [Browse...]        │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ /username/home/stabiliNNator_results                 │    │
│ └─────────────────────────────────────────────────────┘    │
│                                                             │
│ ▼ Advanced Options                                          │
│   ┌─────────────────────────────────────────────────────┐  │
│   │ Compute Device: [Auto ▼]                            │  │
│   │ Hidden Dimension: [32]  (leave default unless       │  │
│   │                          using custom model)         │  │
│   └─────────────────────────────────────────────────────┘  │
│                                                             │
│                              [Submit Job]                   │
└─────────────────────────────────────────────────────────────┘
```

### Suggested Help Text

**Input Structure File**:
> Upload a protein structure file in PDB or mmCIF format. This can be an experimental structure from PDB or a predicted structure from AlphaFold/Boltz/Chai.

**Analysis Type**:
> - **Proline mutations**: Identifies residues favorable for substitution with proline, which can increase rigidity
> - **Disulfide bonds**: Identifies cysteine pairs favorable for disulfide bond formation, which can increase stability
> - **Both analyses**: Runs both analyses (recommended for comprehensive stability engineering)

**Compute Device**:
> Leave as "Auto" for best performance. GPU provides faster analysis but is not required.

### Results Display

After job completion, the UI should:

1. **List output files** with download links
2. **Show file previews** if structure viewer is available
3. **Indicate probability interpretation**:
   - Higher values (closer to 1.0) = more favorable for mutation/bond
   - Lower values (closer to 0.0) = less favorable

### Suggested Results Page

```
┌─────────────────────────────────────────────────────────────┐
│ Job Results: stabiliNNator                                  │
├─────────────────────────────────────────────────────────────┤
│ Status: Completed                                           │
│ Runtime: 2 minutes 34 seconds                               │
│                                                             │
│ Output Files:                                               │
│ ┌─────────────────────────────────────────────────────────┐│
│ │ 📄 myprotein_proline.pdb     [Download] [View]          ││
│ │    Proline mutation probabilities                       ││
│ │                                                         ││
│ │ 📄 myprotein_disulfide.pdb   [Download] [View]          ││
│ │    Disulfide bond probabilities                         ││
│ └─────────────────────────────────────────────────────────┘│
│                                                             │
│ Interpretation:                                             │
│ • Open files in PyMOL or ChimeraX                          │
│ • Color by B-factor to visualize probabilities              │
│ • Higher values (red) = more favorable for mutation         │
│ • Lower values (blue) = less favorable                      │
└─────────────────────────────────────────────────────────────┘
```

## Visualization Integration

If the BV-BRC viewer supports B-factor coloring:

```javascript
// Suggested coloring scheme
const colorScheme = {
    type: 'bfactor',
    range: [0, 1],
    colors: ['#0000FF', '#FFFFFF', '#FF0000']  // blue-white-red
};
```

## Resource Requirements

This app is lightweight and does not require GPU:

| Resource | Value |
|----------|-------|
| Default CPU | 4 |
| Default Memory | 8G |
| Default Runtime | 600s (10 min) |
| GPU Required | No |

## Error Messages

Common user-facing errors:

| Error | User Message |
|-------|--------------|
| Invalid file format | "The uploaded file does not appear to be a valid PDB or mmCIF structure file." |
| No residues found | "No protein residues were found in the structure. Please ensure the file contains standard amino acids." |
| GPU unavailable | "GPU was requested but is not available. Please select 'Auto' or 'CPU' for compute device." |

## Questions?

Contact the backend team for:
- API endpoint changes
- New parameters
- Output format modifications
