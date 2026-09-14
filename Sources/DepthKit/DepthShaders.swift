import Foundation

/// The whole effect in one fragment shader.
///
/// Each screen pixel maps back through the exact glass-to-picture homography,
/// so a picture frozen in the room stays put no matter where the lid is. What
/// the pixel gathers there is a real footprint rather than one isotropic tap:
/// the Jacobian of that mapping gives the ellipse the pixel covers on the
/// picture, the blur widens it, and the samples run along the ellipse's long
/// axis. One tap at a scalar mip level reads as smeared under strong
/// foreshortening, because the receding half wants a long thin footprint and a
/// pyramid can only offer a square one.
///
/// The blur and the dimming arrive already solved, as a radius and a
/// brightness, because they are not optical: the picture and the eye are both
/// fixed, so nothing ever leaves the focal plane. They follow how far the
/// panel has turned, which is what the effect this imitates does.
///
/// The texture holds the picture on black, so the two blur together and the
/// picture edge needs no special handling.
public enum DepthShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct Uniforms {
        float4 column0;          // glass-to-picture matrix, column 0 in xyz
        float4 column1;
        float4 column2;
        float4 screenAndOrigin;  // screen size, padded origin in picture points
        float4 paddedAndScale;   // padded size, pixel scale, max mip level
        float4 optics0;          // sin and cos of the separation, blur radius, brightness
        float4 optics1;          // eye distance, travel, unused, unused
    };

    /// Longest run of taps across a footprint. Eight is where the cost stops
    /// buying visible sharpness on the receding half.
    constant int kMaxTaps = 8;

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    fragment float4 depthFragment(float4 position [[position]],
                                   constant Uniforms &uniforms [[buffer(0)]],
                                   texture2d<float> picture [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

        float2 screenSize = uniforms.screenAndOrigin.xy;
        float2 paddedOrigin = uniforms.screenAndOrigin.zw;
        float2 paddedSize = uniforms.paddedAndScale.xy;
        float pixelScale = uniforms.paddedAndScale.z;
        float maxLevel = uniforms.paddedAndScale.w;
        float blurRadius = uniforms.optics0.z;
        float brightness = uniforms.optics0.w;

        // Fragment coordinates are pixels with y down; the geometry is points
        // with y up.
        float2 screenPoint = float2(position.x / pixelScale,
                                    screenSize.y - position.y / pixelScale);

        float3x3 glassToPicture = float3x3(uniforms.column0.xyz,
                                           uniforms.column1.xyz,
                                           uniforms.column2.xyz);
        float3 mapped = glassToPicture * float3(screenPoint, 1.0);
        if (abs(mapped.z) < 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 picturePoint = mapped.xy / mapped.z;

        // The ellipse one pixel covers on the picture, widened by the blur.
        float2 dpdx = dfdx(picturePoint);
        float2 dpdy = dfdy(picturePoint);
        float lengthX = length(dpdx);
        float lengthY = length(dpdy);
        float majorLength = max(lengthX, lengthY);
        float minorLength = min(lengthX, lengthY);
        float2 majorAxis = (lengthX >= lengthY) ? dpdx : dpdy;
        float2 majorDirection = majorLength > 1e-6 ? majorAxis / majorLength : float2(1.0, 0.0);

        float majorRadius = 0.5 * majorLength + blurRadius;
        float minorRadius = max(0.5 * minorLength + blurRadius, 1e-4);

        // One tap covers the narrow direction; the run of them covers the long
        // one, which is what a pyramid alone cannot do.
        int taps = int(ceil(clamp(majorRadius / minorRadius, 1.0, float(kMaxTaps))));
        float mipLevel = clamp(log2(max(minorRadius * 2.0 * pixelScale, 1.0)), 0.0, maxLevel);
        float span = majorRadius - minorRadius;

        float3 gathered = float3(0.0);
        float weightSum = 0.0;
        for (int i = 0; i < kMaxTaps; ++i) {
            if (i >= taps) { break; }
            float offset = (taps == 1) ? 0.0 : (float(i) / float(taps - 1)) * 2.0 - 1.0;
            float weight = 1.0 - 0.5 * offset * offset;
            weightSum += weight;
            float2 samplePoint = picturePoint + majorDirection * (offset * span);
            float2 unit = (samplePoint - paddedOrigin) / paddedSize;
            // Outside the picture and its margin is black, which is what the
            // margin is there to blend into.
            if (unit.x < 0.0 || unit.x > 1.0 || unit.y < 0.0 || unit.y > 1.0) { continue; }
            float2 texCoord = float2(unit.x, 1.0 - unit.y);
            gathered += picture.sample(linearSampler, texCoord, level(mipLevel)).rgb * weight;
        }
        float3 colour = gathered / max(weightSum, 1e-4);

        // The sample is linear light, so the brightness multiplies it directly.
        colour *= brightness;
        return float4(colour, 1.0);
    }
    """
}
