# HTML report generation

`generate_report.py` builds a single self-contained HTML report from a
stabiliNNator run's outputs. It is called (non-fatally) by
`service-scripts/App-StabiliNNator.pl` after the TSV/JSON summaries, and the
resulting `stabilinnator_report.html` is uploaded into the job's result folder
alongside the data files (with workspace type `html`, so the BV-BRC portal renders it).

## How it works

The report is a **template + data** split:

- `report_template.html` carries all markup, CSS, and rendering JS, plus one
  placeholder: `{{REPORT_DATA_JSON}}`.
- `generate_report.py` derives a JSON data blob from the run's real outputs and
  substitutes it into the placeholder. The template's JS reads that blob from a
  `<script type="application/json">` tag and renders every section.

Data comes only from the run itself:

- **Per-residue probabilities** are read from the annotated PDBs' B-factor
  column (one value per residue; CA atom sampled).
- **Disulfide bonds** are detected geometrically from the input structure
  (cysteine SG–SG distance ≤ 2.5 Å) — correct for any protein, not assumed.
- **Downloads** are the sibling files in the output folder, linked relatively
  by default, with the full workspace path shown as text.

Pure standard library — no third-party Python dependencies.

## Usage

```bash
python generate_report.py \
  --template report_template.html \
  --output   stabilinnator_report.html \
  --input    <input>.pdb \
  --proline  <name>_proline.pdb   --proline-model   proline_gat.pt \
  --disulfide <name>_disulfide.pdb --disulfide-model cys_gat.pt \
  --workspace-path /user@bvbrc/home/.../output \
  --hidden-dim 32 --device cpu \
  --link-mode relative        # relative | paths | portal
```

At least one of `--proline` / `--disulfide` is required; the report adapts to
whichever analyses ran. `--link-mode portal` additionally needs `--portal-base`.

## Template placeholder contract

`{{REPORT_DATA_JSON}}` → a JSON object with: `input` (file, name, header, title,
n_residues, chains, sequence, cys_positions), `analyses[]` (key, label, blurb,
model, command, sites), `per_residue[]`, `disulfide_bonds[]`, `params`,
`outputs[]` (name, kind, href, ws_path, bytes), `workspace_path`, `generated`.
To restyle the report, edit the template only; to change what data is computed,
edit the script.
