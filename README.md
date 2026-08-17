# xmrig-zig

xmrig 6.26.0 built with the Zig build system. The xmrig source is pulled as a
Zig dependency (a pinned release tarball) rather than forked, so no xmrig source
is vendored here — only the build glue.

## Files

- `build.zig` — the Zig build script. Compiles xmrig from the `xmrig` dep with
  runtime-dispatched per-ISA modules (blake2b SSE4.1/AVX2, argon2, VAES) so a
  single portable binary can run on baseline (SSE2 + AES-NI) machines.
- `build.zig.zon` — dependencies: `xmrig` (v6.26.0), `libuv`, `openssl`.
- `patches/openssl-zig.patch` + `patches/apply-patches.ps1` — the upstream
  `openssl-zig` package at the pinned commit is incomplete (it omits perl-
  generated `.c` files and several source entries), so it must be patched.
- `.gitignore` — ignores zig caches and `zig-pkg`.

## Build (Windows, x86_64)

```
powershell -File patches\apply-patches.ps1   # fetch deps + apply openssl patch
zig build -Drelease=true                      # native build (machine-specific)
```

For a binary that runs on the widest range of x86-64 Windows machines (any CPU
with SSE2 + AES-NI, i.e. roughly anything from 2010 onward), pin the baseline
target instead:

```
zig build -Drelease=true -Dtarget=x86_64-windows-gnu
```

The executable and the WinRing0 driver land in `zig-out\bin`.

## Why the patch script

Zig 0.16 extracts dependencies into a project-local `zig-pkg` directory (ignored
by git). The pinned `openssl-zig` commit cannot build a complete static TLS
library as-is, so `apply-patches.ps1`:
1. runs `zig build --fetch` to populate `zig-pkg`,
2. locates the openssl-zig package dir (by its `crypto/x509/standard_exts.h`),
3. applies `openssl-zig.patch` into it.

The patch adds the missing generated cipher sources (`ciphercommon.c`,
`cipher_chacha20_poly1305.c`), the missing crypto source entries
(`defaults.c`, `comp_methods.c`, `skeymgmt_meth.c`, `indicator_core.c`,
`hashfunc.c`, `thread/internal.c`, `ecp_nistp384.c`, `signature.c`, `s_lib.c`,
`err_save.c`, `hashtable.c`, `rand_uniform.c`, the ETM ciphers,
`test_rng.c`, `aes_skmgmt.c`/`generic.c`), the `ENGINESDIR`/`MODULESDIR`
macros, removes the ACERT extension entries from `standard_exts.h`, and drops
`sm4`/`ecp_nistz256` from the no-asm build. The script is idempotent.

The durable fix would be to upstream these changes to `kassane/openssl-zig` so
the patch becomes unnecessary.
