#!/usr/bin/env luajit
local class = require 'ext.class'
local table = require 'ext.table'
local ffi = require 'ffi'
local bit = require 'bit'
local matrix_ffi = require 'matrix.ffi'
local template = require 'template'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLTex2D = require 'gl.tex2d'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLAttribute = require 'gl.attribute'
local GLVertexArray = require 'gl.vertexarray'
local GLProgram = require 'gl.program'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local GLPingPong = require 'gl.pingpong'
local clnumber = require 'cl.obj.number'
local Image = require 'image'

matrix_ffi.real = 'float'

require 'glapp.view'.useBuiltinMatrixMath = true

local App = require 'imguiapp.withorbit'()

App.title = 'LIC'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.ortho = true
	self.view.orthoSize = .5
	self.view.pos:set(.5, .5, 10)

	self.pingPongProjMat = matrix_ffi{4,4}:zeros():setOrtho(0, 1, 0, 1, 0, 1)

	self.stateSize = 1024
	self.state = GLPingPong{
		internalFormat = gl.GL_RGBA32F,
		width = self.stateSize,
		height = self.stateSize,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
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
		internalFormat = gl.GL_RGBA32F,
		width = self.noiseSize,
		height = self.noiseSize,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
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

	self.vtxBufferDim = 2
	local vtxs = {
		0, 0,
		1, 0,
		0, 1,
		1, 1,
	}
	self.vtxBufferCount = #vtxs / self.vtxBufferDim
	self.vtxBuffer = GLArrayBuffer{data = vtxs}:unbind()

	self.updateShader = GLProgram{
		vertexCode =
GLProgram.getVersionPragma()..'\n'
..[[
in vec2 vtx;
out vec2 tc;
uniform mat4 mvProjMat;
void main() {
	tc = vtx.xy;
	gl_Position = mvProjMat * vec4(vtx, 0., 1.);
}
]],
		fragmentCode = template(
GLProgram.getVersionPragma()..'\n'
..[[
in vec2 tc;
uniform sampler2D noiseTex;

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
?>	E += <?=clnumber(q)?> * EField(x - vec2(<?=clnumber(cx)?>, <?=clnumber(cy)?>));
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
void main() {
	vec3 c = texture(noiseTex, tc).rgb;

	<? for dir=-1,1,2 do ?>{
		vec2 r  = tc;
		for (int iter = 0; iter < <?=maxiter?>; ++iter) {
			float f = float(iter + 1) * <?=clnumber(1/(maxiter+1))?>;
			float k = smoothstep(1, 0, f);
			vec2 dr_ds = normalize(field(r));
			r += dr_ds * <?=ds * dir?>;
			c += texture(noiseTex, r).rgb;
		}
	}<? end ?>

	c *= <?=clnumber(1/(2*maxiter+1))?>;

	//add some contract
	c = smoothstep(-.1, .8, c);

	fragColor = vec4(c, 1.);
}
]],			{
				clnumber = clnumber,
				ds = clnumber(1 / self.noiseSize),
				maxiter = 9,
			}),

		uniforms = {
			noiseTex = 0,
		},
	}:useNone()

	self.quadGeom = GLGeometry{
		mode = gl.GL_TRIANGLE_STRIP,
		count = self.vtxBufferCount,
	}

	self.updateSceneObj = GLSceneObject{
		program = self.updateShader,
		geometry = self.quadGeom,
		attrs = {
			vtx = self.vtxBuffer,
		},
	}

	self.drawShader = GLProgram{
		vertexCode =
GLProgram.getVersionPragma()..'\n'
..[[
in vec2 vtx;
out vec2 tc;
uniform mat4 mvProjMat;
void main() {
	tc = vtx.xy;
	gl_Position = mvProjMat * vec4(vtx.xy, 0., 1.);
}
]],
		fragmentCode =
GLProgram.getVersionPragma()..'\n'
..[[
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
	}:useNone()

	self.drawSceneObj = GLSceneObject{
		program = self.drawShader,
		geometry = self.quadGeom,
		attrs = {
			vtx = self.vtxBuffer,
		},
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
			self.updateSceneObj.uniforms.mvProjMat = self.pingPongProjMat.ptr
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
