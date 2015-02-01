#!/usr/bin/perl

## * Copyright (c) 2008,2009, Chris O'Halloran

#############################################################################
# svnrestore.pl  version .16-beta                                           #
#                                                                           #
# History and information:                                                  #
# http://www.ghostwheel.com/merlin/Personal/notes/svnbackuppl/              #
#                                                                           #
# Synapsis:                                                                 #
#   This script allows you to restore SVN repository backups made with      #
#   svnbackup.pl                                                            #
#   It does not perform incremental restores, only complete ones.           #
#                                                                           #
#   If you absolutely need an incremental restore, the log file created by  #
#   svnbackup.pl is human-readable and the recovery method is documented    #
#   below:                                                                  #
#                                                                           #
# Usage:                                                                    #
#   svnrestore.pl BACKUPDIR REPODIR                                         #
#   The expectation here is that BACKUPDIR contains a backup created by     #
#   svnbackup.pl and that REPODIR is either does not exist or is empty.     #
#                                                                           #
#                                                                           #
# Manual Recovery:                                                          #
#   - use 'svnadmin create' to create a new repository.                     #
#   - use 'svnadmin load' to restore all of the backup files, in order.     #
#   ie:                                                                     #
#      svnadmin create /tmp/test                                            #
#      gzcat 0-100.svnz | svnadmin load /tmp/test                           #
#      gzcat 101-110.svnz | svnadmin load /tmp/test                         #
#                                                                           #
#  To do:                                                                   #
#    - Add better activity messages                                         #
#                                                                           #
#############################################################################
#                                                                           #
# Version .16-beta changes                                                  #
# - Fixed a critical issue where the conf/ and hooks/ directories were not  #
#   being restored to the correct path.                                     #
#                                                                           #
# Version .15-beta changes                                                  #
# - Fixed an issue where moving the backup directory would cause            #
#   svnrestore.pl to see the backup as invalid.                             #
#                                                                           #
# Version .14-beta changes                                                  #
# - Fixed bad logic in the utility file path code.                          #
# - Added a set of common path locations to the search path.                #
#                                                                           #
# Version .13-beta changes                                                  #
# - Improved lock file detection to prevent concurrent execution, and added #
#   a message stating the age of the lockfile if one is found.              #
#                                                                           #
# Version .12-beta changes                                                  #
# - Fixed an incorrect file test operator in svnrestore.pl                  #
#                                                                           #
# Version .11-beta changes                                                  #
# - Added backup and restore of the conf/ and hooks/ directories.           #
# - Preserve and restore the user/group ownership of the SVN repository.    #
#                                                                           #
# Version .10-beta changes                                                  #
# - Added locating utilities from within PATH so that this script should    #
#   run without modification on most systems.                               #
#                                                                           #
# Version .9-beta changes                                                   #
# - Added using /tmp/svnbackup-BACKUPDIR.lock as a lock-file to prevent     #
#   concurrent execution of svnbackup.pl or svnrestore.pl which could       #
#   corrupt backups and prevent complete restores.                          #
# - Added error handling in case the external call to svnadmin fails.       #
#                                                                           #
#############################################################################

#use warnings;
use File::Path;
use Archive::Tar;
use Time::localtime;

$VERSION="Version 0.16-Beta";

## Change to 1 if you want debugging messages.
$DEBUG=1;

## Here is an example of how to specify a location for a particular utility.  
#$UtilLocation{'gunzip'} = '/usr/bin/gunzip';


## Let's make sure there is a good PATH in place when this script runs:
$ENV{'PATH'} .= ':/sbin:/bin:/usr/sbin:/usr/bin:/usr/games:/usr/local/sbin:/usr/local/bin:/opt/bin:/opt/sbin:/opt/local/bin:/opt/local/sbin:~/bin';

## Locate the following utilities for use by the script
@Utils = ('svnlook', 'svnadmin', 'gzip', 'gunzip', 'tar', 'chown');
foreach $Util (@Utils) 
	{

    ##  Populate $UtilLocation{$Util} if it isn't set manually
    if ( !(defined($UtilLocation{$Util})) ) 
		{
		($UtilLocation{$Util} = `which $Util`) =~ s/[\n\r]*//g;
		}      

	## If $UtilLocation{$Util} is still not set, we have to abort.	
	if ( !(defined($UtilLocation{$Util})) || $UtilLocation{$Util} eq "" )
		{
		die("Unable to find $Util in the current PATH.\n");
		}
	elsif ( !(-f $UtilLocation{$Util}) )
		{
		die("$UtilLocation{$Util} is not valid.\n");
		}

	}


## Verify the number of arguments supplied matches the requirements, and prints a usage statement
## if necessary.
if ( @ARGV < 2 )
	{
	print "svnrestore.pl - $VERSION\n";
	print "Insufficient arguments.\n";
	print "Usage:  svnrestore.pl BACKUPDIR REPO-RESTORE-DIR\n\n";
	exit;
	}
$BACKUPDIR = $ARGV[0];
$REPODIR = $ARGV[1];
print "BACKUPDIR: $BACKUPDIR\n" if $DEBUG;
print "REPODIR: $REPODIR\n" if $DEBUG;

($LOCKSUFFIX = $BACKUPDIR) =~ s/\//_/g;
my $LockFile = "/tmp/svnbackup-$LOCKSUFFIX.lock";


if ( -f $LockFile ) {
	## If the lockfile exists, we need to toss up an error and exit.
	my $message = "A lockfile for $BACKUPDIR already exists.\n";
	my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = stat($LockFile);
	my $datetime_string = ctime($mtime);
	$message .= "$LockFile was created at $datetime_string\n";
	die($message);
	}

	
## If the lockfile doesn't exist, then we need to open and lock it.	
open(LOCK, ">$LockFile");
flock(LOCK,2);


## Let's check to see if the supplied BACKUPDIR includes a svnbackup.pl archive
if (-f "$BACKUPDIR/svnbackup.id") {
	## svnbackup.id exists, so let's get A.R. and verify there is a correct svnbackup.log file
	## Might as well read in the relevant content while we are at it, and abort if it is corrupt.
	if (-f "$BACKUPDIR/svnbackup.log") {
		open(LOG, "$BACKUPDIR/svnbackup.log");
		while (<LOG>) {
			if ( $_ =~ m/[0-9]+\t[0-9]+\t.+\/([0-9\-]+\.svnz)$/ ) {
				push(@BACKUPFILES, $1);		  	
		  		}
			else {
				print "ABORT:  $BACKUPDIR/svnbackup.log contains corrupt lines.\n";
				close(LOG);
				&unlockexit;
		  		}
		  	}
		close(LOG);
		}
	else {
		print "ABORT:  Supplied BACKDIR ($BACKUPDIR) does not contain a svnbackup.log file.\n";
		&unlockexit;
		}
	}
else {
	print "ABORT:  Supplied BACKDIR ($BACKUPDIR) does not contain a svnbackup.id file.\n";
	&unlockexit;
	}


## Let's check to see if the supplied REPODIR is viable.  Viable is when it needs to be created, or is empty.
if (-d $REPODIR) {
	print "REPDIRCHECK: $REPODIR exists\n" if $DEBUG;
	## OK, the directory exists, so we need to make sure it is empty.
	opendir(DIR, $REPODIR) or die "can't opendir $REPODIR: $!";
	@FILES = readdir(DIR);
	$CountDirEntries = scalar(@FILES);
	closedir(DIR);
	print "REPDIRCHECK: $CountDirEntries file entries in $REPODIR\n" if $DEBUG;
	if (2 == $CountDirEntries) {
		print "REPDIRCHECK: $REPODIR is ready to go.\n" if $DEBUG;
	}
	else {
		print "REPDIRCHECK: $REPODIR is not empty.\n" if $DEBUG;
		print "Unable to restore to $REPODIR because it is not empty.\n";
		&unlockexit;
	}
}
else {
	## Since it doesn't exist, we will create it.
	print "REPDIRCHECK: Creating $REPODIR\n" if $DEBUG;
	eval { mkpath($REPODIR) };
  	if ($@) {
    	print "Couldn't create $REPODIR: $@\n\n";
    	&unlockexit;
  	}
}



print "$UtilLocation{'svnadmin'} create $REPODIR\n" if $DEBUG;
system("$UtilLocation{'svnadmin'} create $REPODIR");

foreach $BackupFile (@BACKUPFILES) {
	if ( -f "$BACKUPDIR/$BackupFile" ) {
		print "$UtilLocation{'gunzip'} -c $BACKUPDIR/$BackupFile | $UtilLocation{'svnadmin'} load $REPODIR\n" if $DEBUG;
		$status = system("$UtilLocation{'gunzip'} -c $BACKUPDIR/$BackupFile | $UtilLocation{'svnadmin'} load $REPODIR");
		if ( $status != 0) {
			## We have had a problem with svnadmin, and need to abort.  
			print "\n\n\nERROR:  svnadmin command execution failed.\nSVN Repository at $REPODIR is corrupt and should be deleted.\n";
			&unlockexit;
		}
	}
	else {
		print "ABORT RESTORE:  $BACKUPDIR/$BackupFile does not exist.  Can not restore.\n";
		&unlockexit;
	}
} 
	
##  Load the ld repository information for final restoration tasks
open(BACKUPID, "$BACKUPDIR/svnbackup.id");
($OLDREPODIR = <BACKUPID>) =~ s/[\n\r]//g;
($OLDPERMS = <BACKUPID>) =~ s/[\n\r]//g;
close(BACKUPID);



## Restore the config/ and hooks/ directories to the Repository
foreach $SpecialSubDirectory ( ('hooks', 'conf') ) {
	if ( -f "$BACKUPDIR/$SpecialSubDirectory.tgz" ) {
		($StartingPath = "$OLDREPODIR") =~ s/(^\/|\/$)//g;
		my $tar = Archive::Tar->new;
		$tar->read("$BACKUPDIR/$SpecialSubDirectory.tgz") || die ("Unable to open $BACKUPDIR/$SpecialSubDirectory.tgz \n");
		@TarredUp = $tar->list_files;
		foreach $TarFileFullPath ( @TarredUp ) {
			if ( $TarFileFullPath ne "$StartingPath/$SpecialSubDirectory") {
				my $DestPath = '';
				($DestPath = $TarFileFullPath) =~ s/$StartingPath/$REPODIR/xe;
				$tar->extract_file( $TarFileFullPath,   $DestPath );

			}
		}
	}
}
	

	

## Restore the original ownership of the repository
system($UtilLocation{'chown'}, "-R", $OLDPERMS, $REPODIR);


print "\n\nRestore complete!\n";
&unlockexit;




	
sub unlockexit {
	flock(LOCK,8);
	close(LOCK);
	unlink($LockFile);
	exit;
	}