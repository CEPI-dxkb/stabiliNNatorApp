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
    coresMin: 4
    ramMin: 8192  # 8GB
    tmpdirMin: 5120  # 5GB
  InlineJavascriptRequirement: {}

hints:
  cwltool:CUDARequirement:
    cudaVersionMin: "11.8"
    cudaDeviceCountMin: 1
    cudaDeviceCountMax: 1

baseCommand: [python]

arguments:
  - valueFrom: |
      ${
        if (inputs.analysis_type === 'disulfide') {
          return '/opt/stabilinnator/disulfiNNate/predict_cysteine_probabilities.py';
        }
        return '/opt/stabilinnator/proliNNator/proliNNator.py';
      }
    position: 0

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
    inputBinding:
      prefix: --hidden-dim
      position: 3
    doc: |
      Hidden dimension size for the neural network.
      Default: 128 for proliNNator, 32 for disulfiNNate.
      Only modify if using custom-trained models.

  device:
    type:
      - "null"
      - type: enum
        symbols: [cuda, cpu]
    default: cuda
    inputBinding:
      prefix: --device
      position: 4
    doc: |
      Compute device to use. 'cuda' for GPU, 'cpu' for CPU.
      GPU is recommended but not required.

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

arguments:
  - prefix: --output-path
    valueFrom: $(inputs.output_filename)
    position: 5

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
