# =================================================================================================
#     Variant Calling
# =================================================================================================

# Return the bam file(s) for a given sample
def get_sample_bams_wildcard(wildcards):
    """
    Get all aligned reads of given sample, with all its units.
    This is where all units are merged together. The function also automatically gets
    which of the mapping resutls to use, depending on the config setting (whether to remove
    duplicates, and whether to recalibrate the base qualities), by using the get_mapping_result
    function, that gives the respective files depending on the config.
    """
    return expand(get_mapping_result(), sample=wildcards.sample, unit=samples.loc[wildcards.sample].unit)

# Return the bai file(s) for a given sample
def get_sample_bais_wildcard(wildcards):
    return expand(get_mapping_result(True), sample=wildcards.sample, unit=samples.loc[wildcards.sample].unit)

# Combine all params to call gatk. We may want to set regions, we set that bit of multithreading
# that gatk is capable of (not much, but the best we can do without spark...), and we add
# all additional params from the config file.
def get_gatk_call_variants_params(wildcards, input):
    return (
        get_gatk_regions_param(regions=input.regions, default="--intervals '{}'".format(wildcards.contig))
        + " --native-pair-hmm-threads " + str(config["params"]["gatk"]["HaplotypeCaller-threads"]) + " "
        + config["params"]["gatk"]["HaplotypeCaller"]
    )

rule call_variants:
    input:
        bam=get_sample_bams_wildcard,
        bai=get_sample_bais_wildcard,
        ref=config["data"]["reference"]["genome"],
        known=config["data"]["reference"].get("known-variants"), # empty if key not present
        regions="called/{contig}.regions.bed" if config["settings"].get("restrict-regions") else []
    output:
        gvcf=protected("called/{sample}.{contig}.g.vcf.gz")
    log:
        "logs/gatk/haplotypecaller/{sample}.{contig}.log"
    benchmark:
        "benchmarks/gatk/haplotypecaller/{sample}.{contig}.bench.log"
    threads:
        # Need to set threads here so that snakemake can plan the job scheduling properly
        config["params"]["gatk"]["HaplotypeCaller-threads"]
    resources:
        # Increase time limit in factors of 24h, if the job fails due to time limit.
        time = lambda wildcards, input, threads, attempt: int(1440 * int(attempt))
    params:
        # The function here is where the contig variable is propagated to haplotypecaller.
        # Took me a while to figure this one out...
        # Contigs are used as long as no restrict-regions are given in the config file.
        extra=get_gatk_call_variants_params
    group:
        "gatk_call_variants"
    shadow: "full"
    wrapper:
        "0.51.3/bio/gatk/haplotypecaller"

# Stupid GATK sometimes writes out index files, and sometimes not, and it is not clear at all
# when that is happening and when not. Let's try with a rule, and see if it works even if the file
# is present sometimes... hopefully snakemake is smart enough for that.
rule vcf_index_gatk:
    input:
        "called/{file}.g.vcf.gz"
    output:
        "called/{file}.g.vcf.gz.tbi"
    params:
        # pass arguments to tabix (e.g. index a vcf)
        "-p vcf"
    log:
        "logs/tabix/{file}.log"
    group:
        "gatk_call_variants"
    wrapper:
        "0.55.1/bio/tabix"

# =================================================================================================
#     Combining Calls
# =================================================================================================

rule combine_calls:
    input:
        ref=config["data"]["reference"]["genome"],
        gvcfs=expand("called/{sample}.{{contig}}.g.vcf.gz", sample=sample_names),
        indices=expand("called/{sample}.{{contig}}.g.vcf.gz.tbi", sample=sample_names)
    output:
        gvcf=temp("called/all.{contig}.g.vcf.gz")
    log:
        "logs/gatk/combine-gvcfs/{contig}.log"
    benchmark:
        "benchmarks/gatk/combine-gvcfs/{contig}.bench.log"
    group:
        "gatk_calls_combine"
    wrapper:
        "0.51.3/bio/gatk/combinegvcfs"

rule genotype_variants:
    input:
        ref=config["data"]["reference"]["genome"],
        gvcf="called/all.{contig}.g.vcf.gz"
    output:
        vcf=temp("genotyped/all.{contig}.vcf.gz")
    params:
        extra=config["params"]["gatk"]["GenotypeGVCFs"]
    log:
        "logs/gatk/genotype-gvcfs/{contig}.log"
    benchmark:
        "benchmarks/gatk/genotype-gvcfs/{contig}.bench.log"
    group:
        "gatk_calls_combine"
    wrapper:
        "0.51.3/bio/gatk/genotypegvcfs"

# =================================================================================================
#     Merging Variants
# =================================================================================================

rule merge_variants:
    input:
        ref=get_fai(), # fai is needed to calculate aggregation over contigs below
        vcfs=lambda w: expand("genotyped/all.{contig}.vcf.gz", contig=get_contigs())
    output:
        vcf="genotyped/all.vcf.gz"
    log:
        "logs/picard/merge-genotyped.log"
    benchmark:
        "benchmarks/picard/merge-genotyped.bench.log"
    wrapper:
        "0.51.3/bio/picard/mergevcfs"
