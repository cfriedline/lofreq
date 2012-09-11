#!/bin/bash

# defaults. have to go before usage()
threads=2
var_thresh=0.01
JAVA_EXTRA_ARGS='-Xmx4g'

usage() {
    # keep in sync with arg parsing below
cat <<EOF
$(basename $0): recalibrate base-call quality scores

Wrapper for GATK's recalibration functionality. Sites with variability
above a certain threshold are marked as 'known' SNVs (needed as GATK
input).

Needs GATK version 2! You will have to set the GATKDIR environment
variable to point to your GATK installation.

  Options:
        -i | --bam_in   : input BAM file (indexed)
        -r | --ref_fa   : reference input fasta
        -o | --bam_out  : output BAM file
        -t | --threads  : number of threads to use (optional: default = $threads)
        -v | --vartresh : site with a variation greater than this are marked as 'known SNPs' (optional: default = $var_thresh)
        -h | --help )   : display this help
EOF
}

# defaults
while [ "$1" != "" ]; do
    case $1 in
        -i | --bam_in )
            shift
            bam_in=$1
            ;;
        -o | --bam_out )
            shift
            bam_out=$1
            ;;
        -t | --threads )
            shift
            threads=$1
            ;;
        -v | --vartresh )
            shift
            var_thresh=$1
            ;;
        -r | --ref_fa )
            shift
            ref_fa=$1
            ;;
        -h | --help ) 
            usage
            exit 0
            ;;
        * ) 
            echo "FATAL: unknown argument \"$1\""
            usage
            exit 1
    esac
    shift
done


# make sure all necessary args where given and files exist
#
if [ ! -e $bam_in ] || [ -z $bam_in ]; then
    echo "FATAL: bam input file \"$bam_in\" missing" 1>&2
    echo
    usage
    exit 1
fi
if [ ! -e $ref_fa ] || [ -z $ref_fa ]; then
    echo "FATAL: reference fasta file \"$ref_fa\" missing" 1>&2
    echo
    usage
    exit 1
fi
if [ -z $bam_out ]; then
    echo "FATAL: missing output BAM file argument" 1>&2;
    usage
    exit 1
fi
if [ -e $bam_out ]; then
    echo "FATAL: refusing to overwrite existing BAM file \"$bam_out\"" 1>&2
    usage
    exit 1
fi


# check for required jar files
#
picard_createseqdict_jar=${PICARDDIR}/CreateSequenceDictionary.jar
if [ ! -s $picard_createseqdict_jar ]; then
    echo "FATAL: couldn't find Picard's $(basename $picard_createseqdict_jar). Please set PICARDDIR to your Picard installation" 1>&2
    exit 1
fi
gatk_jar=${GATKDIR}/GenomeAnalysisTK.jar
if [ ! -s $gatk_jar ]; then
    echo "FATAL: couldn't GATK's $(basename $gatk_jar). Please set GATKDIR to your GATK installation" 1>&2
    exit 1
fi

# check for executables
#
for dep in samtools java lofreq_varpos_to_vcf.py; do
    if ! which $dep >/dev/null 2>&1; then
        echo "FATAL: couldn't find $dep. Please make sure it's in your path" 1>&2
        exit 1
    fi
done



test -e ${ref_fa}.fai || \
    samtools faidx $ref_fa || exit 1

vcf=$(dirname $bam_out)/$(basename $bam_in .bam)_t${var_thresh}.vcf
if [ -s $vcf ]; then
	echo "Reusing existing vcf file $vcf" 1>&2
elif [ -s ${vcf}.gz ]; then
	echo "Will unzip and reusing existing vcf file $vcf" 1>&2
    gunzip ${vcf}.gz
else
	samtools mpileup -d 1000000 -B -f $ref_fa $bam_in | \
	    lofreq_varpos_to_vcf.py -t ${var_thresh} -i - -o $vcf || exit 1;
fi


recal=$(dirname $bam_out)/$(basename $bam_in .bam)_recal.csv
if [ -s $recal ]; then
	echo "Reusing existing recal file $recal" 1>&2
else
    log=${recal}.log
    if ! java $JAVA_EXTRA_ARGS -jar $gatk_jar \
        -T BaseRecalibrator \
        -I $bam_in \
        -l INFO \
        -R $ref_fa \
        -nt $threads \
        -knownSites $vcf \
        -o $recal > $log 2>&1; then
        echo "ERROR: GATK's BaseRecalibrator failed. See $log" 1>&2
        exit 1
    fi
fi

log=${bam_out}.log
if ! java $JAVA_EXTRA_ARGS -jar $gatk_jar \
    -T PrintReads \
    -I $bam_in \
    -l INFO \
    -R $ref_fa \
    -BQSR $recal \
    -o $bam_out > $log 2>&1; then
    echo "ERROR: GATK's PrintReads failed. See $log" 1>&2
    exit 1
fi

samtools index $bam_out 

gzip $recal $vcf

#EOF

echo "Successful exit."
