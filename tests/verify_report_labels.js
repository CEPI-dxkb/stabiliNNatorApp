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
// Usage: node tests/verify_report_labels.js <generated-report.html> [...]
// Exit status is non-zero if any row is mislabelled.
//
const fs=require('fs');
const html=fs.readFileSync(process.argv[2],'utf8');
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
console.log(`${process.argv[2].split('/').pop()}: chains=${DATA.input.chains.join('')} rows=${n}`);
console.log(`  mislabeled now: ${bad}   (old sequence[pos-1] lookup would mislabel ${oldBad}/${pro?pro.sites.length:0})`);
console.log(`  misplaced gold cysteines: ${seqBad}`);
console.log(`  distinct proline labels: ${uniq.size}/${pro?pro.sites.length:0}`);
process.exit(bad+seqBad?1:0);
