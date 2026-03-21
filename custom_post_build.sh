#!/bin/bash
set -e

TOP_DIR=$(readlink -f $(pwd))
echo "PROJ_DIR: ${TOP_DIR}"

# 定义路径（根据你的实际架构修改TARGET_TRIPLE）
TARGET_TRIPLE="aarch64-buildroot-linux-gnu"  # 替换为你的目标架构
BUILDROOT_OUTPUT="${TOP_DIR}/output"
ROOTFS_INCLUDE_PARENTDIR="${BUILDROOT_OUTPUT}/target/usr/include"
HOST_INCLUDE="${BUILDROOT_OUTPUT}/host/usr/${TARGET_TRIPLE}/sysroot/usr/include"

# 创建根文件系统的include目录
mkdir -p ${ROOTFS_INCLUDE_PARENTDIR}

# 拷贝系统头文件到根文件系统
cp -ar ${HOST_INCLUDE}/* ${ROOTFS_INCLUDE_PARENTDIR}

# 可选：仅拷贝需要的头文件（减少体积）
# cp -r ${HOST_INCLUDE}/stdio.h ${HOST_INCLUDE}/stdlib.h ${ROOTFS_INCLUDE}/

