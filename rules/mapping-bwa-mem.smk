# =================================================================================================
#     Read Mapping
# =================================================================================================

rule map_reads:
    input:
        reads=get_trimmed_reads
    output:
        "mapped/{sample}-{unit}.sorted.bam"
    log:
        "logs/bwa-mem/{sample}-{unit}.log"
    benchmark:
        "benchmarks/bwa-mem/{sample}-{unit}.bench.log"
    params:
        index=config["data"]["reference"]["genome"],

        # We need the read group tags, including `ID` and `SM`, as downstream tools use these.
        extra=r"-R '@RG\tID:{sample}\tSM:{sample}'",
        # TODO add LD field as well for the unit?! http://www.htslib.org/workflow/

        sort="samtools",         # Can be 'none', 'samtools' or 'picard'.
        sort_order="coordinate", # Can be 'queryname' or 'coordinate'.
        sort_extra=""            # Extra args for samtools/picard.
    threads:
        config["params"]["bwamem"]["threads"]
    resources:
        # Increase time limit in factors of 2h, if the job fails due to time limit.
        time = lambda wildcards, input, threads, attempt: int(120 * int(attempt))

    # We need a full shadow directory, as `samtools sort` creates a bunch of tmp files that mess
    # up any later attempts, as `samtools sort` terminates if these files are already present.
    # We experimented with all kinds of other solutions, such as setting the `-T` option of
    # `samtools sort` via the `sort_extra` param, and creating and deleting tmp directories for that,
    # but that fails due to issues with snakemake handling directories instead of files...
    # The snakemake shadow rule here seems to do the job. At least, if we understood their mediocre
    # documentation correctly...
    shadow: "full"
    wrapper:
        "0.51.3/bio/bwa/mem"
