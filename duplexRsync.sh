#!/bin/bash

# REQUIREMENT we need fswatch on both ends, run this to get it on ubuntu1604
#sudo add-apt-repository ppa:hadret/fswatch
#sudo apt-get update
#sudo apt-get install -y fswatch
printHelp(){
  echo "USAGE: duplexRsync --remoteHost user@host

  DuplexRsync requires fswatch on both ends, this tries to install it locally using brew(required).
    on the remote end run:
    sudo add-apt-repository ppa:hadret/fswatch
    sudo apt-get update
    sudo apt-get install -y fswatch

  you need to specify:
    --remoteHost        ex: user@192.168.0.2.

  You can also optionally specify:
    --remoteParent      contains/will contain the remoteDir"
}

# if our arguments match this string, it's the socat fork trgger for remote change detection; increment sentinel and exit
if [ "$*" =  "sentinelIncrement" ];
then
  sentval=$(cat .____sentinel);sentval=$((sentval+1));echo $sentval > .____sentinel;
  exit;
fi


if [ "$*" =  "" ];
then
   printHelp;
  exit;
fi

# we need brew on macosx
if [ -z $(command -v brew) ];
then
  printHelp;
  exit
fi

# this is for macosx, we also need socat to create a socket to remote trigger rsync
brew install socat fswatch gnu-getopt


function randomLocalPort() {
  localPort=42
  localPort=$RANDOM;
  let "localPort %= 999";
  localPort="42$localPort"
}

function randomRemotePort() {
  remotePort=42
  remotePort=$RANDOM;
  let "remotePort %= 999";
  remotePort="42$remotePort"
}


if ! options=$(/usr/local/Cellar/gnu-getopt/1.1.6/bin/getopt -u -o hr:p: -l help,remoteHost:,remoteParent: -- "$@")
then
    # something went wrong, getopt will put out an error message for us
    exit 1
fi


set -- $options

while [ $# -gt 0 ]
do
    case $1 in
    # for options with required arguments, an additional shift is required
    -h|--help ) printHelp; exit; shift;;
    -r|--remoteHost ) remoteHost=$2; shift;;
    -p|--remoteParent ) remoteParent=$2; shift;;
    --) shift; break;;
    #(-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
    (*) break;;
    esac
    shift
done

if [ -z "$remoteHost" ];
then
  echo "Missing Argument: --remoteHost"
  printHelp;
  exit;
fi

remoteDir=${PWD##*/}
remoteDir="$remoteParent$remoteDir"




if [ ! -f ~/.ssh/id_rsa.pub ];
then
  echo "You need a key pair to use duplexRsync. You can generate one using: ssh-keygen -t rsa"
  exit;
fi

# we'll need to ssh without pass - use public key crypto to ssh into remote end,  rsync needs this
#we are copying our pubkey to ssh in without prompt
cat ~/.ssh/id_rsa.pub | ssh "$remoteHost"  'mkdir .ssh;pubkey=$(cat); touch .ssh/authorized_keys; if grep -q "$pubkey" ".ssh/authorized_keys"; then echo "puublic key for this user already present"; else echo $pubkey >> .ssh/authorized_keys;fi'


fswatchPath=$(ssh "$remoteHost" 'command -v fswatch')
#on macosx remote the $PATH variable is different when local or ssh, lets try with looking up the local path
if [ -z "$fswatchPath" ];
then
  fswatchPath=$(ssh "$remoteHost" 'command -v /usr/local/bin/fswatch')
fi

if [ -z "$fswatchPath" ];
then
  echo "ERROR: missing fswatch at remote end"
  printHelp;
  exit;
fi

ssh $remoteHost "pkill -f '____rsyncSignal.sh --pwd $PWD'"
# if we have the ssh tunnel running this will match and we kill it; pwd args to prevent killing other folders being watched
pkill -f "rsyncSignal.sh --pwd $PWD"
# if we have a lingering socat kill it
# we shouldnt have one, this is a bad plan if using multple sockets
#pkill -f "sentinelIncrement.sh --pwd $PWD"

echo '0' > .____sentinel
#create localsocket to listen for remote changes
socatRes="not listening yet, we get a random port in the following loop";
while [ ! -z "$socatRes" ]
do
  randomLocalPort;
  socatRes="";
  # frok call this script with a special argument that simply inccrement snetinel and exits
  socatRes=$(socat TCP-LISTEN:$localPort,fork EXEC:"./duplexRsync.sh sentinelIncrement" 2>&1 &) &
  # result should be empty when listen works
done;

echo "listening locally on:$localPort"


#for now we use the same port at both ends, this is a bit sloppy we should test to make sure it's not used with the ssh -R call
remotePort=$localPort

#we dump to a remote file the fswatch command that allows local running socat to get a signal of a remote change
# modification to add the -r switch to all subs excluding node_modules. This is required because fswatch will still iterate over all subdirs because the -e switch is a pattern, not a path

# if you get a bunch of: inotify_add_watch: No space left on device
# you will need to https://github.com/guard/listen/wiki/Increasing-the-amount-of-inotify-watchers
# check your current limit: cat /proc/sys/fs/inotify/max_user_watches
# ATTENTION: you cannot change this kernel param if running in an unpriviledged container, you'll need to run this in the hosting kernel's env
#  echo fs.inotify.max_user_watches=524288 | tee -a /etc/sysctl.conf && sysctl -p; echo "increasing the limit of watches, cannot be done in unpriv container"
#echo "$fswatchPath -r -e \"node_modules\" -o . | while read f; do echo 1 | nc localhost $remotePort; done" | ssh $remoteHost  "mkdir -p $remoteDir; cd $remoteDir; cat > .____rsyncSignal.sh"
absPath=$(ssh nuxt@10.12.14.65 "mkdir -p $remoteDir; cd $remoteDir; pwd")

#/usr/bin/fswatch -o -r  /home/nuxt/apollo1/plugins | while read f; do if [ -z   "$v1" ]; then v1='first recursive is spurious';echo $v1; else echo $f '1 | nc localhost 42832'; fi done &

#find /home/nuxt/apollo1 -maxdepth 1 -mindepth 1 -type d  ! -name \"node_modules\" ! -name \".*\"| nl | awk '{printf "/usr/bin/fswatch -o -r %s  | while read f; do if [ -z \"$var%d\" ]; then var%d=\"recursive first msg is spurious\"; else echo 1 | nc localhost $remotePort; fi done \& \n", $2, $1, $1}'

# we are exluding node_modules and .git
ssh $remoteHost "mkdir -p $remoteDir; cd $remoteDir; find $absPath -maxdepth 1 -mindepth 1 -type d  ! -name \"node_modules\" ! -name \".*\"| nl | awk '{printf \"/usr/bin/fswatch -o -r %s  | while read f; do if [ -z \\\"\$var%d\\\" ]; then var%d=\\\"recursive first msg is spurious\\\"; else  echo 1 | nc localhost $remotePort; fi done \& \n\", \$2, \$1, \$1}' > .____rsyncSignal.sh"
ssh $remoteHost "cd $remoteDir; echo \"/usr/bin/fswatch -o $absPath | while read f; do echo 1 | nc localhost $remotePort; done\" >> .____rsyncSignal.sh"


function duplex_rsync() {
    # kill the remote fswatch while we sync, pwd arg used to prevent attempting to kill other watches; port prevent killing if 2 locals have the exact same path local
    # also this discloses local path to remote end; dont think this is serious
    ssh $remoteHost "pkill -f '____rsyncSignal.sh --pwd $PWD --port $remotePort'"
    # kill all remote fswatches
    ssh $remoteHost "kill \$(ps ax | egrep \"/usr/bin/fswatch -o( -r)? /home/nuxt/apollo1.*\" | awk '{print \$1}')"

    # also kill the tunnel
    pkill -f "rsyncSignal.sh --pwd $PWD"

    # order matters; if we got a remote trigger we'll process remote as src first to prevent restoring files that might have just been deleted
    if [ "$trigger" = "remote" ];
    then
      rsync -auzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" --delete "$remoteHost:$remoteDir/" .;
      rsync -auzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" --delete . "$remoteHost:$remoteDir";
    else # local as src first
      rsync -auzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" --delete . "$remoteHost:$remoteDir";
      rsync -auzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" --delete "$remoteHost:$remoteDir/" .;
    fi;


    ssh  -R localhost:$localPort:127.0.0.1:$remotePort $remoteHost "cd $remoteDir; bash .____rsyncSignal.sh --pwd $PWD --port $remotePort"&
    #tunnelPid="$!"
    # echo "tunnelPid:$tunnelPid"
}

lastSentinel=$(cat .____sentinel);

# we always start from the local dir
trigger=local;
# do a trial run to see if we'd delete files on the remote end
wouldDeleteCount=$(rsync -anuzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" --delete . $remoteHost:$remoteDir/ | grep deleting | wc -l);
wouldDeleteCount="$(echo -e "${wouldDeleteCount}" | tr -d '[:space:]')"

wouldDeleteRemoteFiles=$(rsync -anuzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" --delete . $remoteHost:$remoteDir/ | grep deleting);
if [ ! -z "$wouldDeleteRemoteFiles" ];
then

  unset destroyAhead
  unset localFileCount
  localFileCount=$(find . -type f | egrep -v '\..+/' | egrep -v '\./duplexRsync.sh' | egrep -v '\./\.____*' |  wc -l |  tr -d '[:space:]')
  # if the local directory is empty using same pattern as rsync above we always merge
  if [ "$localFileCount" -eq 0 ]
  then
    destroyAhead="merge"
  else
    echo "WOULD delete count: $wouldDeleteCount"
    echo "$wouldDeleteRemoteFiles"
  fi

  while ! [[ "$destroyAhead" =~ ^(destroy|merge|abort)$ ]]
  do

    if [ "$wouldDeleteCount" -gt 5 ]
    then
      major=" ----MAJOR----- ";
    fi

    if [ "$wouldDeleteCount" -gt 42 ]
    then
      major=" ----INTERSTELLAR BYPASS LEVEL----- ";
    fi

    echo "ATTENTION $major DESTRUCTION  AHEAD: There is/are $wouldDeleteCount file(s) present in the remote folder that are not present locally. Could the remote folder be totally unrelated? Would you like to merge the folders by creeating these locally(merge),Sync and destroy(destroy) or abort?(merge/destroy/abort)"
    read destroyAhead
  done
  if [ "$destroyAhead" = "abort" ];
  then
    exit;
  elif [ "$destroyAhead" = "merge" ];
  then
    # sync from remote without delete
    rsync -auzP --exclude ".*/" --exclude ".____*"  --exclude "node_modules" "$remoteHost:$remoteDir/" .;
  fi
fi;

duplex_rsync;fswatch -r -o . | while read f;
  do
    sentinel=$(cat .____sentinel);
    sentinelInc=$((sentinel-lastSentinel));
    # if the change is remote(incremented ____sentinel) lets slow down and wait to gobble multiple events
    if [ $sentinelInc -gt 0 ]
    then
      echo 'remote change detected';
      trigger=remote;
      duplex_rsync;
      sleep 3;
    else
      echo 'local change detected';
      trigger=local;
      duplex_rsync;
    fi
    lastSentinel=$sentinel;
  done;
