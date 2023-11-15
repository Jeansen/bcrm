![](https://rawgit.com/Jeansen/assets/master/project-status.svg)
[![](https://rawgit.com/Jeansen/assets/master/license.svg)](LICENSE)

[//]: # ([![Build Status]&#40;https://travis-ci.org/Jeansen/bcrm.svg?branch=master&#41;]&#40;https://travis-ci.org/Jeansen/bcrm&#41;)
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2FJeansen%2Fbcrm.svg?type=shield)](https://app.fossa.com/projects/git%2Bgithub.com%2FJeansen%2Fbcrm?ref=badge_shield)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/8077/badge)](https://www.bestpractices.dev/projects/8077)


# Backup, Clone, Restore and More (bcrm)

This project is a result of finding a solution for backing up and restoring my private systems in use. To some extend
one could say it is a combination of [relax-and-restore](http://relax-and-recover.org) and
[borg](https://www.borgbackup.org). Though these are robust, solid and field-proven tools, I was missing the option to
do live backups without having to use a special rescue image. And I always wanted to do something like this myself :-)

## bcrm - what can it do for you?

While bcrm can do a simple (file-based) clone from system A to B, it can also do a lot more:

-   Clone a "legacy" system and convert it to UEFI
-   Clone or Restore a system and encrypt it with LUKS
-   Clone or Restore LVM-base setups
-   Optionally create and validate checksums
-   Optionally compress backups
-   Do things in parallel (where possible)
-   Provide a simple UI (including progress counters)
-   Protect a user in doing too dangerous things
-   And much more ... 

Check the [project page](https://github.com/Jeansen/bcrm/projects/1) to see what is currently in development and the 
backlog.

## Backup options

You can either clone or backup your system, that is:

-   Clone a (live) system (including LVM and GRUB) to another disk.
-   Backup a (live) system to a destination folder and restore from it from there (including LVM and GRUB).
-   If you use LVM you can also choose to encrypt the clone.

## Intended usage

Ideally, the system to be cloned uses LVM and has some free space left for the creation of a snapshot. Before the 
creation of a clone or backup a snapshot will be created. A destination disk does not have to be the same size as the
source disk. It can be bigger or smaller. Just make sure it has enough space for all the data! But don't worry, bcrm
should be smart enough to figure out if the destination is too small, anyway.

When cloning LVM-based systems, the cloned volume group will get the postfix `_<ddmmjjjj>` appended. You can
overwrite this with the `-n` argument.

You will need at least 500MB of free space in your volume group, otherwise no snapshot will be created. In this case you
are on your own, should you clone a live system.

Be aware that this script is not meant for server environments. I have created it to clone or backup my desktop and 
raspberry Pi systems. I have tested and used it with a standard Raspberry Pi OS installation and standard Debian installations,
with and without LVM.

It is also possible to use encryption. That is, when cloning bcrm will create the encryption layer via LUKS before cloning.
All you have to do is provide a pass phrase.

## Other use cases

Of course, you can also backup or clone systems without LVM. If you are not cloning a live system, there is not much to
it. But, If you need to clone a live system that is not using LVM, make sure there is a minimum of activity. And even 
then it would be more reliable to take the system offline and proceed from a Live CD.

# Usage

If you need help, just call the script without any options or use the `-h` option.  Otherwise, there are only a handful
of options that are necessary, mainly: `-s` and `-d`, each excepting a block device or a folder.

Let's assume the source disk you want to clone `/dev/sda` and `/dev/sdb` is a destination disk.

## Clone

To clone a disk, us the following command:

    ./bcrm.sh -s /dev/sda -d /dev/sdb

## Backup

To backup a disk, us the following command:

    ./bcrm.sh -s /dev/sda -d /mnt/folder/to/clone/into [-x] [-c]

With the `-x` flag, you can have backup files compressed with XZ and a compression ID of 4. 
And with the `-c` flag, checksums will be created for each backup file.

## Restore

Restoring is the inverse of a backup. Taking the above example, you would just switch the source and
destination:

    ./bcrm.sh -s /mnt/folder/to/clone/into -d /dev/sda [-c]

If you provide the `-c` flag, checksums (if available) will be validated before restoring from the backup.

## Checksums

If you do a backup, you can use the optional `-c` flag. This will create checksums for each backup chunk. When you
restore the system later on, use the `-c` flag again for validation.

## Encryption

If you use LVM you can use the `-e` flag to encrypt your clone. This also works when restoring from a backup folder.

## LVM

When cloning or restoring you can use `-n vg-name` to provide a custom Volume Group name.

## Help

Throughout the years of development more options have been added. Some of them for convenience, others for more advanced scenarios.
Heck out the help!

## Safety

The script will take care that you do not fry your system. For instance:

- Invalid combinations will not be accepted or ignored.
- Missing tools and programs will be announced with installation instructions. 
- Multiple instances will be prevented.
- Multiple checks are run to make sure the destination is actually suitable for a clone or backup.
- And a lot more checks ...

# Contributing

Fork it, make a Pull Request, create Issues with suggestions, bugs or questions ... You are always welcome to contribute!

# Self-Promotion

Like bcrm? Follow me and/or the repository on GitHub.

# License

GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007


[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2FJeansen%2Fbcrm.svg?type=large)](https://app.fossa.com/projects/git%2Bgithub.com%2FJeansen%2Fbcrm?ref=badge_large)
