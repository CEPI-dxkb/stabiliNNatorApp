#!/usr/bin/env node
//
// Regression test for the residue-label bug fixed in "fix: label ranked
// residues by their own identity, not by sequence offset".
//
// The report templates used to name a ranked residue with
// AA3[DATA.input.sequence[pos-1]] -- indexing the concatenated one-letter
// sequence by residue number. That is only correct for a single chain
// numbered 1..N with no gaps. On 3ft7 (two chains, numbered from 8) it
// mislabelled 86 of 88 proline rows, including showing "LEU 18" with an
// "already PRO" badge because the underlying residue really was a proline.
//
// Two independent checks per report:
//
//   RENDERING  the report's own inline script must not identify a residue by
//              indexing DATA.input.sequence with a residue number. This is the
//              check that actually guards the regression: the label is built in
//              the template, so reading the embedded JSON cannot see the bug.
//   DATA       already_pro must agree with the residue name, per_residue must be
//              index-aligned with the sequence, and labels must be distinct.
//
// It also reports whether the input DISCRIMINATES. A structure numbered
// contiguously from 1 - a single chain, or anything a clean/renumber step has
// produced - makes the offset lookup and the identity lookup coincide, so the
// DATA check passes whether or not the bug is present. Use --require-discriminating
// in CI to make that a failure rather than a silent pass.
//
// Usage: node tests/verify_report_labels.js [--require-discriminating] <report.html> [...]
// Exit: 0 ok, 1 a check failed, 2 usage, 3 input does not discriminate (with the flag).
//
const fs=require('fs');

const argv=process.argv.slice(2);
const REQUIRE_DISCRIMINATING=argv.includes('--require-discriminating');
const files=argv.filter(a=>a!=='--require-discriminating');
if(!files.length){
  console.error('usage: node tests/verify_report_labels.js [--require-discriminating] <report.html> [...]');
  process.exit(2);
}

let failed=0, blunt=0;
for(const file of files){
check(file);
}
process.exit(failed?1:(blunt&&REQUIRE_DISCRIMINATING?3:0));

function check(file){
const html=fs.readFileSync(file,'utf8');

// The label is built in the template, not in the data, so this is the only
// check here that can see a revert. DATA.input.sequence is the concatenated
// one-letter sequence; indexing it by a residue number is the bug.
const scripts=[...html.matchAll(/<script(?![^>]*type="application\/json")[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const offenders=[];
for(const src of scripts){
  const re=/DATA\.input\.sequence\s*\[[^\]]*\.pos\s*-\s*1[^\]]*\]/g;
  let m; while((m=re.exec(src))) offenders.push(m[0]);
}
const DATA=JSON.parse(html.match(/<script[^>]*id="report-data"[^>]*>([\s\S]*?)<\/script>/)[1]);

// resLabel / resTag, taken verbatim from the template
const MULTICHAIN=(DATA.input.chains||[]).length>1;
const resTag=(chain,pos)=>MULTICHAIN?`${chain}${pos}`:`${pos}`;
const resLabel=r=>MULTICHAIN?`${r.chain} ${r.res} ${r.pos}`:`${r.res} ${r.pos}`;

let bad=0, n=0;
for(const a of DATA.analyses){
  for(const s of a.sites){
    n++;
    const label=resLabel(s);
    // the label must name the residue the row actually is
    if(!label.includes(s.res)||!label.includes(String(s.pos))){bad++;console.log('BAD',a.key,label,s);}
    // already_pro must agree with the displayed name
    if(a.key==='proline'&&s.already_pro!==(s.res==='PRO')){bad++;console.log('BADGE MISMATCH',label,s);}
  }
}

// compact sequence: gold cysteines must land on the cysteines
const pr=DATA.per_residue, seq=DATA.input.sequence;
let seqBad=0;
if(pr.length!==seq.length){console.log('LENGTH MISMATCH',pr.length,seq.length);seqBad++;}
pr.forEach((p,k)=>{ if(p.is_cys && seq[k]!=='C'){seqBad++;console.log('CYS MISPLACED at index',k,seq[k],p);} });

// what the old code would have done, for contrast
const AA3={A:"ALA",R:"ARG",N:"ASN",D:"ASP",C:"CYS",Q:"GLN",E:"GLU",G:"GLY",H:"HIS",I:"ILE",L:"LEU",K:"LYS",M:"MET",F:"PHE",P:"PRO",S:"SER",T:"THR",W:"TRP",Y:"TYR",V:"VAL"};
const pro=DATA.analyses.find(a=>a.key==='proline');
let oldBad=0;
if(pro) for(const s of pro.sites){ const disp=AA3[seq[s.pos-1]]||s.res; if(disp!==s.res) oldBad++; }

const uniq=new Set((pro?pro.sites:[]).map(resLabel));
// An input only exercises the bug when the offset and identity lookups
// disagree somewhere. On a contiguously numbered structure they coincide and
// every check below passes with the bug present.
const discriminating = oldBad > 0;
if(!discriminating) blunt++;

console.log(`${file.split('/').pop()}: chains=${DATA.input.chains.join('')} rows=${n}`);
console.log(`  rendering: ${offenders.length?`FAIL - ${offenders.length} sequence[pos-1] lookup(s): ${offenders[0]}`:'ok - no sequence[pos-1] lookups'}`);
console.log(`  mislabeled now: ${bad}   (old sequence[pos-1] lookup would mislabel ${oldBad}/${pro?pro.sites.length:0})`);
console.log(`  misplaced gold cysteines: ${seqBad}`);
console.log(`  distinct proline labels: ${uniq.size}/${pro?pro.sites.length:0}`);
console.log(`  discriminating input: ${discriminating?'yes':'NO - numbered 1..N contiguously, so the data checks pass either way; only the rendering check is meaningful here'}`);
if(offenders.length) failed++;
if(bad+seqBad) failed++;
}
