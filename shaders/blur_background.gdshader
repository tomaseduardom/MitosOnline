shader_type canvas_item;

uniform float blur_amount : hint_range(0.0, 5.0) = 2.0;
uniform float darken_amount : hint_range(0.0, 1.0) = 0.4;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec2 pixel_size = 1.0 / vec2(textureSize(SCREEN_TEXTURE, 0));
	vec4 color = vec4(0.0);

	// Box blur 9 samples
	float total_weight = 0.0;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			vec2 offset = vec2(float(x), float(y)) * pixel_size * blur_amount * 3.0;
			color += texture(SCREEN_TEXTURE, SCREEN_UV + offset);
			total_weight += 1.0;
		}
	}
	color /= total_weight;

	// Darken
	color.rgb *= (1.0 - darken_amount);

	COLOR = color;
}
