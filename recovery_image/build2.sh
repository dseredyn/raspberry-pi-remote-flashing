#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-2.0 #
# (C) Copyright Argus Cyber Security Ltd
#  All rights reserved

#######################################################################################################################
# Script Name   :   Recovery Image Generator
# Description   :   This scripts fetch U-Boot sources and Raspberry Pi Firmware files
#                   build U-boot from sources, and then constructs a template image
#                   that is flashed on the Raspberry Pi SD Card to enable the remote flashing.
# Args          :   clean (cleans sources and build folder)
# Date          :   23/11/2020
# Author        :   Itay Sperling
# Email         :   itay.sperling@argus-sec.com
#######################################################################################################################
# Modified by Dawid Seredynski
# Email dawid.seredynski (at) gmail.com
#######################################################################################################################

set -e

print_title() {
    echo ""
    echo -e '\033[1;30m'"$1"'\033[0m'
}

## Paths
BUILDROOT_PATH="/home/dseredyn/Dawid/dydaktyka/21Z/skps_21z/buildroot/try2/buildroot-2021.08"
IMAGE_NANE="skps.img"

SCRIPT=$(realpath $0)
SCRIPT_PATH=$(dirname $SCRIPT)
BUILD_PATH="${SCRIPT_PATH}/build"
IMAGE_PATH="${SCRIPT_PATH}/${IMAGE_NANE}"
SCRIPTS_PATH="${SCRIPT_PATH}/scripts"

# Partitions sizes are in KiB
let PARTITION_1_SIZE_KB=128*1024
PARTITION_1_NAME=boot

let PARTITION_2_SIZE_KB=4*1024*1024
PARTITION_2_NAME=rootfs_recovery

let PARTITION_3_SIZE_KB=256*1024
PARTITION_3_NAME=images

let PARTITION_4_SIZE_KB=4*1024*1024
PARTITION_4_NAME=rootfs

# Set alignment to 4MB [in KiB]
IMAGE_ROOTFS_ALIGNMENT="4096"

PARTITION_1_SIZE_KB_ALIGNED=$(( PARTITION_1_SIZE_KB + IMAGE_ROOTFS_ALIGNMENT - 1 ))
PARTITION_1_SIZE_KB_ALIGNED=$(( PARTITION_1_SIZE_KB_ALIGNED - (( PARTITION_1_SIZE_KB_ALIGNED % IMAGE_ROOTFS_ALIGNMENT)) ))

PARTITION_2_SIZE_KB_ALIGNED=$(( PARTITION_2_SIZE_KB + IMAGE_ROOTFS_ALIGNMENT - 1 ))
PARTITION_2_SIZE_KB_ALIGNED=$(( PARTITION_2_SIZE_KB_ALIGNED - (( PARTITION_2_SIZE_KB_ALIGNED % IMAGE_ROOTFS_ALIGNMENT)) ))

PARTITION_3_SIZE_KB_ALIGNED=$(( PARTITION_3_SIZE_KB + IMAGE_ROOTFS_ALIGNMENT - 1 ))
PARTITION_3_SIZE_KB_ALIGNED=$(( PARTITION_3_SIZE_KB_ALIGNED - (( PARTITION_3_SIZE_KB_ALIGNED % IMAGE_ROOTFS_ALIGNMENT)) ))

PARTITION_4_SIZE_KB_ALIGNED=$(( PARTITION_4_SIZE_KB + IMAGE_ROOTFS_ALIGNMENT - 1 ))
PARTITION_4_SIZE_KB_ALIGNED=$(( PARTITION_4_SIZE_KB_ALIGNED - (( PARTITION_4_SIZE_KB_ALIGNED % IMAGE_ROOTFS_ALIGNMENT)) ))


function build_uboot_script() {
    mkdir -p "${BUILD_PATH}"

    # Build Boot Script
    print_title "Building U-BOOT boot script.."
    mkimage -A arm -O linux -T script -C none -n boot_script -d "${SCRIPTS_PATH}/boot_script.txt" "${BUILD_PATH}/boot.scr.uimg"
}

function create_image() {
    print_title "Generating Image.."

    cd "${BUILD_PATH}"

    # Remove old image if exists
    rm -rf "${IMAGE_PATH}"

    # Recovery Image Settings
    # Use an uncompressed ext3 by default as rootfs
    ROOTFS_REC_TYPE="ext4"
    ROOTFS_TYPE="ext4"
    #ROOTFS_PT_SIZE="10485760" #10GB
    # Boot partition size [in KiB] (will be rounded up to IMAGE_ROOTFS_ALIGNMENT)
    #BOOT_PART_SIZE="262144" # 256MB

    #SDIMG_SIZE=$(( IMAGE_ROOTFS_ALIGNMENT + BOOT_PART_SIZE_ALIGNED + ROOTFS_PT_SIZE ))

    PARTITION_1_START="${IMAGE_ROOTFS_ALIGNMENT}"
    PARTITION_1_END=$(( PARTITION_1_SIZE_KB_ALIGNED + IMAGE_ROOTFS_ALIGNMENT ))
    PARTITION_2_END=$(( PARTITION_2_SIZE_KB_ALIGNED + PARTITION_1_END ))
    PARTITION_3_END=$(( PARTITION_3_SIZE_KB_ALIGNED + PARTITION_2_END ))
    PARTITION_4_END=$(( PARTITION_4_SIZE_KB_ALIGNED + PARTITION_3_END ))

    #BOOT_PARTITION_END=$(( UBOOT_PARTITION_END + BOOT_PART_SIZE_ALIGNED ))

    SDIMG_SIZE=$((IMAGE_ROOTFS_ALIGNMENT + PARTITION_1_SIZE_KB_ALIGNED + PARTITION_2_SIZE_KB_ALIGNED + PARTITION_3_SIZE_KB_ALIGNED + PARTITION_4_SIZE_KB_ALIGNED))

    sudo dd if=/dev/zero of=${IMAGE_PATH} bs=1024 count=0 seek=${SDIMG_SIZE}
    sudo parted -s ${IMAGE_PATH} mklabel msdos
    sudo parted -s ${IMAGE_PATH} unit KiB mkpart primary fat32 ${PARTITION_1_START} ${PARTITION_1_END}
    sudo parted -s ${IMAGE_PATH} set 1 boot on
    sudo parted -s ${IMAGE_PATH} unit KiB mkpart primary ${ROOTFS_REC_TYPE} ${PARTITION_1_END} ${PARTITION_2_END}
    sudo parted -s ${IMAGE_PATH} unit KiB mkpart primary fat32 ${PARTITION_2_END} ${PARTITION_3_END}

    # Note the use of ‘--’, to prevent the following ‘-1s’ last-sector indicator from being interpreted as an invalid command-line option
    sudo parted -s ${IMAGE_PATH} -- unit KiB mkpart primary ${ROOTFS_TYPE} ${PARTITION_3_END} -1s
    sudo parted ${IMAGE_PATH} print

    # Format partitions
    variable=$(sudo kpartx -av "${IMAGE_PATH}")
    print_title "$variable"

    # Get loop device name
    while IFS= read -r line;
    do
        echo "LINE: '${line}'"
        loopdev_name=$(grep -oP '(?<=add map ).*?(?=p1)' <<< "${line}")
        if [ ! -z "$loopdev_name" ]; then
            break
        fi
    done <<< "$variable"

    print_title "loopdev_name: $loopdev_name"

    LOOPDEV="$loopdev_name"

    sudo mkfs.vfat -F32 -n ${PARTITION_1_NAME} "/dev/mapper/${LOOPDEV}p1"
    sudo mkfs.ext4 -L ${PARTITION_2_NAME} "/dev/mapper/${LOOPDEV}p2"
    sudo mkfs.vfat -F32 -n ${PARTITION_3_NAME} "/dev/mapper/${LOOPDEV}p3"
    sudo mkfs.ext4 -L ${PARTITION_4_NAME} "/dev/mapper/${LOOPDEV}p4"
    sudo parted "${IMAGE_PATH}" print

    # Mount boot Partition and Copy Files
    sudo mkdir -p /mnt/skps1
    sudo mount "/dev/mapper/${LOOPDEV}p1" /mnt/skps1

    sudo cp -rv "${BUILDROOT_PATH}/output/images/"{bcm2711-rpi-4-b.dtb,u-boot.bin} /mnt/skps1/
    sudo cp -rv "${BUILDROOT_PATH}/output/images/rpi-firmware/"{overlays,cmdline.txt,fixup.dat,start.elf} /mnt/skps1/

    #sudo cp -rv "${SOURCES_PATH}/firmware-${RPI_FIRMWARE_VER}/boot/"{overlays,bootcode.bin,bcm2711-*.dtb,fixup4*.dat,start4*.elf} /mnt/rpi/
    #sudo cp -rv "${SCRIPT_PATH}/config.txt" /mnt/rpi/

    # Copy U-BOOT script
    sudo cp -rv "${BUILD_PATH}/boot.scr.uimg" /mnt/skps1/

    sudo cp -rv "/home/dseredyn/Dawid/dydaktyka/21Z/skps_21z/online_flashing/original_image/raspios_extracted/boot_partition/kernel8.img" /mnt/skps1/

    sudo cp -rv "${SCRIPT_PATH}/config.txt" /mnt/skps1/

    #sudo cp -rv "${SCRIPT_PATH}/env.txt" /mnt/rpi/
    #sudo cp -rv "${SCRIPT_PATH}/kernimg.txt" /mnt/rpi/

    sudo mkdir -p /mnt/skps2
    sudo mount "/dev/mapper/${LOOPDEV}p2" /mnt/skps2

    cd /mnt/skps2

    sudo tar -xf "/home/dseredyn/Dawid/dydaktyka/21Z/skps_21z/online_flashing/original_image/raspios_extracted/filesystem.tar" 
    sudo cp -rv "${SCRIPT_PATH}/fstab" /mnt/skps2/etc/fstab

    read  -n 1 -p "Filesystems are mounted. You can now check their contents, or add some files. Press any key to continue:" "mainmenuinput"

    sync
    sudo umount /mnt/skps1
    sudo umount /mnt/skps2

    cd "${BUILD_PATH}"

    sudo kpartx -dv "${IMAGE_PATH}"

    CURRENT_USER=$(whoami)
    sudo chown "${CURRENT_USER}:${CURRENT_USER}" "${IMAGE_PATH}"
}

build_uboot_script
create_image

exit 0

ARTIFACTS_PATH="${SCRIPT_PATH}/artifacts"
PATCHES_PATH="${SCRIPT_PATH}/patches"
SCRIPTS_PATH="${SCRIPT_PATH}/scripts"

## Settings

TRUNCATE_IMAGE_AFTER="700M" #MB

# Be careful when changing the following. U-boot version should be compatible with firmware version.
RPI_FIRMWARE_VER="1.20210831"
U_BOOT_VER="2021.10-rc4"

# Toolchain for 32 bits: arm-linux-gnueabi
# Toolchain for 64 bits: aarch64-linux-gnu
TOOLCHAIN=arm-linux-gnueabi

# defconfig for 32 bits: rpi_4_32b_defconfig
# toolchain for 64 bits: rpi_4_defconfig
DEFCONFIG=rpi_4_32b_defconfig



# clean old image file
function clean() {
    if [ -d ${ARTIFACTS_PATH} ]; then
        print_title "Cleaning old atrifacts.."
        rm -rf "${BUILD_PATH}"
        rm -rfv "${ARTIFACTS_PATH}"
    fi
}

function parse_script_args() {
    # Clean sources folder (Only extracted tarballs)
    if [[ $1 == "clean" ]]; then
        print_title "Cleaning sources folder.."
        rm -rf $(ls -1 -d ${SOURCES_PATH}/*/ 2>/dev/null)
        exit 0
    fi
}

function handle_dependencies() {
    print_title "Installing dependencies.."
    sudo apt-get install make bison flex kpartx u-boot-tools gcc-${TOOLCHAIN} coreutils -y
}

function get_sources() {
    mkdir -p "${SOURCES_PATH}"

    ## get sources
    cd "${SOURCES_PATH}"

    # Raspberry Pi Firmware
    if [ ! -f "${RPI_FIRMWARE_VER}.tar.gz" ]; then
        print_title "Downloading Raspberry Pi Firmware ${RPI_FIRMWARE_VER}package"
        wget https://github.com/raspberrypi/firmware/archive/${RPI_FIRMWARE_VER}.tar.gz
    fi

    if [ ! -d "${RPI_FIRMWARE_VER}" ]; then
        tar -xzf ${RPI_FIRMWARE_VER}.tar.gz
    fi

    # U-BOOT
    if [ ! -f "v${U_BOOT_VER}.tar.gz" ]; then
        print_title "Downloading U-Boot ${U_BOOT_VER} sources"
        wget "https://github.com/u-boot/u-boot/archive/v${U_BOOT_VER}.tar.gz"
    fi
}

function patch_sources() {
    if [ ! -d "u-boot-${U_BOOT_VER}" ]; then
        tar -xzf "v${U_BOOT_VER}.tar.gz"

        print_title "Patching U-BOOT.."
        # apply u-boot patches
        cd "u-boot-${U_BOOT_VER}"
        for i in "${PATCHES_PATH}"/u-boot/*.patch; do patch -p1 <"$i"; done
        cd -
    fi
}

function build_sources() {
    mkdir -p "${BUILD_PATH}"

    # Build U-BOOT
    print_title "Building U-BOOT.."
    cd "${SOURCES_PATH}/u-boot-${U_BOOT_VER}"

    make ARCH=arm CROSS_COMPILE=${TOOLCHAIN}- ${DEFCONFIG}
    make ARCH=arm CROSS_COMPILE=${TOOLCHAIN}- -j"$(nproc)"

    # Build Boot Script
    print_title "Building U-BOOT boot script.."
    mkimage -A arm -O linux -T script -C none -n boot_script -d "${SCRIPTS_PATH}/boot_script.txt" "${BUILD_PATH}/boot.scr.uimg"
}

function create_image() {
    print_title "Generating Recovery Image.."

    cd "${BUILD_PATH}"

    # Remove old image if exists
    rm -rf "${IMAGE_PATH}"

    # Recovery Image Settings
    # Use an uncompressed ext3 by default as rootfs
    SDIMG_ROOTFS_TYPE="ext3"
    ROOTFS_PT_SIZE="10485760" #10GB
    # Boot partition size [in KiB] (will be rounded up to IMAGE_ROOTFS_ALIGNMENT)
    BOOT_PART_SIZE="262144" # 256MB
    # Set alignment to 4MB [in KiB]
    IMAGE_ROOTFS_ALIGNMENT="4096"

    BOOT_PART_SIZE_ALIGNED=$(( BOOT_PART_SIZE + IMAGE_ROOTFS_ALIGNMENT - 1 ))
    BOOT_PART_SIZE_ALIGNED=$(( BOOT_PART_SIZE_ALIGNED - (( BOOT_PART_SIZE_ALIGNED % IMAGE_ROOTFS_ALIGNMENT)) ))
    SDIMG_SIZE=$(( IMAGE_ROOTFS_ALIGNMENT + BOOT_PART_SIZE_ALIGNED + ROOTFS_PT_SIZE ))

    UBOOT_PARTITION_START="${IMAGE_ROOTFS_ALIGNMENT}"
    UBOOT_PARTITION_END=$(( BOOT_PART_SIZE_ALIGNED + IMAGE_ROOTFS_ALIGNMENT ))
    BOOT_PARTITION_END=$(( UBOOT_PARTITION_END + BOOT_PART_SIZE_ALIGNED ))

    sudo dd if=/dev/zero of=${IMAGE_PATH} bs=1024 count=0 seek=${SDIMG_SIZE}
    sudo parted -s ${IMAGE_PATH} mklabel msdos
    sudo parted -s ${IMAGE_PATH} unit KiB mkpart primary fat32 ${UBOOT_PARTITION_START} ${UBOOT_PARTITION_END}
    sudo parted -s ${IMAGE_PATH} set 1 boot on
    sudo parted -s ${IMAGE_PATH} unit KiB mkpart primary fat32 ${UBOOT_PARTITION_END} ${BOOT_PARTITION_END}
    sudo parted -s ${IMAGE_PATH} -- unit KiB mkpart primary ${SDIMG_ROOTFS_TYPE} ${BOOT_PARTITION_END} -1s
    sudo parted ${IMAGE_PATH} print

    # Format partitions
    variable=$(sudo kpartx -av "${IMAGE_PATH}")
    print_title "$variable"

    # Get loop device name
    while IFS= read -r line;
    do
        echo "LINE: '${line}'"
        loopdev_name=$(grep -oP '(?<=add map ).*?(?=p1)' <<< "${line}")
        if [ ! -z "$loopdev_name" ]; then
            break
        fi
    done <<< "$variable"

    print_title "loopdev_name: $loopdev_name"

    LOOPDEV="$loopdev_name"

    sudo mkfs.vfat -F32 -n raspberry "/dev/mapper/${LOOPDEV}p1"
    sudo mkfs.vfat -F32 -n raspberry "/dev/mapper/${LOOPDEV}p2"
    sudo mkfs.ext3 "/dev/mapper/${LOOPDEV}p3"
    sudo parted "${IMAGE_PATH}" print

    # Mount U-BOOT Partition and Copy Files
    sudo mkdir -p /mnt/rpi
    sudo mount "/dev/mapper/${LOOPDEV}p1" /mnt/rpi

    sudo cp -rv "${SOURCES_PATH}/firmware-${RPI_FIRMWARE_VER}/boot/"{overlays,bootcode.bin,bcm2711-*.dtb,fixup4*.dat,start4*.elf} /mnt/rpi/
    sudo cp -rv "${SCRIPT_PATH}/config.txt" /mnt/rpi/

    # Copy U-BOOT Files
    sudo cp -rv "${SOURCES_PATH}/u-boot-${U_BOOT_VER}/u-boot.bin" /mnt/rpi/
    sudo cp -rv "${BUILD_PATH}/boot.scr.uimg" /mnt/rpi/
    sudo cp -rv "${SCRIPT_PATH}/env.txt" /mnt/rpi/
    sudo cp -rv "${SCRIPT_PATH}/kernimg.txt" /mnt/rpi/

    sync
    sudo umount /mnt/rpi

    cd "${BUILD_PATH}"

    sudo kpartx -dv "${IMAGE_PATH}"

    CURRENT_USER=$(whoami)
    sudo chown "${CURRENT_USER}:${CURRENT_USER}" "${IMAGE_PATH}"
}

function truncating_image() {
    # At this point we have a very large image which is filled with zero so it's going
    # to be a very small after compression, but it still will take long time to flash.
    # The only important parts are until the ROOTFS partition begining.
    # So we can cut it after around 200MB

    echo ""
    print_title "Truncating recovery image after ${TRUNCATE_IMAGE_AFTER} .."
    truncate --size ${TRUNCATE_IMAGE_AFTER} "${IMAGE_PATH}"
}

function compress_image() {
    print_title "Compressing recovery image.."
    tar -cjvf recovery.tar.bz2 "${IMAGE_PATH}"
}

function copy_artifacts() {
    print_title "Copying artifacts to ${ARTIFACTS_PATH}:"
    mkdir -p "${ARTIFACTS_PATH}"
    mv -v "${BUILD_PATH}/recovery.tar.bz2" "${ARTIFACTS_PATH}"
    cp -rv "${BUILD_PATH}/boot.scr.uimg" "${ARTIFACTS_PATH}"
    cp -rv "${SOURCES_PATH}/u-boot-${U_BOOT_VER}/u-boot.bin" "${ARTIFACTS_PATH}"
}

function print_header() {
    echo -e '\033[0;33m'"=================================="
    echo -e "     Recovery Image Builder       "
    echo -e "=================================="'\033[0m'
}

function print_footer() {
    print_title "Done"
}

print_header
clean
parse_script_args "${@}"
handle_dependencies
get_sources
patch_sources
build_sources
create_image
truncating_image
compress_image
copy_artifacts
print_footer
