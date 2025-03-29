#!/usr/bin/perl -w
use strict;
use POSIX qw(ceil);

# /tmp/custom-image-cuda-pre-init-2-0-debian10-2024-11-14-20-00-20241114-200043/logs/workflow.log
# /tmp/custom-image-dataproc-2-0-deb10-20250422-193049-secure-boot-20250422-193247
my $fn = $ARGV[0];
my( @matches ) =
  ( $fn =~
    m{custom-image-dataproc-
       (
	 \d+-\d+-(?:deb|roc|ubu)\d+
       )-
       (\d{8}-\d{6})-(.+)-(\d{8}-\d{6})
    }x
  );
#print "matches: @matches\n";
my($short_dp_ver, $timestamp, $purpose, $another_timestamp)=@matches;
$short_dp_ver =~ s/-/./;

my $dp_version = $short_dp_ver;
$dp_version =~ s/deb/debian/;
$dp_version =~ s/roc/rocky/;
$dp_version =~ s/ubu/ubuntu/;

my @raw_lines = <STDIN>;
my( $l ) = grep { m: /dev/.*/\s*$: } @raw_lines;

exit 0 unless $l;

my( $stats ) = ( $l =~ m:\s*/dev/\S+\s+(.*?)\s*$: );
$stats =~ s:(\d{4,}):sprintf(q{%7s}, sprintf(q{%.2fG},($1/1024)/1024)):eg;

my $max_regex = qr/ maximum-disk-used:\s+(\d+)/;
my($max)   = map { /$max_regex/ ; $1 } grep { /$max_regex/ } @raw_lines;
my($gbmax) = ceil((($max / 1024) / 1024) * 1.15);
$gbmax     = 30 if $gbmax < 30;
my $i_dp_version = sprintf(q{%-15s}, qq{"$dp_version"});
print( qq{  $i_dp_version) disk_size_gb="$gbmax" ;; # $stats # $timestamp-$purpose}, $/ );
