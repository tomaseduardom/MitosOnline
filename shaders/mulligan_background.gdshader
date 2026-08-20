shader_type canvas_item;

// Fondo atmosférico para la fase de Mulligan
// Efecto de profundidad con viñeta y partículas sutiles

uniform vec4 color_deep : source_color = vec4(0.02, 0.03, 0.06, 1.0);
uniform vec4 color_mid : source_color = vec4(0.05, 0.08, 0.15, 1.0);
uniform vec4 color_highlight : source_color = vec4(0.1, 0.15, 0.25, 1.0);
uniform float vignette_strength : hint_range(0.0, 2.0) = 0.8;
uniform float vignette_softness : hint_range(0.0, 1.0) = 0.4;
uniform float noise_intensity : hint_range(0.0, 0.5) = 0.08;
uniform float time_scale : hint_range(0.0, 2.0) = 0.3;
uniform float radial_gradient_power : hint_range(0.5, 3.0) = 1.5;

// Función de ruido
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec2 uv = UV;
	vec2 center = uv - 0.5;
	float time = TIME * time_scale;

	// Distancia al centro (para gradiente radial)
	float dist = length(center);

	// Gradiente radial con power para controlar la transición
	float radial = pow(dist * 2.0, radial_gradient_power);
	radial = clamp(radial, 0.0, 1.0);

	// Mezcla de colores base (centro claro, bordes oscuros)
	vec4 base_color = mix(color_highlight, color_mid, radial);
	base_color = mix(base_color, color_deep, pow(radial, 0.7));

	// Ruido animado sutil
	float n = fbm(uv * 5.0 + vec2(time * 0.1, time * 0.05));
	float n2 = fbm(uv * 3.0 - vec2(time * 0.08, time * 0.12));
	float noise_value = (n + n2) * 0.5;

	// Aplicar ruido
	base_color.rgb += (noise_value - 0.5) * noise_intensity;

	// Viñeta
	float vignette = 1.0 - pow(dist * vignette_strength, 2.0 - vignette_softness);
	vignette = clamp(vignette, 0.0, 1.0);
	base_color.rgb *= vignette;

	// Efecto de "luz central" sutil
	float glow = exp(-dist * 4.0) * 0.15;
	base_color.rgb += color_highlight.rgb * glow;

	// Partículas de polvo flotante (muy sutiles)
	float dust = noise(uv * 50.0 + vec2(time * 0.5, time * 0.3));
	dust = smoothstep(0.7, 0.9, dust) * 0.03;
	base_color.rgb += dust;

	COLOR = base_color;
}
