#version 400

precision highp float;
precision highp int;

#define gl_FragColor isf_FragColor
out vec4 gl_FragColor;
in vec2		isf_FragNormCoord;
in vec2		isf_FragCoord;
uniform sampler2D		lineState;
layout (std140) uniform VVISF_UNIFORMS	{
	int		PASSINDEX;
	float		TIME;
	vec2		RENDERSIZE;
	vec4		DATE;
	float		TIMEDELTA;
	int		FRAMEINDEX;
	vec2		PADDING_INFO;
	vec4		_lineState_imgRect;
	vec2		_lineState_imgSize;
	bool		_lineState_flip;
	int		_lineState_padding;
	float		Items;
	float		Growth;
	bool		Clear;
	float		Speed;
	float		Opacity;
	float		Width;
};

vec4 VVSAMPLER_2DBYPIXEL(sampler2D inSampler, vec4 inSamplerImgRect, vec2 inSamplerImgSize, bool inSamplerFlip, vec2 inLoc)	{
	return (inSamplerFlip)
		? texture		(inSampler,vec2(((inLoc.x/inSamplerImgSize.x*inSamplerImgRect.z)+inSamplerImgRect.x), (inSamplerImgRect.w-(inLoc.y/inSamplerImgSize.y*inSamplerImgRect.w)+inSamplerImgRect.y)))
		: texture		(inSampler,vec2(((inLoc.x/inSamplerImgSize.x*inSamplerImgRect.z)+inSamplerImgRect.x), ((inLoc.y/inSamplerImgSize.y*inSamplerImgRect.w)+inSamplerImgRect.y)));
}
vec4 VVSAMPLER_2DBYNORM(sampler2D inSampler, vec4 inSamplerImgRect, vec2 inSamplerImgSize, bool inSamplerFlip, vec2 normLoc)	{
	vec4		returnMe = VVSAMPLER_2DBYPIXEL(		inSampler,inSamplerImgRect,inSamplerImgSize,inSamplerFlip,vec2(normLoc.x*inSamplerImgSize.x, normLoc.y*inSamplerImgSize.y));
	return returnMe;
}
