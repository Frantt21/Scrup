// Fondo "iridiscente" del fullscreen (adaptado del componente LiquidChrome/
// Iridescence de React+ogl).
//
// TRUCO CENTRAL — FEEDBACK LOOP: dos acumuladores (`a`, `d`) se
// retroalimentan durante 8 iteraciones: `a` integra cosenos de la posición
// X deformada por `d`, y `d` integra senos de Y deformado por `a`. El
// resultado es un patrón orgánico tipo aceite sobre agua imposible de
// lograr con ruido plano.
//
// El tinte sale de una PALETA DE COSENOS (patrón → fase → cos) modulada
// por la paleta tricolor del artwork (uniforms ya interpolados en Dart).
// Un factor de atenuación global mantiene el fondo lo bastante oscuro para
// los lyrics; cubre todo el lienzo borde a borde y el tiempo nunca se
// detiene.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;  // índices 0-1
uniform float uTime;       // índice 2
uniform vec3 uColorA;      // índices 3-5
uniform vec3 uColorB;      // índices 6-8
uniform vec3 uColorC;      // índices 9-11

out vec4 fragColor;

// Parámetros ajustables.
const float kSpeed = 0.45;    // velocidad del flujo
const float kDim = 0.80;      // atenuación global (contraste lyrics)

void main() {
  // Coordenadas centradas escaladas por el lado menor (como el original).
  float mr = min(uResolution.x, uResolution.y);
  vec2 uv = (FlutterFragCoord().xy * 2.0 - uResolution) / mr;

  float t = uTime * kSpeed;

  // Feedback loop: cada iteración alimenta la siguiente con su propia salida.
  float d = -t * 0.5;
  float a = 0.0;
  for (float i = 0.0; i < 8.0; ++i) {
    a += cos(i - d - a * uv.x);
    d += sin(uv.y * i + a);
  }
  d += t * 0.5;

  // Patrón iridiscente: canal R/G desde el campo deformado, B del par (a,d).
  vec3 pat = vec3(
    cos(uv * vec2(d, a)) * 0.6 + 0.4,
    cos(a + d) * 0.5 + 0.5
  );
  // Paleta de cosenos: patrón → fase → cos (los negativos caen a negro al
  // escribir el framebuffer, como en el original WebGL).
  vec3 wave = cos(pat * cos(vec3(d, a, 2.5)) * 0.5 + 0.5);

  // Tinte tricolor: A/B se reparten según la fase `d`, C entra con `a` —
  // los tres colores fluyen por zonas distintas del patrón.
  vec3 base = mix(uColorA, uColorB, clamp(0.5 + 0.5 * sin(d * 0.7), 0.0, 1.0));
  base = mix(base, uColorC, clamp(0.5 + 0.5 * cos(a * 0.6), 0.0, 1.0));

  fragColor = vec4(max(wave, 0.0) * base * kDim, 1.0);
}
