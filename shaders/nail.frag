#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform vec2 uCenter;
uniform float uAngle;
uniform vec2 uPhotoSize;
uniform vec3 uColor;
uniform vec3 uAccent;
uniform float uPattern;
uniform float uGloss;
uniform float uCoverage;
uniform float uPatternScale;
uniform float uVariant;
uniform float uFinishGloss;
uniform float uHasDesign;
uniform float uHasWarp;
uniform float uLightDirection;
uniform float uCoatAmount;
uniform sampler2D uPhoto;
uniform sampler2D uMask;
uniform sampler2D uDesign;
uniform sampler2D uWarp;
out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}
float cloud(vec2 p) {
  return noise(p) * 0.58 + noise(p * 2.07 + 7.2) * 0.28 + noise(p * 4.13 + 2.8) * 0.14;
}
float circle(vec2 p, float radius) {
  return 1.0 - smoothstep(radius - 0.012, radius + 0.012, length(p));
}
float ellipse(vec2 p, vec2 radii) {
  return 1.0 - smoothstep(0.94, 1.06, length(p / radii));
}
float flower(vec2 p, float radius) {
  float a = atan(p.y, p.x);
  float edge = radius * (0.77 + 0.23 * cos(5.0 * a));
  return 1.0 - smoothstep(edge - 0.009, edge + 0.009, length(p));
}
float heart(vec2 p) {
  vec2 q = vec2(p.x * 3.4, -p.y * 3.4 + 0.20);
  float a = dot(q, q) - 0.75;
  float d = a * a * a - q.x * q.x * q.y * q.y * q.y;
  return 1.0 - smoothstep(-0.025, 0.025, d);
}
float star(vec2 p) {
  float a = atan(p.y, p.x) + 1.5707963;
  float radius = 0.22 + 0.11 * cos(5.0 * a);
  return 1.0 - smoothstep(radius - 0.012, radius + 0.012, length(p));
}

// Flake centers, outlines and facet tilts belong to the cured polish. Only
// their reflection changes with the lamp; never seed particles with the light.
vec2 flakeLayer(vec2 uv, vec2 count, vec2 seed, vec3 normal, vec3 halfLight, float density) {
  vec2 grid = uv * count;
  vec2 cell = floor(grid);
  float id = hash(cell + seed);
  vec2 center = vec2(0.27) + vec2(hash(cell + seed + 3.7), hash(cell + seed + 9.1)) * 0.46;
  vec2 p = fract(grid) - center;
  float angle = hash(cell + seed + 17.4) * 6.2831853;
  float c = cos(angle), s = sin(angle);
  p = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
  p.y *= 0.78 + hash(cell + seed + 21.0) * 0.85;
  float edge = max(abs(p.x) * 0.8660254 + abs(p.y) * 0.5, abs(p.y));
  float radius = 0.12 + hash(cell + seed + 4.1) * 0.12;
  float aa = clamp(max(count.x / uSize.x, count.y / uSize.y) * 0.18, 0.018, 0.22);
  float covered = (1.0 - smoothstep(radius - aa, radius + aa, edge)) * step(1.0 - density, id);
  vec2 tilt = (vec2(hash(cell + seed + 31.3), hash(cell + seed + 39.7)) - 0.5) * 1.40;
  vec3 facet = normalize(normal + vec3(tilt, 0.12));
  float facing = max(dot(facet, halfLight), 0.0);
  float reflected = pow(facing, 70.0) * 0.82 + pow(facing, 16.0) * 0.18;
  float resolution = clamp(min(uSize.x / count.x, uSize.y / count.y) * 0.7, 0.3, 1.0);
  return vec2(covered, covered * reflected) * resolution;
}

vec3 glitterMaterial(vec3 color, vec2 uv, vec3 normal, vec3 halfLight, float gloss) {
  float scale = max(0.45, uPatternScale);
  vec2 seed = vec2(uVariant * 11.3, uVariant * 7.7);
  vec2 coarse = flakeLayer(uv, vec2(22.0, 33.0) * scale, seed, normal, halfLight, 0.64);
  vec2 fine = flakeLayer(uv, vec2(61.0, 92.0) * scale, seed + 53.8, normal, halfLight, 0.86);
  float body = coarse.x * 0.13 + fine.x * 0.095;
  float glints = coarse.y * 0.82 + fine.y * 0.48;
  float finish = 0.56 + gloss * 0.44;
  vec3 flakeColor = mix(uColor, uAccent, 0.80);
  color = mix(color, flakeColor, clamp(body + glints * finish, 0.0, 0.91));
  // The few near-aligned facets can approach white. The dark/color base stays
  // visible between them, unlike a broad white lamp painted over all glitter.
  return mix(color, mix(uAccent, vec3(1.0), 0.38), clamp(glints * glints * 0.30 * finish, 0.0, 0.26));
}

vec3 magneticMaterial(vec3 color, vec2 uv, vec3 normal, vec3 halfLight, float gloss) {
  float scale = max(0.45, uPatternScale);
  vec2 seed = vec2(uVariant * 11.3, uVariant * 7.7);
  // The magnet pattern is fixed by the saved style. A new lamp changes which
  // magnetic facets reflect; it does not rotate the cured particle arrangement.
  vec2 across = normalize(vec2(1.0, 0.35 + uVariant * 0.8));
  vec2 along = vec2(-across.y, across.x);
  float coordinate = dot(uv - vec2(0.5), across);
  float shift = dot(halfLight.xy, across) * 0.95;
  float width = (0.065 + uVariant * 0.038) / sqrt(scale);
  float distance = coordinate - shift;
  // GLSL pow is undefined for negative bases even with an integer exponent.
  // Explicit even powers keep both sides of a shifted beam and rotated nails
  // symmetric on Skia as well as Impeller.
  float beamDistance = distance / width;
  float haloDistance = distance / (width * 2.8);
  float lengthDistance = dot(uv - vec2(0.5), along) / 0.68;
  float beam = exp(-beamDistance * beamDistance);
  float halo = exp(-haloDistance * haloDistance);
  float lengthSquare = lengthDistance * lengthDistance;
  float lengthFade = 0.74 + 0.26 * exp(-lengthSquare * lengthSquare);
  float grain = hash(floor(uv * vec2(91.0, 137.0) * scale) + seed);
  float fibers = 0.76 + grain * 0.24;
  float angular = 0.67 + 0.33 * pow(max(dot(normal, halfLight), 0.0), 8.0);
  float finish = 0.63 + gloss * 0.37;
  float reflection = (halo * 0.13 + beam * fibers * 0.64) * lengthFade * angular * finish;
  color = mix(color, uAccent, clamp(reflection, 0.0, 0.80));
  vec2 flecks = flakeLayer(uv, vec2(69.0, 104.0) * scale, seed + 67.2, normal, halfLight, 0.91);
  return mix(color, mix(uAccent, vec3(1.0), 0.17), clamp(flecks.y * (0.05 + beam * 0.24) * finish, 0.0, 0.27));
}

// Velvet cat-eye uses a soft field of aligned particles. The lamp moves the
// reflected lobe across this field while the grain stays fixed to the polish.
vec3 velvetMaterial(vec3 color, vec2 uv, vec3 normal, vec3 halfLight, float gloss) {
  vec2 across = normalize(vec2(1.0, mix(-0.48, 0.62, uVariant)));
  vec2 along = vec2(-across.y, across.x);
  vec2 shifted = uv - vec2(0.5) - halfLight.xy * 0.72;
  vec2 lobe = vec2(dot(shifted, across) * 2.45, dot(shifted, along) * 1.5);
  float field = exp(-dot(lobe, lobe) * uPatternScale);
  float grain = hash(floor(uv * vec2(89.0, 126.0) * uPatternScale) + uVariant * 24.0);
  float facing = pow(max(dot(normal, halfLight), 0.0), 9.0);
  float reflection = field * (0.50 + facing * 0.16 + grain * 0.12);
  reflection *= 0.75 + 0.25 * gloss;
  return mix(color, uAccent, reflection);
}

float frenchTrim(vec2 uv) {
  float side = abs(uv.x - 0.5) * 2.0;
  float smile = 0.04 + mix(0.055, 0.08, uVariant) / uPatternScale + side * side * 0.13;
  float aa = clamp(0.85 / uSize.y, 0.005, 0.03);
  if (uPattern < 26.5) {
    return 1.0 - smoothstep(smile - aa, smile + aa, uv.y);
  }
  float width = 0.020 / uPatternScale;
  float distance = abs(uv.y - smile);
  if (uVariant > 0.55) {
    // A narrow gap separates the two metallic lines on the double-trim styles.
    distance = min(distance, abs(uv.y - smile - 0.058) * 1.25);
  }
  return 1.0 - smoothstep(max(width - aa, 0.0), width + aa, distance);
}

vec2 turn(vec2 p, float angle) {
  float c = cos(angle), s = sin(angle);
  return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

float stroke(vec2 p, vec2 a, vec2 b, float width) {
  vec2 axis = b - a;
  float t = clamp(dot(p - a, axis) / dot(axis, axis), 0.0, 1.0);
  float distance = length(p - a - axis * t);
  float aa = clamp(0.55 / uSize.x, 0.003, 0.010);
  return 1.0 - smoothstep(max(width - aa, 0.0), width + aa, distance);
}

float snowCrystal(vec2 p) {
  const float sector = 1.04719755;
  float angle = atan(p.y, p.x + 0.000001);
  angle = mod(angle + sector * 0.5, sector) - sector * 0.5;
  vec2 arm = length(p) * vec2(cos(angle), abs(sin(angle)));
  float shaft = stroke(arm, vec2(0.0), vec2(0.275, 0.0), 0.010);
  float barb = stroke(arm, vec2(0.130, 0.0), vec2(0.193, 0.066), 0.009);
  float tip = stroke(arm, vec2(0.201, 0.0), vec2(0.246, 0.044), 0.008);
  return max(shaft, max(barb, tip));
}

vec3 crystalGem(vec3 base, vec2 p, float size, float angle) {
  vec2 q = turn(p, angle) / size;
  float diamond = abs(q.x) * 0.88 + abs(q.y);
  float outline = 1.0 - smoothstep(0.85, 1.09, diamond);
  float center = 1.0 - smoothstep(0.49, 0.65, diamond);
  float lamp = 0.56 + 0.44 * cos(uLightDirection - angle);
  float facet = step(q.x * 0.55, q.y) * 0.24 + step(0.0, q.x + q.y) * 0.23;
  vec3 tint = mix(uAccent * 0.43, mix(uAccent, vec3(1.0), 0.68), 0.22 + facet + lamp * 0.18);
  tint = mix(tint, uAccent, center * 0.48);
  float glint = circle(p - vec2(-0.19, -0.22) * size, size * 0.25) * lamp;
  return mix(mix(base, tint, outline), vec3(1.0, 0.99, 0.96), glint * outline);
}

vec3 nailColor(vec2 uv, float trim) {
  vec3 color = uColor;
  float kind = uPattern;
  float scale = max(0.45, uPatternScale);
  vec2 seed = vec2(uVariant * 11.3, uVariant * 7.7);
  if (kind < 0.5) {
    return color;
  }
  if (kind < 1.5) {
    float edge = 0.19 + 0.12 * pow(abs(uv.x - 0.5) * 2.0, 2.0);
    color = mix(color, uAccent, 1.0 - smoothstep(edge - 0.012, edge + 0.012, uv.y));
    return color;
  }
  if (kind < 2.5) {
    color = mix(color, uAccent, smoothstep(0.15, 1.0, uv.y) * 0.78);
    return color;
  }
  if (kind < 3.5) {
    return color;
  }
  if (kind < 4.5) {
    float edge = smoothstep(0.1, 0.8, abs(uv.x - 0.5) * 1.8);
    color = mix(color, uAccent, (1.0 - edge) * 0.20);
    return color;
  }
  if (kind < 5.5) {
    float edge = 0.22 + (uv.x - 0.5) * (0.52 + uVariant * 0.22);
    color = mix(color, uAccent, 1.0 - smoothstep(edge - 0.012, edge + 0.012, uv.y));
    return color;
  }
  if (kind < 6.5) {
    float edge = 0.78 + 0.14 * pow(abs(uv.x - 0.5) * 2.0, 2.0);
    color = mix(color, uAccent, smoothstep(edge - 0.012, edge + 0.012, uv.y));
    return color;
  }
  if (kind < 7.5) {
    vec2 center = vec2(0.48 + 0.12 * sin(uVariant * 8.0), 0.48);
    vec2 d = (uv - center) * vec2(3.2, 2.6);
    color = mix(color, uAccent, exp(-dot(d, d) * scale) * 0.94);
    return color;
  }
  if (kind < 8.5) {
    return color * 0.62;
  }
  if (kind < 9.5) {
    float reflection = 0.45 + 0.42 * sin(uv.x * 11.0 + uv.y * 2.0 + uVariant * 4.0);
    reflection += 0.16 * sin(uv.x * 25.0 - 0.7);
    color = mix(color * 0.36, uAccent, clamp(reflection, 0.0, 1.0));
    color += exp(-pow((uv.x - 0.36) / 0.075, 2.0)) * 0.23;
    return color;
  }
  if (kind < 10.5) {
    float nacre = 0.5 + 0.5 * sin(uv.x * 8.0 + uv.y * 5.0 + uVariant * 6.0);
    color = mix(color, uAccent, nacre * 0.52);
    color += vec3(0.08, 0.065, 0.085) * pow(nacre, 4.0);
    return color;
  }
  if (kind < 11.5) {
    vec2 p = uv * vec2(3.0, 5.0) * scale + seed;
    float veins = abs(sin(p.x * 2.7 + p.y * 1.3 + cloud(p) * 8.0));
    color = mix(color, uAccent, 1.0 - smoothstep(0.05, 0.24, veins));
    color = mix(color, uAccent, cloud(p * 1.4) * 0.17);
    return color;
  }
  if (kind < 12.5) {
    vec2 grid = uv * vec2(2.1, 3.2) * scale;
    vec2 cell = floor(grid), p = fract(grid) - 0.5;
    p += (vec2(hash(cell + seed), hash(cell + seed + 4.0)) - 0.5) * 0.16;
    color = mix(color, uAccent, flower(p, 0.36));
    color = mix(color, mix(uColor, vec3(1.0, 0.83, 0.43), 0.72), circle(p, 0.07));
    return color;
  }
  if (kind < 13.5) {
    vec2 p = vec2(uv.x - 0.5 + sin(uv.y * 5.0) * 0.07, uv.y);
    float foliage = 1.0 - smoothstep(0.01, 0.025, abs(p.x));
    for (int i = 0; i < 5; i++) {
      float y = 0.16 + float(i) * 0.16;
      float side = mod(float(i), 2.0) * 2.0 - 1.0;
      vec2 leaf = p - vec2(side * 0.12, y);
      vec2 rotated = vec2(leaf.x * 0.78 + leaf.y * side * 0.63, -leaf.x * side * 0.63 + leaf.y * 0.78);
      foliage = max(foliage, ellipse(rotated, vec2(0.17, 0.055)));
    }
    color = mix(color, uAccent, foliage);
    return color;
  }
  if (kind < 14.5) {
    float stripe = fract((uv.x * 4.0 + uv.y * (uVariant * 2.0 - 1.0)) * scale);
    color = mix(color, uAccent, 1.0 - smoothstep(0.14, 0.20, stripe));
    return color;
  }
  if (kind < 15.5) {
    vec2 cell = floor(uv * vec2(4.0, 6.0) * scale);
    color = mix(color, uAccent, mod(cell.x + cell.y, 2.0));
    return color;
  }
  if (kind < 16.5) {
    vec2 grid = uv * vec2(3.5, 5.0) * scale;
    grid.x += mod(floor(grid.y), 2.0) * 0.5;
    color = mix(color, uAccent, circle(fract(grid) - 0.5, 0.16 + uVariant * 0.07));
    return color;
  }
  if (kind < 17.5) {
    vec2 grid = uv * vec2(2.2, 3.2) * scale;
    grid.x += mod(floor(grid.y), 2.0) * 0.5;
    color = mix(color, uAccent, heart(fract(grid) - 0.5));
    return color;
  }
  if (kind < 18.5) {
    vec2 grid = uv * vec2(2.2, 3.4) * scale;
    grid.x += mod(floor(grid.y), 2.0) * 0.5;
    color = mix(color, uAccent, star(fract(grid) - 0.5));
    return color;
  }
  if (kind < 19.5) {
    vec2 p = fract(uv * vec2(1.7, 2.6) * scale + vec2(0.15, 0.1)) - 0.5;
    float wing = (1.0 - smoothstep(0.32, 0.35, abs(p.x))) * (1.0 - smoothstep(abs(p.x) * 0.65, abs(p.x) * 0.65 + 0.025, abs(p.y)));
    float knot = ellipse(p, vec2(0.065, 0.085));
    vec2 t = p - vec2(0.0, 0.13);
    float tails = (1.0 - smoothstep(0.06, 0.085, abs(abs(t.x) - t.y * 0.45))) * step(0.0, t.y) * (1.0 - smoothstep(0.15, 0.19, t.y));
    color = mix(color, uAccent, max(max(wing, knot), tails));
    return color;
  }
  if (kind < 20.5) {
    vec2 grid = uv * vec2(3.3, 5.0) * scale;
    vec2 cell = floor(grid), p = fract(grid) - 0.5;
    p -= (vec2(hash(cell + seed), hash(cell + seed + 8.0)) - 0.5) * 0.24;
    float radius = length(p * vec2(1.0, 1.2)) + sin(atan(p.y, p.x) * 3.0) * 0.04;
    float ring = smoothstep(0.15, 0.19, radius) * (1.0 - smoothstep(0.29, 0.34, radius));
    ring *= smoothstep(-0.25, 0.05, p.x + p.y + hash(cell) * 0.28);
    color = mix(color, uAccent, ring);
    return color;
  }
  if (kind < 21.5) {
    float wave = uv.x * 20.0 * scale + sin(uv.y * 12.0 + uVariant * 7.0) * 2.7;
    wave += sin(uv.y * 26.0 + uv.x * 8.0) * 0.65;
    color = mix(color, uAccent, smoothstep(-0.12, 0.12, sin(wave)));
    return color;
  }
  if (kind < 22.5) {
    float blobs = cloud(uv * vec2(5.0, 7.0) * scale + seed);
    color = mix(color, uAccent, smoothstep(0.48, 0.53, blobs));
    return color;
  }
  if (kind < 23.5) {
    vec2 p = uv * vec2(4.2, 5.7) * scale + seed;
    color = mix(uColor, uAccent, smoothstep(0.30, 0.66, cloud(p)));
    color = mix(color, vec3(0.18, 0.07, 0.025), smoothstep(0.64, 0.78, cloud(p * 1.3)) * 0.8);
    return color;
  }
  if (kind < 24.5) {
    vec2 p = uv * vec2(3.0, 4.8) * scale + seed;
    float vein = abs(sin(p.x * 2.8 + p.y + cloud(p) * 7.4));
    color = mix(color, uAccent, 1.0 - smoothstep(0.025, 0.12, vein));
    color += (1.0 - smoothstep(0.01, 0.035, vein)) * 0.15;
    color = mix(color, uAccent, cloud(p) * 0.075);
    return color;
  }
  if (kind < 25.5) {
    return color * 0.79;
  }
  if (kind < 26.5) {
    return mix(color, uAccent, trim);
  }
  if (kind < 27.5) {
    float sheen = 0.5 + 0.5 * sin(uv.x * 10.0 - cos(uLightDirection) * 1.6 + 0.9);
    vec3 metal = mix(uAccent * 0.57, mix(uAccent, vec3(1.0), 0.35), sheen);
    return mix(color, metal, trim);
  }
  if (kind < 28.5) {
    // Soft honey-colored borders surround denser pools in the amber layer.
    vec2 p = uv * vec2(4.2, 5.6) * scale + seed;
    vec2 drift = vec2(cloud(p * 0.85 + 13.7), cloud(p * 0.77 + 31.2));
    float resin = cloud(p + drift * 1.35);
    float shadow = cloud(p * 1.53 + 4.4);
    color = mix(color * 0.78, mix(color, vec3(1.0, 0.67, 0.33), 0.34), smoothstep(0.23, 0.58, resin));
    color = mix(color, uAccent, smoothstep(0.49, 0.68, resin) * 0.78);
    float pools = smoothstep(0.61, 0.77, resin + (shadow - 0.5) * 0.27);
    return mix(color, uAccent * 0.47, pools * 0.88);
  }
  if (kind < 29.5) {
    float angle = uVariant > 0.3 && uVariant < 0.7 ? 0.27 : -0.035;
    float c = cos(angle), s = sin(angle);
    vec2 p = uv - 0.5;
    vec2 grid = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    grid = grid * vec2(2.5, 3.8) * scale + vec2(0.19, 0.34);
    vec2 line = abs(fract(grid) - 0.5);
    vec2 wide = 1.0 - smoothstep(vec2(0.15), vec2(0.19), line);
    vec2 fine = 1.0 - smoothstep(vec2(0.012), vec2(0.049), abs(line - 0.31));
    float thread = 0.72 + 0.28 * sin((grid.x + grid.y) * 107.0);
    color = mix(color, color * 0.60, (wide.x + wide.y) * 0.31);
    color = mix(color, uAccent, (fine.x + fine.y) * 0.33 * thread);
    return mix(color, uAccent, wide.x * wide.y * 0.12 * thread);
  }
  if (kind < 30.5) {
    // The varying marks taper and stagger along the base, like a fawn coat.
    vec2 grid = uv * vec2(3.1, 4.6) * scale + vec2(0.1, 0.16);
    grid.x += mod(floor(grid.y), 2.0) * 0.5;
    vec2 cell = floor(grid);
    vec2 p = fract(grid) - 0.5;
    p -= (vec2(hash(cell + seed), hash(cell + seed + 2.4)) - 0.5) * 0.34;
    p.x += p.y * (hash(cell + seed + 8.7) - 0.5) * 0.65;
    float size = mix(0.115, 0.24, hash(cell + seed + 6.5));
    float shape = length(p / vec2(size, size * 0.70));
    shape += sin(atan(p.y, p.x) * 3.0 + uVariant * 9.0) * 0.10;
    float spots = (1.0 - smoothstep(0.79, 1.14, shape)) * step(0.13, hash(cell + seed + 19.2));
    color = mix(color * 0.81, mix(color, uAccent, 0.18), smoothstep(0.06, 1.0, uv.y));
    return mix(color, uAccent, spots * 0.93);
  }
  if (kind < 31.5) {
    vec2 p = (uv - vec2(0.43 + uVariant * 0.12, 0.42)) * vec2(1.0, 1.38) * scale;
    float large = snowCrystal(turn(p, uVariant * 0.8));
    vec2 small = (uv - vec2(0.73 - uVariant * 0.33, 0.76)) * vec2(1.0, 1.38) * scale * 2.1;
    float flakes = max(large, snowCrystal(turn(small, -0.35)) * 0.76);
    flakes = max(flakes, circle(uv - vec2(0.24, 0.64), 0.020) * 0.55);
    flakes = max(flakes, circle(uv - vec2(0.72, 0.24), 0.016) * 0.62);
    return mix(color, uAccent, flakes);
  }
  if (kind < 32.5) {
    vec2 p = turn((uv - vec2(0.50, 0.40)) * vec2(1.0, 1.4) * scale, (uVariant - 0.5) * 0.47);
    float band = 1.0 - smoothstep(0.028, 0.041, abs(p.x));
    band = max(band, (1.0 - smoothstep(0.026, 0.037, abs(p.y))) * 0.84);
    vec2 loop = turn(vec2(abs(p.x), p.y) - vec2(0.145, -0.046), 0.42);
    float loopEdge = abs(length(loop / vec2(0.126, 0.061)) - 1.0);
    float ribbon = 1.0 - smoothstep(0.08, 0.26, loopEdge);
    vec2 tail = vec2(abs(p.x), p.y);
    ribbon = max(ribbon, stroke(tail, vec2(0.03, 0.025), vec2(0.11, 0.12), 0.020));
    ribbon = max(ribbon, stroke(tail, vec2(0.11, 0.12), vec2(0.18, 0.18), 0.017));
    ribbon = max(ribbon, ellipse(p, vec2(0.049, 0.038)));
    color = mix(color, mix(uAccent, color, 0.29), band * 0.79);
    return mix(color, mix(uAccent, vec3(1.0, 0.95, 0.86), 0.18), ribbon);
  }
  if (kind < 33.5) {
    vec2 p = turn((uv - vec2(0.50, 0.49)) * vec2(1.0, 1.36) * scale, (uVariant - 0.5) * 0.54);
    float leaves = ellipse(turn(p - vec2(-0.12, 0.055), 0.34), vec2(0.143, 0.050));
    leaves = max(leaves, ellipse(turn(p - vec2(0.13, 0.075), 0.66), vec2(0.155, 0.048)));
    leaves = max(leaves, ellipse(turn(p - vec2(0.13, -0.153), 0.88), vec2(0.145, 0.042)));
    float stem = stroke(p, vec2(-0.20, 0.22), vec2(0.19, -0.225), 0.011);
    color = mix(color, uAccent, max(stem * 0.76, leaves * 0.96));
    float berries = circle(p - vec2(-0.017, -0.032), 0.047);
    berries = max(berries, circle(p - vec2(-0.083, -0.095), 0.041));
    berries = max(berries, circle(p - vec2(0.002, -0.126), 0.041));
    color = mix(color, vec3(0.72, 0.22, 0.26), berries);
    return mix(color, vec3(1.0, 0.76, 0.69), circle(p - vec2(-0.032, -0.044), 0.013) * 0.72);
  }
  if (kind < 34.5) {
    vec2 p = turn((uv - vec2(0.52, 0.43)) * vec2(1.0, 1.34) * scale, (uVariant - 0.5) * 0.72);
    float stem = stroke(p, vec2(0.105, 0.0), vec2(0.105, 0.38), 0.049);
    float hook = abs(length(p - vec2(-0.051, 0.0)) - 0.156);
    float top = (1.0 - smoothstep(0.043, 0.056, hook)) * (1.0 - smoothstep(0.0, 0.012, p.y));
    float shortEnd = stroke(p, vec2(-0.207, 0.0), vec2(-0.207, 0.056), 0.049);
    float stripes = smoothstep(-0.21, 0.21, sin((p.y + p.x * 0.80) * 53.0 + 1.0));
    vec3 candy = mix(color * 0.60, uAccent, stripes);
    return mix(color, candy, max(stem, max(top, shortEnd)));
  }
  if (kind < 35.5) {
    vec2 p = uv * vec2(3.7, 4.4) * scale + seed;
    float fold = cloud(p + vec2(cloud(p * 0.65 + 11.0), 0.0) * 1.6);
    float milk = smoothstep(0.35, 0.69, fold);
    float vein = cloud(p * 1.9 + 12.0);
    float feather = smoothstep(0.51, 0.66, vein) * smoothstep(0.41, 0.70, fold);
    color = mix(color * 0.78, mix(color, uAccent, 0.68), milk);
    return mix(color, uAccent, feather * 0.48);
  }
  if (kind < 36.5) {
    // Layer two slopes with translucent, broken brush edges and a mist gap.
    float x = uv.x;
    float farX = (x - 0.32 - uVariant * 0.23) * 3.6;
    float nearX = (x - 0.77 + uVariant * 0.47) * 3.1;
    float farRidge = 0.60 - 0.26 * exp(-farX * farX);
    farRidge += (noise(vec2(x * 12.0 * scale, seed.x)) - 0.5) * 0.12;
    float nearRidge = 0.93 - 0.25 * exp(-nearX * nearX);
    nearRidge += (noise(vec2(x * 10.0 * scale + 23.0, seed.y)) - 0.5) * 0.15;
    float farInk = smoothstep(farRidge - 0.018, farRidge + 0.04, uv.y);
    farInk *= 1.0 - smoothstep(farRidge + 0.08, farRidge + 0.31, uv.y);
    float nearInk = smoothstep(nearRidge - 0.015, nearRidge + 0.044, uv.y);
    float wash = cloud(uv * vec2(7.2, 6.7) + seed);
    color = mix(color, uAccent, farInk * (0.26 + wash * 0.35));
    color = mix(color, uAccent, nearInk * (0.43 + wash * 0.45));
    if (uVariant > 0.65) {
      color = mix(color, vec3(0.72, 0.31, 0.27), circle((uv - vec2(0.27, 0.24)) * vec2(1.0, 1.35), 0.049) * 0.72);
    }
    return color;
  }
  if (kind < 37.5) {
    vec2 p = turn((uv - vec2(0.49, 0.49)) * vec2(1.0, 1.39) * scale, (uVariant - 0.5) * 0.73);
    vec2 a = vec2(-0.19, 0.33), b = vec2(0.01, 0.10), c = vec2(0.14, -0.12);
    float branch = stroke(p, a, b, 0.016);
    branch = max(branch, stroke(p, b, c, 0.013));
    branch = max(branch, stroke(p, c, vec2(0.23, -0.31), 0.010));
    branch = max(branch, stroke(p, b, vec2(-0.16, -0.095), 0.011));
    branch = max(branch, stroke(p, c, vec2(0.31, -0.02), 0.009));
    vec3 ink = mix(color, uAccent, 0.76);
    color = mix(color, ink, branch);
    float petals = flower(p - vec2(-0.16, -0.095), 0.111);
    petals = max(petals, flower(p - vec2(0.23, -0.31), 0.087));
    petals = max(petals, flower(p - vec2(0.29, -0.035), 0.071));
    if (uVariant < 0.55) {
      petals = max(petals, ellipse(turn(p - vec2(-0.11, 0.12), -0.27), vec2(0.099, 0.028)));
      petals = max(petals, ellipse(turn(p - vec2(0.16, 0.096), -0.30), vec2(0.102, 0.029)));
    } else {
      petals = max(petals, flower(p - vec2(0.10, 0.028), 0.078));
    }
    color = mix(color, uAccent, petals * 0.94);
    float pollen = max(circle(p - vec2(-0.16, -0.095), 0.018), circle(p - vec2(0.23, -0.31), 0.014));
    return mix(color, vec3(0.98, 0.83, 0.61), pollen * 0.83);
  }
  if (kind < 38.5) {
    float sweep = uv.x - 0.48 - cos(uLightDirection) * 0.17;
    float veil = exp(-sweep * sweep * 9.1);
    float pearl = 0.5 + 0.5 * sin((uv.x * 8.5 + uv.y * 4.4) * scale + seed.x);
    float grain = hash(floor(uv * vec2(108.0, 146.0) * scale) + seed);
    float shimmer = smoothstep(0.77, 0.98, grain) * clamp(uSize.x / 70.0, 0.25, 1.0);
    vec3 iridescence = mix(uAccent, mix(uAccent, vec3(0.73, 0.85, 1.0), 0.37), pearl);
    color = mix(color, iridescence, 0.15 + veil * 0.37 + shimmer * 0.15);
    return color;
  }
  if (kind < 39.5) {
    vec2 grid = uv * vec2(5.2, 7.8) * scale;
    vec2 cell = floor(grid);
    float id = hash(cell + seed);
    vec2 center = (vec2(hash(cell + seed + 2.1), hash(cell + seed + 6.2)) - 0.5) * 0.34;
    float angle = hash(cell + seed + 13.7) * 6.2831853;
    vec2 q = turn(fract(grid) - 0.5 - center, angle);
    float polygon = max(abs(q.x) * 0.83 + q.y * 0.35, abs(q.y) + q.x * 0.34);
    float size = mix(0.11, 0.27, hash(cell + seed + 20.5));
    float foil = (1.0 - smoothstep(size - 0.035, size + 0.025, polygon)) * step(0.66, id);
    float facing = 0.5 + 0.5 * cos(angle - uLightDirection);
    float facets = step(q.y, q.x * 0.29) * 0.19 + step(q.x, -q.y * 0.63) * 0.21;
    vec3 metal = mix(uAccent * 0.42, mix(uAccent, vec3(1.0), 0.55), facing * 0.49 + facets);
    return mix(color, metal, foil * 0.92);
  }
  if (kind < 40.5) {
    vec2 p = (uv - vec2(0.5, 0.49)) * vec2(1.0, 1.36) * scale;
    float side = uVariant < 0.6 ? 1.0 : -1.0;
    color = crystalGem(color, p - vec2(-0.115 * side, -0.09), 0.104, -0.21);
    color = crystalGem(color, p - vec2(0.124 * side, 0.060), 0.071, 0.43);
    color = crystalGem(color, p - vec2(-0.044 * side, 0.224), 0.050, -0.34);
    return color;
  }
  return color;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 uv = p / uSize;
  vec2 surfaceUv = uv;
  if (uHasDesign > 0.5 && uHasWarp > 0.5) {
    surfaceUv = texture(uWarp, uv).rg;
  }
  float rawMask = texture(uMask, uv).a;
  // Tighten the transition while retaining a one-pixel soft boundary. This does
  // not grow the mask into surrounding skin; geometric expansion is separate.
  float mask = 1.0 - pow(1.0 - clamp(rawMask, 0.0, 1.0), 1.55);
  vec2 local = p - uSize * 0.5;
  float c = cos(uAngle), s = sin(uAngle);
  vec2 imagePos = uCenter + vec2(c * local.x - s * local.y, s * local.x + c * local.y);
  vec2 photoUv = imagePos / uPhotoSize;
  vec3 original = texture(uPhoto, photoUv).rgb;
  vec3 weights = vec3(0.2126, 0.7152, 0.0722);
  float luminance = dot(original, weights);
  vec2 sampleX = vec2(c, s) * min(3.0, uSize.x * 0.045) / uPhotoSize;
  vec2 sampleY = vec2(-s, c) * min(3.0, uSize.y * 0.03) / uPhotoSize;
  float softLight = luminance * 0.40;
  softLight += dot(texture(uPhoto, photoUv + sampleX).rgb, weights) * 0.15;
  softLight += dot(texture(uPhoto, photoUv - sampleX).rgb, weights) * 0.15;
  softLight += dot(texture(uPhoto, photoUv + sampleY).rgb, weights) * 0.15;
  softLight += dot(texture(uPhoto, photoUv - sampleY).rgb, weights) * 0.15;
  float side = abs(surfaceUv.x - 0.5) * 2.0;
  float shading = clamp(0.72 + softLight * 0.43 - 0.075 * side * side, 0.66, 1.12);
  float fineDetail = clamp(luminance - softLight, -0.12, 0.12) * 0.24;
  bool fineFrench = uHasDesign < 0.5 && uPattern > 25.5 && uPattern < 27.5;
  // Map narrow tips to the same fitted outline as custom designs, keeping
  // them visible on a photo whose nail outline fills less of the mask box.
  vec2 patternUv = fineFrench && uHasWarp > 0.5 ? texture(uWarp, uv).rg : uv;
  float trim = fineFrench ? frenchTrim(patternUv) : 0.0;
  vec3 baseColor = nailColor(patternUv, trim);
  float designCoverage = 1.0;
  if (uHasDesign > 0.5) {
    // Cylindrical surface mapping compresses artwork near the nail sides. It
    // remains a subtle 2D surface approximation rather than a floating sticker.
    // Warp already maps through the exact canonical canvas outline and the
    // slight cylindrical compression. Swatches use the original design UV.
    vec4 design = texture(uDesign, clamp(surfaceUv, vec2(0.0), vec2(1.0)));
    // The saved PNG already contains its chosen base coat and every layer.
    // Preserve that flattened alpha, including a semi-transparent base coat.
    designCoverage = design.a;
    baseColor = design.rgb / max(designCoverage, 0.0001);
  }
  float coatAmount = clamp(uCoatAmount, 0.0, 2.0);
  float extraCoat = max(coatAmount - 1.0, 0.0);
  // An opaque coat has no remaining transparency to fill. Additional
  // pigment gives the base a slightly denser color without widening it.
  if (uHasDesign < 0.5) {
    float density = extraCoat * smoothstep(0.86, 0.95, uCoverage) * 0.08;
    baseColor *= vec3(1.0) - density * (vec3(1.0) - baseColor);
  }
  vec3 color = baseColor * shading + vec3(fineDetail * (1.0 - 0.60 * extraCoat));
  float gloss = clamp(uGloss * uFinishGloss, 0.0, 1.0);
  // A shallow curved nail crown provides a directional studio-light preview.
  // The binding converts the photograph's lamp angle into this nail's axes,
  // so differently rotated fingers share one lamp rather than independent ones.
  // Geometry UV, rather than DIY artwork UV, keeps light attached to the nail.
  vec2 crown = (uv - vec2(0.5)) * vec2(1.60, 1.10);
  vec3 normal = normalize(vec3(crown, sqrt(max(0.08, 1.0 - dot(crown, crown)))));
  vec3 lamp = normalize(vec3(cos(uLightDirection) * 0.72, sin(uLightDirection) * 0.72, 1.5));
  vec3 halfLight = normalize(lamp + vec3(0.0, 0.0, 1.0));
  float highlight = pow(max(dot(normal, halfLight), 0.0), 38.0);
  float directionalShade = dot(normal, lamp) - normal.z;
  color *= 1.0 + directionalShade * 0.12 * gloss;
  bool glitter = uHasDesign < 0.5 && uPattern > 2.5 && uPattern < 3.5;
  bool magnetic = uHasDesign < 0.5 && uPattern > 7.5 && uPattern < 8.5;
  bool velvet = uHasDesign < 0.5 && uPattern > 24.5 && uPattern < 25.5;
  if (velvet) color = velvetMaterial(color, uv, normal, halfLight, gloss);
  if (glitter) color = glitterMaterial(color, uv, normal, halfLight, gloss);
  if (magnetic) color = magneticMaterial(color, uv, normal, halfLight, gloss);
  float photoSpecular = smoothstep(0.64, 0.98, softLight);
  float coat = glitter ? 0.34 : (magnetic || velvet ? 0.27 : 1.0);
  color = mix(color, vec3(1.0, 0.98, 0.96), (highlight * 0.23 + photoSpecular * 0.11) * gloss * coat);
  color = clamp(color, 0.0, 1.0);
  // Opaque polish fully covers the interior; jelly recipes retain translucency.
  float coverage = uCoverage >= 0.95 ? 1.0 : clamp(uCoverage, 0.0, 1.0);
  // The base may be sheer while the drawn tip or metal trim is solid.
  coverage = mix(coverage, 1.0, trim);
  // One is the original recipe. A second coat covers a share of the
  // remaining visible nail, while a thin coat lets more of it show through.
  // Apply this inside the mask so brush coverage cannot widen the nail.
  float polish = coverage * designCoverage;
  float layered = polish + extraCoat * polish * (1.0 - polish);
  float alpha = mask * layered * mix(0.32, 1.0, min(coatAmount, 1.0));
  fragColor = vec4(color * alpha, alpha);
}
