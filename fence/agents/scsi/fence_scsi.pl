#!/usr/bin/perl

use Cwd 'realpath';
use File::Basename;
use File::Path;
use Getopt::Std;
use POSIX;
use B;

#BEGIN_VERSION_GENERATION
$RELEASE_VERSION="";
$REDHAT_COPYRIGHT="";
$BUILD_DATE="";
#END_VERSION_GENERATION

my $ME = fileparse ($0, ".pl");

################################################################################

sub log_debug ($)
{
    my $time = strftime "%b %e %T", localtime;
    my ($msg) = @_;

    print STDOUT "$time $ME: [debug] $msg\n" unless defined ($opt_q);

    return;
}

sub log_error ($)
{
    my $time = strftime "%b %e %T", localtime;
    my ($msg) = @_;

    print STDERR "$time $ME: [error] $msg\n" unless defined ($opt_q);

    exit (1);
}

sub do_action_on ($@)
{
    my $self = (caller(0))[3];
    my ($node_key, @devices) = @_;

    key_write ($node_key);

    foreach $dev (@devices) {
	log_error ("device $dev does not exist") if (! -e $dev);
	log_error ("device $dev is not a block device") if (! -b $dev);

	if (do_register_ignore ($node_key, $dev) != 0) {
	    log_error ("failed to create registration (key=$node_key, device=$dev)");
	}

	if (!get_reservation_key ($dev)) {
	    if (do_reserve ($node_key, $dev) != 0) {
		if (!get_reservation_key ($dev)) {
		    log_error ("failed to create reservation (key=$node_key, device=$dev)");
		}
	    }
	}
    }

    return;
}

sub do_action_off ($@)
{
    my $self = (caller(0))[3];
    my ($node_key, @devices) = @_;

    my $host_key = key_read ();

    if ($host_key eq $node_key) {
	log_error ($self);
    }

    foreach $dev (@devices) {
	log_error ("device $dev does not exist") if (! -e $dev);
	log_error ("device $dev is not a block device") if (! -b $dev);

	my @keys = grep { /^$node_key$/i } get_registration_keys ($dev);

	if (scalar (@keys) != 0) {
	    do_preempt_abort ($host_key, $node_key, $dev);
	}
    }

    return;
}

sub do_action_status ($@)
{
    my $self = (caller(0))[3];
    my ($node_key, @devices) = @_;

    my $dev_count = 0;
    my $key_count = 0;

    foreach $dev (@devices) {
	log_error ("device $dev does not exist") if (! -e $dev);
	log_error ("device $dev is not a block device") if (! -b $dev);

	do_reset ($dev);

	my @keys = grep { /^$node_key$/i } get_registration_keys ($dev);

	if (scalar (@keys) != 0) {
	    $dev_count++;
	}
    }

    if ($dev_count != 0) {
	exit (0);
    } else {
	exit (2);
    }
}

sub do_verify_on ($@)
{
    my $self = (caller(0))[3];
    my ($node_key, @devices) = @_;
    my $count = 0;

    for $dev (@devices) {
        my @keys = grep { /^$node_key$/i } get_registration_keys ($dev);

        ## check that our key is registered
        if (scalar (@keys) == 0) {
            log_debug ("failed to register key $node_key on device $dev");
            $count++;
            next;
        }

	## write dev to device file once registration is verified
	dev_write ($dev);

        ## check that a reservation exists
        if (!get_reservation_key ($dev)) {
            log_debug ("no reservation exists on device $dev");
            $count++;
        }
    }

    if ($count != 0) {
        log_error ("$self: failed to verify $count devices");
    }
}

sub do_verify_off ($@)
{
    my $self = (caller(0))[3];
    my ($node_key, @devices) = @_;
    my $count = 0;

    for $dev (@devices) {
        my @keys = grep { /^$node_key$/i } get_registration_keys ($dev);

        ## check that our key is not registered
        if (scalar (@keys) != 0) {
            log_debug ("failed to remove key $node_key from device $dev");
            $count++;
            next;
        }

        ## check that a reservation exists
        if (!get_reservation_key ($dev)) {
            log_debug ("no reservation exists on device $dev");
            $count++;
        }
    }

    if ($count != 0) {
        log_error ("$self: failed to verify $count devices");
    }
}

sub do_register ($$$)
{
    my $self = (caller(0))[3];
    my ($host_key, $node_key, $dev) = @_;

    $dev = realpath ($dev);

    if (substr ($dev, 5) =~ /^dm/) {
	my @slaves = get_mpath_slaves ($dev);
	foreach (@slaves) {
	    do_register ($node_key, $_);
	}
	return;
    }

    log_debug ("$self (host_key=$host_key, node_key=$node_key, dev=$dev)");

    my $cmd;
    my $out;
    my $err;

    do_reset ($dev);

    $cmd = "sg_persist -n -o -G -K $host_key -S $node_key -d $dev";
    $cmd .= " -Z" if (defined $opt_a);
    $out = qx { $cmd 2> /dev/null };
    $err = ($?>>8);

    # if ($err != 0) {
    # 	log_error ("$self (err=$err)");
    # }

    log_debug ("$self (err=$err)");

    return ($err);
}

sub do_register_ignore ($$)
{
    my $self = (caller(0))[3];
    my ($node_key, $dev) = @_;

    $dev = realpath ($dev);

    if (substr ($dev, 5) =~ /^dm/) {
	my @slaves = get_mpath_slaves ($dev);
	foreach (@slaves) {
	    do_register_ignore ($node_key, $_);
	}
	return;
    }

    log_debug ("$self (node_key=$node_key, dev=$dev)");

    my $cmd;
    my $out;
    my $err;

    do_reset ($dev);

    $cmd = "sg_persist -n -o -I -S $node_key -d $dev";
    $cmd .= " -Z" if (defined $opt_a);
    $out = qx { $cmd 2> /dev/null };
    $err = ($?>>8);

    # if ($err != 0) {
    # 	log_error ("$self (err=$err)");
    # }

    log_debug ("$self (err=$err)");

    return ($err);
}

sub do_reserve ($$)
{
    my $self = (caller(0))[3];
    my ($host_key, $dev) = @_;

    log_debug ("$self (host_key=$host_key, dev=$dev)");

    my $cmd = "sg_persist -n -o -R -T 5 -K $host_key -d $dev";
    my $out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    # if ($err != 0) {
    # 	log_error ("$self (err=$err)");
    # }

    log_debug ("$self (err=$err)");

    return ($err);
}

sub do_release ($$)
{
    my $self = (caller(0))[3];
    my ($host_key, $dev) = @_;

    log_debug ("$self (host_key=$host_key, dev=$dev)");

    my $cmd = "sg_persist -n -o -L -T 5 -K $host_key -d $dev";
    my $out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    # if ($err != 0) {
    # 	log_error ("$self (err=$err)");
    # }

    log_debug ("$self (err=$err)");

    return ($err);
}

sub do_preempt ($$$)
{
    my $self = (caller(0))[3];
    my ($host_key, $node_key, $dev) = @_;

    log_debug ("$self (host_key=$host_key, node_key=$node_key, dev=$dev)");

    my $cmd = "sg_persist -n -o -P -T 5 -K $host_key -S $node_key -d $dev";
    my $out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    # if ($err != 0) {
    # 	log_error ("$self (err=$err)");
    # }

    log_debug ("$self (err=$err)");

    return ($err);
}

sub do_preempt_abort ($$$)
{
    my $self = (caller(0))[3];
    my ($host_key, $node_key, $dev) = @_;

    log_debug ("$self (host_key=$host_key, node_key=$node_key, dev=$dev)");

    my $cmd = "sg_persist -n -o -A -T 5 -K $host_key -S $node_key -d $dev";
    my $out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    # if ($err != 0) {
    # 	log_error ("$self (err=$err)");
    # }

    log_debug ("$self (err=$err)");

    return ($err);
}

sub do_reset (S)
{
    my $self = (caller(0))[3];
    my ($dev) = @_;

    my $cmd = "sg_turs $dev";
    my @out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    ## note that it is not necessarily an error is $err is non-zero,
    ## so just log the device and status and continue.

    log_debug ("$self (dev=$dev, status=$err)");

    return ($err);
}

sub dev_unlink ()
{
    my $self = (caller(0))[3];
    my $file = "/var/run/cluster/fence_scsi.dev";

    if (-e $file) {
	unlink ($file) or die "$!\n";
    }

    return;
}

sub dev_write ($)
{
    my $self = (caller(0))[3];
    my $file = "/var/run/cluster/fence_scsi.dev";
    my $dev = shift;

    if (! -d "/var/run/cluster") {
	mkpath ("/var/run/cluster");
    }

    open (\*FILE, "+>>$file") or die "$!\n";

    ## since the file is opened for read, write and append,
    ## we need to seek to the beginning of the file before grep.

    seek (FILE, 0, 0);

    if (! grep { /^$dev$/ } <FILE>) {
	print FILE "$dev\n";
    }

    close (FILE);

    return;
}

sub key_read ()
{
    my $self = (caller(0))[3];
    my $file = "/var/run/cluster/fence_scsi.key";
    my $key;

    open (\*FILE, "<$file") or die "$!\n";
    chomp ($key = <FILE>);
    close (FILE);

    return ($key);
}

sub key_write ($)
{
    my $self = (caller(0))[3];
    my $file = "/var/run/cluster/fence_scsi.key";
    my $key = shift;

    if (! -d "/var/run/cluster") {
	mkpath ("/var/run/cluster");
    }

    open (\*FILE, ">$file") or die "$!\n";
    print FILE "$key\n";
    close (FILE);

    return;
}

sub get_key ($)
{
    my $self = (caller(0))[3];

    my $key = sprintf ("%.4x%.4x", get_cluster_id (), get_node_id ($_[0]));

    return ($key);
}

sub get_node_id ($)
{
    my $self = (caller(0))[3];
    my $node = $_[0];

    my $cmd = "/usr/sbin/corosync-cmapctl nodelist.";
    my @out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    if ($err != 0) {
	log_error ("$self (err=$err)");
    }

    # die "[error]: $self\n" if ($?>>8);

    foreach my $line (@out) {
        chomp($line);
        if ($line =~ /.(\d+?).ring._addr \(str\) = ${node}$/) {
            return $1;
        }
    }
                                        
    log_error("$self (unable to parse output of corosync-cmapctl or node does not exist)");
}

sub get_cluster_id ()
{
    my $self = (caller(0))[3];
    my $cluster_id;

    my $cmd = "/usr/sbin/corosync-cmapctl totem.cluster_name";
    my $out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    if ($err != 0) {
	log_error ("$self (err=$err)");
    }

    # die "[error]: $self\n" if ($?>>8);

    chomp($out);

    if ($out =~ /=\s(.*?)$/) {
        my $cluster_name = $1;
        # tranform string to a number
        $cluster_id = (hex B::hash($cluster_name)) % 65536;
    } else {
        log_error("$self (unable to parse output of corosync-cmapctl)");
    }

    return ($cluster_id);
}

sub get_devices_clvm ()
{
    my $self = (caller(0))[3];
    my @devices;

    my $cmd = "vgs --noheadings " .
	"    --separator : " .
	"    --sort pv_uuid " .
	"    --options vg_attr,pv_name " .
	"    --config 'global { locking_type = 0 } " .
	"              devices { preferred_names = [ \"^/dev/dm\" ] }'";

    my @out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    if ($err != 0) {
	log_error ("$self (err=$err)");
    }

    # die "[error]: $self\n" if ($?>>8);

    foreach (@out) {
	chomp;
	my ($vg_attr, $pv_name) = split (/:/, $_);
	if ($vg_attr =~ /c$/) {
	    push (@devices, $pv_name);
	}
    }

    return (@devices);
}

sub get_devices_scsi ()
{
    my $self = (caller(0))[3];
    my @devices;

    opendir (\*DIR, "/sys/block/") or die "$!\n";
    @devices = grep { /^sd/ } readdir (DIR);
    closedir (DIR);

    return (@devices);
}

sub get_mpath_name ($)
{
    my $self = (caller(0))[3];
    my ($dev) = @_;
    my $name;

    if ($dev =~ /^\/dev\//) {
	$dev = substr ($dev, 5);
    }

    open (\*FILE, "/sys/block/$dev/dm/name") or die "$!\n";
    chomp ($name = <FILE>);
    close (FILE);

    return ($name);
}

sub get_mpath_uuid ($)
{
    my $self = (caller(0))[3];
    my ($dev) = @_;
    my $uuid;

    if ($dev =~ /^\/dev\//) {
	$dev = substr ($dev, 5);
    }

    open (\*FILE, "/sys/block/$dev/dm/uuid") or die "$!\n";
    chomp ($uuid = <FILE>);
    close (FILE);

    return ($name);
}

sub get_mpath_slaves ($)
{
    my $self = (caller(0))[3];
    my ($dev) = @_;
    my @slaves;

    if ($dev =~ /^\/dev\//) {
	$dev = substr ($dev, 5);
    }

    opendir (\*DIR, "/sys/block/$dev/slaves/") or die "$!\n";

    @slaves = grep { !/^\./ } readdir (DIR);
    if ($slaves[0] =~ /^dm/) {
	@slaves = get_mpath_slaves ($slaves[0]);
    } else {
	@slaves = map { "/dev/$_" } @slaves;
    }

    closedir (DIR);

    return (@slaves);
}

sub get_registration_keys ($)
{
    my $self = (caller(0))[3];
    my ($dev) = @_;
    my @keys;

    my $cmd = "sg_persist -n -i -k -d $dev";
    my @out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    if ($err != 0) {
	log_error ("$self (err=$err)");
    }

    # die "[error]: $self\n" if ($?>>8);

    foreach (@out) {
	chomp;
	if ($_ =~ s/^\s+0x//i) {
	    push (@keys, $_);
	}
    }

    return (@keys);
}

sub get_reservation_key ($)
{
    my $self = (caller(0))[3];
    my ($dev) = @_;
    my $key;

    my $cmd = "sg_persist -n -i -r -d $dev";
    my @out = qx { $cmd 2> /dev/null };
    my $err = ($?>>8);

    if ($err != 0) {
	log_error ("$self (err=$err)");
    }

    # die "[error]: $self\n" if ($?>>8);

    foreach (@out) {
	chomp;
	if ($_ =~ s/^\s+key=0x//i) {
	    $key = $_;
	    last;
	}
    }

    return ($key)
}

sub get_options_stdin ()
{
    my $num = 0;

    while (<STDIN>) {
	chomp;
	s/^\s*//;
	s/\s*$//;

	next if (/^#/);

	$num++;

	next unless ($_);

	my ($opt, $arg) = split (/\s*=\s*/, $_);

	if ($opt eq "") {
	    exit (1);
	}
	elsif ($opt eq "aptpl") {
	    $opt_a = $arg;
	}
	elsif ($opt eq "devices") {
	    $opt_d = $arg;
	}
	elsif ($opt eq "logfile") {
	    $opt_f = $arg;
	}
	elsif ($opt eq "key") {
	    $opt_k = $arg;
	}
	elsif ($opt eq "nodename") {
	    $opt_n = $arg;
	}
	elsif ($opt eq "action") {
	    $opt_o = $arg;
	}
	elsif ($opt eq "delay") {
	    $opt_H = $arg;
	}
    }
}

sub print_usage ()
{
    print "Usage:\n";
    print "\n";
    print "$ME [options]\n";
    print "\n";
    print "Options:\n";
    print "  -a               Use APTPL flag\n";
    print "  -d <devices>     Devices to be used for action\n";
    print "  -f <logfile>     File to write debug/error output\n";
    print "  -H <timeout>     Wait X seconds before fencing is started\n";
    print "  -h               Usage\n";
    print "  -k <key>         Key to be used for current action\n";
    print "  -n <nodename>    Name of node to operate on\n";
    print "  -o <action>      Action: off (default), on, or status\n";
    print "  -q               Quiet mode\n";
    print "  -V               Version\n";

    exit (0);
}

sub print_version ()
{
    print "$ME $RELEASE_VERSION $BUILD_DATE\n";
    print "$REDHAT_COPYRIGHT\n" if ( $REDHAT_COPYRIGHT );

    exit (0);
}

sub print_metadata ()
{
    print "<?xml version=\"1.0\" ?>\n";
    print "<resource-agent name=\"fence_scsi\"" .
          " shortdesc=\"fence agent for SCSI-3 persistent reservations\">\n";
    print "<longdesc>fence_scsi</longdesc>\n";
    print "<vendor-url>http://www.t10.org</vendor-url>\n";
    print "<parameters>\n";
    print "\t<parameter name=\"aptpl\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-a\"/>\n";
    print "\t\t<content type=\"boolean\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "Use APTPL flag for registrations" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "\t<parameter name=\"devices\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-d\"/>\n";
    print "\t\t<content type=\"string\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "List of devices to be used for fencing action" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "\t<parameter name=\"logfile\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-f\"/>\n";
    print "\t\t<content type=\"string\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "File to write error/debug messages" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "\t<parameter name=\"delay\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-H\"/>\n";
    print "\t\t<content type=\"string\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "Wait X seconds before fencing is started" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "\t<parameter name=\"key\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-k\"/>\n";
    print "\t\t<content type=\"string\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "Key value to be used for fencing action" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "\t<parameter name=\"action\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-o\"/>\n";
    print "\t\t<content type=\"string\" default=\"off\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "Fencing action" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "\t<parameter name=\"nodename\" unique=\"0\" required=\"0\">\n";
    print "\t\t<getopt mixed=\"-n\"/>\n";
    print "\t\t<content type=\"string\"/>\n";
    print "\t\t<shortdesc lang=\"en\">" .
          "Name of node" .
          "</shortdesc>\n";
    print "\t</parameter>\n";
    print "</parameters>\n";
    print "<actions>\n";
    print "\t<action name=\"on\" on_target=\"1\" automatic=\"1\"/>\n";
    print "\t<action name=\"off\"/>\n";
    print "\t<action name=\"status\"/>\n";
    print "\t<action name=\"metadata\"/>\n";
    print "</actions>\n";
    print "</resource-agent>\n";

    exit (0);
}

################################################################################

if (@ARGV > 0) {
    getopts ("ad:f:H:hk:n:o:qV") or print_usage;
    print_usage if (defined $opt_h);
    print_version if (defined $opt_V);
} else {
    get_options_stdin ();
}

## handle the metadata action here to avoid other parameter checks
##
if ($opt_o =~ /^metadata$/i) {
    print_metadata;
}

## if the logfile (-f) parameter was specified, open the logfile
## and redirect STDOUT and STDERR to the logfile.
##
if (defined $opt_f) {
    open (LOG, ">>$opt_f") or die "$!\n";
    open (STDOUT, ">&LOG");
    open (STDERR, ">&LOG");
}

## verify that either key or nodename have been specified
##
if ((!defined $opt_n) && (!defined $opt_k)) {
    print_usage ();
}

## determine key value
##
if (defined $opt_k) {
    $key = $opt_k;
} else {
    $key = get_key ($opt_n);
}

## verify that key is not zero
##
if (hex($key) == 0) {
    log_error ("key cannot be zero");
}

## remove any leading zeros from key
##
if ($key =~ /^0/) {
    $key =~ s/^0+//;
}

## get devices
##
if (defined $opt_d) {
    @devices = split (/\s*,\s*/, $opt_d);
} else {
    @devices = get_devices_clvm ();
}

## verify that device list is not empty
##
if (scalar (@devices) == 0) {
    log_error ("no devices found");
}

## default action is "off"
##
if (!defined $opt_o) {
    $opt_o = "off";
}

## Wait for defined period (-H / delay= )
##
if ((defined $opt_H) && ($opt_H =~ /^[0-9]+/)) {
    sleep($opt_H);
}

## determine the action to perform
##
if ($opt_o =~ /^on$/i) {
    do_action_on ($key, @devices);
    do_verify_on ($key, @devices);
}
elsif ($opt_o =~ /^off$/i) {
    do_action_off ($key, @devices);
    do_verify_off ($key, @devices);
}
elsif ($opt_o =~ /^status/i) {
    do_action_status ($key, @devices);
} else {
    log_error ("unknown action '$opt_o'");
    exit (1);
}

## close the logfile
##
if (defined $opt_f) {
    close (LOG);
}
