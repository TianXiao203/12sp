#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch-ak3-zip.py —— 就地替换已有 AnyKernel3 zip 里的 anykernel.sh

用途：内核 Image 已经编好了（在内核 zip 里），只是 anykernel.sh 有问题时，
     不必再跑一次十几分钟的编译，直接换掉脚本里那一个文件即可。

为什么需要它：
  AK3 backend（META-INF/com/google/android/update-binary）里写死的是小写
  `anykernel.sh`（`ash anykernel.sh` 就是入口）。而 clone 下来的目录、或某些
  大小写不敏感的文件系统上，可能残留成 `Anykernel.sh`，从而导致行为不一致。
  本脚本会删掉所有大小写变体，只写回一个规范的小写 `anykernel.sh`。

用法：
  python patch-ak3-zip.py <输入.zip> <新的anykernel.sh> [输出.zip]
      不给输出路径时，默认在输入文件旁生成 <名字>-fixed.zip
"""

import os
import sys
import zipfile

VARIANTS = ("anykernel.sh", "Anykernel.sh", "ANYKERNEL.SH", "AnyKernel.sh")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    src = sys.argv[1]
    new_sh = sys.argv[2]
    if len(sys.argv) >= 4:
        dst = sys.argv[3]
    else:
        root, ext = os.path.splitext(src)
        dst = f"{root}-fixed{ext}"

    if not os.path.isfile(src):
        print(f"[ERROR] 找不到输入 zip: {src}")
        return 1
    if not os.path.isfile(new_sh):
        print(f"[ERROR] 找不到 anykernel.sh: {new_sh}")
        return 1

    with open(new_sh, "rb") as f:
        sh_bytes = f.read()

    text = sh_bytes.decode("utf-8", "replace")
    if "\nBLOCK=" not in "\n" + text:
        print("[ERROR] 新的 anykernel.sh 里没有大写的 BLOCK= ——"
              " 现行 ak3-core.sh 只认大写变量，写小写会在刷机时报 "
              "'Unable to determine  partition'")
        return 1
    if "\nblock=" in "\n" + text:
        print("[ERROR] 新的 anykernel.sh 里还有小写 block= —— 新旧混用会出歧义")
        return 1

    zin = zipfile.ZipFile(src, "r")
    dropped = [n for n in zin.namelist() if n in VARIANTS or os.path.basename(n) in VARIANTS]

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for item in zin.infolist():
            if item.filename in dropped:
                continue
            data = zin.read(item.filename)
            zout.writestr(item, data)

        # 写回规范的小写 anykernel.sh
        info = zipfile.ZipInfo("anykernel.sh")
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        zout.writestr(info, sh_bytes)
    zin.close()

    with zipfile.ZipFile(dst) as z:
        names = z.namelist()
        if "anykernel.sh" not in names:
            print("[ERROR] 输出 zip 里没有 anykernel.sh")
            return 1

    print(f"[+] 输入: {src}")
    print(f"[+] 替换掉的旧条目: {dropped if dropped else '(无)'}")
    print(f"[+] 写入: anykernel.sh  ({len(sh_bytes)} bytes)")
    print(f"[+] 输出: {dst}  ({os.path.getsize(dst):,} bytes)")
    print(f"[+] 顶层条目: {sorted({n.split('/')[0] for n in names})}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
