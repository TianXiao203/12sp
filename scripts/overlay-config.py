#!/usr/bin/env python3
# =============================================================================
# overlay-config.py —— 把碎片里的 CONFIG 项【精确覆盖】到一份完整 .config 上
#
# 为什么不用内核自带的 scripts/kconfig/merge_config.sh：
#   merge_config.sh 是为 "defconfig + 若干碎片" 设计的，它对 base 的处理方式
#   是逐项替换 + 最后 make olddefconfig，用作完整 .config（7000+ 行）的基座时
#   行为不够直观（重复 key、被 sed 掉的注释、-y 选项会把 =m 全改成 =y 等）。
#   而我们的场景非常明确：设备真实配置是权威，只有碎片里列出的 key 允许变，
#   其余 7000 多行必须【逐字保持】。这个脚本就干这件事。
#
# 用法:
#   python3 overlay-config.py <base.config> <out.config> [fragment1 fragment2 ...]
#
# 规则:
#   · base 里已存在的 key   → 就地替换成碎片里的值（保持原位置）
#   · base 里不存在的 key   → 追加到文件末尾（带一段注释头）
#   · 同一 key 在 base 里出现多次 → 只保留一份（后出现的值胜出，符合 kconfig 语义）
#   · 碎片里的注释行 / 空行一律忽略（它们只是给人看的）
# =============================================================================
import re
import sys

KEY_RE = re.compile(r'^(?:# )?(CONFIG_[A-Za-z0-9_]+)(?: is not set|=.*)?$')


def parse_entry(line):
    """把一行 CONFIG 解析成 (key, 规范化后的行)；不是【有效】CONFIG 行则返回 None。

    必须区分两种 '#' 行：
        "# CONFIG_FOO is not set"   → 有效（表示 =n）
        "# CONFIG_FOO=y   # 注释"   → 无效（只是被人注释掉的建议项，必须忽略）
    前者若被当成有效项还好；后者若被写进 .config，kconfig 会把它读成 n，
    从而悄悄关掉一个设备本来开着的功能（本项目就踩过：
    fragment 里注释掉的 CONFIG_KSU_TRACEPOINT_HOOK 把设备的 y 覆盖成了 n）。
    """
    s = line.strip()
    if not s:
        return None
    if s.startswith('#'):
        m = re.match(r'^#\s*(CONFIG_[A-Za-z0-9_]+)\s+is not set\s*$', s)
        if m:
            return m.group(1), '# %s is not set' % m.group(1)
        return None                      # 注释行 —— 一律忽略
    s = s.split(' #')[0].strip()         # 去掉行尾注释
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)(?:=(.*))?$', s)
    if not m:
        return None
    key = m.group(1)
    val = m.group(2)
    return key, ('%s=%s' % (key, val) if val is not None else '%s=y' % key)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('用法: overlay-config.py <base.config> <out.config> [fragment...]\n')
        return 2
    base_path, out_path = sys.argv[1], sys.argv[2]
    frag_paths = sys.argv[3:]

    # 1) 收集碎片里的覆盖项（后出现的胜出）
    overlay = {}
    order = []
    for fp in frag_paths:
        with open(fp, encoding='utf-8', errors='replace') as f:
            for line in f:
                e = parse_entry(line)
                if not e:
                    continue
                k, v = e
                if k not in overlay:
                    order.append(k)
                overlay[k] = v

    # 2) 逐行重写 base
    seen = set()
    out_lines = []
    replaced = 0
    with open(base_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            e = parse_entry(line)
            if not e:
                out_lines.append(line.rstrip('\n'))
                continue
            k, _ = e
            if k in overlay:
                if k in seen:
                    replaced += 1
                    continue          # 删掉重复定义
                seen.add(k)
                out_lines.append(overlay[k])
                replaced += 1
            else:
                out_lines.append(line.rstrip('\n'))

    # 3) 追加 base 里没有的项
    added = []
    for k in order:
        if k not in seen:
            added.append(overlay[k])

    if added:
        out_lines.append('')
        out_lines.append('# ---- 由 overlay-config.py 追加（设备配置里原本没有这些符号）----')
        out_lines.extend(added)

    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out_lines) + '\n')

    print('[overlay-config] base=%s (%d 行)' % (base_path, len(out_lines)))
    print('[overlay-config] 覆盖 %d 项，追加 %d 项 → %s' % (replaced, len(added), out_path))
    for k in order:
        print('    %s' % overlay[k])
    return 0


if __name__ == '__main__':
    sys.exit(main())
