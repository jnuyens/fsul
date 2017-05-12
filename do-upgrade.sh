#!/bin/ash 
#Copyright Jasper Nuyens <jasper@linux.com>
#Licensed under the GPLv2
#version 17-22-04-2016
#version 23-08-2016 switched to nand updating stuff also updated nandcreate.sh for that
#version 9-09-2016 removed exit 31 and 32 for not being able to wget the pubkey
#as its already there from before and no problem if it cant be transferred
#if its not there, the sig check will fail. And added a sleep before fw_setenv to
# prevent kernel oops
#version 20-03-2017 added file preservation
#version 30-03-2017 changed script to reduce space while upgrading 
#version 13-04-2017 added nosig option to run without checking signature
#version 13-04-2017v2 added check against double launching
#version 13-04-2017v3 small bugfixes
#version 12-05-2017 cleaned up 
#
#one big script to update them all

#bootserver is used to store public key and used as time server
bootserver=
#preserved files are kept between upgrades
preserved_files="/etc/shadow /etc/ssh/*key* /etc/hostname"

if [[ ! -f "$1" ]]
then
	echo "Usage Error: please provide the full path to the filename to upgrade as an argument"
	exit 100
fi

sigcheck=true
if [[ $# == 2 ]]
then
	if [[ "$2" == "nosig" ]]
	then 
		sigcheck=false
	else
		echo "Usage Error: nosig is the only 2nd argument we allow"
		exit 101
	fi
else
	sigcheck=true
fi

prevlaunch=$(pidof -o $$ do-upgrade.sh)
if [[ "${prevlaunch}" != "" ]]
then
	#prev di-upgrade is running
	echo "Sry do-upgrade.sh is already running"
	exit 102
fi

oldpath=$(pwd)
#clean up old failed upgrades
rm -rf /data/upgrade.work.* 2> /dev/null

mkdir -p /data/upgrade.work.$$ || exit 1       # not writable /data directory

#in case we boot from NFS, we want to preseve the original file
#we can replace the cp with mv otherwise

mv $1 /data/upgrade.work.$$/$(basename $1).xz
cd /data/upgrade.work.$$ 
#could do the following 3 lines in 1 go with GNU tar, but busybox tar doesn't support this
unxz -cf $(basename $1).xz | tar xvf - || exit 2                           # can't extract the file, possibly incomplete, corrupt or fake or filesystem full
cd upgrade || exit 3 			       # non-existing correct directory structure

#verify manifest content
cat manifest || exit 4 			       # missing manifest file
reportedsize=$(grep rootfs manifest | awk '{ print $2 }' )     
reportedchecksum=$(grep rootfs manifest | awk '{ print $3 }' )
#while it would allow for more flexibility that the rootfs.ubi filename is 
#extracted out of the manifest file, this also poses a potential
#security risk
size=$(ls -la rootfs.ubi | awk '{ print $5 }')
[[ "$size" == "$reportedsize" ]] || exit 6     # rootfs filesize does not match
checksum=$(sha512sum rootfs.ubi | awk '{ print $1}')
#echo checksum=$checksum
#echo repchsum=$reportedchecksum
[[ "$checksum" == "$reportedchecksum" ]] || exit 7  # incorrect checksum

if [[ ! -s /etc/resolv.conf ]]
then
 echo "nameserver 8.8.8.8" > /etc/resolv.conf
fi

if ${sigcheck}
then
 #need a correct date for signature verification
 rdate  $bootserver

 if [[ ! -s /root/.gnupg/pubring.gpg ]]
 then
  wget http://$bootserver/pubkey.asc -O /data/pubkey.asc # can't fetch pubkey
  mount -o remount,rw /
  gpg2 --import /data/pubkey.asc 	#can't import pubkey
  mount -o remount,ro /
 fi

  #verify signature
  gpg2 --verify rootfs.ubi.sig rootfs.ubi || exit 8  # incorrect signature
fi

echo Detecting boot partition
#determine the current booted partition to determine where we write the upgrade to
#it can be currently nfs, mmcblk0p2 or mmcblk0p3, mmcblk1p2 or mmcblk1p3
#and ubi0!rootfs but in this case, we need to look at the uboot-env to determine
#if mtd6 (rootfs) or mtd7 (rootfs-next) is being used as rootfs - as it's
#not visible in the bootcommandline kernel arguments.
#it can also be determined with dmesg|grep mtd it shows if rootfs is mtd6 or mtd7
#however, this is not a reliable method as the kernel log buffer can be filled with other output (and thus no longer showing up in dmesg).
#so we prefer to use fw_printenv to determine if bootcmd=run nandboot or bootcmd=run nandboot-next
#
#
#In the case of mmcblk0p2 and mmcblk0p3, it is the internal eMMC when the sd 
#card is not inserted (mmcblk1 not present), othewise this is the sd card: when
#booted from sd card, the sd card is mmcblk0 and the eMMC becomes mmcblk1
#in case mmcblk0p6 doesn't exist, the formatting isn't correct yet

nfsboot=$(grep "root=/dev/nfs" /proc/cmdline)
if [[ "$nfsboot" != "" ]]
then
 #we are booted from nfs
 #we presume that we need to format and write the rootfsnext to the first rootfs nand partition
 echo NFS boot detected
 rootfsnext="/dev/mtd6"
 bootcmd="fw_setenv bootcmd run nandboot"
 #just to be sure if it would be attached
 ubidetach -d 0 2> /dev/null
else
 #we convert /proc/cmdline to individual lines for each argument so we can grep
 #the root= line and print the second argument
 rootfs=$(tr ' ' '\n' < /proc/cmdline | grep ^root= | awk -Froot= '{ print $2 }')
 echo $rootfs boot detected
 if [[ "$rootfs" == "/dev/mmcblk0p2" ]]
 then
  rootfsnext=/dev/mmcblk0p3
  writefat=/dev/mmcblk0p1
 elif [[ "$rootfs" == "/dev/mmcblk0p3" ]]
 then
  rootfsnext=/dev/mmcblk0p2
  writefat=/dev/mmcblk0p1
 elif [[ "$rootfs" == "ubi0!rootfs" ]]
 then
  #so in this case we are already booting from NAND
  #now we still need to determine if we booted from mtd6 or mtd7
  #easyest way is to use fw_printenv | grep bootcmd
  #see remarks above
  fwprinenvoutput=`fw_printenv| grep bootcmd | grep nandboot-next`
  if [[ "$fwprinenvoutput" != "" ]]
  then
   #we booted from nandboot-next (mtd7), so rootfsnext should be mtd6
   echo Currently booted from rootfs-next on nand 
   rootfsnext="/dev/mtd6"
   bootcmd="fw_setenv bootcmd run nandboot"
  else
   echo Currently booted from rootfs on nand
   rootfsnext="/dev/mtd7"
   bootcmd="fw_setenv bootcmd run nandboot-next"
  fi
  writefat="writeubootenv"
 fi
fi
 
#now we know where to write and if we need to format
echo rootfsnext=$rootfsnext
echo formattool=$formattool
echo writefat=$writefat

#if [[ ! -f /sbin/mkfs.vfat ]]
#then
# #if other tools are missing they could also be added in a similar manner
# wget http://$bootserver/mkfs.vfat -O /sbin/mkfs.vfat  || exit 16 #cant fetch mkfs.vfat
# chmod a+x /sbin/mkfs.vfat
#fi



#let's write
#when adding the nand, use nandwrite instead of dd to deal with bad blocks correctly
#echo dd if=rootfs.ubi of=$rootfsnext bs=10M


flash_erase $rootfsnext 0 0 || exit 12   #problem erasing rootfsnext partition - possibly mounted or wrong partitioned?
#the real thing
ubiformat $rootfsnext -f rootfs.ubi || exit 13 #problem writing the new updated filesystem

#preserve certain files
cd /
tar cvf /data/upgrade.work.$$/preserved_files.tar ${preserved_files} || exit 20 #file preservation write error
if [[ ${rootfsnext}  == "/dev/mtd7" ]] 
then
 #booting from mtd6
 ubiattach /dev/ubi_ctrl -m 7			|| exit 21 # ubiattach failure of new rootfs
elif [[ ${rootfsnext}  == "/dev/mtd6" ]] 
then
 #booting from mtd7
 ubiattach /dev/ubi_ctrl -m 6			|| exit 22 # ubiattach failure of new rootfs
else
	exit 23 # we dont know where we wrote rootfsnext
fi

ubilocation=ubi2:rootfs
if [[ ! "$nfsboot" == "" ]]
then
 ubilocation=ubi0:rootfs
fi
mount -t ubifs ${ubilocation} /mnt  || exit 25 # mount of new rootfs failed

cd /mnt || exit 26 # /mnt mount point nonexistant
tar xvf /data/upgrade.work.$$/preserved_files.tar  || exit 27 # extract of preserved files to new rootfs failed
cd /
umount /mnt || exit 28 # umount of new rootfs failed
ubidetach /dev/ubi_ctrl -m 8 
rm /data/upgrade.work.$$/preserved_files.tar  || exit 28 # extract of preserved files to new rootfs failed

#switch bootloader to use the rootfsnext
#update the bootloader to switch from bootnext to boot and vice versa

sleep 3 # to prevent kernel oopses in certain instances directly after ubiformat

$bootcmd  || exit 33 #failed to update uboot_env partition. 
#/etc/fw_env.config might be incorrect, if this happens in real life
# might be an option to create a new /etc/fw_env.config file first.


#only delete the upgrade file if not booted from nfs
if [[ ! "$nfsboot" == "" ]]
then
 mv /data/upgrade.work.$$/$(basename $1).xz $1
fi
rm -rf /data/upgrade.work.* 2> /dev/null


sync
# if something went wrong we don't get to reboot
reboot
