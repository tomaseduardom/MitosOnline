shader_type canvas_item;

uniform vec2 panel_size = vec2(500.0, 300.0);
uniform float corner_radius : hint_range(0.0, 60.0) = 22.0;
uniform float vignette_amount : hint_range(0.0, 1.0) = 0.70;
uniform vec4 tint_color : source_color = vec4(0.01, 0.03, 0.04, 0.38);
uniform vec4 edge_shadow_color : source_color = vec4(0.01, 0.01, 0.02, 0.95);

float rounded_box(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void fragment() {
    vec2 pixel_pos = (UV - 0.5) * panel_size;
    float dist = rounded_box(pixel_pos, panel_size * 0.5, corner_radius);
    
    // Antialiased corner cut
    float alpha = 1.0 - smoothstep(-1.5, 0.5, dist);
    
    vec4 tex = texture(TEXTURE, UV);
    
    // Atmospheric tint
    tex.rgb = mix(tex.rgb, tint_color.rgb, tint_color.a);
    
    // Edge vignette & shadow for depth and contrast
    vec2 uv_dist = abs(UV - 0.5) * 2.0;
    float edge_factor = max(pow(uv_dist.x, 2.2), pow(uv_dist.y, 2.2));
    float vignette = clamp(edge_factor * vignette_amount, 0.0, 1.0);
    
    tex.rgb = mix(tex.rgb, edge_shadow_color.rgb, vignette);
    
    // Soft inner rim bevel
    float inner_border = smoothstep(-3.0, -0.5, dist) * (1.0 - smoothstep(-0.5, 0.5, dist));
    tex.rgb = mix(tex.rgb, vec3(0.12, 0.16, 0.18), inner_border * 0.35);
    
    tex.a *= alpha;
    COLOR = tex;
}

