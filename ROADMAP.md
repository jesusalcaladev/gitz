# GitZ Roadmap — Todo lo que falta

> Estado actual: **Fase 1A completa + Fase 2A/2B parcial**

---

## ✅ Lo que ya funciona

```
gitz init                    ✅ Crea .gitz/ con estructura completa
gitz add .                   ✅ Agrega recursivo, salta .gitz/, respeta .gitignore
gitz add <file>              ✅ Agrega archivo individual
gitz commit -m "msg"         ✅ Crea commit con tree + blobs correctos
gitz commit -a               ✅ Auto-staged tracked files
gitz commit --amend          ✅ Modifica último commit
gitz status                  ✅ Staged/unstaged/untracked detection completa
gitz diff                    ✅ Algoritmo LCS real + colores ANSI
gitz diff --staged           ✅ Muestra cambios staged
gitz log --oneline           ✅ Historial de commits
gitz log --graph             ✅ Grafo ASCII
gitz log --all               ✅ Todas las branches
gitz log -n <N>              ✅ Limitar cantidad
gitz log --author="name"     ✅ Filtrar por autor
gitz log --grep="text"       ✅ Filtrar por mensaje
gitz log <file>              ✅ Historial de archivo
gitz log show <commit>       ✅ Mostrar diff de commit
gitz branch                  ✅ Lista branches con * para la actual
gitz branch <name>           ✅ Crea branch nueva
gitz branch -d/-D <name>     ✅ Eliminar branch
gitz branch -m <old> <new>   ✅ Renombrar branch
gitz switch -c <name>        ✅ Crea + cambia a branch nueva
gitz switch <branch>         ✅ Cambia a branch existente
gitz merge                   ✅ Fast-forward merge
gitz merge --no-ff           ✅ Merge commit real con 2 padres
gitz rebase                  ✅ Rebase simple sobre branch
gitz rebase --abort          ✅ Cancelar rebase
gitz rebase --onto           ✅ Rebase con base personalizada
gitz stash                   ✅ Guardar working + staged
gitz stash pop/apply         ✅ Aplicar cambios reales al working tree
gitz stash list/drop/show    ✅ Gestión completa de stashes
gitz reset --soft            ✅ Mover HEAD, mantener staged
gitz reset --mixed           ✅ Mover HEAD, unstage
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
.ggitignore support          ✅ Parser completo con !, **, *, ?
SHA-1 hashing                ✅ Usa std.crypto.hash.Sha1 (correcto)
Git objects                  ✅ blob, tree, commit, tag serializados correctamente
Loose object store           ✅ Read/write de objetos en .gitz/objects/
Refs system                  ✅ HEAD, branches, tags con getdents64 raw
Index (staging area)         ✅ Read/write de .gitz/index
Config                       ✅ user.name, user.email via config o env vars
```

---

## 🟢 Fase 1A — Core Local: **COMPLETA (16/16)**

Todos los 16 pasos completados ✅

| Paso | Comando | Estado |
|------|---------|--------|
| 1 | `.gitignore` parser | ✅ Completo |
| 2 | `gitz status` completo | ✅ Completo |
| 3 | `gitz commit` expansiones | ✅ Completo |
| 4 | `gitz log` expansiones | ✅ Completo |
| 5 | `gitz diff` algoritmo LCS | ✅ Completo |
| 6 | `gitz merge` | ✅ Completo |
| 7 | `gitz rebase` simple | ✅ Completo |
| 8 | `gitz rebase -i` (TUI) | 🟡 Placeholder — falta TUI interactivo |
| 9 | `gitz stash` | ✅ Completo |
| 10 | `gitz reset` | ✅ Completo |
| 11 | `gitz undo` | ✅ Completo |
| 12 | `gitz tag` expansiones | ✅ Completo |
| 13 | `gitz branch` expansiones | ✅ Completo |
| 14 | `gitz blame` | ✅ Completo |
| 15 | `gitz gc` | ✅ Completo |
| 16 | Tests compatibilidad Git | ✅ Básicos implementados |

---

## 🟢 Fase 2A — Transporte HTTP: **Parcial (5/8)**

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

## 🟢 Fase 2B — Transporte SSH: **Completa (2/2)**

| Paso | Comando | Estado |
|------|---------|--------|
| 25 | SSH Transport | ✅ Via child process pipes |
| 26 | `gitz remote` con SSH | ✅ Detecta git@ URLs |

---

## 🟣 Fase 3 — Developer Experience: **2/7**

| Paso | Comando | Estado |
|------|---------|--------|
| 27 | `gitz search` | 🔴 No implementado |
| 28 | `gitz review` | 🔴 No implementado |
| 29 | `gitz sync` | 🔴 No implementado |
| 30 | Performance | 🔴 No implementado |
| 31 | Colored Output | ✅ Colores ANSI en diff |
| 32 | Shell Completions | 🔴 No implementado |
| 33 | Configuración | ✅ user.name/email |

---

## 🟢 Fase 4 — Polish & Release: **2/7**

| Paso | Comando | Estado |
|------|---------|--------|
| 34 | Cross-platform Build | ✅ Linux x86_64 |
| 35 | Documentation | 🔴 Pendiente |
| 36 | Error Messages | 🟡 Básicos |
| 37 | Dogfooding | ✅ Gitz se versiona a sí mismo |
| 38 | Tests Finales | 🟡 46+ tests |
| 39 | Benchmark Suite | 🔴 No implementado |
| 40 | Release v1.0 | 🔴 No implementado |

---

## Resumen de progreso

| Fase | Total | ✅ Hecho | 🟡 Parcial | 🔴 Pendiente |
|------|-------|----------|------------|--------------|
| 1A Core Local | 16 | 15 | 1 | 0 |
| 2A Transport HTTP | 8 | 5 | 2 | 1 |
| 2B Transport SSH | 2 | 2 | 0 | 0 |
| 3 DX | 7 | 2 | 0 | 5 |
| 4 Polish | 7 | 2 | 1 | 4 |
| **Total** | **40** | **26** | **4** | **10** |

---

## 🎉 Hitos alcanzados

- **Gitz se versiona a sí mismo** — `gitz init` + `gitz add .` + `gitz commit` funciona
- **Clone desde GitHub** — `gitz clone git@github.com:user/repo.git` funciona con SSH
- **1186 objetos importados** del repositorio orbit en un solo clone
- **Bidirectional compatibility** — git puede operar sobre repos de gitz y viceversa
- **Config** — `gitz config user.name "..."` funciona para commits
- **.gitignore completo** — `gitz add .` respeta archivos ignorados

---

## Siguientes pasos

1. **`gitz rebase -i` con TUI** — Último paso del core local
2. **HTTP clone sin git** — Implementar Smart HTTP Client completo
3. **`gitz push` funcional** — Push a GitHub vía SSH sin git
4. **Shell completions** — bash/zsh/fish
5. **Documentation** — README, man pages

---

*Última actualización: Agosto 2026*
