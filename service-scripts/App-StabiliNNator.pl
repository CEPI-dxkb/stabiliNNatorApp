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
use Cwd 'abs_path';
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

    # Collapse NMR / multi-model ensembles to the first model. The GNN tools
    # otherwise treat every model as extra residues (e.g. a 38-model, 20-residue
    # ensemble becomes 760 concatenated residues).
    strip_to_first_model($local_input) if $file_format eq 'PDB';

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

    # Generate user-friendly ranked summaries (TSV per analysis + combined JSON)
    # from the annotated PDBs. Non-fatal: the annotated PDBs are the primary
    # deliverable and must still upload even if summarization fails.
    try {
        generate_summaries(\@output_files, $output_dir, $input_basename, $analysis_type);
    } catch {
        warn "Summary generation failed (continuing with PDB outputs): $_\n";
    };

    # Upload results to workspace
    my $output_path = $params->{output_path};
    die "Output path is required\n" unless $output_path;

    # Generate a self-contained HTML report from the outputs. Runs after the
    # summaries so they are listed in the report's downloads. Non-fatal: the
    # data files must still upload if report generation fails.
    try {
        generate_html_report($output_dir, $input_basename, $analysis_type,
            $local_input, $output_path, $device, ($hidden_dim // 32),
            $prolinnator_model, $disulfinnate_model, ($params->{theme} // 'bvbrc'));
    } catch {
        warn "HTML report generation failed (continuing with data outputs): $_\n";
    };

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

=head2 strip_to_first_model

If a PDB contains multiple MODEL records (e.g. an NMR ensemble), rewrite it in
place keeping only the first model. Records before the first MODEL (header) are
retained. No-op for single-model files.

=cut

sub strip_to_first_model {
    my ($file) = @_;

    my @lines = read_file($file);
    my $n_models = grep { /^MODEL\s/ } @lines;
    return if $n_models <= 1;

    print "Input has $n_models models; keeping first model only\n";

    my @out;
    my $seen = 0;
    for my $l (@lines) {
        if ($l =~ /^MODEL\s/) {
            $seen++;
            last if $seen > 1;   # start of second model
            next;                # drop the MODEL record itself
        }
        last if $seen >= 1 && $l =~ /^ENDMDL/;
        push @out, $l;
    }
    write_file($file, @out);
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
                    $type = "pdb";
                } elsif ($file =~ /\.json$/i) {
                    $type = "json";
                } elsif ($file =~ /\.html?$/i) {
                    $type = "html";
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

=head2 parse_pdb_residue_scores

Parse an annotated PDB and return one probability per residue.

stabiliNNator writes the per-residue probability (0-1) into the B-factor column
of every atom of a standard amino-acid residue; all atoms of a residue share the
same value. We read the CA atom of each residue as the single representative.
HETATM and non-standard records are ignored (their B-factors are not meaningful
here). Returns an arrayref of hashes: { chain, pos, icode, resname, prob }.

=cut

sub parse_pdb_residue_scores {
    my ($pdb_file) = @_;

    my @rows;
    my $content = read_file($pdb_file);
    for my $line (split /\n/, $content) {
        next unless $line =~ /^ATOM/;              # ATOM records only, skip HETATM
        my $atom = _trim(substr($line, 12, 4));
        next unless $atom eq 'CA';                 # one representative per residue

        my $resname = _trim(substr($line, 17, 3));
        my $chain   = _trim(substr($line, 21, 1));
        my $resseq  = _trim(substr($line, 22, 4));
        my $icode   = _trim(substr($line, 26, 1));
        my $bfactor = _trim(substr($line, 60, 6));

        next unless length $bfactor && $bfactor =~ /^-?\d+(?:\.\d+)?$/;

        push @rows, {
            chain   => ($chain ne '' ? $chain : '-'),
            pos     => $resseq,
            icode   => $icode,
            resname => $resname,
            prob    => $bfactor + 0,
        };
    }

    return \@rows;
}

sub _trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

=head2 rank_sites

Given parsed residue rows and an analysis type, return the rows sorted by
probability descending, filtered as appropriate for the analysis:

  * proline  - all standard residues (existing PRO kept, flagged by caller)
  * disulfide - only CYS/CYX residues (the model annotates every residue, but
    only cysteines are biologically meaningful for disulfide formation)

=cut

sub rank_sites {
    my ($rows, $analysis) = @_;

    my @filtered = @$rows;
    if ($analysis eq 'disulfide') {
        @filtered = grep { $_->{resname} =~ /^(?:CYS|CYX)$/ } @filtered;
    }

    return [ sort { $b->{prob} <=> $a->{prob} } @filtered ];
}

=head2 write_summary_tsv

Write a ranked, human-readable TSV for one analysis.

=cut

sub write_summary_tsv {
    my ($ranked, $out_path, $analysis) = @_;

    my @lines;
    if ($analysis eq 'proline') {
        push @lines, join("\t", qw(rank chain pos residue probability note));
    } else {
        push @lines, join("\t", qw(rank chain pos residue probability));
    }

    my $rank = 0;
    for my $r (@$ranked) {
        $rank++;
        my $pos = $r->{pos} . ($r->{icode} ne '' ? $r->{icode} : '');
        my $prob = sprintf("%.2f", $r->{prob});
        if ($analysis eq 'proline') {
            my $note = ($r->{resname} eq 'PRO') ? 'already PRO' : '';
            push @lines, join("\t", $rank, $r->{chain}, $pos, $r->{resname}, $prob, $note);
        } else {
            push @lines, join("\t", $rank, $r->{chain}, $pos, $r->{resname}, $prob);
        }
    }

    write_file($out_path, join("\n", @lines) . "\n");
    print "Wrote summary: $out_path (" . scalar(@$ranked) . " sites)\n";
}

=head2 sites_to_json_list

Convert ranked rows into a compact list of site hashes for the JSON summary,
capped at $limit entries for UI compactness.

=cut

sub sites_to_json_list {
    my ($ranked, $limit) = @_;

    my @sites;
    my $rank = 0;
    for my $r (@$ranked) {
        last if defined $limit && $rank >= $limit;
        $rank++;
        push @sites, {
            rank        => $rank,
            chain       => $r->{chain},
            pos         => ($r->{pos} + 0),
            icode       => $r->{icode},
            residue     => $r->{resname},
            probability => ($r->{prob} + 0),
            ($r->{resname} eq 'PRO' ? (note => 'already PRO') : ()),
        };
    }
    return \@sites;
}

=head2 generate_summaries

Produce ranked summary artifacts from the annotated PDB outputs: a TSV per
analysis plus a single combined JSON. All files are written into $output_dir so
they are picked up automatically by upload_results/find_files.

=cut

sub generate_summaries {
    my ($output_files, $output_dir, $input_basename, $analysis_type) = @_;

    my $TOP_N = 25;   # cap for JSON site lists; TSV keeps the full ranking
    my %summary = (
        input         => "$input_basename.pdb",
        analysis_type => $analysis_type,
    );

    for my $pdb (@$output_files) {
        my $analysis;
        if    ($pdb =~ /_proline\.pdb$/)   { $analysis = 'proline' }
        elsif ($pdb =~ /_disulfide\.pdb$/) { $analysis = 'disulfide' }
        else  { next }

        my $rows   = parse_pdb_residue_scores($pdb);
        my $ranked = rank_sites($rows, $analysis);

        my $tsv_path = "$output_dir/${input_basename}_${analysis}_summary.tsv";
        write_summary_tsv($ranked, $tsv_path, $analysis);

        my $key = ($analysis eq 'proline') ? 'top_sites' : 'cys_sites';
        $summary{$analysis} = { $key => sites_to_json_list($ranked, $TOP_N) };
    }

    my $json_path = "$output_dir/${input_basename}_summary.json";
    write_file($json_path, to_json(\%summary, { pretty => 1, canonical => 1 }));
    print "Wrote summary: $json_path\n";
}

=head2 generate_html_report

Produce a self-contained HTML report from the run's outputs by filling the
report template with a JSON data blob (delegated to report/generate_report.py).
The report is written into $output_dir alongside the data files so it is
uploaded automatically, and links to those sibling files. Non-fatal.

=cut

sub generate_html_report {
    my ($output_dir, $basename, $analysis_type, $input_file, $ws_path,
        $device, $hidden_dim, $pro_model, $dis_model, $theme) = @_;

    # Locate the report template + generator within the module. Overridable via
    # STABILINNATOR_MODULE_DIR; otherwise derived from this script's location.
    my $module_dir = $ENV{STABILINNATOR_MODULE_DIR}
        // dirname(dirname(abs_path(__FILE__)));

    # Theme registry -> template file. Default is the BV-BRC theme. Add new
    # themes (e.g. 'cepi') here alongside their template file.
    my %theme_template = (
        bvbrc     => "report_template_bvbrc.html",
        editorial => "report_template.html",
    );
    my $tpl_file = $theme_template{$theme // 'bvbrc'} // $theme_template{bvbrc};
    my $template = "$module_dir/report/$tpl_file";
    my $script   = "$module_dir/report/generate_report.py";
    unless (-f $template && -f $script) {
        warn "Report template/script not found under $module_dir/report; skipping HTML report\n";
        return;
    }

    my $report  = "$output_dir/${basename}_report.html";
    my $pro_pdb = "$output_dir/${basename}_proline.pdb";
    my $dis_pdb = "$output_dir/${basename}_disulfide.pdb";

    # Record the exact upstream tool commit for provenance (the source is a git
    # clone at STABILINNATOR_DIR). Best-effort; empty if git/clone unavailable.
    my $stabilinnator_dir = $ENV{STABILINNATOR_DIR} // "/opt/stabilinnator";
    my $src_commit = `git -C $stabilinnator_dir rev-parse --short HEAD 2>/dev/null`;
    chomp $src_commit;

    my @cmd = ("python", $script,
        "--template",       $template,
        "--output",         $report,
        "--input",          $input_file,
        "--workspace-path", $ws_path,
        "--hidden-dim",     $hidden_dim,
        "--device",         $device,
        "--container",      "dxkb/stabilinnator-bvbrc",
        "--link-mode",      "relative",
        "--source-repo",    "https://github.com/schoederlab/stabiliNNator",
    );
    push @cmd, "--source-commit", $src_commit if $src_commit;
    push @cmd, "--proline",   $pro_pdb, "--proline-model",   $pro_model if -f $pro_pdb;
    push @cmd, "--disulfide", $dis_pdb, "--disulfide-model", $dis_model if -f $dis_pdb;

    print "Generating HTML report: " . join(" ", @cmd) . "\n";
    my $rc = system(@cmd);
    if ($rc != 0) {
        warn "Report generator exited with code " . ($rc >> 8) . "\n";
    } elsif (-f $report) {
        print "Wrote report: $report\n";
    }
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
