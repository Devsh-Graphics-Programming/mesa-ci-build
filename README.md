# Mesa llvmpipe Windows build (CI-aligned)

## Build

```powershell
git clone <REPO_URL>
cd <CLONE DIR>

pwsh -NoProfile -ExecutionPolicy RemoteSigned -File .\build-simple.ps1 -Config release
pwsh -NoProfile -ExecutionPolicy RemoteSigned -File .\build-simple.ps1 -Config debug

Write-Host "Artifacts in _artifacts\\release and _artifacts\\debug"
Write-Host "Logs in _artifacts\\logs"
```

Artifacts land in:
- `_artifacts\release`
- `_artifacts\debug`
- `_artifacts\logs`

Debug PDBs:
- Mesa: `_artifacts\debug\bin\*.pdb`
- LLVM: `_artifacts\debug\llvm-pdb\**\*.pdb`

## Prefer official Mesa artifacts

First choice should be the official Mesa CI artifacts.
Use this repo only when you need a debug build or custom instrumentation.
Always check Mesa pipelines and container registry first.

Pipelines: `https://gitlab.freedesktop.org/mesa/mesa/-/pipelines`  
Container registry: `https://gitlab.freedesktop.org/mesa/mesa/container_registry/47680`

## What we use

- Base image: `registry.freedesktop.org/mesa/mesa/windows/x86_64_build:20251120-bison--20251120-bison`
- Mesa commit: `c46902660461b38150133d43719a456926ec5dfb`
- LLVM: `19.1.7`
- SPIRV-LLVM-Translator: `19.1.10`
- Meson: `1.9.1`

Release build uses the LLVM and toolchain already in the base image.
Debug build builds debug LLVM and debug Mesa inside the container.

## Prereqs

- Docker with Windows containers and process isolation enabled
- Vulkan SDK or `vulkaninfo` and `vkcube` available on PATH for host smoke tests

## Manual container start

If you need to attach and iterate inside the container, use `dev-container.ps1`.

## Why this repo exists

We tried to use mesa-dist-win at `https://github.com/pal1000/mesa-dist-win`.
As of 2026-03-02 07:25 it tracked Mesa 25.3 with LLVM 21.1.8.
We attempted to mirror that build, then also rebuilt with LLVM 22.1.0.
Both MCJIT and ORC paths crashed or misbehaved.
The failure we could reproduce consistently was a llvmpipe crash in MCJIT or llc with `X86 SelectionDAG Cannot select X86ISD::BLENDV`.
Mesa IR looked valid.

Official Mesa CI on a newer 26.0.1 branch still uses LLVM 19.1.7.
We pulled the official Mesa artifact and it worked.
Then we rebuilt it 1:1 with the same CI options.
We also added a debug variant with debug LLVM and debug Mesa for symbols.
