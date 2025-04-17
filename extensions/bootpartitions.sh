# this will change the first root FS lable from "armbi_root" to "armbi_roota
function pre_prepare_partitions__600_fix_rootfs_label() {
	display_alert "fix rootfs label" "${EXTENSION}" "info"
	ROOT_FS_LABEL="armbi_roota"
}

# this adds the 3rd and 4th partitions, as well as hooks in the userpatch partition hook
function prepare_image_size__601_partition() {
	display_alert "Adding partition function" "${EXTENSION}" "info"
	# this will allow the "CREATE_PARTITION_TABLE" function to be called
	declare -g USE_HOOK_FOR_PARTITION=yes
	local rootb_part=3
	local data_part=4
}

#This sets the partition sizes
function prepare_image_size__600_image_size() {
	display_alert "partition size" "${EXTENSION}" "info"
	FIXED_IMAGE_SIZE=5000
	local old_RFS=${rootfs_size}
	rootfs_size=2000
	display_alert "devloper mode is >${DEVELOPER_MODE}<" "${EXTENSION}" "info"
	if [[ "$DEVELOPER_MODE" == "yes" ]]; then
		FIXED_IMAGE_SIZE=16000
		rootfs_size=4000
		display_alert "Developer extended rootfs_size is ${old_RFS}Mib, changeing to ${rootfs_size}MiB" "${EXTENSION}" "warning"
	else
		display_alert "Normal rootfs_size is ${old_RFS}Mib, changeing to ${rootfs_size}MiB" "${EXTENSION}" "info"
	fi

}

#this creates the new partition table
function create_partition_table() {

	display_alert "Running partition function" "${EXTENSION}" "info"

	# stage: calculate partition size
	# local bootstart=$(($OFFSET * 2048))
	# local rootstart=$(($bootstart + ($BOOTSIZE * 2048) ))
	# local bootend=$(($rootstart - 1))
	# local rootstart2=$(($rootstart  + ($rootfs_size * 2048) ))
	# local rootend=$(($rootstart2 - 1))
	# local datastart2=$(($rootstart2 + ($rootfs_size * 2048) ))
	# local rootend2=$(($datastart - 1))

	local next=$OFFSET
	# Create a script in a bracket shell, then pipe it to fdisk.
	{
		[[ "$IMAGE_PARTITION_TABLE" == "msdos" ]] && echo "label: dos" || echo "label: $IMAGE_PARTITION_TABLE"

		if [[ -n "$biospart" ]]; then
			# gpt: BIOS boot
			local type="21686148-6449-6E6F-744E-656564454649"
			echo "$biospart : name=\"bios\", start=${next}MiB, size=${BIOSSIZE}MiB, type=${type}"
			local next=$(($next + $BIOSSIZE))
		fi
		if [[ -n "$uefipart" ]]; then
			# dos: EFI (FAT-12/16/32)
			# gpt: EFI System
			[[ "$IMAGE_PARTITION_TABLE" != "gpt" ]] && local type="ef" || local type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
			echo "$uefipart : name=\"efi\", start=${next}MiB, size=${UEFISIZE}MiB, type=${type}"
			local next=$(($next + $UEFISIZE))
		fi
		if [[ -n "$bootpart" ]]; then
			# Linux extended boot
			[[ "$IMAGE_PARTITION_TABLE" != "gpt" ]] && local type="ea" || local type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
			if [[ -n "$rootpart" ]]; then
				echo "$bootpart : name=\"bootfs\", start=${next}MiB, size=${BOOTSIZE}MiB, type=${type}"
				local next=$(($next + $BOOTSIZE))
			else
				# no `size` argument mean "as much as possible"
				echo "$bootpart : name=\"bootfs\", start=${next}MiB, type=${type}"
			fi
		fi

		# create main , and secondary root FS
		[[ "$IMAGE_PARTITION_TABLE" != "gpt" ]] && local type="83" || local type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
		echo "2 : name=\"rootfs_a\", start=${next}MiB, size=${rootfs_size}MiB, type=${type}"
		local next=$(($next + $rootfs_size))
		echo "3 : name=\"rootfs_b\", start=${next}MiB, size=${rootfs_size}MiB, type=${type}"
		#and finally the data partition
		local next=$(($next + $rootfs_size))
		echo "4 : name=\"data\", start=${next}MiB, type=${type}"

	} | run_host_command_logged sfdisk "${SDCARD}".raw || exit_with_error "Partition fail."
}

#this formats the 2 new partitons, and sets up the fstab file in the image
function format_partitions__600_format_partitons() {

	display_alert "${EXTENSION} ${BOARD}" "format_partitions__600_format_partitons" "info"
	if [[ -n $rootpart ]]; then

		local rootdeviceb="${LOOP}p3"
		check_loop_device "${rootdeviceb}"
		display_alert "Creating second rootfs " "$ROOTFS_TYPE on 3"
		run_host_command_logged mkfs.${mkfs[$ROOTFS_TYPE]} ${mkopts[$ROOTFS_TYPE]} ${mkopts_label[$ROOTFS_TYPE]:+${mkopts_label[$ROOTFS_TYPE]}"armbi_rootb"} "${rootdeviceb}"
		[[ $ROOTFS_TYPE == ext4 ]] && run_host_command_logged tune2fs -o journal_data_writeback "${rootdeviceb}"
		if [[ $ROOTFS_TYPE == btrfs && $BTRFS_COMPRESSION != none ]]; then
			local fscreateopt="-o compress-force=${BTRFS_COMPRESSION}"
		fi
		wait_for_disk_sync "after mkfs" # force writes to be really flushed

		# store in readonly global for usage in later hooks
		rootb_part_uuid="$(blkid -s UUID -o value ${LOOP}p3)"
		declare -g -r ROOTB_PART_UUID="${rootb_part_uuid}"

		display_alert "Mounting root b fs" "$rootdevice (UUID=${ROOTB_PART_UUID})"
		mkdir -p "${MOUNT}/rfs_backup"
		run_host_command_logged mount ${fscreateopt} $rootdeviceb $MOUNT/rfs_backup

		# create fstab (and crypttab) entry
		local rootfsb
		if [[ $CRYPTROOT_ENABLE == yes ]]; then
			# map the LUKS container partition via its UUID to be the 'cryptroot' device
			echo "$ROOT_MAPPER UUID=${root_part_uuid} none luks" >> $SDCARD/etc/crypttab
			rootfsb=${rootdeviceb} # used in fstab
		else
			rootfsb="UUID=$(blkid -s UUID -o value ${rootdeviceb})"
		fi
		#ToDo: possibly remove the mount
		echo "$rootfsb /rfs_backup ${mkfs[$ROOTFS_TYPE]} defaults,noatime${mountopts[$ROOTFS_TYPE]} 0 2"
		echo "$rootfsb /rfs_backup ${mkfs[$ROOTFS_TYPE]} defaults,noatime${mountopts[$ROOTFS_TYPE]} 0 2" >> $SDCARD/etc/fstab

		local datadevice="${LOOP}p4"
		check_loop_device "${datadevice}"
		display_alert "Creating data rootfs " "$ROOTFS_TYPE on 4"
		run_host_command_logged mkfs.${mkfs[$ROOTFS_TYPE]} ${mkopts[$ROOTFS_TYPE]} ${mkopts_label[$ROOTFS_TYPE]:+${mkopts_label[$ROOTFS_TYPE]}"armbi_data"} "${datadevice}"
		[[ $ROOTFS_TYPE == ext4 ]] && run_host_command_logged tune2fs -o journal_data_writeback "${datadevice}"
		if [[ $ROOTFS_TYPE == btrfs && $BTRFS_COMPRESSION != none ]]; then
			local fscreateopt="-o compress-force=${BTRFS_COMPRESSION}"
		fi
		wait_for_disk_sync "after mkfs" # force writes to be really flushed

		display_alert "Mounting datafs" "$datadevice (UUID=${ROOT_PART_UUID})"
		mkdir -p "${MOUNT}/home"
		run_host_command_logged mount ${fscreateopt} $datadevice $MOUNT/home

		# store in readonly global for usage in later hooks
		data_part_uuid="$(blkid -s UUID -o value ${LOOP}p3)"
		declare -g -r DATA_PARTB_UUID="${data_part_uuid}"

		# create fstab (and crypttab) entry
		local datafs
		if [[ $CRYPTROOT_ENABLE == yes ]]; then
			# map the LUKS container partition via its UUID to be the 'cryptroot' device
			echo "$ROOT_MAPPER UUID=${ata_part_uuid} none luks" >> $SDCARD/etc/crypttab
			datafs=$datadevice # used in fstab
		else
			datafs="UUID=$(blkid -s UUID -o value $datadevice)"
		fi
		echo "$datafs  /home         ${mkfs[$ROOTFS_TYPE]} defaults,noatime${mountopts[$ROOTFS_TYPE]} 0 2" >> $SDCARD/etc/fstab
	fi

	# stage: create new fstab, with labels and not UUID
	rm -f $SDCARD/etc/fstab
	display_alert "${EXTENSION} ${BOARD}" "Adding comments to fstab" "info"
	echo "LABEL=armbi_roota /           ${mkfs[$ROOTFS_TYPE]} defaults,noatime${mountopts[$ROOTFS_TYPE]} 0 1" >> $SDCARD/etc/fstab
	#echo "LABEL=armbi_rootb /rfs_backup ${mkfs[$ROOTFS_TYPE]} defaults,noatime${mountopts[$ROOTFS_TYPE]} 0 2" >> $SDCARD/etc/fstab
	echo "LABEL=armbi_data  /home       ${mkfs[$ROOTFS_TYPE]} defaults,noatime${mountopts[$ROOTFS_TYPE]} 0 2" >> $SDCARD/etc/fstab
	echo "tmpfs             /tmp        tmpfs defaults,nosuid 0 0" >> $SDCARD/etc/fstab
	echo "LABEL=RPICFG      ${UEFI_MOUNT_POINT} vfat defaults 0 2" >> $SDCARD/etc/fstab

}
