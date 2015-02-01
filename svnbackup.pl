#!/usr/bin/perl

#############################################################################
# svnbackup.pl  version .14-beta                                             #
#                                                                           #
# History and information:                                                  #
# http://www.ghostwheel.com/merlin/Personal/notes/svnbackuppl/              #
#                                                                           #
# Synapsis:                                                                 #
#   This script allows you to make incremental backups of a SVN repository. #
#   Unlike 'hotcopy' backups, these can efficiently be backed up via        #
#   rsync or duplicity and can be done while the repository is in use.      #
#                                                                           #
# Usage:                                                                    #
#   svnbackup.pl REPODIR BACKUPDIR                                          #
#                                                                           #
# Automatic recovery:                                                       #
#   Use svnrestore.pl to automatically process the backup log and .svnz     #
#   files too re-create a new SVN repository.                               #
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
#                                                                           #
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


#use warnings;
use File::Path;
use File::Find;
use Archive::Tar;
use Time::localtime;

$VERSION="Version 0.13-Beta";

## Change to 1 if you want debugging messages.
$DEBUG=0;

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
	print "svnbackup.pl - $VERSION\n";
	print "Insufficient arguments.\n";
	print "Usage:  svnbackup.pl REPODIR BACKUPDIR\n\n";
	exit;
	}
$REPODIR = $ARGV[0];
$BACKUPDIR = $ARGV[1];
print "REPODIR: $REPODIR\n" if $DEBUG;
print "BACKUPDIR: $BACKUPDIR\n" if $DEBUG;

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


## This performs two functions at once, one it verifies that the supplied REPODIR is valid AND
## it reads the ID for the most recent check-in
($LASTCHECKIN = `$UtilLocation{'svnlook'} youngest $REPODIR 2>&1`) =~ s/[\n\r]//g;
print "LASTCHECKIN: $LASTCHECKIN\n" if $DEBUG;
if ( $LASTCHECKIN =~ m/^[0-9]+/)
	{
	}
else
	{
	print "ABORT:  $REPODIR is not a valid SVN repository.\n\n";
	&unlockexit;
	}

## If $LASTCHECKIN is 0, then this is an empty repository and there is no reason to back it up.
if ($LASTCHECKIN == 0)
	{
	print "ABORT:  $REPODIR is an empty repository with no check-ins.\n\n";
	&unlockexit;
	}



## Check to see if the specified backup directory is valid, matches the repository to be backed up,
## and then read information about the check-ins that have been backed up if all checks out.
if ( -d $BACKUPDIR )
	{
	## Backup directory exists, so let's see if there is a svnbackup.id created by this script
	if ( -f "$BACKUPDIR/svnbackup.id" )
		{
		## svnbackup.id exists, so lets read the contents and see if it matches the repo
		open(BACKUPID, "$BACKUPDIR/svnbackup.id");
		($SVNBACKUP = <BACKUPID>) =~ s/[\n\r]//g;
		($OLDPERMS = <BACKUPID>) =~ s/[\n\r]//g;
		close(BACKUPID);
		print "SVNBACKUP: $SVNBACKUP\n" if $DEBUG;
		if ( $SVNBACKUP eq $REPODIR )
			## Since the repo and the backup match, we need to read information about the last backup.
			{
			## Check to see if there is a backup log, and if there is read the last backed up check-in
			## and use that information to set LASTBACKUP and FIRSTTOBACKUP;
			if ( -f "$BACKUPDIR/svnbackup.log" )
				{
				open(READLOG, "$BACKUPDIR/svnbackup.log") || die("Unable to open $BACKUPDIR/svnbackup.log for reading.\n");
				while ( ($LOGLINE = <READLOG>) =~ s/[\n\r]//g)
					{
					if ( $LOGLINE =~ m/([0-9]+)\t([0-9]+)\t(.+)$/ )
						{
						$STARTID = $1;
						$STOPID = $2;
						$BACKUPILENAME = $3;
						print "LOGLINE: $STARTID\t$STOPID\t$BACKUPILENAME\n" if $DEBUG;
						}
					}
				close(READLOG);
				$FIRSTTOBACKUP = $STOPID +1;
				$DUMPFLAGS .= " --incremental ";
				}
			else
				{
				## svnbackup.log does not exist, so $FIRSTTOBACKUP automatically is 0
				print "DEBUG:  $BACKUPDIR/svnbackup.log does not exist\n" if $DEBUG;
				}
				print "FIRSTTOBACKUP: $FIRSTTOBACKUP\n" if $DEBUG;

			}
		else
			{
    		print "Existing backup in $BACKUPDIR (repo $SVNBACKUP) does not match repository $REPODIR.\n\n";
    		&unlockexit;
			}
		
		my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = stat("$REPODIR/format");
		if ($OLDPERMS ne "$uid:$gid") 
			{
			print "Existing backup in $BACKUPDIR does not have the same OWNER:GROUP ($uid:$gid) as repository $REPODIR ($OLDPERMS).\n\n";
    		&unlockexit;
			}
		}
	}
else
	## The backup directory passed to this script does not exist, so we need to create it.
	{
	eval { mkpath($BACKUPDIR) };
  	if ($@) 
  		{
    	print "Couldn't create $BACKUPDIR: $@\n\n";
    	&unlockexit;
  		}
  	
	}
	
## Write the svnbackup.id file, if it doesn't already exist.
if ( !(-f "$BACKUPDIR/svnbackup.id") )
	{
	## svnbackup.id did not exist, so let's create it and write the path for the repo passed to this script
	## 2009-07-06 - Also store the owner:group of the repository in the svnbackup.id file for use in svnrestore.pl
	open(BACKUPID, ">$BACKUPDIR/svnbackup.id");
	print BACKUPID "$REPODIR\n";
	
	my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = stat("$REPODIR/format");
	print BACKUPID "$uid:$gid\n";

	close(BACKUPID);
	}
	
## If $FIRSTTOBACKUP hasn't been defined from the log file, it's automatically a 0
if ( !(defined($FIRSTTOBACKUP)) )
	{
	$FIRSTTOBACKUP = 0;
	}


####  Here is where we start the actual backup process.  If the starting ID is 0 we do a full backup
####  and if it is anyting other than 0 we use the --incremental flag.

## Set the filename for this backup set:
$FILENAME = "$FIRSTTOBACKUP-$LASTCHECKIN.svnz";

## Perform the backup, if the log does not indicate it has already been backed up
if ($FIRSTTOBACKUP <= $LASTCHECKIN) 
	{
	print "$UtilLocation{'svnadmin'} dump -r $FIRSTTOBACKUP:$LASTCHECKIN $DUMPFLAGS $REPODIR | $UtilLocation{'gzip'} -c > $BACKUPDIR/$FILENAME\n" if $DEBUG;
	$status = system("$UtilLocation{'svnadmin'} dump -r $FIRSTTOBACKUP:$LASTCHECKIN $DUMPFLAGS $REPODIR | $UtilLocation{'gzip'} -c > $BACKUPDIR/$FILENAME");
	if ( $status != 0) {
		## We have had a problem with svnadmin, and need to abort.  We should clean up before exiting, and exit before updating the log.
		unlink("$BACKUPDIR/$FILENAME");
		print "ERROR:  svnadmin command execution failed.\n";
		&unlockexit;
		}
	open(WRITELOG, ">>$BACKUPDIR/svnbackup.log");
	print WRITELOG "$FIRSTTOBACKUP\t$LASTCHECKIN\t$BACKUPDIR/$FILENAME\n";
	close(WRITELOG);
	}
else
	{
	print "The backup is current, so there is nothing to do.\n\n";
	}


##  Backup the hooks/ and config/ directories here.
foreach $SpecialSubDirectory ( ('hooks', 'conf') ) {
	$StartingPath = "$REPODIR/$SpecialSubDirectory";
	@TarThemUp = ();
	find(\&wanted, $StartingPath);
	my $tar = Archive::Tar->new;
	$tar->add_files( @TarThemUp );
	$tar->write("$BACKUPDIR/$SpecialSubDirectory.tgz", COMPRESS_GZIP) || die ("Unable to write $BACKUPDIR/$SpecialSubDirectory.tgz \n");    # gzip compressed
}


## All done, so let's invoke the lock file removal and exit routine.
&unlockexit;


	
sub unlockexit {
	flock(LOCK,8);
	close(LOCK);
	unlink($LockFile);
	exit;
	}
	
sub wanted {
	push(@TarThemUp, $File::Find::name);
}