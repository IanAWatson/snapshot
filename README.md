# snapshot
Periodically takes a snapshot of a directory structure.
Useful for going back in time.

One of the most useful things I found working at Google was their
code snapshot utility. Every 5 minutes, it would take a snapshot of
your work, and it was then easy to go back in time. Just look for the
files in .snapshot/minutes_ago/15 or .snapshot/hours_ago/2 or
.snapshot/days_ago/5

I have looked for something like this, but most of the snapshot/backup
functionality seems much more complex and heavy-weight. Better
no doubt, but not what I was looking for.

This tool is completely simple and minimally functional, but so far, seems
to be working just as I want it to.

Unlike the Google tool, this does not present what looks like a
complete file system, I take a tarfile snapshot and store that.  If
you want to recover file(s) you will need to un-tar that file -
presumably to a different location, and work from that.  While this is
not as nice as what Google does it is simpler.  And unfortunately I
copy the entire directory tree, so clearly this will not work if you
are working in a directory tree with large files - although there is
an exclusion list capability.

For me, I am storing the snapshot tar files on either a different local
disk, or a remote mounted disk.
