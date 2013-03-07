=head1 NAME

Alien::Gnuplot - Find and verify functionality of the gnuplot executable.

=head1 SYNOPSIS

 package MyGnuplotter;

 use strict;

 use Alien::Gnuplot;

 $gnuplot = $Alien::Gnuplot::executable;

 `$gnuplot < /tmp/plotfile`;

 1;

=head1 DESCRIPTION

As an Alien module, Alien::Gnuplot just verifies existence and sanity
of the gnuplot executable.  It doesn't have any methods.  Using
Alien::Gnuplot checks for existence of the executable, and also 
sets several global variables:

=over 3

=item * C<$Alien::Gnuplot::executable> gets the path to the executable that was found.

=item * C<$Alien::Gnuplot::version> gets the self-reported version number of the executable.

=item * C<$Alien::Gnuplot::pl> gets the self-reported patch level.

=item * C<@Alien::Gnuplot::terms> gets a list of the names of all supported terminal devices

=item * C<%Alien::Gnuplot::terms> gets a key for each supported terminal device; values are the 1-line description from gnuplot.

=back

You can point Alien::Gnuplot to a particular path for gnuplot, by
setting the environment variable GNUPLOT_BINARY to the path.

If there is no executable application in your path or in the location
pointed to by GNUPLOT_BINARY, then the module throws an exception.
You can also verify that it has not completed successfully, by
examining $Alien::Gnuplot::version, which is undefined in case of
failure and contains the gnuplot version string on success.

=head1 INSTALLATION STRATEGY

Installation initial work is done by the Makefile.PL, which attempts
to install gnuplot via common package managers on particular
platforms.  If package management fails, Makefile.PL creates a script
to generate a default install of the included gnuplot source code.
(Downloading from the official Sourceforge repository would reduce
load on CPAN, but it is impractical -- Sourceforge obfuscates download
links in a way that confuses LWP and HTTP::Tiny).

=head1 REPOSITORIES

Alien::Gnuplot development is at "http://github.com/drzowie/Alien-Gnuplot".

Gnuplot's main home page is at "http://www.gnuplot.info", and the source code
tarball in src is downloaded from there.

=head1 AUTHOR

Craig DeForest <craig@deforest.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Craig DeForest

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

package Alien::Gnuplot;

use strict;

use File::Temp qw/tempfile/;
use Time::HiRes qw/usleep/;
use POSIX ":sys_wait_h";

# VERSION here is for CPAN to parse -- it is the version of the module itself.  But we
# overload the system VERSION to compare a required version against gnuplot itself, rather
# than against eh module version.

our $VERSION = '1.001';

# On install, try to make sure at least this version is present.
our $GNUPLOT_RECOMMENDED_VERSION = '4.6';  

our $executable;  # Holds the path to the found gnuplot
our $version;     # Holds the found version number
our $pl;          # Holds the found patchlevel
our @terms;
our %terms;

sub VERSION {
    my $module =shift;
    my $req_v = shift;
    unless($req_v <= $version) {
	die qq{

Alien::Gnuplot: Found gnuplot version $version, but you requested $req_v. 
You should upgrade gnuplot, either by reinstalling Alien::Gnuplot or 
getting it yourself from L<http://www.gnuplot.info>.

};
    }
}


##############################
# Search the path for the executable
#
my $exec_path;
if($ENV{'GNUPLOT_BINARY'}) {
   $exec_path = $ENV{'GNUPLOT_BINARY'};
} else {
    my $exec_str = "gnuplot";
    if( defined($ENV{'PATH'}) ) {
	# POSIX path present...
	my @path = split (/\:/,$ENV{'PATH'});
	for my $dir(@path) {
	    $exec_path = "$dir/$exec_str";
	    last if( -x $exec_path );
	}
    } else {
	die "Alien::Gnuplot: No POSIX-style path found, and no GNUPLOT_BINARY environment\nvariable found either\n\n";
    }
}

unless(-x $exec_path) { 
    die q{
Alien::Gnuplot: no executable gnuplot found!  If you have gnuplot,
you can put its exact location in your GNUPLOT_BINARY environment 
variable or make sure your PATH contains it.  If you do not have
gnuplot, you can reinstall Alien::Gnuplot to get it, or get
it yourself from L<http:/www.gnuplot.info>.
};
}


##############################
# Execute the executable to make sure it's really gnuplot, and parse
# out its reported version.  This is complicated by gnuplot's shenanigans
# with STDOUT and STDERR, so we fork and redirect everything to a file.
# The parent process gives the daughter 2 seconds to report progress, then
# kills it dead.
my($pid);
my ($undef, $file) = tempfile('gnuplot_test_XXXX');

$pid = fork();
if(!$pid) {
    # daughter
    open STDOUT, ">$file";
    open STDERR, ">&STDOUT";
    open FOO, "|$exec_path";
    print FOO "show version\nset terminal\n\n\n\n\n\n\n\n\n\n";
    close FOO;
    exit(0);
}
elsif($pid>0) {
    # Poll for 2 seconds, cheesily.
    for (1..20) {
	if(waitpid($pid,WNOHANG)) {
	    $pid=0;
	    last;
	}
	usleep(1e5);
    }

    if($pid) {
	kill 9,$pid;   # zap
	waidpid($pid); # reap
    }
} else {
    die "Couldn't fork!";
}

##############################
# Read what gnuplot had to say, and clean up our mess...
open FOO, "<$file";
my @lines = <FOO>;
unlink $file;


##############################
# Whew.  Now parse out the 'GNUPLOT' and version number...
my $lines = join("", map { chomp $_; $_} @lines);
$lines =~ s/\s+G N U P L O T\s*//  or  die qq{
Alien::Gnuplot: the executable file $exec_path appears not to be gnuplot!  You can 
remove it or set your GNUPLOT_BINARY variable to an actual gnuplot.

};

$lines =~ m/Version (\d+\.\d+) (patchlevel (\d+))?/ or die qq{
Alien::Gnuplot: the executable file $exec_path claims to be gnuplot, but 
I could not parse a verion number from its output.  Sorry, I give up.

};

$version = $1;
$pl = $3;
$executable = $exec_path;


##############################
# Parse out available terminals and put them into the 
# global list and hash.
@terms = ();
%terms = ();
my $reading_terms = 0;
for my $line(@lines) {
    if(!$reading_terms) {
	if($line =~ m/^Available terminal types\:/) {
	    $reading_terms = 1;
	}
    } else {
	next if($line =~ m/^Press return for more/);
	$line =~ m/^\s*(\w+)\s(.*[^\s])\s*$/ || last;
	push(@terms, $1);
	$terms{$1} = $2;
    }
}

1;
