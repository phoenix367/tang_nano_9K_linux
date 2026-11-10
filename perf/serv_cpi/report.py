#!/usr/bin/env python3
"""Print a compact W=1 / W=4 table from results.json."""
import json
import sys

ROWS = [
    "add", "sub", "addi", "and", "xor", "andi", "lui", "auipc", "nop", "slt", "sltu", "slti",
    "sltiu",
    "slli_0", "slli_1", "slli_8", "slli_31", "sll_8",
    "srli_0", "srli_1", "srli_2", "srli_4", "srli_8", "srli_16", "srli_31", "srai_8",
    "srl_8", "sra_31",
    "beq_taken", "bne_taken", "beq_not_taken", "bne_not_taken", "jal", "jalr",
    "lw", "lh", "lhu", "lb", "lbu", "sw", "sh", "sb",
    "mul", "mulh", "mulhu", "mulhsu", "div", "divu", "rem", "remu",
    "csrrw_mscratch", "csrrs_mscratch", "csrrc_mscratch", "csrr_mcause", "csrr_mepc",
    "csrrs_mstatus",
    "ecall_entry", "mret", "trap_roundtrip", "ecall_roundtrip_min_handler",
    "fence", "fence_i", "wfi_trap_entry",
]


def main():
    r = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "results.json"))
    print(f"{'class':30s} {'W=1':>8s} {'W=4':>8s}")
    for k in ROWS:
        a = r.get("W1", {}).get(k, "-")
        b = r.get("W4", {}).get(k, "-")
        print(f"{k:30s} {a!s:>8s} {b!s:>8s}")
    for tag, c in r.get("checks", {}).items():
        print(f"check {tag}: {'OK' if c['ok'] else 'FAILED'} "
              f"({c['fetches']} fetches, {c['stores']} stores)")
        for e in c["errors"]:
            print("   ", e)
    for tag in ("W1", "W4"):
        d = r.get("details", {}).get(tag)
        if not d:
            continue
        print(f"{tag}: shift formula: {r.get('shift_formula', {}).get(tag)}")
        print(f"{tag}: mix additivity: {d['mix_additivity']}")
        for key in ("fetch_count_mismatches", "window_vs_delta_mismatches",
                    "non_constant_per_instance",
                    "latency_sensitivity_vs_bus_count_mismatches"):
            if d.get(key):
                print(f"{tag}: {key}: {d[key]}")


if __name__ == "__main__":
    main()
