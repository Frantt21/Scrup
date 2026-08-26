// Fondo "líquido cromado" del fullscreen (inspirado en LiquidChrome).
//
// Dos ingredientes:
//  1. WARP ITERATIVO: 9 pasadas de `amp/i * cos(i·f·coord + t)` sobre las
//     coordenadas — cada pasada añade una frecuencia superior con menos
//     amplitud, generando el flujo orgánico en capas.
//  2. CAMPO CROMO: `1 / |sin(t - x - y)|` — vetas brillantes donde el seno
//     cruza cero, oscuridad entre ellas. Es lo que da el aspecto metálico
//     líquido.
//
// La paleta tricolor del artwork llega por uniforms (ya interpolada en Dart
// durante las transiciones de canción) y tiñe las vetas. El brillo queda
// TECHADO para que los lyrics conserven contraste pase lo que pase.
//
// Cubre TODO el lienzo borde a borde (sin viñeta ni anclas) y el tiempo es
// continuo: nunca se congela.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;  // índices 0-1
uniform float uTime;       // índice 2
uniform vec3 uColorA;      // índices 3-5
uniform vec3 uColorB;      // índices 6-8
uniform vec3 uColorC;      // índices 9-11

out vec4 fragColor;

// Parámetros del efecto (ajustables a ojo).
const float kSpeed = 0.55;      // velocidad global del flujo
const float kAmplitude = 0.28;  // cuánto se deforma el espacio
const float kFreqX = 2.6;       // densidad de ondas horizontales
const float kFreqY = 3.4;       // densidad de ondas verticales

void main() {
  vec2 frag = FlutterFragCoord().xy;

  // Coordenadas centradas, normalizadas al lado menor (aspecto correcto).
  vec2 uv = (2.0 * frag - uResolution) / min(uResolution.x, uResolution.y);

  float t = uTime * kSpeed;

  // 1. Warp iterativo: frecuencias crecientes con amplitud decreciente.
  vec2 p = uv;
  for (float i = 1.0; i < 10.0; i++) {
    p.x += kAmplitude / i * cos(i * kFreqX * uv.y + t + i * 0.7);
    p.y += kAmplitude / i * cos(i * kFreqY * uv.x + t - i * 0.5);
  }

  // 2. Campo cromo: vetas donde sin(t - x - y) ≈ 0. El +0.35 techa el
  //    máximo (evita divisiones hacia infinito = píxeles calientes) y el
  //    pow afina la veta.
  float band = abs(sin(t - p.x - p.y));
  float ridge = pow(1.0 / (band + 0.35), 1.5);

  // Luminancia mayormente OSCURA con vetas luminosas: contraste seguro
  // para el texto del reproductor. El piso (0.18) deja ver el TONO del
  // color en las zonas bajas en vez de caer a negro puro.
  float lum = 0.18 + 0.17 * ridge;

  // Paleta TRICOLOR: tres regiones que fluyen con el campo deformado, cada
  // una con fase y dirección PROPIAS para que los tres colores del artwork
  // sean visibles (antes las mezclas eran tan anchas/oscuras que parecía
  // monocromo). Los smoothstep marcan fronteras nítidas entre zonas.
  float mAB = clamp(0.5 + 0.5 * sin(p.x * 0.75 + t * 0.18), 0.0, 1.0);
  vec3 col = mix(uColorA, uColorB, smoothstep(0.15, 0.85, mAB));
  float mC = clamp(
    0.5 + 0.5 * sin(p.y * 0.85 - p.x * 0.45 + t * 0.24),
    0.0,
    1.0
  );
  col = mix(col, uColorC, smoothstep(0.35, 0.90, mC));

  fragColor = vec4(col * lum, 1.0);
}
