#! /bin/bash
#
# piSnapshot - Installation

set -e

my_path=$0
my_basename=${my_path##*/}

# check if script was run as root
if [ "$EUID" -ne 0 ]; then
	>&2 echo "$my_basename must be run as root. Try 'sudo $my_path'."
	exit 1
fi

cd $(dirname "$0")

bin_dir=/usr/local/bin/
etc_dir=/usr/local/etc/

cp -vt "$bin_dir" piSnapshot.sh
cp -vt "$etc_dir" piSnapshot.conf piSnapshotExclude.txt
chmod 755 "$bin_dir/piSnapshot.sh"
mkdir --parents /mnt/backup

echo "piSnapshot installation successfully completed."

exit 0
