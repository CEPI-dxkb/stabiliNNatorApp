#!/usr/bin/env cwl-runner

cwlVersion: v1.2
class: CommandLineTool

label: stabiliNNator Protein Stability Prediction
doc: |
  GNN-based protein stability prediction using stabiliNNator.

  stabiliNNator consists of two complementary tools:
  - proliNNator: Predicts favorable sites for proline mutations
  - disulfiNNate: Predicts favorable sites for disulfide bond formation

  Both tools use Graph Attention Networks to analyze protein structures and
  output probabilities (0-1) in the B-factor column of the output PDB.

  For more information: https://github.com/jakobriccabona/stabiliNNator

requirements:
  DockerRequirement:
    dockerPull: dxkb/stabilinnator:latest-gpu
  ResourceRequirement:
    # Based on benchmarks: ~500MB memory, minimal CPU needed
    # See docs/RUNTIME_METRICS.md for full benchmark data
    coresMin: 2
    ramMin: 1024  # 1GB (benchmarked at ~500MB)
    tmpdirMin: 1024  # 1GB
  InlineJavascriptRequirement: {}

# Note: GPU is NOT recommended - CPU is actually faster for these small models
# CUDA initialization overhead (~3-4s) exceeds compute savings
# CUDARequirement removed since GPU provides no benefit

baseCommand: []

arguments:
  # Use wrapper scripts which provide default model paths and hidden_dim=32
  - valueFrom: |
      ${
        if (inputs.analysis_type === 'disulfide') {
          return 'disulfinnate';
        }
        return 'prolinnator';
      }
    position: 0
  - prefix: --output-path
    valueFrom: $(inputs.output_filename)
    position: 5

inputs:
  input_file:
    type: File
    inputBinding:
      prefix: --pdb-path
      position: 1
    doc: |
      Input protein structure file in PDB format.
      Structure must contain standard amino acids with CA atoms.

  analysis_type:
    type:
      - "null"
      - type: enum
        symbols: [proline, disulfide]
    default: proline
    doc: |
      Type of stability analysis to perform:
      - proline: Predict favorable proline mutation sites
      - disulfide: Predict favorable disulfide bond sites

      Note: For 'both' analyses, run this tool twice with different analysis_type.

  model_path:
    type: File?
    inputBinding:
      prefix: --model-path
      position: 2
    doc: |
      Optional path to custom trained model file (.pt).
      If not specified, uses the default pre-trained model.

  hidden_dim:
    type: int?
    default: 32
    inputBinding:
      prefix: --hidden-dim
      position: 3
    doc: |
      Hidden dimension size for the neural network.
      Default: 32 (both models were trained with hidden_dim=32).
      Only modify if using custom-trained models.

  device:
    type:
      - "null"
      - type: enum
        symbols: [cpu, cuda]
    default: cpu
    inputBinding:
      prefix: --device
      position: 4
    doc: |
      Compute device to use. 'cpu' for CPU, 'cuda' for GPU.
      CPU is recommended - benchmarks show CPU is faster than GPU
      due to CUDA initialization overhead exceeding compute savings.

  output_filename:
    type: string?
    default: "output.pdb"
    doc: Output filename for the annotated PDB.

outputs:
  output_pdb:
    type: File
    outputBinding:
      glob: $(inputs.output_filename)
    doc: |
      Output PDB file with stability probabilities in the B-factor column.
      Values range from 0 to 1:
      - For proline analysis: higher values = more favorable for proline substitution
      - For disulfide analysis: higher values = higher likelihood of disulfide bond

stdout: stabilinnator_stdout.txt
stderr: stabilinnator_stderr.txt

s:author:
  - class: s:Person
    s:name: BV-BRC Team
    s:email: help@bv-brc.org

s:license: https://spdx.org/licenses/MIT

$namespaces:
  s: https://schema.org/
  cwltool: http://commonwl.org/cwltool#

$schemas:
  - https://schema.org/version/latest/schemaorg-current-https.rdf
