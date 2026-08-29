# Capa de Compatibilidad con Git — Estado y Hoja de Ruta

> Última actualización: Agosto 2026
> Objetivo: 100% compatibilidad bidireccional con git

Este documento cataloga cada componente del formato interno de git, su estado actual en gitz y qué falta para compatibilidad total. Está basado en una auditoría línea por línea del código fuente.

---

## Tabla Resumen

| Componente | Estado | Compatibilidad |
|-----------|--------|---------------|
| Objetos sueltos (loose) | ✅ Funcional | 100% |
| Formato blob/tree/commit/tag | ✅ Funcional | 95% |
| Compresión zlib | ✅ Funcional | 100% |
| Packfile v2 (escritura) | ✅ Funcional | 90% |
| Packfile v2 (lectura) | 🟡 Parcial | 70% |
| Pack index (.idx) | 🟡 Parcial | 80% |
| Delta resolution (ofs-delta) | ✅ Funcional | 90% |
| Delta resolution (ref-delta) | 🔴 Incompleto | 0% |
| Index (staging area) | 🔴 Bugs | 60% |
| Refs (refs/heads, refs/tags) | ✅ Funcional | 90% |
| Packed-refs | 🔴 No implementado | 0% |
| Reflog | 🔴 No implementado | 0% |
| Config (repo-level) | ✅ Funcional | 80% |
| Config (global) | 🔴 No implementado | 0% |
| .gitignore | ✅ Funcional | 95% |
| HEAD (symbolic ref) | ✅ Funcional | 100% |
| Transporte HTTP (fetch) | ✅ Funcional | 80% |
| Transporte HTTP (push) | 🔴 Sin auth | 40% |
| Transporte SSH | 🔴 Solo child process | 30% |
| Smart HTTP protocol | 🟡 Parcial | 60% |
| Hooks | 🔴 No implementado | 0% |
| GPG signing | 🔴 No implementado | 0% |
| LFS | 🔴 No implementado | 0% |
| Submodules | 🔴 No implementado | 0% |

---

## 1. Index (Staging Area) — 🔴 Bugs críticos

**Archivo:** `src/core/index.zig`

El index es el componente con más bugs de compatibilidad. Git no puede leerlo.

### 1.1 Checksum SHA-1 final ausente

**Bug:** `writeToFile` escribe 20 bytes de ceros como checksum en vez del SHA-1 real del contenido del index.

```zig
// Código actual (index.zig:191-192)
var zero_sha: [20]u8 = [_]u8{0} ** 20;
try std.Io.File.writeStreamingAll(f, io, &zero_sha);
```

**Corrección:** Calcular SHA-1 de todo el contenido del index (desde "DIRC" hasta el último byte de padding) y escribirlo como checksum final.

```zig
// Corrección propuesta
const sha = Sha1.hash(all_bytes_written);
try std.Io.File.writeStreamingAll(f, io, &sha);
```

**Impacto:** Git rechaza el index con `bad index file` o lo ignora silenciosamente.

### 1.2 Flags sin longitud de nombre

**Bug:** El campo `flags` (2 bytes) siempre es 0. Git requiere que los bits 0-11 contengan la longitud del nombre del archivo (capped a 0xFFF).

```zig
// Código actual (index.zig:177)
std.mem.writeInt(u16, buf[pos..][0..2], entry.flags, .big); // flags siempre 0
```

**Corrección:**

```zig
const name_len: u16 = @intCast(@min(entry.name.len, 0x0FFF));
const flags = entry.flags | name_len;
std.mem.writeInt(u16, buf[pos..][0..2], flags, .big);
```

### 1.3 Entradas sin ordenar

**Bug:** Las entradas del index no se ordenan por nombre antes de escribir. Git requiere que las entradas estén ordenadas lexicográficamente por path.

**Corrección:** Ordenar `entries.items` por nombre antes del bucle de escritura.

### 1.4 Sin extensiones del index

**Falta:** Git usa extensiones al final del index:
- `TREE` — cache de árbol para acelerar `status`
- `REUC` — resolved undo entries (para conflictos de merge)
- `link` — para múltiples índices (worktrees)

**Prioridad:** Baja. Funcionalidad opcional, no afecta compatibilidad básica.

### 1.5 Stat info incompleta

**Bug:** Los campos `dev`, `ino`, `uid`, `gid` siempre son 0 en `addFile`. Git los llena con valores reales del stat del archivo.

### 1.6 Sin modo 100755

**Bug:** `addFile` siempre usa `0o100644`. No detecta archivos ejecutables (`0o100755`).

### 1.7 Sin soporte para symlinks

**Falta:** Git guarda symlinks como blobs con modo `0o120000`. Gitz no los detecta.

### 1.8 Sin version 3 ni 4 del index

**Falta:** El index v3 soporta entries con flags extendidos. El index v4 usa path prefix compression. Gitz solo soporta v2.

---

## 2. Refs — 🟡 Funcional pero incompleto

**Archivo:** `src/core/refs.zig`

### 2.1 Sin packed-refs

**Falta:** Git empaqueta refs en `.git/packed-refs` (un solo archivo texto) después de `gc`. Cuando una ref no existe como loose, git la busca en `packed-refs`.

**Impacto:** Si un repo clonado con git tiene `packed-refs` pero no refs sueltas, gitz no ve ninguna rama.

**Corrección:** Implementar lectura de `packed-refs` como fallback en `Refs.read()`.

### 2.2 Listado de refs no recursivo

**Bug:** `listDirRaw` no es recursivo. Si hay refs en subdirectorios como `refs/heads/feature/foo`, no las lista correctamente (solo lista el directorio `feature/` como si fuera un archivo).

### 2.3 Sin reflog

**Falta:** Git escribe en `.git/logs/HEAD` (y `.git/logs/refs/heads/<branch>`) después de cada commit, merge, rebase, reset, etc. Gitz no escribe reflog.

**Impacto:**
- `gitz reflog` no funciona
- `gitz reset --hard @{1}` no funciona
- Git muestra warning "no reflog" al leer un repo de gitz

**Corrección:** Añadir escritura de reflog en cada operación que mueve HEAD.

### 2.4 Sin soporte para HEAD crudo

**Falta:** Git soporta HEAD como SHA crudo (detached HEAD). Gitz lo maneja pero no escribe el formato correcto al hacer checkout de un commit específico.

### 2.5 Sin symref en refs

**Falta:** Git soporta refs simbólicas además de HEAD (ej. `refs/heads/main` puede apuntar a otra ref). Gitz solo soporta symbolic ref para HEAD.

---

## 3. Objetos — ✅ Casi perfecto

**Archivo:** `src/core/object.zig`

### 3.1 Sin soporte GPG signature en commits

**Falta:** Los commits de git pueden incluir bloques `gpgsig`:

```
-----BEGIN PGP SIGNATURE-----
...
-----END PGP SIGNATURE-----
```

Gitz no parsea ni preserva firmas GPG al serializar commits.

**Impacto:** Commits firmados pierden su firma al ser re-serializados.

### 3.2 Sin header `encoding` en commits

**Falta:** Git soporta `encoding` en commits para especificar la codificación del mensaje. Gitz ignora este header.

### 3.3 Sin soporte para tree entries con modo 160000 (gitlinks)

**Falta:** Los submodules usan modo `0o160000` (gitlink) en tree entries. Gitz no lo distingue.

### 3.4 Serialización de tree con modo incorrecto

**Bug menor:** `serializeTree` usa `{o}` para formatear el modo. Para `0o100644` produce `100644` (correcto), pero para `0o040000` produce `40000` (correcto). Sin embargo, el modo `0o100755` produce `100755` (correcto). **Este punto está bien.**

---

## 4. Packfile y Pack Index — 🟡 Parcial

**Archivos:** `src/core/packfile.zig`, `src/core/packindex.zig`, `src/core/delta.zig`

### 4.1 Ref-delta sin resolver

**Bug:** `delta.zig` línea 100 retorna `error.BaseObjectNotFound` para ref-deltas. Solo ofs-delta está implementado.

```zig
// delta.zig:98-101
// For now, we need to find the base object by SHA
// In a full implementation, this would search the pack index
return error.BaseObjectNotFound;
```

**Impacto:** Packfiles generados por git que usen ref-delta (común en fetch/clone) no se pueden leer completamente.

### 4.2 Pack index sin checksums correctos

**Bug:** `writeIndex` escribe placeholders de ceros para el pack SHA-1 y el index SHA-1.

```zig
// packindex.zig:177-179
try buf.appendSlice(allocator, &[_]u8{0} ** 20);  // pack SHA placeholder
try buf.appendSlice(allocator, &[_]u8{0} ** 20);  // index SHA placeholder
```

**Impacto:** Git valida estos checksums al leer el index y rechaza archivos corruptos.

### 4.3 GC no genera .idx

**Bug:** `ObjectStore.gc()` escribe el packfile (`.pack`) pero no genera el `.idx` correspondiente. Sin el index, los objetos en el pack son inaccesibles.

**Corrección:** Llamar a `writeIndex` después de `finalize` y escribir el `.idx` junto al `.pack`.

### 4.4 GC no actualiza packed-refs

**Falta:** Después de `gc`, git mueve refs sueltas a `packed-refs`. Gitz deja las refs sueltas y elimina los objetos loose.

### 4.5 Sin soporte multi-pack-index

**Falta:** Git soporta `.git/objects/pack/multi-pack-index` para acelerar búsquedas en múltiples packs. Opcional pero mejora rendimiento.

### 4.6 Packfile sin thin pack support

**Falta:** El protocolo smart HTTP puede enviar "thin packs" que usan refs del remote como base para deltas. Gitz no maneja thin packs.

---

## 5. Config — 🟡 Funcional pero limitado

**Archivo:** `src/core/config.zig`

### 5.1 Sin config global

**Bug:** Gitz solo lee `.gitz/config`. No lee `~/.gitconfig` ni `/etc/gitconfig`.

**Impacto:** `user.name` y `user.email` deben configurarse por repo. No respeta la configuración global del usuario.

**Corrección:** Leer config en orden: sistema → global → repo (con override).

### 5.2 Config no preserva formato

**Bug:** Al serializar, gitz reescribe todo el config perdiendo comentarios, orden de secciones y formato original.

### 5.3 Sin includeIf

**Falta:** Git soporta `[includeIf "gitdir:..."]` para includes condicionales. Gitz no lo implementa.

### 5.4 Sin soporte de booleanos y enteros tipados

**Falta:** Git distingue entre `true`/`false`/`1`/`0` para valores booleanos. Gitz trata todo como string.

### 5.5 Parser de config no maneja espacios en valores

**Bug:** El parser hace `trim` de comillas pero no maneja valores con espacios escapados o comillas anidadas.

### 5.6 Sin soporte de `core.*`

**Falta:** Gitz no lee ni respeta settings de `core.*` como:
- `core.filemode` — si respetar el bit de ejecutable
- `core.symlinks` — si seguir symlinks
- `core.ignorecase` — si ignorar mayúsculas/minúsculas
- `core.autocrlf` — conversión de line endings
- `core.safecrlf` — validación de CRLF

---

## 6. .gitignore — ✅ Casi completo

**Archivo:** `src/core/ignore.zig`

### 6.1 Sin soporte para gitignore global

**Falta:** Git lee `~/.config/git/ignore` y `core.excludesFile`. Gitz solo lee `.gitignore` en el directorio actual.

### 6.2 Sin .git/info/exclude

**Falta:** Git lee `.git/info/exclude` como un gitignore local adicional.

### 6.3 Patrones con [charset]

**Falta:** No se soportan patrones con clases de caracteres como `*.[oa]`.

### 6.4 Stack de ignore no jerárquico correcto

**Bug menor:** `IgnoreStack.isIgnored` retorna true si CUALQUIER ruleset coincide, pero no respeta la precedencia correcta (último match gana a través de toda la jerarquía).

---

## 7. Transporte HTTP — 🔴 Sin autenticación

**Archivo:** `src/transport/http.zig`

### 7.1 Sin headers de autenticación

**Bug crítico:** `httpRequest` no envía headers `Authorization`. GitHub devuelve 401 para cualquier operación de escritura (receive-pack).

```zig
// http.zig:489-494 — sin headers de auth
const result = client.fetch(.{
    .location = .{ .uri = uri },
    .method = method_enum,
    .payload = if (body.len > 0) body else null,
    .response_writer = &aw.writer,
}) catch return error.HttpRequestFailed;
```

**Corrección:** Detectar token de `GITHUB_TOKEN`/`GH_TOKEN` o credentials, añadir `Authorization: Bearer <token>` o `Authorization: Basic <base64(user:pass)>`.

### 7.2 Sin Content-Type correcto

**Bug:** Los POST a `/git-receive-pack` y `/git-upload-pack` requieren `Content-Type: application/git-receive-pack-request` y `application/git-upload-pack-request` respectivamente. Gitz no los envía.

### 7.3 Sin redirect handling

**Falta:** GitHub HTTP puede redirigir (301/302). `std.http.Client` los sigue pero gitz no maneja el caso donde la URL del remote cambia.

### 7.4 Sin soporte para credentials helper

**Falta:** Git usa `credential.helper` para obtener credenciales. Gitz no lo invoca.

### 7.5 Sin HTTPS con certificados personalizados

**Falta:** No hay soporte para `http.sslCAInfo` o `http.sslVerify`.

### 7.6 Sin protocolo Wire v2

**Falta:** Git protocolo v2 (`Git-Protocol: version=2`) permite fetch más eficiente con server-side filtering. Gitz usa protocolo v0.

---

## 8. Transporte SSH — 🔰 Solo child process

**Archivo:** `src/transport/ssh.zig`

### 8.1 No es SSH nativo

**Estado actual:** `ssh.zig` solo parsea URLs SSH y delega a `ssh` binary vía child process. No hay implementación del protocolo SSH.

**Lo que falta para SSH nativo:**
- Handshake SSH (kex)
- Autenticación por clave pública
- Cipher suites (AES, ChaCha20)
- MAC (HMAC, Poly1305)
- Canales y multiplexing
- `git-upload-pack` y `git-receive-pack` sobre canal SSH

### 8.2 Sin ssh-agent support

**Falta:** No se puede usar ssh-agent para autenticación.

### 8.3 Sin known_hosts

**Falta:** No se verifica la firma del servidor SSH contra `~/.ssh/known_hosts`.

---

## 9. Operaciones Git — Bugs y funcionalidades faltantes

### 9.1 Merge sin resolución de conflictos

**Archivo:** `src/cli/commands/merge.zig`

**Falta:** El merge actual solo soporta fast-forward y merge sin conflictos. Si hay conflictos, no los marca ni genera markers `<<<<<<<`.

### 9.2 Rebase -i sin TUI

**Falta:** El rebase interactivo es un placeholder. No hay menú pick/squash/drop funcional.

### 9.3 Stash aplica todos los archivos

**Bug conocido:** `stash` guarda y aplica todos los tracked files, no solo los modificados.

### 9.4 Commit -a re-adds todos los archivos

**Bug conocido:** `commit -a` re-stages todos los archivos, no solo los modificados.

### 9.5 Clone sin checkout automático

**Bug conocido:** El clone funciona como `--bare`. No hace checkout de archivos al working tree.

### 9.6 Blame con encoding incorrecto

**Bug conocido:** El autor se muestra con caracteres corruptos en commits importados vía clone.

### 9.7 Diff sin hunks con contexto

**Bug:** El diff siempre emite un solo hunk con todo el archivo. Git segmenta en hunks con contexto de 3 líneas por defecto (`@@ -a,b +c,d @@`).

### 9.8 Sin soporte para `git worktree`

**Falta:** No hay soporte para worktrees (`git worktree add`).

### 9.9 Sin soporte para `git cherry-pick`

**Falta:** No implementado.

### 9.10 Sin soporte para `git revert`

**Falta:** `gitz undo` crea un commit inverso, pero no hay `revert` con rango de commits.

### 9.11 Sin soporte para `git bisect`

**Falta:** No implementado.

### 9.12 Sin soporte para `git submodule`

**Falta:** No hay soporte para submodules.

### 9.13 Sin soporte para hooks

**Falta:** Git ejecuta hooks en `.git/hooks/` (pre-commit, post-commit, pre-push, etc.). Gitz no los ejecuta.

### 9.14 Sin soporte para `git notes`

**Falta:** No implementado.

### 9.15 Sin soporte para `git describe`

**Falta:** No implementado.

### 9.16 Sin soporte para `git format-patch` / `git am`

**Falta:** No implementado.

### 9.17 Sin soporte para `git archive`

**Falta:** No implementado.

### 9.18 Sin soporte para `git fsck`

**Falta:** No hay verificación de integridad de objetos.

---

## 10. Formatos de Archivo Faltantes

### 10.1 Sin commit-graph

**Falta:** Git usa `.git/objects/info/commit-graph` para acelerar `log` y traversal de commits.

### 10.2 Sin multi-pack-index

**Falta:** `.git/objects/pack/multi-pack-index` para acelerar lookups en múltiples packs.

### 10.3 Sin alternates

**Falta:** `.git/objects/info/alternates` permite compartir objetos entre repos. Gitz no lo soporta.

### 10.4 Sin `.gitattributes`

**Falta:** No hay soporte para atributos de archivo (line endings, diff drivers, merge drivers).

### 10.5 Sin `.git/info/attributes`

**Falta:** Attributes locales del repo.

---

## 11. Line Endings y Archivos Binarios

### 11.1 Sin detección de archivos binarios

**Falta:** `diff` no detecta archivos binarios. Intenta hacer diff de cualquier archivo como texto.

### 11.2 Sin `core.autocrlf`

**Falta:** No hay conversión automática de CRLF/LF.

---

## 12. Protocolo Wire — 🟡 Parcial

### 12.1 Sin protocolo v2

**Falta:** Protocol v2 permite:
- Server-side ref filtering
- Partial clone (`--filter=blob:none`)
- `ls-refs` command
- `fetch` con capabilities

### 12.2 Sin shallow clone

**Falta:** `--depth=N` no implementado. Requiere soporte de shallow refs y grafts.

### 12.3 Sin partial clone

**Falta:** `--filter` no implementado. Requiere soporte de promisor remotes y missing objects.

### 12.4 Sin bundle support

**Falta:** `git bundle` crea un archivo autocontenido con objetos y refs. Gitz no lo soporta.

---

## 13. Internacionalización y Encoding

### 13.1 Sin soporte UTF-8 BOM

**Falta:** Algunos archivos pueden tener BOM. Gitz no lo maneja.

### 13.2 Sin soporte para paths con caracteres especiales

**Falta:** Git usa `core.quotePath` para mostrar paths con caracteres no ASCII. Gitz no escapa paths.

---

## 14. Prioridades de Implementación

### 🔴 Crítico (bloquea compatibilidad básica con git)

1. **Index checksum SHA-1** — Sin esto, git no puede leer el index
2. **Index flags con longitud de nombre** — Sin esto, git no puede leer entries
3. **Index entries ordenadas** — Sin esto, git no puede leer el index
4. **GC genera .idx** — Sin esto, los objetos packed son inaccesibles
5. **HTTP auth** — Sin esto, no se puede push a GitHub
6. **Packed-refs** — Sin esto, gitz no ve branches en repos clonados con git

### 🟡 Alto (rompe flujos comunes)

7. **Reflog** — Sin esto, `git reflog` y `HEAD@{N}` no funcionan
8. **Ref-delta resolution** — Sin esto, no se pueden leer todos los packfiles de git
9. **Config global** — Sin esto, cada repo necesita config individual
10. **Modo ejecutable (100755)** — Sin esto, los permisos se pierden
11. **Diff hunks con contexto** — Sin esto, el diff no es legible
12. **Content-Type en HTTP POST** — Sin esto, GitHub rechaza el push
13. **Listado de refs recursivo** — Sin esto, no se ven branches anidadas

### 🟢 Medio (funcionalidad importante)

14. **Merge con resolución de conflictos**
15. **Symlinks**
16. **Hooks**
17. **GPG signature preservation**
18. **SSH nativo** (sin child process)
19. **Protocolo v2**
20. **Shallow clone**

### ⚪ Bajo (nice to have)

21. Commit-graph
22. Multi-pack-index
23. Worktrees
24. Submodules
25. Bisect
26. Notes
27. .gitattributes
28. Partial clone

---

## 15. Tests de Compatibilidad

### Tests existentes

**Archivo:** `src/tests/integration/compat.zig`

Los tests actuales verifican:
- Formato de objetos (blob, tree, commit)
- SHA-1 correctness
- Roundtrip serialize/deserialize

### Tests faltantes

1. **Index interchange:** `git --git-dir=.gitz status` debe funcionar sin errores
2. **Pack interchange:** `git verify-pack .gitz/objects/pack/*.idx` debe pasar
3. **Config interchange:** `git config --file .gitz/config --list` debe listar todo
4. **Clone bidireccional:** `git clone` un repo creado por gitz
5. **Push bidireccional:** `gitz push` a un repo creado por git
6. **Fetch bidireccional:** `gitz fetch` de un repo con packed-refs
7. **Roundtrip completo:** `gitz commit` → `git read` → `gitz read` → `git read`

---

## 16. Resumen Ejecutivo

Gitz tiene una base sólida: los formatos de objetos, la serialización, la compresión zlib y la estructura de refs son compatibles con git. El push a GitHub funcionó usando `git --git-dir=.gitz push` porque los objetos sueltos son 100% compatibles.

**Los 6 bugs críticos que impiden 100% compatibilidad son:**

1. Index sin checksum SHA-1
2. Index sin flags de longitud de nombre
3. Index sin entries ordenadas
4. GC sin generación de .idx
5. HTTP sin autenticación
6. Sin soporte de packed-refs

Corregir estos 6 puntos llevaría la compatibilidad de ~70% a ~95%. El 5% restante son funcionalidades avanzadas (protocol v2, partial clone, submodules, hooks).

---

*Auditoría basada en revisión línea por línea del código fuente en `src/`. Agosto 2026.*
