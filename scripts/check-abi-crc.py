#!/usr/bin/env python3
# =============================================================================
# check-abi-crc.py —— 内核 ABI 预检：把 ROM 里 vendor 模块的符号 CRC 和自编内核比对
#
# 为什么需要它（这是"刷进去卡在开机 logo"的根因防御）：
#   Android GKI 的内核与 vendor 模块是【分离编译】的。ROM 里 /vendor/lib/modules/*.ko
#   在编译时把"所需符号的 CRC"写进了模块的 __versions 段。内核启动加载模块时，
#   会拿自己算出的 CRC 去比对；不一致就直接拒绝加载。
#
#   CRC 由 genksyms 从【类型定义】算出来 —— 所以只要自编内核里某个被导出符号
#   签名涉及的结构体布局与官方不同（例如：
#       CONFIG_NF_TABLES=y      -> struct net 多出 netns_nftables nft;
#       CONFIG_SYSVIPC=y        -> struct task_struct 多出 sysvsem / sysvshm
#   ），该符号的 CRC 就变了 → 模块集体拒载 → vendor init 起不来 →
#   显示驱动模块也没加载 → 【屏幕永远停在米标】，且没有任何日志。
#
#   这类问题不报编译错、不 panic，只能靠 ABI 比对提前发现。
#
# 用法：
#   1) 生成基线（从设备上拉下来的 .ko）：
#        python scripts/check-abi-crc.py baseline abi-baseline/ -o abi-baseline/abi-crcs.txt
#   2) 编译后核对（需要一个 Module.symvers）：
#        python scripts/check-abi-crc.py check <out>/Module.symvers \
#               -b abi-baseline/abi-crcs.txt
#      退出码 0 = ABI 兼容，可以刷；非 0 = 有符号 CRC 不一致，别刷。
# =============================================================================
import argparse
import os
import struct
import sys

MODULE_NAME_LEN = 56          # MAX_PARAM_PREFIX_LEN
ENTRY_SIZE = 8 + MODULE_NAME_LEN   # struct modversion_info


def read_elf_sections(path):
    """返回 [(name, sh_type, offset, size), ...]（只支持 64 位小端 ELF）。"""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'\x7fELF':
        raise ValueError('不是 ELF 文件')
    if data[4] != 2:
        raise ValueError('不是 64 位 ELF')
    if data[5] != 1:
        raise ValueError('不是小端 ELF')
    e_shoff = struct.unpack_from('<Q', data, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', data, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', data, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', data, 0x3E)[0]
    if e_shoff == 0 or e_shnum == 0:
        raise ValueError('没有节表')

    def sh(i):
        off = e_shoff + i * e_shentsize
        name, sh_type, _flags, _addr, offset, size = struct.unpack_from('<IIQQQQ', data, off)
        return name, sh_type, offset, size

    _, _, str_off, str_size = sh(e_shstrndx)
    strtab = data[str_off:str_off + str_size]

    def sname(off):
        end = strtab.find(b'\0', off)
        return strtab[off:end].decode('utf-8', 'replace')

    out = []
    for i in range(e_shnum):
        n, t, o, s = sh(i)
        out.append((sname(n), t, o, s))
    return out, data


def parse_versions(path):
    """从 .ko 里取出 __versions 段：{symbol: crc}"""
    sections, data = read_elf_sections(path)
    res = {}
    for name, sh_type, off, size in sections:
        if name != '__versions':
            continue
        if size % ENTRY_SIZE != 0:
            raise ValueError('%s: __versions 大小 %d 不是 %d 的整数倍'
                             % (os.path.basename(path), size, ENTRY_SIZE))
        for i in range(size // ENTRY_SIZE):
            base = off + i * ENTRY_SIZE
            crc = struct.unpack_from('<Q', data, base)[0]
            raw = data[base + 8: base + 8 + MODULE_NAME_LEN]
            sym = raw.split(b'\0', 1)[0].decode('utf-8', 'replace')
            if sym:
                res[sym] = crc
    return res


def parse_symvers(path):
    """解析内核构建产物 Module.symvers -> {symbol: crc}"""
    res = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.strip():
                continue
            parts = line.split('\t')
            if len(parts) < 2:
                parts = line.split()
            if len(parts) < 2:
                continue
            try:
                crc = int(parts[0], 16)
            except ValueError:
                continue
            res[parts[1]] = crc
    return res


def cmd_baseline(args):
    merged = {}          # sym -> (crc, [modules])
    n_ko = 0
    for root, _dirs, files in os.walk(args.kodir):
        for fn in sorted(files):
            if not fn.endswith('.ko'):
                continue
            p = os.path.join(root, fn)
            try:
                v = parse_versions(p)
            except Exception as e:
                print('  [WARN] %s: %s' % (fn, e), file=sys.stderr)
                continue
            n_ko += 1
            for s, c in v.items():
                if s in merged and merged[s][0] != c:
                    print('  [WARN] %s 与前面模块的 CRC 不一致: %s (0x%08x vs 0x%08x)'
                          % (s, fn, c, merged[s][0]), file=sys.stderr)
                    continue
                merged.setdefault(s, (c, []))[1].append(fn)
    out = args.output or os.path.join(args.kodir, 'abi-crcs.txt')
    with open(out, 'w', encoding='utf-8') as f:
        f.write('# 由 scripts/check-abi-crc.py baseline 生成\n')
        f.write('# 来源：设备 /vendor/lib/modules/*.ko 的 __versions 段\n')
        f.write('# <symbol>\\t<crc_hex>\\t<来源模块>\n')
        for s in sorted(merged):
            crc, mods = merged[s]
            f.write('%s\t0x%08x\t%s\n' % (s, crc, ','.join(mods[:3])))
    print('[+] 扫描了 %d 个 .ko，得到 %d 个符号的 ABI 基线' % (n_ko, len(merged)))
    print('[+] 写入 %s' % out)
    return 0


def cmd_check(args):
    base = {}
    with open(args.baseline, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            parts = line.rstrip('\n').split('\t')
            base[parts[0]] = int(parts[1], 16)

    ours = parse_symvers(args.symvers)
    print('[i] 基线符号数: %d   Module.symvers 符号数: %d' % (len(base), len(ours)))

    common = set(base) & set(ours)
    missing = sorted(set(base) - set(ours))       # ROM 需要但我们的内核没导出
    bad = sorted(s for s in common if base[s] != ours[s])

    print('[i] 共同符号: %d' % len(common))
    if bad:
        print('\n[FAIL] 有 %d 个符号 CRC 不一致 —— 内核 ABI 与 ROM 的 vendor 模块不兼容！'
              % len(bad))
        print('       刷进去会卡在开机 logo（模块全部拒载）。')
        print('       %-44s %-12s %s' % ('符号', 'ROM 期望', '我们的内核'))
        for s in bad[:60]:
            print('       %-44s 0x%08x   0x%08x' % (s, base[s], ours[s]))
        if len(bad) > 60:
            print('       ... 还有 %d 个' % (len(bad) - 60))
    else:
        print('\n[OK] 所有共同符号的 CRC 完全一致 —— ABI 兼容，模块可以加载。')

    if missing:
        print('\n[WARN] %d 个 ROM 需要的符号我们的内核没导出（前 20 个）：' % len(missing))
        for s in missing[:20]:
            print('       %s' % s)

    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description='内核 ABI（模块符号 CRC）预检')
    sub = ap.add_subparsers(dest='cmd', required=True)

    b = sub.add_parser('baseline', help='从 .ko 目录生成 ABI 基线')
    b.add_argument('kodir')
    b.add_argument('-o', '--output')
    b.set_defaults(func=cmd_baseline)

    c = sub.add_parser('check', help='用 Module.symvers 核对 ABI')
    c.add_argument('symvers')
    c.add_argument('-b', '--baseline', required=True)
    c.set_defaults(func=cmd_check)

    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
