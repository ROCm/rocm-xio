# Plan: Export ROCm-XIO SDMA device functions as Triton-consumable LLVM bitcode

**Repo:** `ROCm/rocm-xio`
**Companion plan:** `PLAN_iris_requires_xio.md` (separate repo, separate engineer/agent)
**Goal:** Produce a per-GPU-architecture `.bc` (LLVM bitcode) file exposing a flat, `extern "C"`
device-callable API for XIO's SDMA endpoint (`put`, `putTile`, and its atomic/signal-counter
primitives), suitable for consumption via Triton's `extern_libs` mechanism — the same shape as
NVSHMEM's `libnvshmem_device.bc` and rocSHMEM's `librocshmem_device_{arch}.bc`.

This plan does **not** touch iris. It only produces and packages the bitcode artifact plus the
thin C wrapper layer around XIO's existing C++ device functions. The other agent will consume
whatever this plan produces.

---

## 0. Context an implementing agent needs before starting

Read these files first, in this order, to build an accurate mental model — do not start writing
code before doing this:

1. `src/include/xio-endpoint-core.h` — the `xio::XioEndpoint` base class. Confirms the host-side
   dispatch model (virtual `getType()`, `getName()`, `run(XioEndpointConfig*)`,
   `initializeEndpointConfig()`). This is host-side only; it is not what gets exposed to Triton.
2. `src/endpoints/sdma-ep/sdma_device.hpp` and the neighboring `anvil_device.hpp` — the actual
   `__device__ __forceinline__` functions (`put()`, `putTile()`, `put_signal_counter_impl()`,
   `submitPacket()`, `poll_until_ge()`) plus the `SdmaQueueState`/`SdmaQueueHandle` structs they
   operate on. These are C++ templated/namespaced functions, **not** flat `extern "C"` symbols —
   this is the main gap this plan closes.
3. `cmake/XIOEndpointDiscovery.cmake` — shows how the build auto-discovers `src/endpoints/*`
   directories and generates registry entries via `endpoint_name_to_define()`. Confirms there is
   no existing convention for "add a new build target inside an endpoint dir"; you'll be adding
   one.
4. `cmake/XIOCompilerOptions.cmake` / `XIOClangCompilerOptions.cmake` — current compiler flags.
   Confirm there is no `-emit-llvm`/`-fgpu-rdc` anywhere today (there wasn't as of this plan being
   written) so you aren't duplicating an existing mechanism.
5. `cmake/XIOKpack.cmake` and `scripts/build/kpack-split.py` — the existing per-arch **HSACO**
   splitting step. This is a different artifact type (machine code, not LLVM IR) but is useful
   precedent for "how does this repo already do per-arch packaging," and its arch list
   (`-DOFFLOAD_ARCH=gfx942:xnack+` in CI, plus a `gfx1010`/`gfx1101` library-only matrix job) tells
   you which architectures are actually validated in CI today.
6. `python/CMakeLists.txt` and `python/sdma_ep_py.cpp` — the existing nanobind-based Python
   binding for the SDMA endpoint. This is the closest existing precedent in this repo for
   "expose a new artifact via a new build option + install step," and this plan's CMake changes
   should follow the same top-level-option/subdirectory structure it uses.

Also worth a quick skim: `CONTRIBUTING.md` (branching/PR conventions) and `docs/how-to/` (no
"add an endpoint" doc exists yet — don't expect one).

---

## 1. Scope: which functions get exported

Target only the SDMA endpoint's device-callable put/get/atomic surface, since it already has
Python bindings as precedent and is the architecture validated in CI (gfx942). Do not attempt to
cover the RDMA or NVMe endpoints in this pass.

Concretely, export flat C wrappers for (confirm exact signatures against
`src/endpoints/sdma-ep/sdma_device.hpp` at implementation time — the function list below is a
starting point, not gospel):

- `put(...)` — single-element/contiguous put
- `putTile(...)` — tiled/strided put
- `put_signal_counter_impl(...)` — put with a trailing signal/counter increment (the rough
  equivalent of NVSHMEM's `putmem_signal`)
- Whatever poll/wait primitive is the natural pairing for the above (`poll_until_ge()` or
  equivalent) — Triton kernels doing a put-with-signal will need a matching device-side wait to
  be useful at all, mirroring how rocSHMEM/NVSHMEM always ship `wait_until` alongside `put_signal`.

If, while reading `sdma_device.hpp`, you find that `put`/`putTile` take C++ reference/template
parameters (queue state structs, compile-time tile shapes) rather than flat scalar/pointer
arguments, **do not try to template-instantiate a generic wrapper**. Instead pick the 1–2 concrete
instantiations that matter for a first Triton use case (e.g. a byte-granular flat put and a
single fixed tile shape) and wrap exactly those. Expand later. Trying to expose the full C++
generality through a C ABI in one pass is the likeliest way this work stalls.

---

## 2. Step 1 — Write `extern "C"` wrapper functions

Create a new file, e.g. `src/endpoints/sdma-ep/sdma_device_extern_c.hip` (or `.cu`/`.hip.cpp` —
match whatever extension the rest of `sdma-ep/` uses for device TUs), containing thin wrappers:

```cpp
extern "C" __device__ __attribute__((used)) int
xio_sdma_put(void* queue_state_handle, const void* src, void* dst, size_t nbytes) {
  // Reconstruct/cast queue_state_handle back to the real SdmaQueueHandle type,
  // then call the existing xio::put(...) implementation from sdma_device.hpp.
  auto* handle = reinterpret_cast<xio::SdmaQueueHandle*>(queue_state_handle);
  return xio::put(*handle, src, dst, nbytes);
}

extern "C" __device__ __attribute__((used)) int
xio_sdma_put_signal(void* queue_state_handle, const void* src, void* dst, size_t nbytes,
                     void* signal_addr, uint64_t signal_val) {
  auto* handle = reinterpret_cast<xio::SdmaQueueHandle*>(queue_state_handle);
  return xio::put_signal_counter_impl(*handle, src, dst, nbytes, signal_addr, signal_val);
}

extern "C" __device__ __attribute__((used)) int
xio_sdma_poll_until_ge(void* signal_addr, uint64_t target_val) {
  return xio::poll_until_ge(signal_addr, target_val);
}
```

Naming convention: prefix every exported symbol `xio_sdma_` so that a future RDMA/NVMe export
pass can use `xio_rdma_`/`xio_nvme_` without collisions, and so the Triton-side declarations read
clearly.

**Apply `__attribute__((used))` to every exported function, not just to constants.** This is the
exact gotcha that bit the rocSHMEM integration (PR `ROCm/rocm-systems#5556`): Triton's bitcode
linker runs in `LinkOnlyNeeded` mode and will discard any symbol not directly reachable from a
Triton-side `extern`/`extern_elementwise` declaration. Since these wrapper functions are the only
thing standing between "compiled into the .bc" and "silently stripped," mark all of them `used`
up front rather than discovering this via a confusing runtime failure later.

**Signature discipline:** every argument must be a scalar type or raw pointer (`void*`, `int`,
`int64_t`, `uint64_t`, `size_t`) — no C++ references, templates, or non-trivial structs in the
`extern "C"` boundary. Triton's `extern_elementwise` declares argument types by exact
`(triton_dtype, ...) -> (symbol_name, triton_dtype)` tuples, so the iris-side implementer will be
hand-writing a Triton `core.extern` declaration that must match this signature exactly, field for
field. Coordinate the final signature list with whoever implements `PLAN_iris_requires_xio.md`
before finalizing — treat this signature list as the interface contract between the two plans.

Write this contract down explicitly once finalized, e.g. as
`docs/reference/xio_device_bitcode_abi.md` or a comment block at the top of the new file, so the
iris side doesn't have to reverse-engineer it from the `.bc` alone.

---

## 3. Step 2 — Add a per-architecture bitcode CMake target

Add a new CMake option, following the existing `XIO_BUILD_PYTHON` pattern in the top-level
`CMakeLists.txt`:

```cmake
option(XIO_BUILD_DEVICE_BITCODE "Build LLVM bitcode for XIO SDMA device functions (for Triton extern_libs)" OFF)
```

Then, likely in a new `cmake/XIODeviceBitcode.cmake` module (mirroring how `XIOKpack.cmake` is
its own module), add a function/target that:

1. Takes the architecture list from the existing `OFFLOAD_ARCH`/`CMAKE_HIP_ARCHITECTURES`
   variable (reuse it — don't introduce a second, divergent arch list) and iterates per-arch.
2. For each `<arch>` (e.g. `gfx942`), invokes `hipcc` directly via a `custom_command`:
   ```
   hipcc --offload-arch=<arch> -c -emit-llvm -x hip
         -I${CMAKE_SOURCE_DIR}/src/include -I${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep
         ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep/sdma_device_extern_c.hip
         -o ${CMAKE_BINARY_DIR}/lib/xio_device_<arch>.bc
   ```
   Only add `-fgpu-rdc` if the wrapper file ends up needing symbols defined in a different
   translation unit than the one being compiled to bitcode (check this empirically — start
   without it, add it only if the link step fails to resolve `xio::put`/`xio::put_signal_counter_impl`
   etc., since those are currently defined as `__device__ __forceinline__` in a header, which
   likely means no cross-TU linkage is actually needed and `-fgpu-rdc` can be skipped entirely).
3. Registers this as a target that depends on the `.bc` outputs, added to `ALL` only when
   `XIO_BUILD_DEVICE_BITCODE=ON` (do not make it part of the default build — it has no consumers
   inside this repo).
4. Confirm the exact arch list against CI reality before hardcoding anything: as of this plan,
   CI validates `gfx942:xnack+` on hardware and builds (library-only, not hardware-tested)
   `gfx1010`/`gfx1101`. Ship `.bc` for whatever the maintainers confirm is actually
   supported/tested — do not silently expand scope to architectures nobody validates (e.g.
   gfx90a/gfx950 were not found anywhere in this repo's CI as of this plan; verify with a
   maintainer whether they're expected before adding them).

**Verification for this step:** after building, run `llvm-dis` on each output `.bc` and grep for
the exported symbol names (`xio_sdma_put`, `xio_sdma_put_signal`, `xio_sdma_poll_until_ge`) to
confirm they survived compilation and are present with `external` (not `internal`) linkage. This
is a fast, cheap check to do before ever touching Triton — if the symbols aren't in the `.bc` at
this stage, no amount of `extern_libs` wiring on the iris side will fix it.

---

## 4. Step 3 — Package and expose the `.bc` for discovery

The consuming side (iris, via `PLAN_iris_requires_xio.md`) needs a deterministic way to find the
right `.bc` file at Triton-compile time, analogous to how `NvshmemLibFinder`/`RocshmemLibFinder`
resolve `libnvshmem_device.bc`/`librocshmem_device_{arch}.bc`. Decide and implement **one** of the
following (recommend option A for a first pass, since it requires the least new infrastructure):

- **(A) Ship inside the existing `python/xio` package.** Since `XIO_BUILD_PYTHON` already installs
  a Python package (`python/xio/sdma_ep/`) via the existing nanobind build, install the `.bc`
  files alongside it, e.g. `python/xio/sdma_ep/lib/xio_device_<arch>.bc`, via a CMake `install()`
  rule inside `python/CMakeLists.txt`. This means anyone with `pip install`'d XIO Python bindings
  automatically has the bitcode discoverable via `sysconfig.get_path("purelib")` — exactly the
  pattern `RocshmemLibFinder` uses for rocSHMEM's device bitcode.
- **(B) Install into the C++ package layout** (e.g. `${CMAKE_INSTALL_LIBDIR}/xio/device/`), for
  consumers who only need the `.bc` and not the full Python bindings. Lower priority; only do
  this if a concrete non-Python consumer is identified.

Whichever option is chosen, document the exact install path in the same
`docs/reference/xio_device_bitcode_abi.md` file from Step 1, since the iris-side lib-finder will
need to hardcode (or env-var-override) this path.

Add an environment variable override too, e.g. `XIO_DEVICE_BITCODE_DIR`, following the
`ROCSHMEM_LIB_DIR` / `NVSHMEM_LIB_DIR` precedent — this is what lets a developer point at a
locally-built `.bc` without reinstalling the package, and is expected by convention if this ever
needs debugging on the iris side.

---

## 5. Step 4 — Tests

Add a minimal device-side smoke test, following the existing `tests/unit/` structure (which
mirrors `src/endpoints/`): a small `.hip` test kernel that directly declares and calls
`xio_sdma_put`/`xio_sdma_poll_until_ge` via `extern "C"` declarations (exactly the pattern used in
rocSHMEM's own `device_bitcode_tester_kernel.hip` from `ROCm/rocm-systems#5556`) — i.e. prove the
`.bc` is linkable and functionally correct *before* any Triton integration is attempted. This
isolates "is the bitcode broken" from "is the Triton wiring broken," which will save the iris-side
engineer significant debugging time if something doesn't work end to end.

```cpp
// tests/unit/sdma-ep/device_bitcode_tester_kernel.hip
extern "C" { __device__ int xio_sdma_put(void*, const void*, void*, size_t); }
extern "C" __global__ void test_xio_sdma_put(void* queue, const void* src, void* dst, size_t n) {
  xio_sdma_put(queue, src, dst, n);
}
```

Wire this into whatever CI job already builds/tests the SDMA endpoint on real gfx942 hardware,
gated behind `XIO_BUILD_DEVICE_BITCODE=ON`.

---

## 6. Definition of done

- [ ] `extern "C"` wrapper file exists with `used`-annotated exports for put/putTile/put_signal/poll
- [ ] Signature contract written down and shared with the iris-side implementer
- [ ] `XIO_BUILD_DEVICE_BITCODE` CMake option added, off by default, reusing the existing arch list
- [ ] Per-arch `.bc` builds succeed for at least gfx942 (the only endpoint arch validated in CI)
- [ ] `llvm-dis` + symbol grep confirms exported symbols survive with external linkage
- [ ] `.bc` is installed/packaged somewhere discoverable, path documented, env-var override added
- [ ] A standalone `.hip` test kernel proves the `.bc` is linkable and functionally correct,
      independent of Triton
- [ ] Handoff note sent to the iris-side implementer with: exact symbol names, exact signatures,
      install path(s), env var name, and which architectures are actually shipped