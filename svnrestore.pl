#!/usr/bin/perl

#############################################################################
# svnrestore.pl  version .11-beta                                           #
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


## * Copyright (c) 2008,2009, Chris O'Halloran
## * All rights reserved.
## *
## * Redistribution and use in source and binary forms, with or without
## * modification, are permitted provided that the following conditions are met:
## *     * Redistributions of source code must retain the above copyright
## *       notice, this list of conditions and the following disclaimer.
## *     * Redistributions in binary form must reproduce the above copyright
## *       notice, this list of conditions and the following disclaimer in the
## *       documentation and/or other materials provided with the distribution.
## *     * Neither the name of Chris O'Halloran nor the
## *       names of any contributors may be used to endorse or promote products
## *       derived from this software without specific prior written permission.
## *
## * THIS SOFTWARE IS PROVIDED BY Chris O'Halloran ''AS IS'' AND ANY
## * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
## * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
## * DISCLAIMED. IN NO EVENT SHALL Chris O'Halloran BE LIABLE FOR ANY
## * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
## * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
## * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
## * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
## * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
## * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


use File::Path;
use Archive::Tar;


## Change to 1 if you want debugging messages.
$DEBUG=0;


## Here is an example of how to specify a location for a particular utility.  
#$UtilLocation{'gunzip'} = '/usr/bin/gunzip';

## Locate the following utilities for use by the script
@Utils = ('svnlook', 'svnadmin', 'gzip', 'gunzip', 'tar', 'chown');
foreach $Util (@Utils) 
	{
	if ($UtilLocation{$Util} && (!-f $UtilLocation{$Util}) )
		{
		die ("$Util path is specified ($UtilLocation{$Util}) but is incorrect.\n");
		}
	elsif ( !($UtilLocation{$Util} = `which $Util`) )
		{
		die ("Unable to fine $Util in the current PATH.\n");
		}
	$UtilLocation{$Util} =~ s/[\n\r]*//g;
	print "$Util - $UtilLocation{$Util}\n" if $DEBUG;
	}


## Verify the number of arguments supplied matches the requirements, and prints a usage statement
## if necessary.
if ( @ARGV < 2 )
	{
	print "Insufficient arguments.\n";
	print "Usage:  svnrestore.pl BACKUPDIR REPO-RESTORE-DIR\n\n";
	exit;
	}
$BACKUPDIR = $ARGV[0];
$REPODIR = $ARGV[1];
print "BACKUPDIR: $BACKUPDIR\n" if $DEBUG;
print "REPODIR: $REPODIR\n" if $DEBUG;

($LOCKSUFFIX = $BACKUPDIR) =~ s/\//_/g;
open(LOCK, ">/tmp/svnbackup-$LOCKSUFFIX.lock");
flock(LOCK,2);


## Let's check to see if the supplied BACKUPDIR includes a svnbackup.pl archive
if (-f "$BACKUPDIR/svnbackup.id") {
	## svnbackup.id exists, so let's get A.R. and verify there is a correct svnbackup.log file
	## Might as well read in the relevant content while we are at it, and abort if it is corrupt.
	if (-f "$BACKUPDIR/svnbackup.log") {
		open(LOG, "$BACKUPDIR/svnbackup.log");
		while (<LOG>) {
			if ( $_ =~ m/[0-9]+\t[0-9]+\t([^ ]+\.svnz)$/ ) {
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
	opendir(DIR, $REPODIR) or die "can't opendir $dirname: $!";
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
	if ( -e $BackupFile ) {
		print "$UtilLocation{'gunzip'} -c $BackupFile | $UtilLocation{'svnadmin'} load $REPODIR\n" if $DEBUG;
		$status = system("$UtilLocation{'gunzip'} -c $BackupFile | $UtilLocation{'svnadmin'} load $REPODIR");
		if ( $status != 0) {
			## We have had a problem with svnadmin, and need to abort.  
			unlink("$BACKUPDIR/$FILENAME");
			print "\n\n\nERROR:  svnadmin command execution failed.\nSVN Repository at $REPODIR is corrupt and should be deleted.\n";
			&unlockexit;
		}
	}
	else {
		print "ABORT RESTORE:  $BackupFile does not exist.  Can not restore.\n";
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
	if ( -e "$BACKUPDIR/$SpecialSubDirectory.tgz" ) {
		($StartingPath = "$OLDREPODIR") =~ s/^\///;
		my $tar = Archive::Tar->new;
		$tar->read("$BACKUPDIR/$SpecialSubDirectory.tgz") || die ("Unable to open $BACKUPDIR/$SpecialSubDirectory.tgz \n");
		@TarredUp = $tar->list_files;
		foreach $TarFileFullPath ( @TarredUp ) {
			if ( $TarFileFullPath ne "$StartingPath/$SpecialSubDirectory") {
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
	unlink("/tmp/svnbackup-$LOCKSUFFIX.lock");
	exit;
	}