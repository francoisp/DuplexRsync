# DuplexRsync

🌟 Simple realtime 2-way sync.

### Problem

I often find myself editing quite a few files on remote hosts; for anything non-trivial I like to use local-running tools such as Sublime. I've used [rsub](https://github.com/henrikpersson/rsub), it's very nice and lightweight. Sometimes(often) the light editing turns heavier and more and more files are worked on. I have noticed that when the ssh tunnel dies and is recreated while a file is open, the file will be truncated to zlitch --a glitch to look out for that is more likely to occur when multiple files are open.

When things keep getting heavier, I've then used [sshfs](https://github.com/osxfuse/osxfuse/wiki/SSHFS) to mount a remote directory and fuse it to the local filesystem. This usually works ok, but for some types of workflows such as sublime projects with a lot of files in subfolders (node_modules? --sometimes this one starts to feel like a whole Gentoo distro) it is inadequate. Search becomes extra slow. The SublimeText project tree spins and spins and spins, features that have become automatisms are unworkable. Also, open files prevent the tunnelling connection from exiting; and a broken tunnel (say you close your laptop without closing everything and unmounting) can leave the fuse subsystem in a weird state, where you cannot remount to the previous location until a reboot, as well as other minor glitches.

### Solution

DuplexRsync is a simple and pretty sweet (although only lightly tested as of 2019/03, PLEASE BE CAREFUL AND ALWAYS HAVE BACKUPS and/or VERSIONING!) solution based on fswatch and rsync. It's a single file you'll put in your local directory that will maintain (DropBox|GoogleDrive)-style 2-way sync between the current directory and a remote directory via SSH. This has the advantage to work fine when offline. This bash script is a bit macOSX-centric because that's what I use locally, please feel free to adapt. By default the script excludes node_modules and all folders that start with a period. (.git etc)

### Merging

If a file has been edited on both ends while offline (duplexRsync not running), merging will simply crush the oldest edit; it will never results in conflict files. This is harsh but simpler; with git these days I think edits that have some value should be committed, so we delegate versioning there.

If you attempt to sync mismatched folders, a lot of files in the remote folder would get deleted. When launching duplexRsync you'll be prompted to either merge the folders (create these files in the local folder), or destroy all the extra files in the remote folder.

Latency for multiple remote edits to propagate to local folder is set by default to 3 seconds, this prevents infinite cycling of change detection. Over very slow network connections you might need to increase this value.

###  Setup

on your remote machine you'll need fswatch:


    sudo add-apt-repository ppa:hadret/fswatch
    sudo apt-get update
    sudo apt-get install -y fswatch

on your local machine you'll need brew, that's it. This script will install the other required components (socat fswatch and gnu-getopt)

    chmod u+x duplexRsync.sh
    ./duplexRsync.sh --remoteHost user@192.168.0.2

### Caveats

This is a simple solution, it does not implement any distributed locking. If you or processes are editing at both ends simultaneously, over and above the crushing of the oldest edit of the same file mentioned, there's a window while a newly created file can get deleted. Conversely but less serious, there's also a window during which a deleted file could be recreated. An argument to --delete-older-than "seconds" in rsync would mitigate the first edge case, I think the second one(zombie file coming back) is a an annoyance I can live with.

### Related

Thanks for all the feedback in various forums. Here are a few related projects that have been brought to my attention. I have not tried any of these, they all look very well written; they could come in handy later.

#### Heavier

- [osync](https://github.com/deajan/osync)

#### Heaviest

- [Mutagen.io](https://mutagen.io/)
- [Syncthing](https://github.com/syncthing/syncthing)
- [Unison](https://github.com/bcpierce00/unison)




That's it!🔥 Cheers!

Please Note: A few hidden files are created to maintain the 2-way sync, they all start by .____*. The remote directory will be straight off the home of your remote user's home; there's an optional --remoteParent if you need to change that.


License: MIT
