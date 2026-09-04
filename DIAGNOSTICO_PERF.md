# Diagnóstico de lag al cambiar de canción (Android)

Bitácora viva de la cacería del lag en transiciones. Flags de diagnóstico en
`lib/core/app_log.dart` (`kPaletteLog`, `kJankLog`, `kShowPerfOverlay`,
`kProfileBuilds`, `kFlatBlackPlayer`, `kHideHomeRecents`).

Lectura de la gráfica (`kShowPerfOverlay`): arriba hilo UI, abajo GPU. Cada
barra = un frame; sobre la línea verde = frame perdido. Medido en release
(Galaxy A15): raster máx ~18.5ms, UI máx ~41ms, curva en U invertida con pico
en medio del cambio.

Logs: `adb logcat -d | grep SCPR` (tags `ACCENT`, `WARM`, `TRACK`, `UI`,
`OS`, `THEME`, `LYRICS`, `PERF`, `JANK`, `SEED`).

## Experimentos (A/B en dispositivo)

| # | Prueba | Resultado |
|---|--------|-----------|
| 1 | Ventana del lila en arranque en frío (~1.6s con acento null → fallback lila) | CONFIRMADO. Fix: fallback neutro transparente en miniplayer y player extendido (funde desde negro, jamás lila). Verificado en logs (`accent=#00000000` → `bg-anim` al color real). |
| 2 | Punto medio del lerp HSL (morado→azul pasaba por azul oscuro vívido, se leía como tercer paso) | CONFIRMADO por análisis (determinista por par de colores). Fix: crossfade RGB en fondo + mini con `begin` real + misma curva/duración (350ms easeOutCubic) en fondo, sheet y mini. |
| 3 | Sheet de letras cambiaba al instante, adelantado al fondo 350ms | CONFIRMADO. Fix: color del sheet con el mismo tween que el fondo (verificado a 23ms de distancia en logs). También se reparó que su fondo no llegaba tras la barra de navegación (el padding del inset va dentro de la caja con color). |
| 4 | Tema animado 700ms reconstruía todo el árbol cada frame | CONFIRMADO (racimos de jank). Fix: 200ms + semilla del tema diferida 400ms tras el acento (`themeSeed`), para no apilar el re-theme sobre la ventana del cambio. |
| 5 | `setState` incondicional cada 250ms en el overlay (reconstruía 1500 líneas 4×/seg, hasta en pausa) | CONFIRMADO (metrónomo en logs hasta en `PAUSED`). Fix: eliminado; el ticker de 500ms ya hacía ese trabajo. Tickers de overlay y mini acotados a cambio de segundo. Reposo: 12s con 0 jank. |
| 6 | Fetches de letras duplicados/triplicados (2 vistas vivas + republicaciones) | CONFIRMADO en logs. Fix: single-flight en `LyricsService` + skip si se republica el mismo tema + spinner solo si tarda >150ms. |
| 7 | Portadas full-res a GPU en cada cambio (sin `cacheWidth`, ×2 widgets) | CONFIRMADO por código (picos de raster al aparecer el arte). Fix: `cacheWidth` 900 (overlay) / 150 (mini) + `gaplessPlayback`. Precache usa `ResizeImage` del mismo tamaño para que el caché coincida. |
| 8 | `kFlatBlackPlayer`: todo el sistema de acento apagado, negro plano | RESULTADO: el lag baja → **la transición es un culpable**. |
| 9 | `kHideHomeRecents`: recientes de home ocultas + sin suscripciones (cada canción dispara `recordPlay` → reemite recientes → rebuild del grid) | RESULTADO: el lag baja más (pico UI a 14ms) → **segundo culpable**. Fix definitivo: update inmediato + skip si no cambia + `cacheWidth` ya existente. |
| 10 | Letras de vuelta + fondo de artwork difuminado + debounce next/prev | Letras restauradas (con single-flight). Fondo del player: artwork con blur sigma 70 + velo negro 60% y fundido 400ms (sustituye al plano de acento; el acento sigue en tintes). Debounce 700ms en `next()`/`previous()` + slide con frescura 1.5s. |
| 10 | Estudio forawn_mobile (`../forawn_mobile`, player local) | Patrones extraídos: recientes en memoria + escritura fire-and-forget (sin streams reactivos de DB); acento como `int` precalculado + animaciones implícitas locales (**chrome estático, sin re-theme global**); artwork con `cacheWidth: w*dpr` + `gaplessPlayback` + placeholder de color; sin precache de siguiente (local no lo necesita); rebuilds granulares (`StreamBuilder` al slider, `ValueNotifier<int>` a la línea activa); tickers mínimos (indicador con `stop()` en pausa). Aplicado a Scrup: tema instantáneo (tinte global sin tormenta), throttle del ticker de letras a 30Hz, precache con `ResizeImage` del mismo tamaño que el display. OJO: forawn tarda 800-1000ms en sus fundidos; aquí 350ms. |
| 11 | Timestamp ausente en notificación + play/pausa "muerto" | Causa: nunca se publicaba `processingState` (sesión en `STATE_NONE`). Fix: se publica `ready/buffering`. Verificado por adb: tarjeta del sistema con `01:38 / 04:07`, los 5 botones (shuffle, prev, play/pausa, next, favorito) con taps reales probados (uiautomator) y estados sincronizados en ambos sentidos. |

## Veredicto (medido por el usuario en release con gráfica)

## Optimizaciones aplicadas (en el código)

- `ThemeController`: nunca anula el acento en fallo (conserva el anterior);
  precarga el acento (+ artwork en disco) de las 2 siguientes al cambiar la
  cola y al aparecer pista "en preparación".
- Transiciones de acento sincronizadas fondo/sheet/mini (350ms easeOutCubic,
  crossfade RGB, sin tercer color, sin salto desde transparente).
- Tema: animación 200ms + `themeSeed` diferida 400ms.
- Rebuilds: fuera el `setState` de posición del stream (overlay), tickers a
  cambio de segundo, `setState` de favorito solo si cambia, spinner de letras
  diferido, single-flight + skip de letras, `cacheWidth` + `gaplessPlayback`.
- Notificación: arte HQ con verificación 200 (fallback al original),
  duración viva (re-emit), shuffle/favorito customs con drawables nativos,
  `processingState`, índices compactos [0,1,2].

## Firma actual del jank (release, extendido)

~5 frames de 30-50ms por transición (build; raster sano salvo primer frame
del arte), ventana de ~1s. Sospechosos restantes por orden: re-theme (aunque
diferido), completions async apiladas ~+800ms (letras listas, primer frame
del arte, warms), republicación por enriquecido.

## Comandos útiles

```bash
# release con gráfica + instalar + lanzar
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.scrup.scrup/.MainActivity
# medir una transición limpia
adb shell "cmd media_session dispatch next"
adb logcat -d | grep "SCPR\[" | grep -E "SET|JANK"
# jank por transición (requiere ventana con SETs)
adb logcat -d | grep "SCPR\[JANK" | head -20
```
