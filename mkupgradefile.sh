#!/bin/bash
#Copyright Jasper Nuyens <jnuyens@linuxbe.com>
#Licensed under GPLv2
#
#18/9/2016 switched to relative pathnames
#23/8/2016 switched to include rootfs.ubi instead of rootfs.ext4
# we should talk less and do more
# 16/11/2016 always ;) added dev option to not sign the upgrade file for development


#if [[ $# != 1 ]]
#then
#echo "Usage Error: Please provide the path to the rootfs.ext4"
#echo "typically: ${buildpath}/../output/images/rootfs.ext4"
#exit 1
#fi

buildpath=$(dirname "$0")

if [[ $# != 2 ]]
then
 if [[ $# != 1 ]]
 then 
  echo "Usage error: provide as first argument dev or prod"
  echo "dev will not require signing and can be used only with nandcreate.sh"
  echo "signdev will sign the image and can be used with nandcreate.sh AND do-upgrade.sh"
  echo "prod will sign the image and can be used with nandcreate.sh AND do-upgrade.sh"
  echo "dev and signdev will upload to updateserver" 
  echo 
  echo "The second argument to this script can be empty or you can provide a rootfs location"
  exit 1
 fi
 echo "You didn't provide a path to the rootfs.ubi ... will use default path"
 echo "default path : ${buildpath}/../output/images/rootfs.ubi"
 echo 
 echo "Also, if you want to make an upgrade image for internal development"
 echo "which isn't signed, use the argument dev"
 rootfs=${buildpath}/../output/images/rootfs.ubi
 else
 	rootfs=$2
fi

nosign="false"
if [[ $1 = "dev" ]]
then
  nosign="true"
fi

# rootfs=$1
oldpath=$(pwd)
buildsdir=${buildpath}/../builds/os/
mkdir -p ${buildsdir} 2> /dev/null
validuser=svc_transfer
#generating the upgrade directory in /tmp
workdir=/tmp/upgrade.$$/upgrade
mkdir -p $workdir
cp $rootfs $workdir/rootfs.ubi
cd $workdir
size=$( ls -la rootfs.ubi | awk '{ print $5 }' )

if [[ "$nosign" != "true" ]]
then
 #sign file
 echo Creating signature file
 gpg -b rootfs.ubi || exit 2
 echo Verifying signature
 gpg --verify rootfs.ubi.sig rootfs.ubi || exit 3
fi

#generate manifest
date > $workdir/manifest
echo "rootfs $size $(sha512sum rootfs.ubi)">> $workdir/manifest

#compress
cd ..
upgradeimage=upgrade-image-`date '+%F%H%M'`
tar cvf $upgradeimage.tar  upgrade || exit 4
export XZ_DEFAULTS=--memlimit=150MiB 
xz -9 $upgradeimage.tar || exit 5
mv $upgradeimage.tar.xz $oldpath/$upgradeimage || exit 6
echo Written $upgradeimage to $oldpath/$upgradeimage
#ook nog naar de builds/os dir kopieren	
echo cp $oldpath/$upgradeimage $buildsdir 
cp $oldpath/$upgradeimage $oldpath/$buildsdir || exit 7
echo copy of $upgradeimage to $buildsdir

rm -rf /tmp/upgrade.$$

echo upgradefile is in: $oldpath/${upgradeimage}
echo nosign=$nosign
if [[ "$nosign" = "true" ]] || [[ "$1" = "signdev" ]]
then
 echo please copy the unsigned upgrade image to the nfs-booted target in the 
 echo /data directory
 echo and run /nandcreate.sh
 echo automatically running: scp  $oldpath/${upgradeimage} $validuser@updateserver:/exportroot/data/
 exit 0
fi

echo "uploading ...."
version=$(cat $oldpath/../output/target/etc/version 2> /dev/null)
echo "Upload with: scp $upgradeimage validuser@update-server:/usr/share/nginx/html/"
echo "Download to board with cd /data; wget http://update-server/latest"

