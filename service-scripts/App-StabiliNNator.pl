#!/usr/bin/env perl

=head1 NAME

App-StabiliNNator - BV-BRC AppService script for protein stability prediction

=head1 SYNOPSIS

    App-StabiliNNator [--preflight] params.json

=head1 DESCRIPTION

This script implements the BV-BRC AppService interface for running stabiliNNator
protein stability predictions. It handles:

- Input validation (PDB/mmCIF format)
- Workspace file download/upload
- Resource estimation for job scheduling
- Execution of proliNNator and disulfiNNate tools
- Result collection and workspace upload

stabiliNNator uses Graph Neural Networks to predict:
- proliNNator: Proline mutation probabilities at each residue
- disulfiNNate: Disulfide bond formation likelihood between cysteine pairs

Output files have probabilities (0-1) encoded in the B-factor column.

=cut

use strict;
use warnings;
use Carp::Always;
use Data::Dumper;
use File::Basename;
use File::Path qw(make_path remove_tree);
use File::Slurp;
use File::Copy;
use JSON;
use Getopt::Long;
use Try::Tiny;

# BV-BRC modules
use Bio::KBase::AppService::AppScript;

# Default log level for production
$ENV{P3_LOG_LEVEL} //= 'INFO';

# Initialize the AppScript with our callbacks
my $script = Bio::KBase::AppService::AppScript->new(\&run_stabilinnator, \&preflight);
$script->run(\@ARGV);

=head2 preflight

Estimate resource requirements based on input parameters.
stabiliNNator is lightweight compared to structure prediction tools.

=cut

sub preflight {
    my ($app, $app_def, $raw_params, $params) = @_;

    # Resource estimates based on actual benchmarks (see docs/RUNTIME_METRICS.md)
    # Benchmark environment: AMD EPYC 9654, NVIDIA H100, Singularity container
    #
    # Key findings:
    # - CPU mode is FASTER than GPU (CUDA overhead exceeds compute savings)
    # - Container startup (~3-4s) dominates runtime
    # - Actual inference is sub-second for most proteins
    # - Memory usage is ~500MB even for very large proteins (8,000 residues)

    my $cpu = 2;           # Sufficient for GNN inference
    my $memory = "1G";     # Benchmarked at ~500MB, 1G provides buffer
    my $runtime = 30;      # Base: container startup + model loading
    my $storage = "1G";    # Output PDBs are small

    # Adjust based on analysis type
    my $analysis_type = $params->{analysis_type} // 'both';

    if ($analysis_type eq 'both') {
        $runtime = 60;     # Both analyses: ~12s actual, 60s with buffer
    }

    # Note: GPU mode is NOT recommended for stabiliNNator
    # Benchmarks show CPU is faster due to small model size (14-22KB)
    # CUDA initialization overhead (~3-4s) exceeds any compute savings
    my $accelerator = $params->{accelerator} // 'cpu';
    my $gpu_count = 0;

    if ($accelerator eq 'gpu') {
        $gpu_count = 1;
        # GPU is actually slower, but user explicitly requested it
        # Keep same runtime (don't reduce)
    }

    # For very large proteins (>1000 residues), disulfiNNate has O(n²) scaling
    # Add buffer for edge computation: 1AON (8,015 residues) took 18.6s
    # Without knowing protein size at preflight, use conservative estimate
    $runtime = $runtime * 2;  # 2x buffer for safety

    return {
        cpu => $cpu,
        memory => $memory,
        runtime => $runtime,
        storage => $storage,
        policy_data => {
            gpu_count => $gpu_count,
            partition => 'normal',  # Always use normal partition (CPU is faster)
        }
    };
}

=head2 run_stabilinnator

Main execution function for stabiliNNator prediction.

=cut

sub run_stabilinnator {
    my ($app, $app_def, $raw_params, $params) = @_;

    print "Starting stabiliNNator protein stability prediction\n";
    print STDERR "Parameters: " . Dumper($params) . "\n" if $ENV{P3_DEBUG};

    # Create working directories
    my $work_dir = $ENV{P3_WORKDIR} // $ENV{TMPDIR} // "/tmp";
    my $input_dir = "$work_dir/input";
    my $output_dir = "$work_dir/output";

    make_path($input_dir) unless -d $input_dir;
    make_path($output_dir) unless -d $output_dir;

    # Download input structure file from workspace
    my $input_file = $params->{input_file};
    die "Input file is required\n" unless $input_file;

    print "Downloading input file: $input_file\n";
    my $local_input = download_workspace_file($app, $input_file, $input_dir);

    # Validate input is PDB or mmCIF
    my $file_format = validate_structure_file($local_input);
    print "Detected file format: $file_format\n";

    # Get analysis parameters
    my $analysis_type = $params->{analysis_type} // 'both';
    my $hidden_dim = $params->{hidden_dim};
    my $accelerator = $params->{accelerator} // 'cpu';  # CPU is faster than GPU for these models

    # Determine device
    my $device = determine_device($accelerator);
    print "Using compute device: $device\n";

    # Get model paths from environment or defaults
    my $stabilinnator_dir = $ENV{STABILINNATOR_DIR} // "/opt/stabilinnator";
    my $prolinnator_model = $ENV{PROLINNATOR_MODEL} // "$stabilinnator_dir/proliNNator/models/proline_gat.pt";
    my $disulfinnate_model = $ENV{DISULFINNATE_MODEL} // "$stabilinnator_dir/disulfiNNate/models/cys_gat.pt";

    # Dry run mode - skip execution
    if ($params->{dry_run}) {
        print "DRY RUN MODE - skipping stabiliNNator execution\n";
        print "Analysis type: $analysis_type\n";
        print "Input file: $local_input\n";
        print "Device: $device\n";
        print "proliNNator model: $prolinnator_model\n";
        print "disulfiNNate model: $disulfinnate_model\n";
        print "Dry run completed successfully\n";
        return 0;
    }

    my $input_basename = basename($local_input);
    $input_basename =~ s/\.(pdb|cif|mmcif|ent)$//i;

    # Run analyses
    my @output_files;

    if ($analysis_type eq 'proline' || $analysis_type eq 'both') {
        print "\n=== Running proliNNator (proline probability prediction) ===\n";

        my $proline_output = "$output_dir/${input_basename}_proline.pdb";
        my $proline_hidden_dim = $hidden_dim // 32;  # Model trained with hidden_dim=32

        my @cmd = (
            "python",
            "$stabilinnator_dir/proliNNator/proliNNator.py",
            "--model-path", $prolinnator_model,
            "--pdb-path", $local_input,
            "--output-path", $proline_output,
            "--hidden-dim", $proline_hidden_dim,
            "--device", $device,
        );

        print "Executing: " . join(" ", @cmd) . "\n";
        my $rc = system(@cmd);
        if ($rc != 0) {
            die "proliNNator prediction failed with exit code: $rc\n";
        }

        if (-f $proline_output) {
            push @output_files, $proline_output;
            print "proliNNator completed: $proline_output\n";
        } else {
            warn "proliNNator output file not found: $proline_output\n";
        }
    }

    if ($analysis_type eq 'disulfide' || $analysis_type eq 'both') {
        print "\n=== Running disulfiNNate (disulfide bond prediction) ===\n";

        my $disulfide_output = "$output_dir/${input_basename}_disulfide.pdb";
        my $disulfide_hidden_dim = $hidden_dim // 32;  # disulfiNNate default

        my @cmd = (
            "python",
            "$stabilinnator_dir/disulfiNNate/predict_cysteine_probabilities.py",
            "--model-path", $disulfinnate_model,
            "--pdb-path", $local_input,
            "--output-path", $disulfide_output,
            "--hidden-dim", $disulfide_hidden_dim,
            "--device", $device,
        );

        print "Executing: " . join(" ", @cmd) . "\n";
        my $rc = system(@cmd);
        if ($rc != 0) {
            die "disulfiNNate prediction failed with exit code: $rc\n";
        }

        if (-f $disulfide_output) {
            push @output_files, $disulfide_output;
            print "disulfiNNate completed: $disulfide_output\n";
        } else {
            warn "disulfiNNate output file not found: $disulfide_output\n";
        }
    }

    print "\nstabiliNNator prediction completed successfully\n";
    print "Output files: " . scalar(@output_files) . "\n";

    # Upload results to workspace
    my $output_path = $params->{output_path};
    die "Output path is required\n" unless $output_path;

    print "Uploading results to workspace: $output_path\n";
    upload_results($app, $output_dir, $output_path);

    print "stabiliNNator job completed\n";
    return 0;
}

=head2 validate_structure_file

Validate that input file is in PDB or mmCIF format.
Returns the detected format.

=cut

sub validate_structure_file {
    my ($file) = @_;

    my $content = read_file($file, { binmode => ':raw' });

    # Check for mmCIF format (starts with data_ or loop_)
    if ($content =~ /^data_/m || $content =~ /^loop_/m) {
        # Verify it has _atom_site records
        unless ($content =~ /_atom_site\./m) {
            die "mmCIF file does not contain atom site records.\n";
        }
        return "mmCIF";
    }

    # Check for PDB format (has ATOM or HETATM records)
    if ($content =~ /^(ATOM|HETATM)\s/m) {
        return "PDB";
    }

    die "Input file does not appear to be in PDB or mmCIF format.\n";
}

=head2 determine_device

Determine the compute device to use based on accelerator parameter.

=cut

sub determine_device {
    my ($accelerator) = @_;

    if ($accelerator eq 'cpu') {
        return 'cpu';
    }

    if ($accelerator eq 'gpu') {
        # Check if CUDA is available
        my $cuda_check = `python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null`;
        chomp $cuda_check;
        if ($cuda_check eq 'True') {
            return 'cuda';
        }
        die "GPU requested but CUDA is not available\n";
    }

    # Auto mode: try GPU first, fall back to CPU
    my $cuda_check = `python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null`;
    chomp $cuda_check;
    return ($cuda_check eq 'True') ? 'cuda' : 'cpu';
}

=head2 download_workspace_file

Download a file from the BV-BRC workspace.

=cut

sub download_workspace_file {
    my ($app, $ws_path, $local_dir) = @_;

    my $basename = basename($ws_path);
    my $local_path = "$local_dir/$basename";

    # Use workspace API to download
    if ($app && $app->can('workspace')) {
        try {
            # Pass use_shock=1 to properly download files stored in Shock
            $app->workspace->download_file($ws_path, $local_path, 1);
        } catch {
            die "Failed to download $ws_path: $_\n";
        };
    } else {
        # Fallback for testing without workspace
        if (-f $ws_path) {
            copy($ws_path, $local_path) or die "Copy failed: $!\n";
        } else {
            die "File not found: $ws_path\n";
        }
    }

    return $local_path;
}

=head2 upload_results

Upload prediction results to the BV-BRC workspace.

=cut

sub upload_results {
    my ($app, $local_dir, $ws_path) = @_;

    # Find all output files
    my @files;
    find_files($local_dir, \@files);

    for my $file (@files) {
        my $rel_path = $file;
        $rel_path =~ s/^\Q$local_dir\E\/?//;

        my $ws_file = "$ws_path/$rel_path";
        print "Uploading: $file -> $ws_file\n";

        if ($app && $app->can('workspace')) {
            try {
                # Determine file type for workspace
                my $type = "txt";
                if ($file =~ /\.(pdb|cif|mmcif)$/i) {
                    $type = "structure";
                } elsif ($file =~ /\.json$/i) {
                    $type = "json";
                }

                # Pass type and enable overwrite
                $app->workspace->save_file_to_file($file, {}, $ws_file, $type, 1);
            } catch {
                warn "Failed to upload $file: $_\n";
            };
        }
    }
}

=head2 find_files

Recursively find all files in a directory.

=cut

sub find_files {
    my ($dir, $files) = @_;

    opendir(my $dh, $dir) or return;
    while (my $entry = readdir($dh)) {
        next if $entry =~ /^\./;
        my $path = "$dir/$entry";
        if (-d $path) {
            find_files($path, $files);
        } else {
            push @$files, $path;
        }
    }
    closedir($dh);
}

__END__

=head1 OUTPUT

The script produces PDB files with stability probabilities encoded in the B-factor column:

=over 4

=item * C<*_proline.pdb> - Proline mutation probabilities (0-1)

Higher values indicate residues more favorable for proline substitution.

=item * C<*_disulfide.pdb> - Disulfide bond formation probabilities (0-1)

Higher values on cysteine residues indicate higher likelihood of participating
in a disulfide bond.

=back

=head1 AUTHOR

BV-BRC Team

=head1 LICENSE

MIT License (following stabiliNNator licensing)

=cut
