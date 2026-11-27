"""Render the BOOM4 simulator's retirement records in BOOM v4 printf format."""
import sys


def field(word, start, width):
    return (word >> start) & ((1 << width) - 1)


def records(lines):
    for line in lines:
        _, marker, payload = line.partition('puts:BOOMLOG ')
        if not marker:
            yield line.rstrip('\n')
            continue
        stamp, mode, lanes, events, memory = payload.split()
        events, memory = int(events, 16), int(memory, 16)
        for _ in range(int(lanes)):
            if events & 1:
                pc = field(events, 1, 64)
                if mode == '1':
                    inst = field(events, 65, 32)
                    digits = 4 if inst & 3 != 3 else 8
                    row = f'{field(events, 161, 2)} 0x{pc:016x} (0x{inst:0{digits}x})'
                    kind, dest = field(events, 163, 2), field(events, 165, 6)
                    if kind == 1 or (kind == 0 and dest):
                        reg = 'f' if kind == 1 else 'x'
                        row += f' {reg}{dest} 0x{field(events, 97, 64):016x}'
                    yield row
                elif mode == '2':
                    branch = field(events, 171, 4)
                    if 1 <= branch <= 8:
                        source, taken = field(events, 175, 3), field(events, 178, 1)
                        yield f'{source:x} {taken} {int(branch < 7)} {int(branch == 7)} {int(branch == 8)} {pc:016x}'
            if memory & 1:
                cmd, size = field(memory, 1, 5), field(memory, 6, 2)
                addr, data, wb = field(memory, 8, 40), field(memory, 48, 64), field(memory, 112, 64)
                yield f'MT {int(stamp, 16):x} 0 {cmd:x} {size:x} {addr:x} {data:x} {wb:x}'
            events >>= 179
            memory >>= 176


if __name__ == '__main__':
    for record in records(sys.stdin):
        print(record)
