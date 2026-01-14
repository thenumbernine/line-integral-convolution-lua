#!/usr/bin/env luajit
local ffi = require 'ffi'
local bit = require 'bit'
local gl = require 'gl.setup' (... or 'OpenGL')
local matrix_ffi = require 'matrix.ffi'
local template = require 'template'
local glreport = require 'gl.report'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local GLPingPong = require 'gl.pingpong'
local glnumber = require 'gl.number'
local Image = require 'image'

local App = require 'imgui.appwithorbit'()
App.title = 'LIC'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.ortho = true
	self.view.orthoSize = .5
	self.view.pos:set(.5, .5, 10)

	self.stateSize = 1024
	self.state = GLPingPong{
		width = self.stateSize,
		height = self.stateSize,
		internalFormat = gl.GL_RGBA32F,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		-- no need for pingpong -- no state needed
		numBuffers = 1,
	}

	--self.noiseSize = 128
	self.noiseSize = 256
	--self.noiseSize = 512
	--self.noiseSize = 1024
	self.noise = GLPingPong{
		width = self.noiseSize,
		height = self.noiseSize,
		internalFormat = gl.GL_RGBA32F,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		-- set this to 1 for a static image
		numBuffers = 1,
	}
	local image = Image(self.noiseSize, self.noiseSize, 4, 'float')
	for i=1,#self.noise.hist do
		for i=0,self.noiseSize*self.noiseSize-1 do
			for j=0,3 do
				image.buffer[j+4*i] = math.random()^3
			end
		end
		self.noise.hist[i]
			:bind()
			:subimage{data = image.buffer}
			:unbind()
	end

	self.quadGeom = GLGeometry{
		mode = gl.GL_TRIANGLE_STRIP,
		vertexes = {
			data = {
				0, 0,
				1, 0,
				0, 1,
				1, 1,
			},
			dim = 2,
		},
	}

	self.updateSceneObj = GLSceneObject{
		program = {
			version = 'latest',
			precision = 'best',
			vertexCode = [[
in vec2 vertex;
out vec2 tc;
void main() {
	tc = vertex.xy;
	gl_Position = vec4(vertex * 2. - 1., 0., 1.);
}
]],
			fragmentCode = template([[
in vec2 tc;
uniform sampler2D noiseTex;

//https://registry.khronos.org/OpenGL-Refpages/gl4/html/smoothstep.xhtml 
float smoothstep_float(float edge0, float edge1, float x) {
	float t = clamp((x - edge0) / (edge1 - edge0), 0., 1.);
	return t * t * (3. - 2. * t);
}
vec3 smoothstep_float_float_vec3(float edge0, float edge1, vec3 x) {
	vec3 t = clamp((x - edge0) / (edge1 - edge0), 0., 1.);
	return vec3(
		t.x * t.x * (3. - 2. * t.x),
		t.y * t.y * (3. - 2. * t.y),
		t.z * t.z * (3. - 2. * t.z)
	);
}

#if 0	//rotation
vec2 field(vec2 x) {
	x -= vec2(.5, .5);
	return vec2(-x.y, x.x);
}
#elif 1	//dipole
float cube(float x) {
	return x * x * x;
}
vec2 EField(vec2 x) {
	return x / cube(length(x));
}
vec2 field(vec2 x) {
	x *= 2.; x -= 1.; x *= 2.;
	//one in the middle
	//return EField(x - vec2(.5, .5));	// one charge in the middle
	//n along a unit circle
	vec2 E = vec2(0,0);
<?
local n = 6
for i=0,n-1 do
	local q = (i % 2) * 2 - 1
	local theta = 2*math.pi*i/n
	local cx = math.cos(theta)
	local cy = math.sin(theta)
?>	E += <?=glnumber(q)?> * EField(x - vec2(<?=glnumber(cx)?>, <?=glnumber(cy)?>));
<?
end
?>	return E;
}
#else	//linear
vec2 field(vec2 x) {
	return vec2(.01, .005);
}
#endif

out vec4 fragColor;
uniform vec2 offset;
void main() {
	vec3 c = texture(noiseTex, tc + offset).rgb;

	<? for dir=-1,1,2 do ?>{
		vec2 r  = tc;
		for (int iter = 0; iter < <?=maxiter?>; ++iter) {
			float f = float(iter + 1) * <?=glnumber(1/(maxiter+1))?>;
			float k = smoothstep_float(1., 0., f);
			vec2 dr_ds = normalize(field(r));
			r += dr_ds * <?=ds * dir?>;
			c += texture(noiseTex, r + offset).rgb;
		}
	}<? end ?>

	c *= <?=glnumber(1/(2*maxiter+1))?>;

	//add some contract
	c = smoothstep_float_float_vec3(-.1, .8, c);

	fragColor = vec4(c, 1.);
}
]],			{
				glnumber = glnumber,
				ds = glnumber(1 / self.noiseSize),
				maxiter = 9,
			}),
			uniforms = {
				noiseTex = 0,
			},
		},
		geometry = self.quadGeom,
	}

	self.drawSceneObj = GLSceneObject{
		program = {
			version = 'latest',
			precision = 'best',
			vertexCode = [[
in vec2 vertex;
out vec2 tc;
uniform mat4 mvProjMat;
void main() {
	tc = vertex.xy;
	gl_Position = mvProjMat * vec4(vertex.xy, 0., 1.);
}
]],
			fragmentCode = [[
in vec2 tc;
uniform sampler2D stateTex;
out vec4 fragColor;
void main() {
	fragColor = vec4(texture(stateTex, tc).rgb, 1.);
}
]],
			uniforms = {
				stateTex = 0,
			},
		},
		geometry = self.quadGeom,
	}

	gl.glEnable(gl.GL_DEPTH_TEST)
	gl.glEnable(gl.GL_CULL_FACE)
end

function App:update()
	App.super.update(self)
	self.state:draw{
		viewport = {0, 0, self.stateSize, self.stateSize},
		callback = function()
			gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
			self.updateSceneObj.texs[1] = self.noise:prev()
			self.updateSceneObj.uniforms.offset = {math.random(), math.random()}
			self.updateSceneObj:draw()
		end,
	}

	self.state:swap()
	self.noise:swap()
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	self.drawSceneObj.texs[1] = self.state:prev()
	self.drawSceneObj.uniforms.mvProjMat = self.view.mvProjMat.ptr
	self.drawSceneObj:draw()

glreport'here'
end

return App():run()
