#!/usr/bin/perl 
use strict;
use warnings;
use Data::Dumper;
use File::Path;
use Getopt::Long;
use File::Spec;
use Text::CSV_XS qw(csv);
use LWP::Simple;
use XML::Simple;
use Encode;
use Cache::File;
use Bio::SeqIO;
use IO::String;

my $base = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/';
my $trace_wgs_base = 'http://www.ncbi.nlm.nih.gov/Traces/wgs/?download=%s.%d.gbff.gz';
my $SLEEP_TIME = 1;
my $cache_dir = "eutils_".$ENV{USER}.".cache";
my $cache_filehandle;
my $cache_keep_time = '2 day';

my $CURL = 'curl';

my $force = 0;
my $debug = 0;
my $retmax = 1000;
my $runonce = 0;
my $use_cache = 1;

my $basedir = 'download';
my $fast;
GetOptions(
    'runonce!'  => \$runonce,
    'fast!'     => \$fast,
    'retmax:i'  => \$retmax,
    'f|force!'  => \$force, # force downloads even if file exists
    'cache!'    => \$use_cache,
    'v|d|debug|verbose!'   => \$debug,
    'f|force!'             => \$force,
    'b|basedir:s'          => \$basedir);

mkdir($basedir) unless -d $basedir;
my $ncbi_id_file = shift || 'lib/organisms.csv';

my $db = 'nuccore';
#$SLEEP_TIME = 0 if $debug; # let's not wait when we are debugging
if( $use_cache ) {
    &init_cache();
}

my $xs = XML::Simple->new;
my $csv = Text::CSV_XS->new ({ binary => 1, auto_diag => 1 });
open my $fh, "<:encoding(utf8)", $ncbi_id_file or die "$ncbi_id_file: $!";

my %orgs;
my %gbk_targets;
my $header = $csv->getline ($fh);
my %header;
my $x = 0;
for my $r ( @$header ) {
    $r =~ s/^\#//;
    warn("storing $r \n");
    $header{ $r } = $x++;
}

while (my $row = $csv->getline ($fh)) {
    next if( $row->[0] =~ /^\#/);
    my $species = $row->[ $header{Species} ];
# Species,Strain,Family,Source,Accession,PMID,Notes
    if( $species =~ s/\s+$// ) {
	warn("trailing space $species\n");
    }
    $orgs{$species} = { 'strain' => $row->[ $header{Strain} ],
			'family' => $row->[ $header{Family} ],
			'source' => $row->[ $header{Source} ],
			'accessions' => $row->[ $header{Accession}] };
    if( $row->[$header{Source} ] =~ /GB/ ) {
	# keep track of the species which we would like to get from GenBank
	$gbk_targets{$species} = 1;
    }
}
my $one = 0;
for my $species ( keys %orgs ) {
    my ($family, $strain, $source,
	$accessions) = map { $orgs{$species}->{$_} } qw(family strain source accessions);
    
    next if ! $accessions;
    next if $source !~ /GB/;
    warn("family is $family species is $species accession is $accessions\n");
    my $speciesnospaces = $species;
    if( $strain ) {
	$speciesnospaces .= "_$strain";
    }
    $speciesnospaces =~ s/[\s\/#]/_/g;
    warn("processing $speciesnospaces\n") if $debug;
    my $targetdir = File::Spec->catfile($basedir,$family,$speciesnospaces,"gbk");
    next if( $fast && -d $targetdir );
    mkpath($targetdir);
    my %acc_query;
    my @targetfiles;
    if ( $source eq 'GB' && $accessions !~ /\-/ ) {
	my $test_target = File::Spec->catfile($targetdir,"$accessions.gbk.gz");
	if( -f $test_target ) {
	    warn("see $test_target -- skipping this $source for $species. rm file if you want to re-download the collection for this master accession\n");
	    next;
	}
    }
    
    for my $pair ( split(/;/,$accessions) ) {
        my ($start,$finish) = split(/-/,$pair);
        my ($s_letter,$s_number, $f_letter,$f_number);
        my $nl;
        if( $start =~ /^([A-Za-z_]+)(\d+)/ ) {
            $nl = length($2);
            ($s_letter,$s_number) = ($1,$2);
        } else {
            warn("Cannot process accession pair $pair\n");
            next;
        }
	$acc_query{$s_letter}->{nl} = $nl;
        if( $finish ) {
            if( $finish =~ /^([A-Za-z_]+)(\d+)/ ) {
                ($f_letter,$f_number) = ($1,$2);
            }  else {
                warn("Cannot process accession pair $pair\n");
                next;
            }
            if( $f_letter ne $s_letter ) {
                warn("Accession set does not match in $pair ($f_letter, $s_letter)\n");
                next;
            }
            for(my $i = $s_number; $i <= $f_number; $i++) {
		my $acc = sprintf("%s%0".$nl."d",$s_letter,$i);
		my $target = File::Spec->catfile($targetdir,"$acc.gbk.gz");
                if( ! -f $target ) { 
		    $acc_query{$s_letter}->{n}->{$i}++;
		    warn("$acc.gbk.gz missing going to request it\n") if $debug;
                } else {
		    push @targetfiles, $target;
#		    warn("I see $acc.gb.gz, skipping\n") if $debug;
		}
            }
        } else {
	    my $targetfile = File::Spec->catfile($targetdir,"$start.gbk.gz");
	    push @targetfiles, $targetfile;
            next if -f $targetfile;
	    $acc_query{$s_letter}->{n}->{$s_number}++;
        }
    }
    next unless keys %acc_query;
    my @qstring;
    for my $l ( keys %acc_query ) {
	my @nums = sort { $a <=> $b } map { int($_) } keys %{$acc_query{$l}->{n}};
	my @collapsed = collapse_nums(@nums);
	my $nl = $acc_query{$l}->{nl};
	warn("nl is $nl for $l and nums are @nums\n") if $debug;
	for my $nm ( @collapsed ) {
	    if( $nm =~ /[-]/ ) {		
		my ($from,$to) = split('-',$nm);
		$from = sprintf("%s%0".$nl."d",$l,$from);
		$to = sprintf("%s%0".$nl."d",$l,$to);
		push @qstring,sprintf("%s:%s",$from,$to)
	    } else {
		my $nm2 = sprintf("%s%0".$nl."d",$l,$nm);
		warn("nm2 is $nm2\n") if $debug;
		push @qstring, sprintf("%s",$nm2);
	     }
	}
    }
    while ( @qstring ) {
	for my $set ( [splice(@qstring,0,$retmax)] ) {
	    my $qstring = join(" OR ", @$set); #  . " " . join(" ",@not);
	    warn("Query: $qstring for $species\n") if $debug;	    
	    my $url = sprintf('esearch.fcgi?db=nuccore&tool=bioperl&retmax=%d&term=%s',$retmax,$qstring);
	    #delete_cache($base,$url);
	    my $output = get_web_cached($base,$url);
	    my $simplesum;
	    eval {
		$simplesum = $xs->XMLin($output);
	    };
	    if( $@ ) {
		delete_cache($base,$url);
		next;
	    }
	    my $ids = $simplesum->{IdList}->{Id};
	    if( ref($ids) !~ /ARRAY/ ) {
		$ids = [$ids];
	    }
	    warn("ids are @$ids\n");
	    for my $id ( @$ids ) {
		next if ! $id;
		if( $source eq 'GB' ) {
		    $url = sprintf('efetch.fcgi?retmode=text&rettype=gbwithparts&db=nuccore&tool=bioperl&retmax=%d&id=%s',$retmax,$id);
		} else {
		    $url = sprintf('efetch.fcgi?retmode=text&rettype=gb&db=nuccore&tool=bioperl&retmax=%d&id=%s',$retmax,$id);		    
		}
		warn("url is $url\n") if $debug;
		sleep $SLEEP_TIME;
		if( $output = get_web_cached($base,$url) ) {
		    my ($acc);
		    my $io = IO::String->new($output);
		    while(<$io>) {
			if( /^ACCESSION\s+(\S+)/ ) {
			    $acc = $1;
			    last;
			} elsif(/^FEATURES/) {
			    last;
			}
		    }
		    unless( $acc ) {
			warn("no Accession for $id\n");
			$acc = $id;
		    }
		    my $targetfile = File::Spec->catfile($targetdir,"$acc.gbk.gz");
		    open(my $ofh => "| gzip -c > $targetfile") || die $!;
		    print $ofh $output;
		    push @targetfiles, $targetfile;
		    $one++;
		    close($ofh);
		}
	    }
	}
	last if $runonce && $one;
    }

    if( $source eq 'GB-WGS') {
	my $targetfile;
	if( @targetfiles == 1 ) {
	    ($targetfile) = @targetfiles;
	} else {
	    warn("too many targetfiles '@targetfiles'\n");
	    next;
	}
	if( -f $targetfile ) {
	    open(my $tfile => "zcat $targetfile | ") || die $!;
	    my ($locus,$acc,$version,@range);
	    while(<$tfile>) {
		if( /^LOCUS\s+(\S+)/ ) {
		    $locus = $1;
		} elsif( /^ACCESSION\s+(\S+)(.+)/ ) {
		    $acc = $1;
		    my (undef,$secondary) = split(/\s+/,$2);
		    if( $secondary ) {
			warn("got secondary $secondary\n") if $debug;
		    }
		} elsif( /^VERSION\s+(\S+)/ ) {
		    my ($p,$ver) = split(/\./,$1);
		    $version = $ver;
		} elsif(/^WGS\s+(\S+)/) {
		    push @range, $1;
		}
	    }
	    unless( $acc && $locus ) {
		warn("no Accession or Locus for $targetfile\n");
		next;
	    }
	
	    my $asm_prefix = substr($locus,0,6);
	    my $url = sprintf($trace_wgs_base,$asm_prefix,$version);
	    warn("source is $source and prefix is $asm_prefix url is $url locus is $locus\n");
	    my $outasm = File::Spec->catfile($targetdir,sprintf("$asm_prefix.$version.gbff.gz"));
	    if( ! -f $outasm ) {
		warn("getting $url --> $outasm\n");
		`$CURL -C - -o $outasm $url`;     
	    }
	} else {
	    warn("no Targetfile $targetfile\n");
	}
    } else {
	warn("source $source is ignored\n");
    }
    last if $runonce && $one;
}


sub collapse_nums {
#------------------
# This is probably not the slickest connectivity algorithm, but will do for now.
    my @a = @_;
    my ($from, $to, $i, @ca, $consec);
    if( scalar @a == 1 ) {
	return @a;
    }
    $consec = 0;
    for($i=0; $i < @a; $i++) {
	not $from and do{ $from = $a[$i]; next; };
	if($a[$i] == $a[$i-1]+1) {
	    $to = $a[$i];
	    $consec++;
	} else {
	    if($consec == 1) { $from .= ",$to"; }
	    else { $from .= $consec>1 ? "\-$to" : ""; }
	    push @ca, split(',', $from);
	    $from =  $a[$i];
	    $consec = 0;
	    $to = undef;
	}
    }
    if(defined $to) {
	if($consec == 1) { $from .= ",$to"; }
	else { $from .= $consec>1 ? "\-$to" : ""; }
    }
    push @ca, split(',', $from) if $from;
    @ca;
}

sub init_cache {
    if( ! $cache_filehandle ) {
	mkdir($cache_dir) unless -d $cache_dir;
	$cache_filehandle = Cache::File->new( cache_root => $cache_dir);
    }
}

sub get_web_cached {
    my ($base,$url) = @_;
    if( ! defined $base || ! defined $url ) {
	die("need both the URL base and the URL stem to proceed\n");
    }
    unless( $use_cache ) {
	sleep $SLEEP_TIME;
	return get($base.$url);
    }
    my $val = $cache_filehandle->get($url); 
    unless( $val ) {
	warn("$base$url not in cache\n") if $debug;
	$val = encode("utf8",get($base.$url));
	sleep $SLEEP_TIME;
	$cache_filehandle->set($url,$val,$cache_keep_time);
    }
    return decode("utf8",$val);
}

sub delete_cache {
    my ($base,$url) = @_;
    return unless $use_cache;

    if( ! defined $base || ! defined $url ) {
	die("need both the URL base and the URL stem to proceed\n");
    }

    $cache_filehandle->remove($base.$url);
}
