# Windows Porting Audit: tippecanoe

## Overview

tippecanoe is **deeply POSIX-coupled**. The core tile-generation algorithms are portable, but virtually every layer of system integration — threading, file I/O, process spawning, memory management — uses Unix-only APIs. A native MSVC port is a significant engineering effort; compatibility layers offer a much faster path.

---

## Tier 1: Blockers (Won't Compile or Run)

### 1. Memory-Mapped I/O (`mmap` / `munmap`)
**Files**: `main.cpp`, `geojson.cpp`, `decode.cpp`, `tile.cpp`

tippecanoe maps large GeoJSON input files directly into memory for performance. This is central to how it reads data, not an incidental use.

```c
// mmap used throughout for file reads
fd = open(fname, O_RDONLY | O_CLOEXEC);
buf = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
```

**Windows fix**: `CreateFileMapping()` + `MapViewOfFile()` / `UnmapViewOfFile()`. Requires an abstraction layer wrapping both platforms — not a one-liner replacement because the Windows API requires two handles (file + mapping object) vs. one.

---

### 2. POSIX Threading (`pthread_*`)
**Files**: `main.cpp`, `tile.cpp`, `thread.cpp`, `thread.hpp`, `pool.cpp`, and others

The entire parallel tile-rendering pipeline is built on pthreads: thread pools, mutexes, condition variables, spinlocks.

```c
pthread_create(&threads[i], NULL, run_worker, &args[i]);
pthread_mutex_lock(&db_lock);
pthread_cond_wait(&task_cond, &task_mutex);
```

**Windows fix**: Two realistic options:
- Refactor to `std::thread` / `std::mutex` / `std::condition_variable` (C++11) — the cleanest long-term solution.
- Use `pthreads-win32` / `winpthreads` (from MinGW-w64) as a drop-in — much faster, but adds a runtime dependency.

---

### 3. Process Spawning (`fork` / `execvp` / `waitpid`)
**File**: `plugin.cpp`

The `--prefilter` and `--postfilter` feature forks a child process, sets up pipes (`pipe()`, `dup2()`), then execs an arbitrary command. There is no `fork()` on Windows.

```c
pid_t pid = fork();
if (pid == 0) {
    dup2(pipefd[0], STDIN_FILENO);
    execvp(argv[0], argv);
}
waitpid(pid, &status, 0);
```

**Windows fix**: `CreateProcess()` with `STARTUPINFO` and `SECURITY_ATTRIBUTES` for pipe setup — substantially more code. This is the most architecturally disruptive change because it touches inter-process pipe I/O throughout the filter pipeline. Alternatively, on a first pass you could `#ifdef` the feature out entirely on Windows.

---

### 4. Temporary File Creation (`mkstemp`)
**Files**: `sort.cpp`, declared in `main.hpp`

Sort passes create temporary files using `mkstemp()` (with a custom `mkstemp_cloexec` variant). The close-on-exec flag is a POSIX concept that has no direct Windows analogue.

**Windows fix**: `GetTempPath()` + `GetTempFileName()`, or `_tempnam()`. The `CLOEXEC` behavior doesn't exist on Windows — you'd use `SECURITY_ATTRIBUTES` with `bInheritHandle = FALSE` on the file handle instead.

---

### 5. System Resource Queries (`sysconf`, `getrlimit`)
**File**: `platform.cpp`

The platform abstraction layer already exists as a file, which is good. But all three branches (Linux, macOS, fallback) use POSIX APIs:

```c
sysconf(_SC_NPROCESSORS_ONLN)   // CPU count
sysconf(_SC_PHYS_PAGES)         // physical memory
getrlimit(RLIMIT_NOFILE, &rl)   // open file limit
```

**Windows fix**: Add a fourth `#ifdef _WIN32` branch using `GetSystemInfo()`, `GlobalMemoryStatusEx()`, and no real equivalent to the file descriptor limit (Windows doesn't have a meaningful one).

---

### 6. Argument Parsing (`getopt_long`)
**Files**: `main.cpp`, `decode.cpp`, `tile-join.cpp`, `overzoom.cpp`, `jsontool.cpp`

`getopt_long` is used in every executable's entry point. MSVC's CRT does not ship it.

**Windows fix**: Options in roughly ascending complexity:
- Lift `getopt`/`getopt_long` from gnulib and compile it as part of the project (most pragmatic).
- Use the [ya_getopt](https://github.com/kubo/ya_getopt) single-header implementation.
- Rewrite argument parsing — lots of work given how extensively `getopt_long` is used here.

---

### 7. Build System (Makefile)
**File**: `Makefile`

The Makefile uses `/bin/sh`, Unix paths, `pkg-config`, and shell utilities (`mkdir -p`, `cp`, `grep`, `sed`) throughout the build and install rules. It cannot run under `cmd.exe` or PowerShell as-is.

**Windows fix**: Migrate to **CMake**, which is the industry standard for cross-platform C++ builds and is already used by nearly all of tippecanoe's dependencies. This would also make package manager integration (vcpkg, Conan, conda) far cleaner.

---

## Tier 2: Correctness Issues

### 8. Data Type Size Assumptions (LP64 vs LLP64)
**Files**: `serial.cpp`, `projection.cpp`, geometry serialization code

On Linux/macOS (LP64): `long` = 64 bits, `off_t` = 64 bits.
On Windows (LLP64): `long` = **32 bits** even on 64-bit systems. `off_t` may also be 32 bits with MSVC.

Any code that stores large file offsets or counts in `long` or `off_t` will silently overflow on Windows when processing files over 2 GB — which tippecanoe routinely handles.

**Fix**: Audit all serialization paths and replace `long` / `off_t` with `int64_t` / `uint64_t`.

---

### 9. Directory Enumeration (`opendir` / `readdir`)
**File**: `dirtiles.cpp`

The directory tile output format (z/x/y directory trees) uses POSIX directory APIs.

**Fix**: The cleanest solution is `std::filesystem` (C++17), which tippecanoe already requires for its compiler flags. `std::filesystem::directory_iterator` replaces `opendir`/`readdir` without any platform conditionals.

---

### 10. `/dev/null` Hardcoded Path
**File**: `platform.hpp`

```cpp
constexpr auto get_null_device() { return "/dev/null"; }
```

**Fix**: Already isolated in one place — just add `#ifdef _WIN32` returning `"NUL"`.

---

### 11. Path Separator
**Files**: Path concatenation throughout `dirtiles.cpp`, `mbtiles.cpp`

Code uses `/` as a hardcoded path separator in string concatenation. Windows accepts `/` at the API level, but mixing with Windows-native tools can cause issues.

**Fix**: Use `std::filesystem::path` concatenation, which handles separators portably.

---

## Tier 3: Compiler Compatibility

tippecanoe requires **C++17**, which modern MSVC (VS 2019+) supports well. However:

| Feature | GCC/Clang | MSVC |
|---|---|---|
| `__attribute__((packed))` | Yes | Use `#pragma pack` |
| `__builtin_expect()` | Yes | No direct equivalent; wrap in macro |
| `__int128` | Yes | Not available — `__m128i` or emulation |
| `alloca()` | `<alloca.h>` | `<malloc.h>` |
| `strndup()` | POSIX ext. | Not in MSVC CRT — trivial to add |
| `strsep()` | POSIX ext. | Not in MSVC CRT — trivial to add |

None of these are blockers individually, but they'd all need `#ifdef` guards or compatibility shims.

---

## Compatibility Layers: MSYS2

**MSYS2** is by far the most pragmatic path to a working Windows binary, and it's worth understanding the two distinct modes it offers:

### Option A: MSYS2 + MinGW-w64 (Recommended for distribution)

MinGW-w64 cross-compiles to a **native Win32 binary** that has no MSYS2 runtime dependency. It provides:

- GCC or Clang targeting `x86_64-w64-mingw32`
- `winpthreads` — a Windows implementation of `pthread_*` using Win32 primitives
- `mingw-w64-x86_64-sqlite3`, `mingw-w64-x86_64-zlib` — prebuilt packages via `pacman`
- POSIX file I/O compatibility wrappers (`open`, `read`, etc. map to `_open`, `_read`)
- **Crucially**: `mmap` is **not** provided — this still needs to be ported

The `mmap` gap is the reason MinGW-w64 alone can't make tippecanoe work without code changes. You'd still need to add a `mmap` compatibility shim (several exist, e.g., `mman-win32`).

**What you'd get**: A standalone `.exe` that runs on any Windows machine — no extra DLLs if you link statically.

### Option B: Cygwin POSIX Layer

Cygwin provides a much more complete POSIX emulation, including `mmap`, `fork()`, and everything else. tippecanoe would likely compile with very few changes.

**The catch**: Cygwin-compiled binaries are **not** native — they require `cygwin1.dll` at runtime (a POSIX compatibility shim). Performance is worse than native, and distribution is more complex. This is a development convenience, not a shipping target.

### Option C: WSL (Windows Subsystem for Linux)

Not technically a Windows port — the binary runs in a Linux kernel on Windows. tippecanoe already works in WSL without any changes. This is the right answer if users just need it to work on their Windows machines, not if you need a native Windows package.

---

## Effort Estimate

| Work Item | Effort |
|---|---|
| `platform.cpp` Windows branch | 1–2 days |
| `mmap` abstraction layer | 2–3 days |
| `getopt_long` shim | 0.5 days |
| `mkstemp` / temp file replacement | 1 day |
| `fork/exec` → `CreateProcess` (plugin.cpp) | 3–5 days |
| Threading: pthreads → std::thread or winpthreads | 3–5 days (std::thread) / 1 day (winpthreads) |
| Build system: Makefile → CMake | 3–4 days |
| Type safety audit (LP64 fixes) | 1–2 days |
| Directory enumeration → std::filesystem | 1 day |
| Testing & validation | 3–5 days |
| **Total (native MSVC port)** | **~4–6 weeks** |
| **Total (MinGW-w64 + mman-win32 shim)** | **~1–2 weeks** |
| **Total (Cygwin, dev only)** | **~2–3 days** |

---

## Recommendation

The most realistic path to a **distributable native Windows binary** in the shortest time is:

1. **Use MSYS2 + MinGW-w64** as the build environment
2. **Add `mman-win32`** (a `mmap` shim that wraps `CreateFileMapping`) — this is the only true blocker MinGW-w64 doesn't solve
3. **Add `getopt_long` from gnulib** (one source file)
4. **Use `winpthreads`** (already ships with MinGW-w64, zero code changes needed)
5. Keep the Makefile working under MSYS2's shell — the `make` and shell utilities all work there
6. Wrap `fork`/`exec` in the plugin filter feature with `#ifdef _WIN32` to disable it initially

This avoids the full CMake rewrite and MSVC porting effort while producing a real `.exe`. The `mman-win32` shim handles `mmap` transparently with minimal code changes. If a future goal is to ship via conda with MSVC, that's a separate, larger effort.
