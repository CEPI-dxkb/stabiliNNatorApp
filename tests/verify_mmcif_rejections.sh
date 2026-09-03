#!/usr/bin/env bash
#
# Negative-path test for convert_mmcif_to_pdb() in App-StabiliNNator.pl.
#
# The converter refuses the two structures PDB format cannot represent:
# multi-character chain identifiers, and more than 99,999 atoms. Both were
# written blind - neither branch had ever been observed to fire - and a
# rejection path nobody has tripped is a guess about behaviour, not a check.
#
# The trap this guards against is a test that passes on error SHAPE rather than
# error IDENTITY. Both branches live downstream of MMCIFParser, so a fixture
# that is merely malformed fails earlier, in the parser, with a different
# message - and an assertion looking only for "it failed" would call that a
# pass. The first oversized fixture written for this test did exactly that:
# repeated atom ids tripped "Atom N defined twice" before the atom count was
# ever reached. So each case here asserts the branch's own wording AND that the
# generic parse failure did not fire instead.
#
# Usage: tests/verify_mmcif_rejections.sh [path-to-App-StabiliNNator.pl]
#
# Defaults to the copy in this checkout; pass the deployed path to test what a
# container actually ships, e.g.
#
#   singularity exec /scout/containers/folding_prod.sif \
#       tests/verify_mmcif_rejections.sh /opt/p3/deployment/plbin/App-StabiliNNator.pl
#
# Requires python3 with Biopython on PATH, which the analysis environment has.

set -u

SCRIPT="${1:-$(dirname "$0")/../service-scripts/App-StabiliNNator.pl}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 2; }

# Drive the real sub, lifted verbatim, without an AppScript or a workspace.
python3 - "$SCRIPT" "$WORK" <<'PY'
import sys
script, work = sys.argv[1], sys.argv[2]
s = open(script).read()
try:
    i = s.index('sub convert_mmcif_to_pdb {')
    j = s.index('\n=head2 determine_device')
except ValueError:
    sys.exit("convert_mmcif_to_pdb not found in %s" % script)
open(work + '/driver.pl', 'w').write(
    "use strict; use warnings;\n" + s[i:j] +
    "\nmy $o = eval { convert_mmcif_to_pdb($ARGV[0], $ARGV[1]) };\n"
    "print $@ ? qq{DIED: $@} : qq{OK: $o\\n};\n")
PY
[ -f "$WORK/driver.pl" ] || exit 2

# Fixtures, built from a real mmCIF so that only the property under test is
# abnormal. Generated rather than committed: the oversized one is ~6 MB.
python3 - "$WORK" "$(dirname "$0")/../test_data/1crn_small.pdb" <<'PY'
import sys
from Bio.PDB import PDBParser, MMCIFIO
work, src = sys.argv[1], sys.argv[2]
io = MMCIFIO(); io.set_structure(PDBParser(QUIET=True).get_structure('x', src))
io.save(work + '/base.cif')

lines = open(work + '/base.cif').read().splitlines(True)
hdr   = [l for l in lines if not l.startswith(('ATOM', 'HETATM'))]
atoms = [l for l in lines if l.startswith(('ATOM', 'HETATM'))]
cols  = [l.strip() for l in lines if l.startswith('_atom_site.')]
c_id, c_auth = cols.index('_atom_site.id'), cols.index('_atom_site.auth_asym_id')
c_lab = cols.index('_atom_site.label_asym_id')
c_aseq, c_lseq = cols.index('_atom_site.auth_seq_id'), cols.index('_atom_site.label_seq_id')

out = []
for l in atoms:
    f = l.split(); f[c_auth] = f[c_lab] = 'AA'; out.append(' '.join(f) + '\n')
open(work + '/widechain.cif', 'w').writelines(hdr + out)

# Valid in every other respect: distinct residue numbers, distinct atom ids.
# Only the total exceeds what PDB serial numbers can hold.
out, aid, off = [], 0, 0
while len(out) <= 100000:
    for l in atoms:
        f = l.split(); aid += 1
        f[c_id] = str(aid)
        f[c_aseq] = str(int(f[c_aseq]) + off)
        if f[c_lseq].lstrip('-').isdigit():
            f[c_lseq] = str(int(f[c_lseq]) + off)
        out.append(' '.join(f) + '\n')
    off += 100
open(work + '/bigatoms.cif', 'w').writelines(hdr + out)
print('fixtures: widechain.cif, bigatoms.cif (%d atoms)' % len(out))
PY
[ -f "$WORK/bigatoms.cif" ] || { echo "fixture generation failed" >&2; exit 2; }

fail=0

run_case() {
  local name="$1" fixture="$2" want="$3"
  local got
  got="$(perl "$WORK/driver.pl" "$WORK/$fixture" "$WORK" 2>&1)"

  if ! grep -qF -- "$want" <<<"$got"; then
    echo "FAIL  $name: expected message not found"
    echo "      want: $want"
    echo "      got:  $(grep -m1 DIED <<<"$got" || echo "$got" | tail -1)"
    fail=1
    return
  fi
  # Identity, not shape: the generic parse failure must NOT be what fired.
  if grep -qF -- 'could not parse the mmCIF file' <<<"$got"; then
    echo "FAIL  $name: failed upstream in the parser, so this branch was never reached"
    fail=1
    return
  fi
  echo "ok    $name"
}

run_case "multi-character chain identifiers" widechain.cif \
  "uses multi-character chain identifiers (AA), which PDB format cannot represent"

run_case "more than 99,999 atoms" bigatoms.cif \
  "atoms; PDB format holds at most 99999"

# A file that really is unparseable must take the parser path, not one of the
# branches above - the mirror image of the check inside run_case.
printf 'data_x\nloop_\n_atom_site.junk\nnope\n' > "$WORK/broken.cif"
got="$(perl "$WORK/driver.pl" "$WORK/broken.cif" "$WORK" 2>&1)"
if grep -qF -- 'could not parse the mmCIF file' <<<"$got"; then
  echo "ok    unparseable file reports a parse failure"
else
  echo "FAIL  unparseable file: expected a parse failure, got: $(tail -1 <<<"$got")"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "all mmCIF rejection paths fire with their own message" \
                 || echo "one or more rejection paths did not behave as documented"
exit "$fail"
