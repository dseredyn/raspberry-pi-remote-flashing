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

## Paths
SCRIPT=$(realpath $0)
SCRIPT_PATH=$(dirname $SCRIPT)
SOURCES_PATH="${SCRIPT_PATH}/sources"
BUILD_PATH="${SCRIPT_PATH}/build"
ARTIFACTS_PATH="${SCRIPT_PATH}/artifacts"
PATCHES_PATH="${SCRIPT_PATH}/patches"
SCRIPTS_PATH="${SCRIPT_PATH}/scripts"

## Settings
IMAGE_NANE="recovery.img"
IMAGE_PATH="${SCRIPT_PATH}/${IMAGE_NANE}"
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

print_title() {
    echo ""
    echo -e '\033[1;30m'"$1"'\033[0m'
}


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
