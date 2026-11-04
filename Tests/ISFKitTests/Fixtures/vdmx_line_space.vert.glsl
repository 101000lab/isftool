#version 400

precision highp float;
precision highp int;

in vec4		VERTEXDATA;
void isf_vertShaderInit();

out vec2		isf_FragNormCoord;
out vec2		isf_FragCoord;
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

void main(void)	{
	isf_vertShaderInit();
}

void isf_vertShaderInit(void)	{
	//	gl_Position should be equal to gl_ProjectionMatrix * gl_ModelViewMatrix * gl_Vertex
	mat4			projectionMatrix = mat4(2./RENDERSIZE.x, 0., 0., -1.,
		0., -2./RENDERSIZE.y, 0., 1.,
		0., 0., -1., 0.,
		0., 0., 0., 1.);
	gl_Position = VERTEXDATA * projectionMatrix;
	isf_FragNormCoord = vec2((gl_Position.x+1.0)/2.0, ((gl_Position.y+1.0)/2.0));
	isf_FragCoord = floor(isf_FragNormCoord * RENDERSIZE);
}
