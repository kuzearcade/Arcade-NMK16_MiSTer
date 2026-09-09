#!/usr/bin/env python3
"""Replay a 68000 ROM-access trace (TB_ROM_TRACE from tb_*_hw.cpp: one
uint32 per ROM read bus cycle, bits 22:0 = word address, bit 31 = program
fetch) through candidate program-ROM cache organisations and report the
miss rate of each. Lines are aligned 2-word pairs (what rtl/sdram.sv
returns per transaction). 'pf' variants also model a next-pair prefetch:
after any access to pair P, pair P+1 is assumed present by the next bus
cycle (a bus cycle is >= 16 clk_sys, the measured fetch is ~10)."""
import sys, struct, collections

def load(path):
    data = open(path, 'rb').read()
    n = len(data) // 4
    return struct.unpack('<%dI' % n, data[:n * 4])

def direct_mapped(trace, lines, prefetch, line_words=2):
    shift = (line_words - 1).bit_length()
    tags = [-1] * lines
    misses = 0
    for w in trace:
        p = (w & 0x7FFFFF) >> shift
        i = p % lines
        if tags[i] != p:
            misses += 1
            tags[i] = p
        if prefetch:
            q = p + 1
            tags[q % lines] = q
    return misses

def fully_assoc(trace, ways, prefetch):
    lru = collections.OrderedDict()
    misses = 0
    def touch(p):
        if p in lru:
            lru.move_to_end(p)
        else:
            lru[p] = True
            if len(lru) > ways:
                lru.popitem(last=False)
    for w in trace:
        p = (w & 0x7FFFFF) >> 1
        if p not in lru:
            misses += 1
        touch(p)
        if prefetch:
            touch(p + 1)
    return misses

def main():
    trace = load(sys.argv[1])
    n = len(trace)
    prog = sum(1 for w in trace if w & 0x80000000)
    print("ROM read cycles %d (program fetches %d, operand/data reads %d)" % (n, prog, n - prog))
    rows = []
    rows.append(("current: 1 line x 2 words", fully_assoc(trace, 1, False)))
    for ways in (2, 4, 8, 16):
        rows.append(("%d-line LRU, 2-word lines" % ways, fully_assoc(trace, ways, False)))
        rows.append(("%d-line LRU + next-pair prefetch" % ways, fully_assoc(trace, ways, True)))
    for kb in (2, 4, 8, 16, 32):
        lines = kb * 1024 // 4
        rows.append(("direct-mapped %2d KB, 2-word lines" % kb, direct_mapped(trace, lines, False)))
        rows.append(("direct-mapped %2d KB + next-pair prefetch" % kb, direct_mapped(trace, lines, True)))
    for kb in (4, 8, 16):
        lines = kb * 1024 // 8
        rows.append(("direct-mapped %2d KB, 4-word lines" % kb, direct_mapped(trace, lines, False, 4)))
    print("%-45s %10s %8s" % ("organisation", "misses", "rate"))
    for name, m in rows:
        print("%-45s %10d %7.1f%%" % (name, m, 100.0 * m / n))

if __name__ == '__main__':
    main()
