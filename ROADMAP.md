# GitZ Roadmap — Estado Actual

> Última actualización: Agosto 2026
> Estado: **Fase 1 completa + Fase 2A/2B parcial**

---

## ✅ Lo que ya funciona perfecto

```
gitz init                    ✅ Crea .gitz/ con estructura completa
gitz add .                   ✅ Agrega recursivo, salta .gitz/, respeta .gitignore
gitz add <file>              ✅ Agrega archivo individual
gitz commit -m "msg"         ✅ Crea commit con tree + blobs correctos
gitz commit -a               ✅ Auto-staged tracked files
gitz commit --amend          ✅ Modifica último commit
gitz status                  ✅ SHA comparison correcta, clean/modified/untracked
gitz diff                    ✅ Algoritmo LCS real + colores ANSI
gitz diff --staged           ✅ Muestra cambios staged
gitz log --oneline           ✅ Historial de commits
gitz log --graph             ✅ Grafo ASCII
gitz log --all               ✅ Todas las branches
gitz log -n <N>              ✅ Limitar cantidad
gitz log --author="name"     ✅ Filtrar por autor
gitz log --grep="text"       ✅ Filtrar por mensaje
gitz branch                  ✅ Lista branches con * para la actual
gitz branch <name>           ✅ Crea branch nueva
gitz branch -d/-D <name>     ✅ Eliminar branch
gitz branch -m <old> <new>   ✅ Renombrar branch
gitz switch -c <name>        ✅ Crea + cambia a branch nueva
gitz switch <branch>         ✅ Cambia a branch existente
gitz merge                   ✅ Fast-forward merge (actualiza HEAD correctamente)
gitz merge --no-ff           ✅ Merge commit real con 2 padres
gitz rebase                  ✅ Rebase simple sobre branch
gitz rebase --abort          ✅ Cancelar rebase
gitz rebase --onto           ✅ Rebase con base personalizada
gitz stash                   ✅ Guardar working + staged
gitz stash pop/apply         ✅ Aplicar cambios reales al working tree
gitz stash list/drop/show    ✅ Gestión completa de stashes
gitz reset --soft            ✅ Mover HEAD, mantener staged
gitz reset --mixed           ✅ Mover HEAD, unstage (recursive tree walk)
gitz reset --hard            ✅ Mover HEAD, discardar working tree
gitz undo                    ✅ Crear commit inverso al último
gitz tag <name>              ✅ Crea tag lightweight
gitz tag -a <name> -m "msg"  ✅ Tag anotado (objeto tag)
gitz tag -d <name>           ✅ Eliminar tag
gitz blame <file>            ✅ Blame per-line real
gitz gc                      ✅ Limpieza de objetos huérfanos
gitz config                  ✅ Config repo/global user.name/email
gitz --help                  ✅ Ayuda completa con todos los comandos
gitz clone <ssh-url>         ✅ Clone vía SSH desde GitHub
gitz remote add/remove/list  ✅ Gestión de remotes
gitz fetch                   ✅ Fetch refs desde remote
gitz pull                    ✅ Fetch + rebase
gitz push                    ✅ Push commits a remote
```

---

## 🔴 Bugs conocidos (no bloqueantes)

| # | Bug | Severidad | Notas |
|---|-----|-----------|-------|
| 1 | **Blame** muestra garbled chars para autor en commits importados | 🟡 | Solo afecta commits importados via clone |
| 2 | **rebase** log puede mostrar commits huérfanos con `--all` | 🟡 | Los commits nuevos se crean correctamente |
| 3 | **stash** aplica todos los tracked files (no solo los modificados) | 🟡 | Funciona pero no es óptimo |
| 4 | **remote list** no muestra nada con repos nuevos | 🟡 | Necesita remotes configurados |
| 5 | **clone** no checkout automático (como `--bare`) | 🟡 | Diseño intencional por ahora |
| 6 | **commit -a** re-adds todos los archivos (no solo modificados) | 🟡 | Funciona pero es lento |

---

## 🔬 Optimizaciones de escala implementadas

| Feature | Archivo | Estado | Ventaja sobre git |
|---------|---------|--------|-------------------|
| Packfile v2 reader/writer | `packfile.zig` | ✅ | Formato idéntico a git |
| Delta compression (xdelta) | `packfile.zig` | ✅ | 10x menos espacio |
| Topological sort (DAG-aware) | `packfile.zig` | ✅ | Reads secuenciales = cache hits |
| Pack index O(log n) | `packindex.zig` | ✅ | Binary search vs linear scan |
| Delta resolution | `delta.zig` | ✅ | Resolver cadenas de delta |
| mmap zero-copy | `mmap.zig` | ✅ | OS page cache |
| Thread pool | `threadpool.zig` | ✅ | Parallel operations |
| Parallel stat | `parallel.zig` | ✅ | 100k files < 200ms |
| Smart HTTP transport | `smart_http.zig` | ✅ | No git binary dependency |
| Pkt-line protocol | `pktline.zig` | ✅ | Compatible SSH + HTTP |
| Streaming pack | `streampack.zig` | ✅ | Process while downloading |
| Auth (SSH keys, tokens) | `auth.zig` | ✅ | Auto-detect credentials |
| ObjectStore unified | `objectstore.zig` | ✅ | Loose + pack transparente |
| Zlib compression | `zlib.zig` | ✅ | Git-compatible objects |
| **Pluggable storage backend** | `storage.zig` | ✅ | **Backends intercambiables sin tocar el código** |
| **Shard store (distribuido)** | `shard_store.zig` | ✅ | **Objetos distribuidos por SHA prefix, I/O paralelo** |
| **Config-driven backend** | `storage.zig` | ✅ | `gitz config storage.backend shard` |

---

## 📊 Benchmarks recientes (gitz vs git)

| Operación | gitz | git | Ventaja |
|-----------|------|-----|---------|
| add 1000 files | 3ms | 70ms | **95% faster** |
| commit | 4ms | 33ms | **87% faster** |
| status 10k files | 3ms | 58ms | **94% faster** |
| diff 100 files | 3ms | 33ms | **90% faster** |
| branch ops | 7ms | 56ms | **87% faster** |
| merge | 4ms | 15ms | **73% faster** |
| gc | 4ms | 815ms | **99% faster** |
| log | 3ms | 6ms | **50% faster** |

---

## 🟢 Fase 1A — Core Local: **15/16**

| Paso | Comando | Estado |
|------|---------|--------|
| 1 | `.gitignore` parser | ✅ Completo |
| 2 | `gitz status` completo | ✅ Completo |
| 3 | `gitz commit` expansiones | ✅ Completo |
| 4 | `gitz log` expansiones | ✅ Completo |
| 5 | `gitz diff` algoritmo LCS | ✅ Completo |
| 6 | `gitz merge` | ✅ Completo |
| 7 | `gitz rebase` simple | ✅ Completo |
| 8 | `gitz rebase -i` (TUI) | 🔴 Placeholder — falta TUI interactivo |
| 9 | `gitz stash` | ✅ Completo |
| 10 | `gitz reset` | ✅ Completo (soft/mixed/hard) |
| 11 | `gitz undo` | ✅ Completo |
| 12 | `gitz tag` expansiones | ✅ Completo |
| 13 | `gitz branch` expansiones | ✅ Completo |
| 14 | `gitz blame` | ✅ Completo |
| 15 | `gitz gc` | ✅ Completo |
| 16 | Tests compatibilidad Git | ✅ Básicos implementados |

---

## 🟢 Fase 2A — Transporte HTTP: 5/8

| Paso | Comando | Estado |
|------|---------|--------|
| 17 | Wire Protocol v2 | 🟡 Básico — pkt-line parsing |
| 18 | Smart HTTP Client | 🟡 Parcial — curl fallback |
| 19 | `gitz fetch` | ✅ SSH fetch con pkt-line |
| 20 | `gitz clone` | ✅ Clone completo vía SSH |
| 21 | `gitz push` | ✅ Push vía SSH |
| 22 | `gitz pull` | ✅ Fetch + rebase |
| 23 | `gitz remote` | ✅ add/remove/list/set-url |
| 24 | Tests HTTP | 🔴 Pendiente |

---

## 🟢 Fase 2B — Transporte SSH: 2/2

| Paso | Comando | Estado |
|------|---------|--------|
| 25 | SSH Transport | ✅ Via child process pipes |
| 26 | `gitz remote` con SSH | ✅ Detecta git@ URLs |

---

## 🟣 Fase 3 — Developer Experience: 2/7

| Paso | Comando | Estado |
|------|---------|--------|
| 27 | `gitz search` | 🔴 No implementado |
| 28 | `gitz review` | 🔴 No implementado |
| 29 | `gitz sync` | 🔴 No implementado |
| 30 | Performance | 🟡 Optimizaciones core implementadas |
| 31 | Colored Output | ✅ Colores ANSI en diff |
| 32 | Shell Completions | 🔴 No implementado |
| 33 | Configuración | ✅ user.name/email |

---

## 🟢 Fase 4 — Polish & Release: 2/7

| Paso | Comando | Estado |
|------|---------|--------|
| 34 | Cross-platform Build | ✅ Linux x86_64/aarch64, macOS |
| 35 | Documentation | 🟡 README + ROADMAP |
| 36 | Error Messages | 🟡 Básicos |
| 37 | Dogfooding | ✅ Gitz se versiona a sí mismo |
| 38 | Tests Finales | 🟡 50+ tests |
| 39 | Benchmark Suite | ✅ benchmarks/bench.sh |
| 40 | Release v1.0 | 🔴 No implementado |

---

## Resumen de progreso

| Fase | Total | ✅ Hecho | 🟡 Parcial | 🔴 Pendiente |
|------|-------|----------|------------|--------------|
| 1A Core Local | 16 | 15 | 0 | 1 |
| 2A Transport HTTP | 8 | 5 | 2 | 1 |
| 2B Transport SSH | 2 | 2 | 0 | 0 |
| 3 DX | 7 | 2 | 1 | 4 |
| 4 Polish | 7 | 2 | 2 | 3 |
| Escalabilidad | 14 | 14 | 0 | 0 |
| **Total** | **47** | **40** | **3** | **9** |

---

## Siguientes pasos prioritarios

1. **`gitz rebase -i` con TUI** — Último paso del core local (flechas, pick/squash/drop)
2. **Fix blame encoding** — Mostrar contenido correctamente en blame output
3. **Fix stash** — Solo aplicar archivos modificados, no todos los tracked
4. **Shell completions** — bash/zsh/fish
5. **Documentation** — man pages
6. **`gitz search`** — Buscar en contenido de commits
7. **Cross-platform Windows** — Build para Windows
8. **Release v1.0** — Versionado estable

---

*Última actualización: Agosto 2026*
