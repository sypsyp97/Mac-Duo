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

    /// Taps around the blur disc. Eight is where more stops showing.
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
        float blurAtFarEdge = uniforms.optics0.z;
        float brightness = uniforms.optics0.w;
        float sinSeparation = uniforms.optics0.x;
        float screenHeight = screenSize.y;

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

        // How far this point of the picture has floated off the glass: zero
        // along the hinge, widest at the far edge, and zero everywhere while
        // the picture still lies flat. The blur follows it, which is what
        // makes the effect read as depth rather than as an out-of-focus
        // screen. A single radius over the whole picture looks like someone
        // turned the focus ring.
        float lift = clamp(picturePoint.y / screenHeight, 0.0, 1.0) * abs(sinSeparation);
        float blurRadius = blurAtFarEdge * lift;

        // A pixel's own footprint on the picture sets the floor, so the
        // receding half is filtered rather than aliased.
        float2 dpdx = dfdx(picturePoint);
        float2 dpdy = dfdy(picturePoint);
        float footprint = 0.5 * max(length(dpdx), length(dpdy));
        float radius = max(blurRadius, footprint);

        // The pyramid carries most of the width and the taps smooth what it
        // leaves behind: a mip level alone is blocky, and its transitions show
        // up as banding across a gradient this wide.
        float mipLevel = clamp(log2(max(radius * pixelScale, 1.0)), 0.0, maxLevel);

        float3 gathered = float3(0.0);
        float weightSum = 0.0;
        for (int i = 0; i < kMaxTaps; ++i) {
            // Golden angle spiral: even coverage of the disc at any tap count,
            // and no axis for the eye to latch onto.
            float t = (float(i) + 0.5) / float(kMaxTaps);
            float angle = float(i) * 2.399963;
            float2 offset = float2(cos(angle), sin(angle)) * sqrt(t) * radius;
            float weight = 1.0 - 0.6 * t;
            weightSum += weight;
            float2 unit = (picturePoint + offset - paddedOrigin) / paddedSize;
            // Outside the picture and its margin is black, which is what the
            // margin is there to blend into.
            if (unit.x < 0.0 || unit.x > 1.0 || unit.y < 0.0 || unit.y > 1.0) { continue; }
            gathered += picture.sample(linearSampler, float2(unit.x, 1.0 - unit.y), level(mipLevel)).rgb * weight;
        }
        float3 colour = gathered / max(weightSum, 1e-4);

        // The sample is linear light, so the brightness multiplies it directly.
        colour *= brightness;
        return float4(colour, 1.0);
    }
    """
}
