#!/bin/bash
# Build OK8MP userspace and kernel, then deploy a matching NFS root filesystem.
set -euo pipefail

buildroot_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
kernel_dir=${KERNEL_DIR:-"$buildroot_dir/../8mp_v6.1"}
kernel_build_dir=${KERNEL_BUILD_DIR:-"$kernel_dir"}
tftp_dir=${TFTP_DIR:-"$HOME/tftp_dir"}
jobs=${JOBS:-16}
clean_build=false
deploy=true
deploy_bundle=
staging_root=
rootfs_backup=
rootfs_replaced=false
deployment_complete=false
replaced_images=()

die()
{
	printf '错误：%s\n' "$*" >&2
	exit 1
}

usage()
{
	cat <<'EOF'
用法：./build_rootfs.sh [--clean] [-j 数量] [--no-deploy]
      ./build_rootfs.sh --deploy-only 打包目录

默认保留现有 .config，编译 Buildroot 和内核，并部署到 ~/tftp_dir/rootfs。
--clean        先执行 Buildroot make clean；保留 .config 和下载缓存
--no-deploy    只构建、打包，不使用 sudo，不修改 TFTP 目录
--deploy-only  部署之前生成的完整包，不重新编译

可覆盖环境变量：JOBS、KERNEL_DIR、KERNEL_BUILD_DIR、CROSS_COMPILE、TFTP_DIR。
请以普通用户运行；部署阶段自动调用 sudo。
替换正在被板端挂载的 NFS rootfs 会影响运行，请先停止板端系统。
EOF
}

while (($#)); do
	case "$1" in
	--clean) clean_build=true ;;
	--no-deploy) deploy=false ;;
	-j|--jobs)
		(($# >= 2)) || die "$1 缺少参数"
		jobs=$2
		shift
		;;
	--deploy-only)
		(($# >= 2)) || die "$1 缺少目录"
		deploy_bundle=$2
		shift
		;;
	-h|--help) usage; exit 0 ;;
	*) die "未知参数：$1" ;;
	esac
	shift
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "并行数量必须为正整数"
[[ $EUID -ne 0 ]] || die "请以普通用户运行，不要 sudo 整个构建脚本"
if [[ -n "$deploy_bundle" ]] && { "$clean_build" || ! "$deploy"; }; then
	die "--deploy-only 不能与 --clean 或 --no-deploy 同时使用"
fi

for tool in make tar python3 sha256sum depmod flock realpath mountpoint; do
	command -v "$tool" >/dev/null || die "缺少命令：$tool"
done

# Keep the lock outside output/, which make clean removes.
lock_key=$(printf '%s' "$buildroot_dir" | sha256sum | cut -d ' ' -f 1)
exec 9>"${TMPDIR:-/tmp}/ok8mp-rootfs-$lock_key.lock"
flock -n 9 || die "同一个 Buildroot 目录已有构建/部署任务运行"

on_exit()
{
	local status=$?
	local image
	if ((status != 0)); then
		if ! "$deployment_complete"; then
			for image in "${replaced_images[@]}"; do
				sudo mv -T -- "$tftp_dir/$image" "$tftp_dir/.$image.failed-$stamp" || true
				if [[ -e "$tftp_dir/$image.backup-$stamp" ||
				      -L "$tftp_dir/$image.backup-$stamp" ]]; then
					sudo cp -a -- "$tftp_dir/$image.backup-$stamp" "$tftp_dir/$image" || true
				fi
			done
			if "$rootfs_replaced"; then
				sudo mv -T -- "$tftp_dir/rootfs" "$staging_root" || true
			fi
			if [[ -n "$rootfs_backup" && ! -e "$tftp_dir/rootfs" ]]; then
				sudo mv -T -- "$rootfs_backup" "$tftp_dir/rootfs" || true
			fi
		fi
		[[ -z "$staging_root" ]] || printf '部署暂存目录保留在：%s\n' "$staging_root" >&2
		[[ -z "$deploy_bundle" ]] || printf '构建包保留在：%s\n' "$deploy_bundle" >&2
	fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$deploy_bundle" ]]; then
	[[ -f "$buildroot_dir/.config" ]] || make -C "$buildroot_dir" OK8MP_defconfig
	make -C "$buildroot_dir" olddefconfig
	grep -qx 'BR2_TARGET_ROOTFS_TAR=y' "$buildroot_dir/.config" || die "请启用 tar 根文件系统"
	grep -qx 'BR2_TARGET_ROOTFS_TAR_NONE=y' "$buildroot_dir/.config" || die "请将 tar 压缩设为 none"

	old_init=$(readlink "$buildroot_dir/output/target/sbin/init" || true)
	if ! "$clean_build" && grep -qx 'BR2_INIT_BUSYBOX=y' "$buildroot_dir/.config" &&
	   [[ "$old_init" == *systemd* ]]; then
		die "配置已改为 BusyBox，但旧 target 仍使用 systemd；请增加 --clean 完整重建"
	fi
	if "$clean_build"; then
		make -C "$buildroot_dir" clean
	fi
	make -C "$buildroot_dir" -j"$jobs"

	kernel_dir=$(realpath -e -- "$kernel_dir")
	kernel_build_dir=$(realpath -e -- "$kernel_build_dir")
	cross_compile=${CROSS_COMPILE:-}
	if [[ -z "$cross_compile" ]]; then
		cross_compile=/opt/toolchains/aarch64-buildroot-linux-gnu_sdk-buildroot/bin/aarch64-buildroot-linux-gnu-
		if [[ ! -x "${cross_compile}gcc" ]]; then
			cross_compile="$buildroot_dir/output/host/bin/aarch64-buildroot-linux-gnu-"
		fi
	fi
	command -v "${cross_compile}gcc" >/dev/null || die "找不到交叉编译器：${cross_compile}gcc"
	kernel_make=(make -C "$kernel_dir" ARCH=arm64 "CROSS_COMPILE=$cross_compile")
	[[ "$kernel_build_dir" == "$kernel_dir" ]] || kernel_make+=("O=$kernel_build_dir")
	[[ -f "$kernel_build_dir/.config" ]] || "${kernel_make[@]}" OK8MP-C_defconfig
	"${kernel_make[@]}" -j"$jobs" Image modules freescale/OK8MP-C.dtb

	release=$(cat "$kernel_build_dir/include/config/kernel.release")
	[[ "$release" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "内核版本字符串不合法"
	[[ -s "$kernel_build_dir/Module.symvers" ]] || die "缺少内核 Module.symvers"
	deploy_bundle=$(mktemp -d "$buildroot_dir/output/images/netboot-$(date +%Y%m%d-%H%M%S).XXXXXX")
	module_stage="$deploy_bundle/modules-stage"
	"${kernel_make[@]}" "INSTALL_MOD_PATH=$module_stage" INSTALL_MOD_STRIP=1 modules_install
	depmod -e -E "$kernel_build_dir/Module.symvers" -b "$module_stage" "$release" \
		2>"$deploy_bundle/depmod-check.log"
	if [[ -s "$deploy_bundle/depmod-check.log" ]]; then
		cat "$deploy_bundle/depmod-check.log" >&2
		die "模块依赖/符号检查有告警，停止部署"
	fi

	# Repack the official image, preserving owners, modes, hard links and xattrs.
	# Remove old module trees from the COPY, never from Buildroot's target/.
	python3 - "$buildroot_dir/output/images/rootfs.tar" "$deploy_bundle/rootfs.tar" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:") as source, tarfile.open(
	sys.argv[2], "w", format=tarfile.PAX_FORMAT
) as target:
	for member in source:
		name = member.name.removeprefix("./").rstrip("/")
		if name.startswith("/") or ".." in name.split("/"):
			raise ValueError("Unsafe rootfs archive path: " + member.name)
		if any(name == prefix or name.startswith(prefix + "/") for prefix in (
			"lib/modules", "usr/lib/modules"
		)):
			continue
		data = source.extractfile(member) if member.isfile() else None
		target.addfile(member, data)
		if data is not None:
			data.close()
PY
	module_prefix=lib/modules
	if grep -qx 'BR2_ROOTFS_MERGED_USR=y' "$buildroot_dir/.config"; then
		module_prefix=usr/lib/modules
	fi
	tar --append --file="$deploy_bundle/rootfs.tar" --owner=0 --group=0 \
		--exclude='modules/*/build' --exclude='modules/*/source' \
		--transform="s,^modules,$module_prefix," -C "$module_stage/lib" modules
	cp "$kernel_build_dir/arch/arm64/boot/Image" "$deploy_bundle/Image"
	cp "$kernel_build_dir/arch/arm64/boot/dts/freescale/OK8MP-C.dtb" "$deploy_bundle/OK8MP-C.dtb"
	printf '%s\n' "$release" > "$deploy_bundle/kernel.release"
	cp "$buildroot_dir/.config" "$deploy_bundle/buildroot.config"
	cp "$kernel_build_dir/.config" "$deploy_bundle/kernel.config"
	(cd "$deploy_bundle" && sha256sum rootfs.tar Image OK8MP-C.dtb kernel.release \
		buildroot.config kernel.config > SHA256SUMS)
	printf '构建包：%s\n' "$deploy_bundle"
fi

"$deploy" || exit 0
deploy_bundle=$(realpath -e -- "$deploy_bundle")
(cd "$deploy_bundle" && sha256sum -c SHA256SUMS)
release=$(cat "$deploy_bundle/kernel.release")
[[ "$release" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "内核版本字符串不合法"
tftp_dir=$(realpath -m -- "$tftp_dir")
[[ "$tftp_dir" != / && "$tftp_dir" != "$HOME" ]] || die "TFTP_DIR 不可设为 / 或用户主目录"
[[ ! -L "$tftp_dir/rootfs" ]] || die "rootfs 是符号链接，请先确认真实部署目录"
[[ ! -e "$tftp_dir/rootfs" || -d "$tftp_dir/rootfs" ]] || die "rootfs 不是目录"
if mountpoint -q "$tftp_dir/rootfs"; then
	die "rootfs 是本机挂载点，不能直接替换"
fi
command -v sudo >/dev/null || die "部署需要 sudo"
sudo -v
sudo mkdir -p -- "$tftp_dir"
staging_root=$(sudo mktemp -d "$tftp_dir/.rootfs-new.XXXXXX")
sudo tar --extract --file="$deploy_bundle/rootfs.tar" --directory="$staging_root" \
	--same-owner --numeric-owner --preserve-permissions --xattrs --xattrs-include='*'
sudo test -e "$staging_root/sbin/init" || die "新 rootfs 缺少有效的 /sbin/init"
sudo test -d "$staging_root/lib/modules/$release" || die "新 rootfs 缺少匹配的内核模块"
sudo depmod -b "$staging_root" "$release"

stamp=$(date +%Y%m%d-%H%M%S)-$$
for image in Image OK8MP-C.dtb; do
	[[ ! -d "$tftp_dir/$image" ]] || die "$tftp_dir/$image 是目录"
	if [[ -e "$tftp_dir/$image" || -L "$tftp_dir/$image" ]]; then
		sudo cp -a -- "$tftp_dir/$image" "$tftp_dir/$image.backup-$stamp"
	fi
	sudo install -m 0644 "$deploy_bundle/$image" "$tftp_dir/.$image.new-$stamp"
done
if [[ -d "$tftp_dir/rootfs" ]]; then
	rootfs_backup="$tftp_dir/rootfs.backup-$stamp"
	sudo mv -T -- "$tftp_dir/rootfs" "$rootfs_backup"
fi
sudo mv -T -- "$staging_root" "$tftp_dir/rootfs"
rootfs_replaced=true
for image in Image OK8MP-C.dtb; do
	sudo mv -T -- "$tftp_dir/.$image.new-$stamp" "$tftp_dir/$image"
	replaced_images+=("$image")
done
sync
deployment_complete=true
staging_root=
printf '已部署：%s/rootfs\n内核版本：%s\n' "$tftp_dir" "$release"
[[ -z "$rootfs_backup" ]] || printf '旧 rootfs 备份：%s\n' "$rootfs_backup"
printf '%s\n' '如已通过 NFS 导出该目录，请执行 sudo exportfs -ra 刷新导出后再启动板子。'
