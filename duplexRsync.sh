#!/bin/bash

# REQUIREMENT we need fswatch on both ends, run this to get it on ubuntu1604
#sudo add-apt-repository ppa:hadret/fswatch
#sudo apt-get update
#sudo apt-get install fswatch
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
    --remoteParent      contains/will contain the remoteDir
    --localPort        if you want to run multiple instances of duplexRsync"
}

if [ -z $(which brew) ];
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
  let "localPort %= 999";
  remotePort="42$localPort"
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


remoteDir=${PWD##*/}
remoteDir="$remoteParent$remoteDir"
# if we have the ssh tunnel running this will match and we kill it; pwd args to prevent killing other folders being watched
pkill -f "rsyncSignal.sh --pwd $PWD"
# if we have a lingering socat kill it
# we shouldnt have one, this is a bad plan if using multple sockets
pkill -f "sentinelIncrement.sh --pwd $PWD"


if [ ! -f ~/.ssh/id_rsa.pub ];
then
  echo "You need a key pair to use duplexRsync. You can generate one using: ssh-keygen -t rsa"
  exit;
fi

# we'll need to ssh without pass - use public key crypto to ssh into remote end,  rsync needs this
#we are copying our pubkey to ssh in without prompt
cat ~/.ssh/id_rsa.pub | ssh "$remoteHost"  'mkdir .ssh;pubkey=$(cat); if grep -q "$pubkey" ".ssh/authorized_keys"; then echo "puublic key for this user already present"; else echo $pubkey >> .ssh/authorized_keys;fi'

fswatchPath=$(ssh "$remoteHost" 'which fswatch')
if [ -z "$fswatchPath" ];
then
  printHelp;
  exit;
fi


#if [ ! -f .____sentinel ];
#then
# we always create a new sentinel file
echo '0' > .____sentinel
#fi


#one liner script to increment our sentinel
echo 'sentval=$(cat .____sentinel);sentval=$((sentval+1));echo $sentval > .____sentinel;' > ./.____sentinelIncrement.sh
chmod a+x ./.____sentinelIncrement.sh

#create localsocket to listen for remote changes
# cannot seem to execute bash command from fork EXEC if it would be possible we'd have one less file
#socat TCP-LISTEN:$localPort,fork EXEC:'/bin/bash -c "sentval=$(cat .____sentinel);sentval=$((sentval+1));echo $sentval > .____sentinel;"" > /dev/null 2>&1 &
socatRes="not listening yet, we get a random port in the following loop";
while [ ! -z "$socatRes" ]
do
  randomLocalPort;
  socatRes="";
  socatRes=$(socat TCP-LISTEN:$localPort,fork EXEC:"./.____sentinelIncrement.sh  --pwd $PWD" 2>&1 &) &
  # result should be empty when listen works
done;

echo "listening locally on:$localPort"


#for now we use the same port at both ends, this is a bit sloppy we should test to make sure it's not used with the ssh -R call
remotePort=$localPort

#we dump to a remote file the fswatch command that allows local running socat to get a signal of a remote change
echo "fswatch -e \"node_modules\" -o . | while read f; do echo 1 | netcat localhost $remotePort; done" | ssh $remoteHost  "mkdir -p $remoteDir; cd $remoteDir; cat > .____rsyncSignal.sh"

function duplex_rsync() {
    # kill the remote fswatch while we sync, pwd arg used to prevent attempting to kill other watches; port prevent killing if 2 locals have the exact same path local
    # also this discloses local path to remote end; dont think this is serious
    ssh $remoteHost "pkill -f 'rsyncSignal.sh --pwd $PWD --port $remotePort'"
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
  echo "WOULD delete count: $wouldDeleteCount"
  echo "$wouldDeleteRemoteFiles"
  #echo "THE DESTINATION DIR CONTAINS $wouldDeleteCount"
  unset destroyAhead
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
      trigger=remote;
      duplex_rsync;
      sleep 3;
    else
      trigger=local;
      duplex_rsync;
    fi
    lastSentinel=$sentinel;
  done;
