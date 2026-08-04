#!/usr/bin/env python3
"""Generate a self-contained HTML stability report for a stabiliNNator run.

The report is a single HTML file that describes the input structure, the models
that were run, a ranked summary, and per-residue visualizations. It is produced
by filling one placeholder ({{REPORT_DATA_JSON}}) in an HTML template with a JSON
data blob derived from the run's own outputs -- so the template carries all
markup/CSS/JS and this script only supplies data.

Data sources (all real outputs of the run):
  * the annotated proline / disulfide PDBs, whose per-residue probability is
    encoded in the B-factor column (0-1), one value per residue on every atom;
  * the input structure, from which disulfide bonds are detected geometrically
    (cysteine SG-SG distance) rather than assumed -- so this is correct for any
    protein, not just the crambin example.

Downloads link to the sibling files that share the report's workspace folder;
by default with relative hrefs plus the full workspace path shown as text.

Pure standard library -- no third-party dependencies.
"""

import argparse
import json
import math
import os
import sys
from datetime import datetime, timezone

THREE2ONE = {
    "ALA": "A", "ARG": "R", "ASN": "N", "ASP": "D", "CYS": "C", "GLN": "Q",
    "GLU": "E", "GLY": "G", "HIS": "H", "ILE": "I", "LEU": "L", "LYS": "K",
    "MET": "M", "PHE": "F", "PRO": "P", "SER": "S", "THR": "T", "TRP": "W",
    "TYR": "Y", "VAL": "V",
}
CYS_NAMES = {"CYS", "CYX"}
PLACEHOLDER = "{{REPORT_DATA_JSON}}"

# Human-readable label for each output file, matched most-specific first.
OUTPUT_KINDS = [
    ("_proline_summary.tsv", "Ranked proline sites (TSV)"),
    ("_disulfide_summary.tsv", "Ranked cysteine sites (TSV)"),
    ("_summary.json", "Combined summary (JSON)"),
    ("_proline.pdb", "Annotated structure - proline (PDB)"),
    ("_disulfide.pdb", "Annotated structure - disulfide (PDB)"),
    (".pdb", "Structure (PDB)"),
    (".cif", "Structure (mmCIF)"),
    (".tsv", "Table (TSV)"),
    (".json", "Data (JSON)"),
]


def first_model_lines(path):
    """Yield the lines of the FIRST model only.

    NMR ensembles (and some other files) contain many MODEL/ENDMDL blocks with
    identical residues. The native tools and this parser would otherwise treat
    them as one giant concatenated chain (e.g. 38 x 20 = 760 "residues"). Header
    records before the first MODEL are kept; everything from the second MODEL on
    is dropped. Files with no MODEL records are yielded unchanged.
    """
    seen_model = False
    with open(path) as fh:
        for line in fh:
            if line.startswith("MODEL"):
                if seen_model:
                    return
                seen_model = True
                continue
            if line.startswith("ENDMDL") and seen_model:
                return
            yield line


def parse_ca_bfactors(path):
    """One representative (CA) record per residue -> list of dicts.

    All atoms of a residue carry the same B-factor value, so CA is a faithful
    single sample. HETATM and records without a CA are ignored. First model only.
    """
    rows = []
    for line in first_model_lines(path):
        if not line.startswith("ATOM"):
            continue
        if line[12:16].strip() != "CA":
            continue
        try:
            prob = float(line[60:66])
        except ValueError:
            continue
        rows.append({
            "chain": line[21].strip() or "A",
            "pos": int(line[22:26]),
            "icode": line[26].strip(),
            "res": line[17:20].strip(),
            "prob": prob,
        })
    return rows


def parse_sg_atoms(path):
    """Cysteine SG atoms as (chain, pos, x, y, z) -- used for bond detection.
    First model only."""
    out = []
    for line in first_model_lines(path):
        if not line.startswith(("ATOM", "HETATM")):
            continue
        if line[12:16].strip() != "SG":
            continue
        if line[17:20].strip() not in CYS_NAMES:
            continue
        try:
            xyz = (float(line[30:38]), float(line[38:46]), float(line[46:54]))
        except ValueError:
            continue
        out.append((line[21].strip() or "A", int(line[22:26]), xyz))
    return out


def detect_disulfides(sg_atoms, cutoff=2.5):
    """Pair cysteines whose SG-SG distance <= cutoff (Angstrom). ~2.05 A is a
    real S-S bond; 2.5 A is a tolerant threshold. Each SG joins at most one
    partner (its nearest within cutoff)."""
    bonds = []
    used = set()
    order = []
    n = len(sg_atoms)
    for i in range(n):
        for j in range(i + 1, n):
            d = math.dist(sg_atoms[i][2], sg_atoms[j][2])
            if d <= cutoff:
                order.append((d, i, j))
    for d, i, j in sorted(order):
        if i in used or j in used:
            continue
        used.add(i); used.add(j)
        bonds.append({
            "a": sg_atoms[i][1], "b": sg_atoms[j][1],
            "chain_a": sg_atoms[i][0], "chain_b": sg_atoms[j][0],
            "dist": round(d, 2),
        })
    bonds.sort(key=lambda b: b["a"])
    return bonds


def read_pdb_meta(path):
    """HEADER classification and TITLE/COMPND text from the input PDB."""
    header, title = "", ""
    with open(path) as fh:
        for line in fh:
            rec = line[:6]
            if rec.startswith("HEADER"):
                header = line[10:50].strip()
            elif rec.startswith("TITLE"):
                title += " " + line[10:].strip()
            elif rec.startswith("COMPND") and not title:
                title += " " + line[10:].strip()
            elif line.startswith(("ATOM", "HETATM")):
                break
    return header, " ".join(title.split())


def kind_for(name):
    for suffix, label in OUTPUT_KINDS:
        if name.endswith(suffix):
            return label
    return "Output file"


def build_outputs(out_dir, report_name, ws_path, link_mode, portal_base):
    """List sibling files in out_dir (everything that will be uploaded) with a
    link resolved per link_mode. The report itself is excluded."""
    entries = []
    for name in sorted(os.listdir(out_dir)):
        full = os.path.join(out_dir, name)
        if not os.path.isfile(full) or name == report_name or name.startswith("."):
            continue
        ws_file = (ws_path.rstrip("/") + "/" + name) if ws_path else name
        if link_mode == "portal" and portal_base:
            href = portal_base.rstrip("/") + ws_file
        elif link_mode == "paths":
            href = ""
        else:  # relative
            href = "./" + name
        entries.append({
            "name": name,
            "kind": kind_for(name),
            "href": href,
            "ws_path": ws_file,
            "bytes": os.path.getsize(full),
        })
    return entries


def analysis_command(kind, model, hidden_dim, device):
    script = ("proliNNator.py" if kind == "proline"
              else "predict_cysteine_probabilities.py")
    out = "<name>_%s.pdb" % kind
    return (
        "python %s\n"
        "  --model-path %s\n"
        "  --pdb-path <input>.pdb\n"
        "  --output-path %s\n"
        "  --hidden-dim %s  --device %s"
    ) % (script, model or ("%s_gat.pt" % ("proline" if kind == "proline" else "cys")),
         out, hidden_dim, device)


def build_data(args):
    # per-residue backbone: prefer the proline PDB (annotates all residues),
    # else fall back to the disulfide PDB.
    backbone_pdb = args.proline or args.disulfide
    if not backbone_pdb:
        raise SystemExit("error: at least one of --proline / --disulfide is required")

    pro_rows = parse_ca_bfactors(args.proline) if args.proline else []
    dis_rows = parse_ca_bfactors(args.disulfide) if args.disulfide else []
    pro_by = {(r["chain"], r["pos"]): r for r in pro_rows}
    dis_by = {(r["chain"], r["pos"]): r for r in dis_rows}

    backbone = pro_rows if args.proline else dis_rows
    backbone = sorted(backbone, key=lambda r: (r["chain"], r["pos"]))

    per_residue = []
    for r in backbone:
        key = (r["chain"], r["pos"])
        is_cys = r["res"] in CYS_NAMES
        per_residue.append({
            "chain": r["chain"], "pos": r["pos"], "res": r["res"],
            "one": THREE2ONE.get(r["res"], "X"),
            "proline_p": pro_by[key]["prob"] if key in pro_by else None,
            # disulfiNNate scores every residue, so report the value for all of
            # them (not only cysteines) in the per-residue table
            "disulfide_p": dis_by[key]["prob"] if key in dis_by else None,
            "is_cys": is_cys,
        })

    sequence = "".join(p["one"] for p in per_residue)
    chains = sorted({p["chain"] for p in per_residue})
    cys_positions = [p["pos"] for p in per_residue if p["is_cys"]]

    analyses = []
    if args.proline:
        # Exclude existing cysteines from proline substitution candidates -- a
        # Cys is likely in a disulfide and should not be mutated away. Existing
        # prolines are kept but flagged. (The full per-residue table still lists
        # every residue's proline score.)
        ranked = sorted(
            [{"pos": r["pos"], "chain": r["chain"], "res": r["res"], "prob": r["prob"],
              "already_pro": r["res"] == "PRO"}
             for r in pro_rows if r["res"] not in CYS_NAMES],
            key=lambda x: -x["prob"])
        analyses.append({
            "key": "proline", "label": "proliNNator",
            "blurb": "Scores how favorable a proline substitution is at each residue. "
                     "High score = a position where introducing proline is predicted to "
                     "rigidify the backbone without disrupting the fold. Existing "
                     "cysteines are excluded as candidates; existing prolines are flagged.",
            "model": os.path.basename(args.proline_model) if args.proline_model else "proline_gat.pt",
            "command": analysis_command("proline", os.path.basename(args.proline_model) if args.proline_model else None,
                                        args.hidden_dim, args.device),
            "n_sites": len(ranked),
            "sites": ranked,
        })
    if args.disulfide:
        ranked = sorted(
            [{"pos": r["pos"], "chain": r["chain"], "res": r["res"], "prob": r["prob"]}
             for r in dis_rows if r["res"] in CYS_NAMES],
            key=lambda x: -x["prob"])
        analyses.append({
            "key": "disulfide", "label": "disulfiNNate",
            "blurb": "Scores each cysteine's likelihood of participating in a disulfide "
                     "bond. The model annotates every residue, but only cysteines are "
                     "biologically meaningful, so only CYS/CYX are ranked.",
            "model": os.path.basename(args.disulfide_model) if args.disulfide_model else "cys_gat.pt",
            "command": analysis_command("disulfide", os.path.basename(args.disulfide_model) if args.disulfide_model else None,
                                        args.hidden_dim, args.device),
            "n_sites": len(ranked),
            "sites": ranked,
        })

    header, title = read_pdb_meta(args.input) if args.input else ("", "")
    disulfide_bonds = detect_disulfides(parse_sg_atoms(args.input)) if args.input else []

    name = args.name or os.path.splitext(os.path.basename(backbone_pdb))[0]
    name = name.replace("_proline", "").replace("_disulfide", "")

    out_dir = os.path.dirname(os.path.abspath(args.output))
    report_name = os.path.basename(args.output)
    outputs = build_outputs(out_dir, report_name, args.workspace_path,
                            args.link_mode, args.portal_base)

    return {
        "generated": args.generated or datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "input": {
            "file": os.path.basename(args.input) if args.input else os.path.basename(backbone_pdb),
            "name": name,
            "header": header,
            "title": title,
            "n_residues": len(per_residue),
            "chains": chains,
            "sequence": sequence,
            "cys_positions": cys_positions,
        },
        "analyses": analyses,
        "per_residue": per_residue,
        "disulfide_bonds": disulfide_bonds,
        "params": {
            "hidden_dim": args.hidden_dim,
            "device": args.device,
            "container": args.container,
            "service": "BV-BRC App-StabiliNNator",
        },
        "source": {
            "name": "stabiliNNator",
            "repo": args.source_repo,
            "commit": args.source_commit,
        },
        "outputs": outputs,
        "workspace_path": args.workspace_path or "",
        "link_mode": args.link_mode,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description="Generate an HTML stability report from stabiliNNator outputs.")
    p.add_argument("--template", required=True, help="HTML template containing the {{REPORT_DATA_JSON}} placeholder")
    p.add_argument("--output", required=True, help="path to write the report .html")
    p.add_argument("--input", help="input structure PDB (for metadata + disulfide detection)")
    p.add_argument("--proline", help="annotated proline PDB output")
    p.add_argument("--disulfide", help="annotated disulfide PDB output")
    p.add_argument("--proline-model", dest="proline_model", help="proline model filename (for provenance)")
    p.add_argument("--disulfide-model", dest="disulfide_model", help="disulfide model filename (for provenance)")
    p.add_argument("--workspace-path", dest="workspace_path", default="", help="workspace folder the outputs are uploaded to")
    p.add_argument("--link-mode", dest="link_mode", default="relative",
                   choices=["relative", "paths", "portal"], help="how download links are formed")
    p.add_argument("--portal-base", dest="portal_base", default="", help="base URL for --link-mode portal")
    p.add_argument("--hidden-dim", dest="hidden_dim", default="32")
    p.add_argument("--device", default="cpu")
    p.add_argument("--container", default="dxkb/stabilinnator-bvbrc")
    p.add_argument("--source-repo", dest="source_repo",
                   default="https://github.com/schoederlab/stabiliNNator",
                   help="upstream tool repository, shown in the report provenance")
    p.add_argument("--source-commit", dest="source_commit", default="",
                   help="pinned upstream commit (short or full), shown in provenance")
    p.add_argument("--name", help="display name for the structure (defaults to file stem)")
    p.add_argument("--generated", help="override the generated timestamp (for reproducible output)")
    args = p.parse_args(argv)

    data = build_data(args)

    with open(args.template) as fh:
        template = fh.read()
    if PLACEHOLDER not in template:
        raise SystemExit("error: template %s has no %s placeholder" % (args.template, PLACEHOLDER))

    # Inject as the text content of a JSON <script> -- escape only the sequence
    # that could close it early. json.dumps already escapes everything else.
    blob = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    html = template.replace(PLACEHOLDER, blob)

    with open(args.output, "w") as fh:
        fh.write(html)
    print("Wrote report: %s (%d residues, %d analyses, %d disulfide bonds)"
          % (args.output, data["input"]["n_residues"], len(data["analyses"]),
             len(data["disulfide_bonds"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
