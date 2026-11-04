"""Read selected Lua files from installed vehicle GMA archives (no game/UI)."""
from pathlib import Path
import argparse
import struct
import re

WORKSHOP = Path(r"F:\SteamLibrary\steamapps\workshop\content\4000")
ARCHIVES = {"glide": WORKSHOP / "3389728250/glide.gma",
            "lvs": WORKSHOP / "2912816023/lvs_base.gma",
            "simfphys": WORKSHOP / "771487490/simfphys_base.gma"}


def entries(path):
    with path.open("rb") as stream:
        assert stream.read(4) == b"GMAD", "not an uncompressed GMA"
        version = stream.read(1)[0]
        stream.read(16)

        def string():
            data = bytearray()
            while (byte := stream.read(1)) != b"\0":
                assert byte and len(data) < 1000000
                data.extend(byte)
            return data.decode("utf-8", "replace")

        if version > 1:
            while string():
                pass
        title, description, author = string(), string(), string()
        stream.read(4)
        files, offset = [], 0
        while struct.unpack("<I", stream.read(4))[0]:
            name, size = string(), struct.unpack("<q", stream.read(8))[0]
            stream.read(4)
            assert size >= 0
            files.append((name, offset, size))
            offset += size
        base = stream.tell()
    return title, [(name, base + offset, size) for name, offset, size in files]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("family", choices=ARCHIVES)
    parser.add_argument("pattern", nargs="?", default="")
    parser.add_argument("--read", action="store_true")
    parser.add_argument("--find", help="Show matching source lines with context")
    args = parser.parse_args()
    path = ARCHIVES[args.family]
    title, files = entries(path)
    print(f"{title} | {path}")
    for name, offset, size in files:
        if name.endswith(".lua") and args.pattern.lower() in name.lower():
            if not args.find:
                print(name)
            if args.read or args.find:
                with path.open("rb") as stream:
                    stream.seek(offset)
                    source = stream.read(size).decode("utf-8", "replace").replace("\r\r\n", "\n")
                    if not args.find:
                        print(source)
                    else:
                        lines = source.splitlines()
                        selected = set()
                        for i, line in enumerate(lines):
                            if re.search(args.find, line):
                                selected.update(range(max(0, i - 3), min(len(lines), i + 5)))
                        if selected:
                            print(name)
                            for i in sorted(selected):
                                print(f"{i+1}: {lines[i]}")
