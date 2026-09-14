import Foundation

/// The whole effect in one fragment shader.
///
/// Each screen pixel maps back into the picture through the inverse
/// perspective. What it gathers there is a real footprint rather than one
/// isotropic tap: the Jacobian of that mapping gives the ellipse a pixel
/// covers on the picture, the circle of confusion widens it, and the samples
/// run along the ellipse's long axis. One tap at a scalar mip level reads as
/// smeared under strong foreshortening, because the receding half wants a long
/// thin footprint and a pyramid can only offer a square one.
///
/// The texture already holds the picture on black, so the two blur together
/// and the picture edge needs no special handling.
public enum DepthShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct Uniforms {
        float4 column0;          // screen-to-picture matrix, column 0 in xyz
        float4 column1;
        float4 column2;
        float4 screenAndOrigin;  // screen size, padded origin in picture points
        float4 paddedAndScale;   // padded size, pixel scale, max mip level
        float4 optics0;          // sin and cos of the separation, eye along and depth
        float4 optics1;          // half width, pupil radius in points, unused, unused
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

        float sinSep = uniforms.optics0.x;
        float cosSep = uniforms.optics0.y;
        float along = uniforms.optics0.z;
        float depth = uniforms.optics0.w;
        float halfWidth = uniforms.optics1.x;
        float pupilRadius = uniforms.optics1.y;

        // Fragment coordinates are pixels with y down; the geometry is points
        // with y up.
        float2 screenPoint = float2(position.x / pixelScale,
                                    screenSize.y - position.y / pixelScale);

        float3x3 screenToPicture = float3x3(uniforms.column0.xyz,
                                            uniforms.column1.xyz,
                                            uniforms.column2.xyz);
        float3 mapped = screenToPicture * float3(screenPoint, 1.0);
        float pictureDistance = depth * cosSep + along * sinSep;
        // Only forward rays from the front of both surfaces are visible.
        if (depth <= 1e-6 || pictureDistance <= 1e-6 || mapped.z <= 1e-6) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 picturePoint = mapped.xy / mapped.z;

        // P = E + rayFraction * (G - E): focus and object distances must
        // follow the same ray. The CoC is in glass points, not picture points.
        float rayFraction = pictureDistance / mapped.z;
        float circleOfConfusion = pupilRadius * abs(1.0 - 1.0 / rayFraction);

        // Map the pixel footprint and the defocus disc through the Jacobian.
        // Oblique incidence stretches the pupil disc on the glass; dpdy has
        // the opposite sign to the glass y axis because fragments run down.
        float2 dpdx = dfdx(picturePoint);
        float2 dpdy = dfdy(picturePoint);
        float2 obliquity = (screenPoint - float2(halfWidth, along)) / depth;
        float2 tilted = dpdx * obliquity.x - dpdy * obliquity.y;
        float blurSquared = pow(circleOfConfusion * pixelScale, 2.0);
        float footprint = 0.25 + blurSquared;
        float a = footprint * (dpdx.x * dpdx.x + dpdy.x * dpdy.x)
                    + blurSquared * tilted.x * tilted.x;
        float b = footprint * (dpdx.x * dpdx.y + dpdy.x * dpdy.y)
                    + blurSquared * tilted.x * tilted.y;
        float c = footprint * (dpdx.y * dpdx.y + dpdy.y * dpdy.y)
                    + blurSquared * tilted.y * tilted.y;
        // Eigenvectors of J J^T, not just the lengths of its columns: shear
        // can make both columns long while the minor axis stays narrow.
        float discriminant = length(float2(a - c, 2.0 * b));
        float majorSquared = max(0.5 * (a + c + discriminant), 1e-8);
        float minorSquared = max((a * c - b * b) / majorSquared, 1e-8);
        float angle = 0.5 * atan2(2.0 * b, a - c);
        float2 majorDirection = float2(cos(angle), sin(angle));
        float majorRadius = sqrt(majorSquared);
        float minorRadius = sqrt(minorSquared);

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

        // A stationary emissive picture viewed by a stationary eye keeps its
        // radiance. Rotating the glass changes projection, not emitted light.
        return float4(colour, 1.0);
    }
    """
}
