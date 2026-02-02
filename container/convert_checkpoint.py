#!/usr/bin/env python3
"""
Convert old stabiliNNator checkpoint format to new PyTorch Geometric format.

Old format (trained with torch-geometric ~2.0-2.1):
- gat.att_src, gat.att_dst, gat.lin.weight, gat.bias

New format (torch-geometric 2.4+):
- gat.att_src, gat.att_dst, gat.lin_src.weight, gat.lin_dst.weight, gat.bias

The conversion duplicates lin.weight into both lin_src and lin_dst.
"""

import argparse
import torch
from pathlib import Path


def convert_checkpoint(input_path: Path, output_path: Path) -> None:
    """Convert old checkpoint format to new format."""
    state_dict = torch.load(input_path, map_location='cpu')

    new_state_dict = {}
    for key, value in state_dict.items():
        if key == 'gat.lin.weight':
            # Duplicate lin.weight into lin_src and lin_dst
            new_state_dict['gat.lin_src.weight'] = value.clone()
            new_state_dict['gat.lin_dst.weight'] = value.clone()
            print(f"  Converted {key} -> gat.lin_src.weight, gat.lin_dst.weight")
        else:
            new_state_dict[key] = value

    torch.save(new_state_dict, output_path)
    print(f"Saved converted checkpoint to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Convert old stabiliNNator checkpoint format")
    parser.add_argument("input", type=Path, help="Input checkpoint file (.pt)")
    parser.add_argument("output", type=Path, help="Output checkpoint file (.pt)")
    args = parser.parse_args()

    if not args.input.exists():
        raise FileNotFoundError(f"Input file not found: {args.input}")

    print(f"Converting {args.input}")
    convert_checkpoint(args.input, args.output)


if __name__ == "__main__":
    main()
