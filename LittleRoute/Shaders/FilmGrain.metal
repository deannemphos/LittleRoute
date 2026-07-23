//
//  FilmGrain.metal
//  LittleRoute
//
//  Animated film grain color effect used on the Y2K background.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Cheap hash-based pseudo-random noise, seeded by pixel position + time
static float grainNoise(float2 p, float time) {
    float3 seed = float3(p, fract(time));
    return fract(sin(dot(seed, float3(12.9898, 78.233, 45.164))) * 43758.5453);
}

[[ stitchable ]] half4 filmGrain(float2 position, half4 color, float time, float intensity) {
    float noise = grainNoise(floor(position), time);

    // Center around 0 so grain darkens and lightens equally
    float grain = (noise - 0.5) * intensity;

    half3 result = clamp(color.rgb + half3(grain), 0.0h, 1.0h);
    return half4(result, color.a);
}
