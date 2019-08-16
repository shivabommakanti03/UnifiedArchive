#!/bin/bash

base_box_directory="/home/vmowner/vms/virtualP162-base"
base_box_filename='virtualP162-base.box'
base_box_full_path="file://${base_box_directory}/${base_box_filename}"
base_box_name="virtualP162"
build_name="testarchive"
ansible_path="/home/vmowner/ve-ansible"
cicd_image_build_path="/home/vmowner/cicd-image-build/fok-ci/cicd-vm-build"
daily_build_path="/home/vmowner/cicd-image-build/fok-ci/cicd-vm-build/output"
inside_git_repo="$(git rev-parse --is-inside-work-tree 2>/dev/null)"
[ "$inside_git_repo" ] && git_id="$(git log -1 --pretty="%h")" || git_id="no_git"
build_id="$(date +%Y%m%d%H%M%S)_${git_id}"
daily_build_name="${build_name}_${build_id}.uar"
daily_box_name="${build_name}_${build_id}.box"
prosfs05="IP"
prosfs05_build_path="/pool01/shared_files/uar/dailyuarbuild"


echo "STEP 0: ENSURE TOOLS ARE ON PATH ......."
which ansible-playbook || exit 1


echo "STEP 1: VERIFY BASE PACKAGE FOR BUILD EXISTS ......."
if [[ -f "${base_box_directory}/${base_box_filename}" ]]; then
        echo "    -> BASE PACKAGE ALREADY EXISTS"
else
	echo "    -> ERROR: VM PACKAGE NOT FOUND - $base_box_filename "
	echo " Create a base vagrant package by spinning up a new VM from the base virtual-P16.2 ova file "
	echo " and package using the command: vagrant package --base <VM_name> --output /some/path/<base_box_filename> "
	exit 1
fi

echo "STEP 2: ADDING BOX TO VAGRANT USING BASE PACKAGE ........."
if [[ $(vagrant box list) == *"${base_box_name}"* ]]; then
	echo "    -> NOTE - BASE $base_box_name BOX ALREADY EXISTS"
else
	vagrant box add ${base_box_name} ${base_box_full_path} && echo "    -> SUCCESS - BASE BOX $base_box_name ADDED TO VAGRANT" || { echo "    -> FAILED - BASE BOX $base_box_name COULD NOT BE ADDED TO VAGRANT"; exit 1; }
fi

echo "STEP 3: SPINNING UP VM AND GENERATING UAR AND DAILY BUILD ........."
echo "CLEANING LOCAL BUILD DIRECTORY ........."
mkdir -p ${daily_build_path} 
rm ${daily_build_path}/*
cd ${cicd_image_build_path}
vagrant_status=$(vagrant global-status | grep 'cicd-vm-build.*running')
[[ -n "$vagrant_status" ]] && { echo "
    NOTE: IT SEEMS AN OLDER VERSION OF THE MACHINE IS ALREADY RUNNING, 
    PLEASE CLEAR OUT PREVIOUSLY RUN VM INSTANCE OF cicd-vm-build (vagrant destroy)
"; exit 1; }
if vagrant up; then
	echo "    -> STARTING: Vagrant machine"
	ip=$(vagrant ssh-config | grep 'HostName' | awk '{print $NF}' | sed 's/ //g')
	box_port=$(vagrant ssh-config | grep 'Port' | awk '{print $NF}' | sed 's/ //g')
	[[ -n "$ip" ]] && echo "    -> SUCCESS: Machine booted and ready! IP: ${ip}:${box_port}"
	#Making changes in the VM using Ansible
	echo "APPLYING CHANGES IN THE VM ........."
	ansible-playbook build-steps/install_root_ssh_key.yml || exit 1
	ansible-playbook build-steps/install_libs.yml || exit 1
	
	/usr/bin/sshpass -p Philips123! ssh -p ${box_port} -o StrictHostKeyChecking=no root@${ip} /usr/sbin/shutdown -y -i5 -g0
	until vagrant status | grep -q "poweroff"; do sleep 1 ; done
	echo "Creating new daily box"
	vagrant package --output ${daily_build_path}/${daily_box_name} && echo "    -> SUCCESS - DAILY BUILD BOX GENERATED" || { echo "    -> FAILED - DAILY BUILD BOX GENERATION UNSUCCESSFUL"; exit 1; }
	vagrant up
	echo "Creating UAR in the VM"
	/usr/bin/sshpass -p Philips123! ssh -p ${box_port} -o StrictHostKeyChecking=no root@${ip} archiveadm create /tmp/${daily_build_name}
	#Extract UAR from the VM
	if /usr/bin/rsync --rsh="sshpass -p Philips123! ssh -o StrictHostKeyChecking=no -p $box_port -l root" ${ip}:/tmp/${daily_build_name} ${daily_build_path}/${daily_build_name}; then 
		src=$(/usr/bin/sshpass -p Philips123! ssh -p $box_port -o StrictHostKeyChecking=no root@${ip} wc -c /tmp/${daily_build_name} | awk -F ' ' '{print $1}')
		dest=$(wc -c ${daily_build_path}/${daily_build_name} | awk -F ' ' '{print $1}')
		echo "VM_FILE_SIZE: $src    HOST_FILE_SIZE: $dest"
	else	
		echo "    -> FAILED: BUILD UNSUCCESSFUL"
		exit 1
	fi	
		
else 
	echo "    -> FAILED: To boot Machine"
fi	

echo "STEP 4: REMOVING VAGRANT VM ........." 
vagrant destroy --force

echo "STEP 5: COPYING BUILDS TO PROSFS05 ........." 
if sshpass -p 'p3rtp123' scp ${daily_build_path}/*  pfgit@${prosfs05}:${prosfs05_build_path}; then
	echo "SUCCESSFULLY COPIED THE BUILDS TO PROSFS05 !"
	echo "REMOVING OLD BUILDS (keeping latest 2 builds) ........."
	sshpass -p 'p3rtp123' ssh pfgit@${prosfs05} "rm ${prosfs05_build_path}/latest.uar"
	sshpass -p 'p3rtp123' ssh pfgit@${prosfs05} "ls -1t ${prosfs05_build_path} | ggrep "${build_name}.*uar" | head -n +1 | gxargs -L 1 -I % cp ${prosfs05_build_path}/% ${prosfs05_build_path}/latest.uar"
	sshpass -p 'p3rtp123' ssh pfgit@${prosfs05} "chmod 644 ${prosfs05_build_path}/latest.uar"
	sshpass -p 'p3rtp123' ssh pfgit@${prosfs05} "ls -1t ${prosfs05_build_path} | ggrep "${build_name}.*uar" | gtail -n +3 | xargs rm -f"
	sshpass -p 'p3rtp123' ssh pfgit@${prosfs05} "ls -1t ${prosfs05_build_path} | ggrep "${build_name}.*box"  | gtail -n +3 | xargs rm -f"
	
	echo "CLEANING LOCAL BUILD DIRECTORY ........."
	rm ${daily_build_path}/*
else
	echo "FAILED TO COPY BUILDS TO PROSFS05"
	echo "CLEANING LOCAL BUILD DIRECTORY ........."
	rm ${daily_build_path}/*
	exit 1
fi

