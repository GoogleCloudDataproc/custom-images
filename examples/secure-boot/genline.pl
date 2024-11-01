#!/usr/bin/perl -w
use strict;
use POSIX qw(ceil);

my $fn = $ARGV[0];
my( $config, $purpose, $dp_version, $timestamp ) =
  ( $fn =~
    qr{custom-image-
       (
	 ([^-]+)-
	 (\d+-\d+-(debian|rocky|ubuntu)\d+)
       )-
       (\d{4}(?:-\d{2}){4})
    }x
  );
$dp_version =~ s/-/./;

my @raw_lines = <STDIN>;
my( $l ) = grep { m: /dev/.*/\s*$: } @raw_lines;
my( $stats ) = ( $l =~ m:\s*/dev/\S+\s+(.*?)\s*$: );
$stats =~ s:(\d{4,}):sprintf(q{%-6s}, sprintf(q{%.2fG},($1/1024)/1024)):eg;

my($max)   = map { / maximum-disk-used: (\d+)/ } @raw_lines;
my($gbmax) = ceil((($max / 1024) / 1024) * 1.03);
$gbmax     = 30 if $gbmax < 30;
my $i_dp_version = sprintf(q{%-15s}, qq{"$dp_version"});
print( qq{  $i_dp_version) disk_size_gb="$gbmax" ;; # $stats # $purpose}, $/ );
