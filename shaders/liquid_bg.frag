// Fondo líquido del fullscreen.
//
// El patrón fluido (feedback loop de cosenos/senos, igual que antes) ya no
// genera color: SOLO modula BRILLO y decide la MEZCLA entre los tres colores
// de la paleta del artwork. Así cada tinte del fondo pertenece al convexo de
// esa paleta — nunca aparecen tonos ajenos (verdes, morados) que desentonen
// con el acento real de la pista.
//
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uTime;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;

out vec4 fragColor;

// Parámetros ajustables.
const float kSpeed = 0.45;    // velocidad del flujo
const float kDim = 0.80;      // atenuación global (contraste lyrics)

void main() {
  // Coordenadas centradas escaladas por el lado menor.
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

  // Campos escalares suaves 0..1 derivados del dominio deformado: deciden
  // QUÉ color de la paleta se pinta en cada punto (sin tocar canales por
  // separado, que era lo que creaba tonos ajenos).
  float m1 = 0.5 + 0.5 * cos(uv.x * d + uv.y * a + a * 0.7);
  float m2 = 0.5 + 0.5 * cos((uv.y - uv.x) * a * 0.6 + d * 0.8);
  float shade = 0.5 + 0.5 * cos(a + d + uv.x * 1.5 - uv.y * 1.2);

  // Mezcla DENTRO de la paleta: A↔B según m1, C entra parcialmente encima.
  vec3 col = mix(uColorA, uColorB, m1);
  col = mix(col, uColorC, m2 * 0.85);

  // Variación de brillo que preserva el tono (multiplica los 3 canales por
  // igual): profundidad del fluido sin desviar el color.
  col *= 0.55 + 0.65 * shade;

  fragColor = vec4(col * kDim, 1.0);
}
