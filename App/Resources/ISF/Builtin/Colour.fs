/*{
    "DESCRIPTION": "Videoboy built-in grade: levels, gamma, shadows and highlights, contrast, brightness, saturation, applied in that order. Ported one-for-one from the native colour_fragment; the order is documented beside that shader and is not arbitrary.",
    "CREDIT": "Videoboy",
    "ISFVSN": "2",
    "CATEGORIES": ["Color Adjustment", "Videoboy"],
    "VIDEOBOY": { "IDENTITY_AT_DEFAULTS": true },
    "INPUTS": [
        { "NAME": "inputImage", "TYPE": "image" },
        { "NAME": "brightness", "LABEL": "bright", "TYPE": "float", "MIN": -1.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "53A" },
        { "NAME": "contrast", "LABEL": "contrast", "TYPE": "float", "MIN": 0.0, "MAX": 2.0, "DEFAULT": 1.0, "VIDEOBOY_CODE": "51A" },
        { "NAME": "saturation", "LABEL": "sat", "TYPE": "float", "MIN": 0.0, "MAX": 2.0, "DEFAULT": 1.0, "VIDEOBOY_CODE": "52A" },
        { "NAME": "shadow", "LABEL": "shadow", "TYPE": "float", "MIN": -1.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "54A" },
        { "NAME": "highlight", "LABEL": "highlt", "TYPE": "float", "MIN": -1.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "55A" },
        { "NAME": "blackLevel", "LABEL": "black", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "56A" },
        { "NAME": "whiteLevel", "LABEL": "white", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 1.0, "VIDEOBOY_CODE": "57A" },
        { "NAME": "gamma", "LABEL": "gamma", "TYPE": "float", "MIN": 0.1, "MAX": 4.0, "DEFAULT": 1.0, "VIDEOBOY_CODE": "58A" }
    ]
}*/

// Rec. 601 luma, the weighting an NTSC chain uses.
float lumaOf(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

void main() {
    vec3 c = IMG_THIS_PIXEL(inputImage).rgb;

    // 1. Levels. The span is floored so a white point at or below the black point
    //    cannot divide by zero or invert the picture.
    float span = max(whiteLevel - blackLevel, 0.001);
    c = clamp((c - blackLevel) / span, 0.0, 1.0);

    // 2. Gamma.
    c = pow(c, vec3(1.0 / max(gamma, 0.01)));

    // 3. Shadows and highlights, each weighted to its own end of the range.
    float luma = lumaOf(c);
    float shadowWeight = 1.0 - smoothstep(0.0, 0.5, luma);
    float highlightWeight = smoothstep(0.5, 1.0, luma);
    c += shadow * shadowWeight * 0.5;
    c += highlight * highlightWeight * 0.5;
    c = clamp(c, 0.0, 1.0);

    // 4. Contrast about mid grey, so more contrast does not also mean darker.
    c = (c - 0.5) * contrast + 0.5;

    // 5. Brightness.
    c += brightness;

    // 6. Saturation about luma, so brightness survives desaturation.
    float grey = lumaOf(clamp(c, 0.0, 1.0));
    c = mix(vec3(grey), c, saturation);

    // Clamped: this feeds an analog output where out-of-range is unencodable.
    gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
