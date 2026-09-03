#!/usr/bin/env python3
import os
import shutil
import struct
import sys

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_VERSION_MIN_WATCHOS = 0x30

PLATFORM_TO_VERSION_MIN = {
    1: LC_VERSION_MIN_MACOSX,
    2: LC_VERSION_MIN_IPHONEOS,
    3: LC_VERSION_MIN_TVOS,
}

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
CPU_TYPE_ARM64 = 0x0100000C


def encode_version(text: str) -> int:
    parts = [int(p) for p in text.split('.') if p != '']
    parts += [0, 0, 0]
    major, minor, patch = parts[:3]
    return ((major & 0xFFFF) << 16) | ((minor & 0xFF) << 8) | (patch & 0xFF)


def patch_slice(data: bytearray, base: int, platform: int, minos: int, sdk: int) -> bool:
    if base + 32 > len(data):
        return False
    magic = struct.unpack_from('<I', data, base)[0]
    if magic == MH_MAGIC_64:
        endian = '<'
    elif magic == MH_CIGAM_64:
        endian = '>'
    else:
        return False

    ncmds = struct.unpack_from(endian + 'I', data, base + 16)[0]
    off = base + 32
    changed = False

    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from(endian + 'II', data, off)
        if cmdsize < 8 or off + cmdsize > len(data):
            break

        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            struct.pack_into(endian + 'I', data, off + 8, platform)
            struct.pack_into(endian + 'I', data, off + 12, minos)
            struct.pack_into(endian + 'I', data, off + 16, sdk)
            changed = True
        elif cmd in {
            LC_VERSION_MIN_MACOSX,
            LC_VERSION_MIN_IPHONEOS,
            LC_VERSION_MIN_TVOS,
            LC_VERSION_MIN_WATCHOS,
        } and cmdsize >= 16:
            replacement = PLATFORM_TO_VERSION_MIN.get(platform)
            if replacement is not None:
                struct.pack_into(endian + 'I', data, off, replacement)
                struct.pack_into(endian + 'I', data, off + 8, minos)
                struct.pack_into(endian + 'I', data, off + 12, sdk)
                changed = True

        off += cmdsize

    return changed


def iter_slices(data: bytearray):
    if len(data) < 4:
        return

    be_magic = struct.unpack_from('>I', data, 0)[0]
    if be_magic in (FAT_MAGIC, FAT_MAGIC_64):
        is64 = be_magic == FAT_MAGIC_64
        nfat = struct.unpack_from('>I', data, 4)[0]
        off = 8
        for _ in range(nfat):
            if is64:
                if off + 32 > len(data):
                    break
                cputype, _cpusubtype, slice_off, _size, _align, _reserved = struct.unpack_from('>IIQQII', data, off)
                off += 32
            else:
                if off + 20 > len(data):
                    break
                cputype, _cpusubtype, slice_off, _size, _align = struct.unpack_from('>IIIII', data, off)
                off += 20
            if cputype == CPU_TYPE_ARM64:
                yield int(slice_off)
        return

    yield 0


def main(argv):
    # Emulates the subset Haze uses:
    # vtool -arch arm64 -set-build-version <platform> <min> <sdk> -replace -output <out> <in>
    try:
        i = argv.index('-set-build-version')
        platform = int(argv[i + 1])
        min_text = argv[i + 2]
        sdk_text = argv[i + 3]
        o = argv.index('-output')
        output = argv[o + 1]
        input_path = argv[-1]
    except (ValueError, IndexError) as exc:
        print(f'HazeBuilder vtool shim: unsupported arguments: {" ".join(argv)}', file=sys.stderr)
        return 2

    if os.path.abspath(output) != os.path.abspath(input_path):
        shutil.copy2(input_path, output)

    try:
        data = bytearray(open(output, 'rb').read())
    except OSError as exc:
        print(f'HazeBuilder vtool shim: {exc}', file=sys.stderr)
        return 1

    minos = encode_version(min_text)
    sdk = encode_version(sdk_text)
    changed = False
    for base in iter_slices(data):
        changed |= patch_slice(data, base, platform, minos, sdk)

    if changed:
        with open(output, 'wb') as f:
            f.write(data)
    else:
        # Match vtool's role without breaking packaging if an older/non-Mach-O file is encountered.
        print(f'HazeBuilder vtool shim: no patchable platform load command in {output}', file=sys.stderr)

    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
