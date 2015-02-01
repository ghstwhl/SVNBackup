# SVNBackup
This script allows you to make incremental backups of a SVN repository.
Unlike 'hotcopy' backups, these can efficiently be backed up via
rsync or duplicity and can be done while the repository is in use.

**Usage:**

~~~
svnbackup.pl REPODIR BACKUPDIR
~~~

**Automatic recovery:**

Use svnrestore.pl to automatically process the backup log and .svnz files too re-create a new SVN repository.

**Manual Recovery:**

* use 'svnadmin create' to create a new repository.
* use 'svnadmin load' to restore all of the backup files, in order.

~~~
svnadmin create /tmp/test
gzcat 0-100.svnz | svnadmin load /tmp/test
gzcat 101-110.svnz | svnadmin load /tmp/test
~~~




# SVNRestore

This script allows you to restore SVN repository backups made with
svnbackup.pl  *It does not perform incremental restores, only complete ones.*

**Usage:**

The expectation here is that BACKUPDIR contains a backup created by
svnbackup.pl and that REPODIR is either does not exist or is empty.

~~~
svnrestore.pl BACKUPDIR REPODIR
~~~


# Version History

***Version .16-beta changes***

* Fixed a critical issue where the conf/ and hooks/ directories were not being restored to the correct path.

***Version .15-beta changes***

* Fixed an issue where moving the backup directory would cause
svnrestore.pl to see the backup as invalid.

***Version .14-beta changes***

* Fixed bad logic in the utility file path code.
* Added a set of common path locations to the search path.

***Version .13-beta changes***

* Improved lock file detection to prevent concurrent execution, and added a message stating the age of the lockfile if one is found.

***Version .12-beta changes***

* Fixed an incorrect file test operator in svnrestore.pl

***Version .11-beta changes***

* Added backup and restore of the conf/ and hooks/ directories.
* Preserve and restore the user/group ownership of the SVN repository.

***Version .10-beta changes***

* Added locating utilities from within PATH so that this script should run without modification on most systems.                         

***Version .9-beta changes***

* Added using /tmp/svnbackup-BACKUPDIR.lock as a lock-file to prevent concurrent execution of svnbackup.pl or svnrestore.pl which could corrupt backups and prevent complete restores.
* Added error handling in case the external call to svnadmin fails.