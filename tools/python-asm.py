#!/usr/bin/env python3
# MIT License
#
# Copyright (c) 2025 Advanced Micro Devices, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# flake8: noqa

"""How to disassemble AMD GPU programs via AMD COMGR

In this example, we disassemble an AMD GPU program that is written in
machine code. Such a program could, for example, be extracted from the body of
a GPU kernel or device function.

This example was derived from the original C++ AMD COMGR test:

https://github.com/ROCm/llvm-project/blob/amd-staging/amd/comgr/test/disasm_instr_test.c
"""

# [literalinclude-begin]

from rocm.amd_comgr import amd_comgr

program = b"\x02\x00\x06\xc0\x00\x00\x00\x00\x7f\xc0\x8c\xbf\x00\x80\x12\xbf\x05\x00\x85\xbf\x00\x02\x00\x7e\xc0\x02\x04\x7e\x01\x02\x02\x7e\x00\x80\x70\xdc\x00\x02\x7f\x00\x00\x00\x81\xbf"  # size: 44 bytes  # noqa: E501

expected_instructions = [
    "s_load_dwordx2 s[0:1], s[4:5], 0x0",
    "s_waitcnt lgkmcnt(0)",
    "s_cmp_eq_u64 s[0:1], 0",
    "s_cbranch_scc1 5",
    "v_mov_b32_e32 v0, s0",
    "v_mov_b32_e32 v2, 64",
    "v_mov_b32_e32 v1, s1",
    "global_store_dword v[0:1], v2, off",
    "s_endpgm",
]

arch = "gfx90a"
source = amd_comgr.ext.disassemble_program(
    f"amdgcn-amd-amdhsa--{arch}", program
)
instructions = source.rstrip().split("\n")
assert len(expected_instructions) == len(
    instructions
), f"{len(expected_instructions)}, {len(instructions)=}"
for i in range(0, len(instructions)):
    assert (
        expected_instructions[i] == instructions[i]
    ), f"{expected_instructions[i]=}, {instructions[i]=}"

print(
    f"""\
Instructions:
```
{source}
```\
  """
)
print("ok")
