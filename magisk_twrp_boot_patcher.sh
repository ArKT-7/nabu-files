#!/bin/bash
#
# Copyright (C) 2025-26 https://github.com/ArKT-7
#
# Made For Patching boot.img with Magisk along with TWRP injection option and AOSP required mod for Xiaomi Pad 5 (Nabu)

BASE_URL="https://raw.githubusercontent.com/arkt-7/Auto-Installer-Forge/main"
URL_BUSYBOX="$BASE_URL/bin/linux_amd64/busybox"
URL_7ZZS="$BASE_URL/bin/linux_amd64/7zzs"

ROOT_DIR="$PWD"
CURR_DIR=$(basename "$PWD")

if [ "$CURR_DIR" = "Auto-Magisk-Patcher" ] || [ "$CURR_DIR" = "Auto-Installer-Forge" ]; then
  BASE_DIR="$PWD"
else
  BASE_DIR="$PWD/Auto-Magisk-Patcher"
fi

WORK_DIR="$BASE_DIR/work"
MAGISK_DIR="$WORK_DIR/magisk_patch"
IMG_OUT="$BASE_DIR/patched_images"
ZIP_OUT="$BASE_DIR/patched_release"

mkdir -p "$WORK_DIR" "$MAGISK_DIR" "$IMG_OUT" "$ZIP_OUT"

ARG_GIVEN_FR=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--boot) BOOT_PATH="$2"; ARG_GIVEN_FR=1; shift ;;
        -v|--vendor) VENDOR_PATH="$2"; shift ;;
        -m|--magisk) MAGISK_PATH="$2"; shift ;;
        -t|--twrp) INSTALL_TWRP="$2"; shift ;;
        -r|--ramdisk) RAMDISK_TYPE="$2"; shift ;;
        -a|--aosp) IS_AOSP="$2"; shift ;;
        -s|--sdk) TARGET_SDK_VER="$2"; shift ;;
        *) echo "[!] Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

cleanup() {
    echo -e "\n[INFO] Cleaning up workspace..."
    rm -rf "$WORK_DIR"
    exit 1
}
trap cleanup INT TERM

log() {
    echo -e -e "\n[$(date +"%H:%M:%S")] $1"
}

get_sdk_ver() {
    local ver="${1:-16}"
    if [[ "$ver" =~ ^[0-9]+$ ]]; then
        [ "$ver" -le 12 ] && echo $((ver + 19)) || echo $((ver + 20))
    else
        echo 36
    fi
}

download_file() {
    local url=$1 dest_file=$2
    curl -L -# -o "$dest_file" "$url" || { log "[ERROR] Failed to download $(basename "$dest_file")"; return 1; }
    echo -e "[SUCCESS] $(basename "$dest_file") downloaded!"
    return 0
}

download_with_fallback() {
    PRIMARY_URL="$1"
    FALLBACK_URL="$2"
    DEST_FILE="$3"

    if download_file "$PRIMARY_URL" "$DEST_FILE"; then
        return 0
    else
        if download_file "$FALLBACK_URL" "$DEST_FILE"; then
            return 0
        else
            return 1
        fi
    fi
}

extract_magisk_tools() {
    local apk_path="$1"
    log "[INFO] Extracting Magisk tools..."

    if ! "$WORK_DIR/7zzs" x "$apk_path" "assets/*" "lib/*" -o"$MAGISK_DIR" -y > /dev/null; then
        log "[ERROR] Failed to unzip Magisk APK"
        return 1
    fi

    ARCH_DIR="arm64-v8a"
    LIB_PATH="$MAGISK_DIR/lib/$ARCH_DIR"
    if [ -d "$LIB_PATH" ]; then
        for file in "$LIB_PATH"/*.so; do
            [ -f "$file" ] || continue
            new_name=$(basename "$file" | "$WORK_DIR/busybox" sed -E 's/^lib(.*)\.so$/\1/')
            mv "$file" "$MAGISK_DIR/assets/$new_name"
        done
    else
        log "[ERROR] Library folder not found for $ARCH_DIR"
        return 1
    fi
    ARCH_DIR="x86_64"
    LIB_PATH="$MAGISK_DIR/lib/$ARCH_DIR"
    if [ -d "$LIB_PATH" ]; then
        for file in "$LIB_PATH"/lib{magiskboot,busybox}.so; do
            [ -f "$file" ] || continue
            new_name=$(basename "$file" | "$WORK_DIR/busybox" sed -E 's/^lib(.*)\.so$/\1/')
            mv "$file" "$MAGISK_DIR/assets/$new_name"
        done
    else
        log "[ERROR] Library folder not found for $ARCH_DIR"
        return 1
    fi
    chmod -R +x "$MAGISK_DIR/assets/"
    export MAGISKBOOT="$MAGISK_DIR/assets/magiskboot"
    return 0
}

patch_twrp_recovery() {
    [ "$INSTALL_TWRP" -ne 1 ] && return 0
    TWRP_RAMDISK_PATH="$WORK_DIR/ramdisk.cpio"
    
    if [ ! -f "$TWRP_RAMDISK_PATH" ]; then
        case "$RAMDISK_TYPE" in
            "windows"|"win"|1) RAMDISK_VER="win-ramdisk.cpio" ;;
            "linux"|"lin"|2) RAMDISK_VER="lin-ramdisk.cpio" ;;
            *) RAMDISK_VER="nor-ramdisk.cpio" ;;
        esac
        RAMDISK_URL="https://raw.githubusercontent.com/ArKT-7/nabu-files/main/recovery/$RAMDISK_VER"

        log "[INFO] Downloading TWRP Ramdisk ($RAMDISK_VER)..."
        download_with_fallback \
            "$RAMDISK_URL" \
            "$RAMDISK_URL" \
            "$TWRP_RAMDISK_PATH"
    fi

    if [ ! -f "$TWRP_RAMDISK_PATH" ]; then
        log "[WARNING] Ramdisk download failed, Skipping TWRP integration..."
        return 0
    fi

    log "[INFO] Starting TWRP Ramdisk Integration..."
    local BOOT_IMG="$WORK_DIR/boot.img"
    local VENDOR_BOOT_IMG="$WORK_DIR/vendor_boot.img"
    local WORK_ROOT="$WORK_DIR/twrp_patch_work"
    local WORK_BOOT="$WORK_ROOT/boot"
    local WORK_VENDOR="$WORK_ROOT/vendor"

    if [ -z "$MAGISKBOOT" ] || [ ! -f "$MAGISKBOOT" ]; then
        MAGISKBOOT="$MAGISK_DIR/assets/magiskboot"
    fi
    "$WORK_DIR/busybox" mkdir -p "$WORK_BOOT" "$WORK_VENDOR"
    
    log "[INFO] Patching boot.img with TWRP ramdisk..."
    if ! cd "$WORK_BOOT"; then log "[ERROR] Work dir error, Skipping..."; return 0; fi
    
    "$MAGISKBOOT" unpack "$BOOT_IMG"
    if [ ! -f "kernel" ]; then
        log "[WARNING] Failed to unpack boot.img, Skipping TWRP..."
        cd "$ROOT_DIR"
        "$WORK_DIR/busybox" rm -rf "$WORK_ROOT"
        return 0
    fi

    "$WORK_DIR/busybox" rm -f "ramdisk.cpio"
    "$WORK_DIR/busybox" cp "$TWRP_RAMDISK_PATH" "ramdisk.cpio"
    "$MAGISKBOOT" repack "$BOOT_IMG"
    
    if [ -f "new-boot.img" ]; then
        "$WORK_DIR/busybox" mv "new-boot.img" "twrp-boot.img"
        if [ "$IS_AOSP" -eq 1 ]; then
            log "[INFO] boot.img patched successfully (will do vendor_boot patch now)..."
        else
            log "[INFO] boot.img patched successfully"
        fi
    else
        log "[WARNING] Failed to repack boot.img, Skipping TWRP..."
        cd "$ROOT_DIR"
        "$WORK_DIR/busybox" rm -rf "$WORK_ROOT"
        return 0
    fi

    if [ "$IS_AOSP" -eq 1 ] && [ -f "$VENDOR_BOOT_IMG" ]; then
        log "[INFO] Patching vendor_boot.img fstab..."
        if ! cd "$WORK_VENDOR"; then return 0; fi
        
        "$MAGISKBOOT" unpack "$VENDOR_BOOT_IMG"
        if [ ! -f "ramdisk.cpio" ]; then
            log "[WARNING] Failed to unpack vendor_boot.img, Skipping Vendor patch..."
            cd "$ROOT_DIR"
            "$WORK_DIR/busybox" mv "$WORK_BOOT/twrp-boot.img" "$BOOT_IMG"
            "$WORK_DIR/busybox" rm -rf "$WORK_ROOT"
            return 0
        fi
        
        "$WORK_DIR/busybox" mkdir -p ramdisk_contents
        cd ramdisk_contents
        
        if command -v cpio >/dev/null 2>&1; then
            cpio -idm < ../ramdisk.cpio 2> ../cpio_err.log
        else
            "$WORK_DIR/busybox" cpio -idm < ../ramdisk.cpio 2> ../cpio_err.log
        fi
        
        grep -vE "cpio: .: File exists|[0-9]+ blocks" ../cpio_err.log > ../cpio_filtered_err.log
        if [ -s "../cpio_filtered_err.log" ]; then
            log "[WARNING] Extraction errors found in vendor ramdisk, Skipping Vendor patch..."
            cd "$ROOT_DIR"
            "$WORK_DIR/busybox" mv "$WORK_BOOT/twrp-boot.img" "$BOOT_IMG"
            "$WORK_DIR/busybox" rm -rf "$WORK_ROOT"
            return 0
        fi
        
        "$WORK_DIR/busybox" mkdir -p first_stage_ramdisk
        fstab_file=$(find . -type f -name "fstab.qcom" -not -path "./first_stage_ramdisk/*" | head -n 1)
        if [ -z "$fstab_file" ]; then
            fstab_file=$(find ./first_stage_ramdisk -type f -name "fstab.qcom" | head -n 1)
        else
            if [ -d "first_stage_ramdisk" ]; then
                find first_stage_ramdisk -type f -name "fstab.qcom" -exec rm -v {} \; > /dev/null 2>&1
            fi
        fi
        
        if [ -n "$fstab_file" ]; then
            mv "$fstab_file" first_stage_ramdisk/
        else
            cat > first_stage_ramdisk/fstab.qcom <<'EOF'
system                                                  /system                erofs   ro                                                   wait,slotselect,avb=vbmeta_system,logical,first_stage_mount,avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey
system                                                  /system                ext4    ro,barrier=1,discard                                 wait,slotselect,avb=vbmeta_system,logical,first_stage_mount,avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey
system_ext                                              /system_ext            erofs   ro                                                   wait,slotselect,avb=vbmeta_system,logical,first_stage_mount
system_ext                                              /system_ext            ext4    ro,barrier=1,discard                                 wait,slotselect,avb=vbmeta_system,logical,first_stage_mount
product                                                 /product               erofs   ro                                                   wait,slotselect,avb=vbmeta_system,logical,first_stage_mount
product                                                 /product               ext4    ro,barrier=1,discard                                 wait,slotselect,avb=vbmeta_system,logical,first_stage_mount
vendor                                                  /vendor                erofs   ro                                                   wait,slotselect,avb,logical,first_stage_mount
vendor                                                  /vendor                ext4    ro,barrier=1,discard                                 wait,slotselect,avb,logical,first_stage_mount
odm                                                     /odm                   erofs   ro                                                   wait,slotselect,avb,logical,first_stage_mount
odm                                                     /odm                   ext4    ro,barrier=1,discard                                 wait,slotselect,avb,logical,first_stage_mount
mi_ext                                                  /mnt/vendor/mi_ext     ext4    ro,barrier=1,discard                                 wait,slotselect,avb=vbmeta,logical,first_stage_mount,nofail
mi_ext                                                  /mnt/vendor/mi_ext     erofs   ro                                                   wait,slotselect,avb=vbmeta,logical,first_stage_mount,nofail
/dev/block/by-name/metadata                             /metadata              ext4    noatime,nosuid,nodev,discard                         wait,check,formattable,wrappedkey,first_stage_mount
/dev/block/bootdevice/by-name/boot                      /boot                  emmc    defaults                                             recoveryonly
/dev/block/bootdevice/by-name/userdata                  /data                  f2fs    noatime,nosuid,nodev,discard,reserve_root=32768,resgid=1065,fsync_mode=nobarrier,inlinecrypt     latemount,wait,check,formattable,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0,metadata_encryption=aes-256-xts:wrappedkey_v0,keydirectory=/metadata/vold/metadata_encryption,quota,reservedsize=128M,checkpoint=fs
/dev/block/bootdevice/by-name/modem                     /vendor/firmware_mnt   vfat    ro,shortname=lower,uid=1000,gid=1000,dmask=227,fmask=337,context=u:object_r:firmware_file:s0 wait,slotselect
/dev/block/bootdevice/by-name/dsp                       /vendor/dsp            ext4    ro,nosuid,nodev,barrier=1                            wait,slotselect
/dev/block/bootdevice/by-name/persist                   /mnt/vendor/persist    ext4    noatime,nosuid,nodev,barrier=1                       wait,check
/dev/block/bootdevice/by-name/bluetooth                 /vendor/bt_firmware    vfat    ro,shortname=lower,uid=1002,gid=3002,dmask=227,fmask=337,context=u:object_r:bt_firmware_file:s0 wait,slotselect
/dev/block/bootdevice/by-name/misc                      /misc                  emmc    defaults                                             defaults
/devices/platform/soc/*.ssusb/*.dwc3/xhci-hcd.*.auto* auto                   auto    defaults                                             wait,voldmanaged=usbotg:auto
EOF
        fi

        find . -mindepth 1 ! -path './first_stage_ramdisk' ! -path './first_stage_ramdisk/*' -exec rm -rf {} +
        if command -v cpio >/dev/null 2>&1; then
            find . -mindepth 1 | cpio -o -H newc > ../new_ramdisk.cpio 2>/dev/null
        else
            find . -mindepth 1 | "$WORK_DIR/busybox" cpio -o -H newc > ../new_ramdisk.cpio 2>/dev/null
        fi
        cd "$WORK_VENDOR"
        "$WORK_DIR/busybox" mv new_ramdisk.cpio ramdisk.cpio
        "$MAGISKBOOT" repack "$VENDOR_BOOT_IMG"
        
        if [ -f "new-boot.img" ]; then
            "$WORK_DIR/busybox" mv "new-boot.img" "$VENDOR_BOOT_IMG"
            "$WORK_DIR/busybox" mv "$WORK_BOOT/twrp-boot.img" "$BOOT_IMG"
            log "[SUCCESS] boot.img and vendor_boot.img patched successfully."
        else
            "$WORK_DIR/busybox" mv "$WORK_BOOT/twrp-boot.img" "$BOOT_IMG"
        fi
    else
        "$WORK_DIR/busybox" mv "$WORK_BOOT/twrp-boot.img" "$BOOT_IMG"
    fi

    "$WORK_DIR/busybox" rm -rf "$WORK_ROOT"
    cd "$ROOT_DIR"
    return 0
}

patch_magisk_boot() {
    local apk_path="$1"
    log "[INFO] Patching boot.img with Magisk..\n"

    if [ -z "$MAGISKBOOT" ] || [ ! -f "$MAGISKBOOT" ]; then
        extract_magisk_tools "$apk_path" || return 1
    fi

    sdk_version=${SDK_VER:-36}
    abi_version=arm64-v8a
    
    echo -e "Patching for API level: $sdk_version"

    "$WORK_DIR/busybox" sed -i \
    -e "s|API=\$(grep_get_prop ro.build.version.sdk)|API=$sdk_version|" \
    -e "s|ABI=\$(grep_get_prop ro.product.cpu.abi)|ABI=$abi_version|" \
    "$MAGISK_DIR/assets/util_functions.sh"

    "$WORK_DIR/busybox" sed -i 's|echo -e "ui_print \$1\\nui_print" >> /proc/self/fd/\$OUTFD|echo -e "\$1"|' "$MAGISK_DIR/assets/util_functions.sh"
    "$WORK_DIR/busybox" sed -i '1 s|^.*$|#!/bin/bash|' "$MAGISK_DIR/assets/boot_patch.sh"
    "$WORK_DIR/busybox" sed -i 's/ui_print/echo -e/g' "$MAGISK_DIR/assets/boot_patch.sh"
    
    if ! "$WORK_DIR/busybox" sed -i 's/\$BOOTMODE && \[ -z "\$PREINITDEVICE" \] && PREINITDEVICE=\$(\.\/magisk --preinit-device)/PREINITDEVICE="sda19"/' "$MAGISK_DIR/assets/boot_patch.sh"; then
        log "[ERROR] Failed to modify boot_patch.sh"
        return 1
    fi

    "$MAGISK_DIR/assets/boot_patch.sh" "$WORK_DIR/boot.img"

    if [ -f "$MAGISK_DIR/assets/new-boot.img" ]; then
        "$WORK_DIR/busybox" cp "$MAGISK_DIR/assets/new-boot.img" "$WORK_DIR/magisk_boot.img"
        log "[SUCCESS] Patching successful! Magisk boot image prepared"
    else
        log "[ERROR] Patching unsuccessful, Please try again!"
        cleanup
    fi
    return 0
}

if [ "$ARG_GIVEN_FR" -eq 0 ]; then
    echo -e "\nAutomating Patching boot.img with Magisk, TWRP injection and AOSP required mod for Xiaomi Pad 5\n"
    echo -e "This script is Written and Made By °⊥⋊ɹ∀°, Telegram - '@ArKT_7', Github - 'ArKT-7'\n"
else
    echo -e "\n[INFO] Runniing in (CI/CD) Mode\n"
fi

log "[INFO] Downloading busybox..."
curl -L -# -o "$WORK_DIR/busybox" "$URL_BUSYBOX"
chmod +x "$WORK_DIR/busybox"

log "[INFO] Downloading 7zzs..."
curl -L -# -o "$WORK_DIR/7zzs" "$URL_7ZZS"
chmod +x "$WORK_DIR/7zzs"
if [ ! -f "$WORK_DIR/busybox" ] || [ ! -f "$WORK_DIR/7zzs" ]; then
    log "[ERROR] Failed to download dependencies. Check your internet connection."
    cleanup
fi

BOOT_IMAGES=()
BULK_MODE=0

if [ "$ARG_GIVEN_FR" -eq 0 ]; then
    while true; do
        echo -e "\nPlease enter the full path to the Magisk APK file."
        echo -e "(leave blank to auto-download v30.7)"
        read -r MAGISK_PATH

        MAGISK_APK_DEST="$WORK_DIR/Magisk.apk"

        if [ -z "$MAGISK_PATH" ]; then
            log "[INFO] Downloading Magisk v30.7..."
            download_with_fallback "https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk" "$BASE_URL/files/Magisk_v30.7.apk" "$MAGISK_APK_DEST"
            break
        elif [ -f "$MAGISK_PATH" ]; then
            if [[ "$MAGISK_PATH" == *.apk ]]; then
                cp "$MAGISK_PATH" "$MAGISK_APK_DEST"
                log "[SUCCESS] Magisk APK Copied"
                break
            else
                echo -e "[ERROR] File is not an APK, Please try again!"
            fi
        else
            echo -e "[ERROR] File not found, Please try again!"
        fi
    done
    extract_magisk_tools "$MAGISK_APK_DEST" || cleanup

    while true; do
        echo -e "\nPlease enter the full path to the boot.img file or a folder containing .img files:"
        read -r BOOT_PATH
        if [ -d "$BOOT_PATH" ]; then
            log "[INFO] Dircetory detected. Scanning for valid .img files..."
            img_files=()
            for f in "$BOOT_PATH"/*.img; do
                [ -e "$f" ] && img_files+=("$f")
            done
            
            if [ ${#img_files[@]} -eq 0 ]; then
                echo -e "[ERROR] No .img files found in folder, Please try again!"
                continue
            fi
            
            valid_images=()
            valid_names=()
            
            for img in "${img_files[@]}"; do
                VERIFY_OUT=$("$MAGISKBOOT" verify "$img" 2>&1)
                KERNEL_SZ=$(echo "$VERIFY_OUT" | grep -m 1 "^KERNEL_SZ" | "$WORK_DIR/busybox" awk -F'[][]' '{print $2}')
                
                if [ -n "$KERNEL_SZ" ] && [[ "$KERNEL_SZ" =~ ^[0-9]+$ ]] && [ "$KERNEL_SZ" -ge 1048576 ]; then
                    valid_images+=("$img")
                    valid_names+=("$(basename "$img")")
                fi
            done
            
            if [ ${#valid_images[@]} -eq 0 ]; then
                echo -e "[ERROR] No valid boot images found in folder! Kernel size is SuS, Please try again!"
                continue
            fi
            
            echo -e "\nFound the following valid boot images:"
            for i in "${!valid_names[@]}"; do
                echo " $((i+1))) ${valid_names[$i]}"
            done
            echo -e "\nEnter the number to patch a specfic image, or press Enter to patch ALL one by one."
            read -r BULK_CHOICE
            
            if [ -z "$BULK_CHOICE" ]; then
                BULK_MODE=1
                BOOT_IMAGES=("${valid_images[@]}")
                log "[SUCCESS] Selected ALL images for Bulk Patching."
                echo -e "[NOTE] For bulk mode, do not use AOSP boot.img!"
                break
            elif [[ "$BULK_CHOICE" =~ ^[0-9]+$ ]] && [ "$BULK_CHOICE" -ge 1 ] && [ "$BULK_CHOICE" -le "${#valid_images[@]}" ]; then
                BULK_MODE=0
                BOOT_IMAGES=("${valid_images[$((BULK_CHOICE-1))]}")
                log "[SUCCESS] Selected ${valid_names[$((BULK_CHOICE-1))]}."
                break
            else
                echo -e "[ERROR] Invalid selection, Please try again!"
                continue
            fi

        elif [ -f "$BOOT_PATH" ]; then
            if [[ "$BOOT_PATH" == *.img ]]; then
                VERIFY_OUT=$("$MAGISKBOOT" verify "$BOOT_PATH" 2>&1)
                KERNEL_SZ=$(echo "$VERIFY_OUT" | grep -m 1 "^KERNEL_SZ" | "$WORK_DIR/busybox" awk -F'[][]' '{print $2}')
                
                if [ -z "$KERNEL_SZ" ] || ! [[ "$KERNEL_SZ" =~ ^[0-9]+$ ]] || [ "$KERNEL_SZ" -lt 1048576 ]; then
                    echo -e "[ERROR] Invalid or corrupted boot image! Kernel size is SuS, Please try again!"
                    continue
                fi

                BOOT_IMAGES=("$BOOT_PATH")
                BULK_MODE=0
                log "[SUCCESS] $(basename "$BOOT_PATH") Copied (Kernel Size: $(("$KERNEL_SZ" / 1024 / 1024)) MB)"
                break
            else
                echo -e "[ERROR] File does not end in .img, Please try again!"
            fi
        else
            echo -e "[ERROR] File or folder not found, Please try again!"
        fi
    done

    if [ "$BULK_MODE" -eq 1 ]; then
        log "[WARNING] Bulk mode active, Will auto-detect OS versions per image"
        echo -e "\nPlease provide a fallback Android version if auto-detect fails:"
        echo -e " 10) Android 10"
        echo -e " 11) Android 11"
        echo -e " 12) Android 12"
        echo -e " 13) Android 13"
        echo -e " 14) Android 14"
        echo -e " 15) Android 15"
        echo -e " 16) Android 16"
        echo -n "Enter version (10-16) or press Enter to default select Android 16: "
        read -r ANDROID_CHOICE

        FALLBACK_SDK=$(get_sdk_ver "$ANDROID_CHOICE")
    else
        VERIFY_OUT=$("$MAGISKBOOT" verify "${BOOT_IMAGES[0]}" 2>&1)
        OS_VER=$(echo "$VERIFY_OUT" | grep -m 1 "^OS_VERSION" | "$WORK_DIR/busybox" awk -F'[][]' '{print $2}')
        
        if [ -n "$OS_VER" ] && [ "$OS_VER" != "0.0.0" ]; then
            ANDROD_VER=$(echo "$OS_VER" | cut -d'.' -f1)
            if [[ "$ANDROD_VER" =~ ^[0-9]+$ ]]; then
                SDK_VER=$(get_sdk_ver "$ANDROD_VER")
                log "[SUCCESS] Auto-detceted Android $ANDROD_VER, Mapping to SDK API $SDK_VER."
            fi
        fi
        
        if [ -z "$SDK_VER" ]; then
            log "[WARNING] Could not auto-detect OS version."
            echo -e "\nWhich Android version is this boot.img for?"
            echo -e " 10) Android 10"
            echo -e " 11) Android 11"
            echo -e " 12) Android 12"
            echo -e " 13) Android 13"
            echo -e " 14) Android 14"
            echo -e " 15) Android 15"
            echo -e " 16) Android 16"
            echo -n "Enter version (10-16) or press Enter to default select Android 16: "
            read -r ANDROID_CHOICE

            SDK_VER=$(get_sdk_ver "$ANDROID_CHOICE")
        fi
    fi

    echo -e "\nDo you want to integrate a Custom Recovery (TWRP) Ramdisk (Ensure kernel supports it)?"
    echo -e "1) Yes - With Windows Mod"
    echo -e "2) Yes - With Linux Mod"
    echo -e "3) Yes - With Normal Mod"
    echo -e "4) No - Do not integrate TWRP"
    while true; do
        echo -n "Enter selection (1-4) [Default 4]: "
        read -r twrp_choice
        case "$twrp_choice" in
            1) INSTALL_TWRP=1; RAMDISK_TYPE="windows"; break ;;
            2) INSTALL_TWRP=1; RAMDISK_TYPE="linux"; break ;;
            3) INSTALL_TWRP=1; RAMDISK_TYPE="normal"; break ;;
            4|"") INSTALL_TWRP=0; RAMDISK_TYPE="none"; break ;;
            *) echo -e "[ERROR] Invalid option!" ;;
        esac
    done

    if [ "$INSTALL_TWRP" -eq 1 ]; then
        if [ "$BULK_MODE" -eq 1 ]; then
            IS_AOSP=0
        else
            echo -e "\nIs this an AOSP ROM boot.img? (Requires vendor_boot for TWRP to work)"
            echo -e "1) Yes"
            echo -e "2) No"
            while true; do
                echo -n "Enter selection (1-2): "
                read -r aosp_choice
                case "$aosp_choice" in
                    1) IS_AOSP=1; break ;;
                    2) IS_AOSP=0; break ;;
                    *) echo "Invalid option!" ;;
                esac
            done

            if [ "$IS_AOSP" -eq 1 ]; then
                while true; do
                    echo -e "\nPlease enter the full path to the vendor_boot.img file:"
                    read -r VENDOR_PATH
                    if [ -f "$VENDOR_PATH" ]; then
                        if [[ "$VENDOR_PATH" == *.img ]]; then
                            cp "$VENDOR_PATH" "$WORK_DIR/vendor_boot_orig.img"
                            log "[SUCCESS] vendor_boot.img Copied"
                            break
                        else
                            echo -e "[ERROR] File does not end in .img, Please try again!"
                        fi
                    else
                        echo -e "[ERROR] File not found, Please try again!"
                    fi
                done
            fi
        fi
    else
        IS_AOSP=0
    fi
else
    MAGISK_APK_DEST="$WORK_DIR/Magisk.apk"
    if [ -z "$MAGISK_PATH" ] || [ ! -f "$MAGISK_PATH" ]; then
        log "[INFO] Downloading Magisk v30.7..."
        download_with_fallback "https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk" "$BASE_URL/files/Magisk_v30.7.apk" "$MAGISK_APK_DEST"
    else
        cp "$MAGISK_PATH" "$MAGISK_APK_DEST"
        log "[SUCCESS] Magisk APK Copied"
    fi
    extract_magisk_tools "$MAGISK_APK_DEST" || cleanup

    BOOT_IMAGES=("$BOOT_PATH")
    BULK_MODE=0

    if [ -f "$BOOT_PATH" ]; then
        ORIG_BOOT_NAME=$(basename "$BOOT_PATH")
        cp "$BOOT_PATH" "$WORK_DIR/boot.img"
        log "[SUCCESS] $ORIG_BOOT_NAME Loaded"

        VERIFY_OUT=$("$MAGISKBOOT" verify "$WORK_DIR/boot.img" 2>&1)
        OS_VER=$(echo "$VERIFY_OUT" | grep -m 1 "^OS_VERSION" | "$WORK_DIR/busybox" awk -F'[][]' '{print $2}')
        if [ -n "$OS_VER" ] && [ "$OS_VER" != "0.0.0" ]; then
            ANDROD_VER=$(echo "$OS_VER" | cut -d'.' -f1)
            SDK_VER=$(get_sdk_ver "$ANDROD_VER")
        else
            SDK_VER=${TARGET_SDK_VER:-36}
        fi
    else
        log "[ERROR] Boot image not found at $BOOT_PATH!"
        cleanup
    fi

    if [ "${INSTALL_TWRP:-0}" -eq 1 ] && [ "${IS_AOSP:-0}" -eq 1 ]; then
        if [ -f "$VENDOR_PATH" ]; then
            cp "$VENDOR_PATH" "$WORK_DIR/vendor_boot_orig.img"
            log "[SUCCESS] vendor_boot.img Loaded"
        else
            log "[ERROR] Vendor boot not found at $VENDOR_PATH!"
            cleanup
        fi
    fi
fi

MAGISK_VER=$("$WORK_DIR/busybox" sed -n 's/^MAGISK_VER=//p' "$MAGISK_DIR/assets/util_functions.sh" | "$WORK_DIR/busybox" head -n 1 | "$WORK_DIR/busybox" tr -d "\"' ")
[ -z "$MAGISK_VER" ] && MAGISK_VER="Patched"

PREFIX="Magisk_${MAGISK_VER}_"
[ "${INSTALL_TWRP:-0}" -eq 1 ] && PREFIX="${PREFIX}TWRP_"

for BOOT_FILE in "${BOOT_IMAGES[@]}"; do
    ORIG_BOOT_NAME=$(basename "$BOOT_FILE")
    FINAL_BOOT_NAME="${PREFIX}${ORIG_BOOT_NAME}"
    
    cp "$BOOT_FILE" "$WORK_DIR/boot.img"
    
    if [ "$BULK_MODE" -eq 1 ]; then
        log "[INFO] Processing $ORIG_BOOT_NAME..."
        VERIFY_OUT=$("$MAGISKBOOT" verify "$WORK_DIR/boot.img" 2>&1)
        OS_VER=$(echo "$VERIFY_OUT" | grep -m 1 "^OS_VERSION" | "$WORK_DIR/busybox" awk -F'[][]' '{print $2}')
        if [ -n "$OS_VER" ] && [ "$OS_VER" != "0.0.0" ]; then
            ANDROD_VER=$(echo "$OS_VER" | cut -d'.' -f1)
            if [[ "$ANDROD_VER" =~ ^[0-9]+$ ]]; then
                SDK_VER=$(get_sdk_ver "$ANDROD_VER")
            else
                SDK_VER=$FALLBACK_SDK
            fi
        else
            SDK_VER=$FALLBACK_SDK
        fi
    fi

    if [ "$IS_AOSP" -eq 1 ] && [ -f "$WORK_DIR/vendor_boot_orig.img" ]; then
        cp "$WORK_DIR/vendor_boot_orig.img" "$WORK_DIR/vendor_boot.img"
    fi

    patch_twrp_recovery
    patch_magisk_boot "$MAGISK_APK_DEST"

    log "[INFO] Exporting final files..."

    if [ -f "$WORK_DIR/magisk_boot.img" ]; then
        cp "$WORK_DIR/magisk_boot.img" "$IMG_OUT/$FINAL_BOOT_NAME"
        
        cd "$IMG_OUT"
        ZIP_NAME="${FINAL_BOOT_NAME%.*}.zip"
        "$WORK_DIR/7zzs" a -tzip "$ZIP_OUT/$ZIP_NAME" "$FINAL_BOOT_NAME" > /dev/null
        
        cd "$ROOT_DIR"
        
        log "[SUCCESS] Patched boot image saved to: $IMG_OUT/$FINAL_BOOT_NAME"
        log "[SUCCESS] Zipped boot image saved to: $ZIP_OUT/$ZIP_NAME"
    fi

    if [ "$IS_AOSP" -eq 1 ] && [ -f "$WORK_DIR/vendor_boot.img" ]; then
        cp "$WORK_DIR/vendor_boot.img" "$IMG_OUT/${PREFIX}vendor_boot.img"
        log "[SUCCESS] Patched vendor_boot saved to: $IMG_OUT/${PREFIX}vendor_boot.img"
    fi
    
    rm -f "$WORK_DIR/boot.img" "$WORK_DIR/magisk_boot.img" "$WORK_DIR/twrp-boot.img" "$WORK_DIR/vendor_boot.img"
done

log "[INFO] Cleaning up..."
rm -rf "$WORK_DIR"

log "[COMPLETED] Patching Finished!"
