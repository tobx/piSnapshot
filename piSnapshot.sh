#! /bin/bash
#
# piSnapshot - Backup your Raspberry PI

set -e

version="0.1.0"

my_path=$0
my_basename=${my_path##*/}
my_name=${my_basename%.*}

usage="Usage:
  Backup:
    $my_basename [options]
  Restore:
    $my_basename [options] <source> <target>

Backup or restore a Raspberry PI SD card

  <source>  backup source path
  <target>  restore device (SD card) path

Options:
 -h         display this help and exit
 -p         show progress during transfers
 -v         output version information and exit
"

config_file="/usr/local/etc/$my_name.conf"
exclude_file="${config_file%.*}Exclude.txt"

# ==== Backup ====

backup() {
	if ! is_mounted "$backup_mount_point"; then
		error "No external device mounted on '$backup_mount_point'."
		return 1
	fi
	backup_root_path="$backup_mount_point/$my_name/$backup_name"
	latest_backup_path="$backup_root_path/Latest"
	new_backup_path="$backup_root_path/$(date --date="$start_time" +%Y-%m-%d-%H%M%S)"
	incomplete_backup_path="$new_backup_path.incomplete"
	log "Backup from device '$system_device' to '$new_backup_path'..."
	mkdir --parents "$incomplete_backup_path/boot" "$incomplete_backup_path/root"
	create_backup_configuration_file
	backup_partition_table
	backup_boot_partition
	backup_root_partition
	mv "$incomplete_backup_path" "$new_backup_path"
	rm "$latest_backup_path"
	ln -sr "$new_backup_path" "$latest_backup_path"
	log "Backup successfully completed."
}

backup_boot_partition() {
	log "Backing up boot partition..."
	local args=("$rsync_options")
	if [ -n "$rsync_info" ]; then
		args+=("--info=$rsync_info")
	fi
	if [ -d "$latest_backup_path" ]; then
		args+=("--link-dest=$latest_backup_path/boot")
	fi
	rsync "${args[@]}" /boot/ "$incomplete_backup_path/boot"
}

backup_root_partition() {
	log "Backing up root partition..."
	local args=("$rsync_options")
	if [ -n "$rsync_info" ]; then
		args+=("--info=$rsync_info")
	fi
	if [ -d "$latest_backup_path" ]; then
		args+=("--link-dest=$latest_backup_path/root")
	fi
	args+=("--exclude-from=$exclude_file")
	rsync "${args[@]}" / "$incomplete_backup_path/root"
}

backup_partition_table() {
	log "Backing up partition table..."
	sfdisk --quiet --dump "$system_device" > "$incomplete_backup_path/partition_table.txt"
}

create_backup_configuration_file() {
	partition_table_UUID=$(blkid -o udev "$system_device" | grep TABLE_UUID | cut -d= -f2)
	if [ -z "$partition_table_UUID" ]; then
		error "Cannot identify system partition table UUID."
		return 1
	fi
	local backup_config_file=$incomplete_backup_path/config.txt
	echo "rsync_options=$rsync_options" > "$backup_config_file"
	echo "partition_table_UUID=$partition_table_UUID" >> "$backup_config_file"
	log "Created backup configuration file."
}

# ==== Restore ====

restore() {
	backup_path=${1%/}
	restore_device=$2
	boot_partition=${restore_device}1
	root_partition=${restore_device}2
	. "$backup_path/config.txt"
	verify_restore_device
	log "Restore from '$backup_path' to device '$restore_device'..."
	restore_partition_table
	format_boot_partition
	format_root_partition
	mkdir --parents "$restore_mount_point"
	restore_boot_partition
	restore_root_partition
	log "Restore successfully completed."
}

format_boot_partition() {
	log "Creating FAT32 file system on boot partition '$boot_partition'..."
	mkfs.vfat -F 32 "$boot_partition" > /dev/null
	sleep 1 # wait for kernel to reread file system
}

format_root_partition() {
	log "Creating ext4 file system on root partition '$root_partition'..."
	mkfs.ext4 -Fq "$root_partition"
	sleep 1 # wait for kernel to reread file system
}

restore_boot_partition() {
	log "Restoring boot partition to '$boot_partition'..."
	mount "$boot_partition" "$restore_mount_point"
	local args=("$rsync_options")
	if [ -n "$rsync_info" ]; then
		args+=("--info=$rsync_info")
	fi
	rsync "${args[@]}" "$backup_path/boot/" "$restore_mount_point"
	umount "$restore_mount_point"
}

restore_root_partition() {
	log "Restoring root partition to '$root_partition'..."
	mount "$root_partition" "$restore_mount_point"
	local args=("$rsync_options")
	if [ -n "$rsync_info" ]; then
		args+=("--info=$rsync_info")
	fi
	rsync "${args[@]}" "$backup_path/root/" "$restore_mount_point"
	umount "$restore_mount_point"
}

restore_partition_table() {
	log "Restoring partition table on '$restore_device'..."
	sfdisk --quiet "$restore_device" < "$backup_path/partition_table.txt"
	sleep 1 # wait for kernel to reread partition table
	printf "x\ni\n0x%s\nr\nw" "$partition_table_UUID" | fdisk "$restore_device" > /dev/null
}

verify_restore_device() {
	if [ ! -b "$restore_device" ]; then
		error "'$restore_device' is no block device."
		return 1
	fi
	if is_mounted "$restore_device"; then
		error "No partition of device '$restore_device' must be mounted."
		return 1
	fi
	if is_mounted "$restore_mount_point"; then
		error "No device must be mounted on '$restore_mount_point'."
		return 1
	fi
}

# ==== Utilities ====

is_mounted() {
	grep -qs "$1" /proc/mounts
}

error() {
	>&2 log "$1"
}

log() {
	printf "%b\n" "$1"
}

quit() {
	[ -z "$1" ] && exit 0;
	exit "$1"
}

# ==== Main program ====

# load piSnapshot configuration file.
. "$config_file"

# Parse script options.
while getopts "hpv" option; do
	case $option in
		h)
			log "$usage"
			quit
			;;
		p)
			rsync_info="progress2"
			;;
		v)
			log "$my_name version $version"
			quit
			;;
		?)
			error "Try '$my_basename -h' for more information."
			quit 1
			;;
	esac
done
shift $((OPTIND-1))

start_time=$(date)

log "$my_basename version $version started at $start_time."

# Check if script was run as root.
if [ "$EUID" -ne 0 ]; then
	error "$my_basename must be run as root."
	quit 1
fi

# Parse command line arguments.
case $# in
	0)
		backup
		;;
	2)
		restore "$1" "$2"
		;;
	*)
		error "$my_path: illegal number of arguments"
		error "Try '$my_basename -h' for more information.";
		quit 1
		;;
esac

quit
