# Vendored libraries

## 3Dmol-min.js
Inlined into the HTML report by `generate_report.py` to power the interactive
3D structure viewer, so the report stays self-contained (works offline and
under the workspace/artifact CSP — no CDN).

- Source: https://3dmol.org/build/3Dmol-min.js
- Project: https://github.com/3dmol/3Dmol.js
- License: BSD-3-Clause / MIT (see the project); redistributed unmodified.

To update: re-download the minified build and replace this file. The report
generator reads it via `--viewer-lib` (defaults to this path).
