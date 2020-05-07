#!/usr/bin/env luajit
local class = require 'ext.class'
local table = require 'ext.table'
local matrix_ffi = require 'matrix.ffi'
local bit = require 'bit'
local ffi = require 'ffi'
local template = require 'template'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLTex2D = require 'gl.tex2d'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLAttribute = require 'gl.attribute'
local GLProgram = require 'gl.program'
local GLPingPong = require 'gl.pingpong'
local clnumber = require 'cl.obj.number'
local Image = require 'image'
local ImGuiApp = require 'imguiapp'

matrix_ffi.real = 'float'


local App = require 'glapp.orbit'(ImGuiApp)

App.title = 'LIC'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.ortho = true 
	self.view.orthoSize = .5
	self.view.pos:set(.5, .5, 10)

	--self.size = 128
	--self.size = 256
	self.size = 512
	--self.size = 1024
	local image = Image(self.size, self.size, 4, 'float')
	for i=0,self.size*self.size-1 do
		--local l = math.floor(math.random(0,3)/3)
		for j=0,3 do
			image.buffer[j+4*i] = 1
		end
	end
	self.state = GLPingPong{
		internalFormat = gl.GL_RGBA32F,
		width = self.size,
		height = self.size,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
		data = image.buffer,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		-- no need for pingpong -- no state needed
		numBuffers = 1,
	}

	self.noise = GLPingPong{
		internalFormat = gl.GL_RGBA32F,
		width = self.size,
		height = self.size,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
		data = image.buffer,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
		-- set this to 1 for a static image
		numBuffers = 1,
	}
	for i=1,#self.noise.hist do
		for i=0,self.size*self.size-1 do
			local l = math.floor(math.random(0,3)/3)
			for j=0,3 do
				image.buffer[j+4*i] = l
			end
		end
		local tex = self.noise.hist[i]
		tex:bind()
		tex:subimage{data = image.buffer}
		tex:unbind()
	end

	self.vtxBufferDim = 2
	local vtxs = {
		0, 0,
		1, 0,
		0, 1,
		1, 1,
	}
	self.vtxBufferCount = #vtxs / self.vtxBufferDim
	self.vtxBuffer = GLArrayBuffer{
		size = self.vtxBufferDim * self.vtxBufferCount * ffi.sizeof'float',
		data = vtxs,
		usage = gl.GL_STATIC_DRAW,
	}
	self.vtxAttr = GLAttribute{
		buffer = self.vtxBuffer,
		size = self.vtxBufferDim,
		type = gl.GL_FLOAT,
	}


	self.updateShader = GLProgram{
		vertexCode = [[
#version 460
attribute vec2 vtx;
varying vec2 tc;
uniform mat4 modelViewProjectionMatrix;
void main() {
	tc = vtx.xy;
	gl_Position = modelViewProjectionMatrix * vec4(vtx, 0., 1.);
}
]],
		fragmentCode = template([[
#version 460
varying vec2 tc;
uniform sampler2D noiseTex;

#if 1	//rotation
vec2 field(vec2 x) {
	x -= vec2(.5, .5);
	return vec2(-x.y, x.x);
}
#else	//linear
vec2 field(vec2 x) {
	return vec2(.01, .005);
}
#endif

out vec4 fragColor;
void main() {
	float l = texture2D(noiseTex, tc).r;

	<? for dir=-1,1,2 do ?>{
		vec2 r  = tc;
		for (int iter = 0; iter < <?=maxiter?>; ++iter) {
			float f = float(iter + 1) * <?=clnumber(1/(maxiter+1))?>;
			float k = smoothstep(1, 0, f);
			vec2 dr_ds = normalize(field(r));
			r += dr_ds * <?=ds * dir?>;
			l += texture2D(noiseTex, r).r;
		}
	}<? end ?>

	l *= <?=clnumber(1/(2*maxiter+1))?>;
	
	fragColor = vec4(l,l,l, 1.);
}
]],			{
				clnumber = clnumber,
				ds = clnumber(1 / self.size),
				maxiter = 9,
			}),
		uniforms = {
			noiseTex = 0,
		},
	}
	

	self.drawShader = GLProgram{
		vertexCode = [[
#version 460
attribute vec2 vtx;
varying vec2 tc;
uniform mat4 modelViewProjectionMatrix;
void main() {
	tc = vtx.xy;
	gl_Position = modelViewProjectionMatrix * vec4(vtx.xy, 0., 1.);
}
]],
		fragmentCode = [[
#version 460
varying vec2 tc;
uniform sampler2D stateTex;
out vec4 fragColor;
void main() {
	float l = texture2D(stateTex, tc).r;
	fragColor = vec4(l, l, l, 1.);
}
]],
		uniforms = {
			stateTex = 0,
		},
	}

	self.modelViewMatrix = matrix_ffi.zeros(4,4)
	self.projectionMatrix = matrix_ffi.zeros(4,4)
	self.modelViewProjectionMatrix = matrix_ffi.zeros(4,4)


	gl.glEnable(gl.GL_DEPTH_TEST)
	gl.glEnable(gl.GL_CULL_FACE)
end

function App:update()
	App.super.update(self)

	self.state:draw{
		viewport = {0, 0, self.size, self.size},
		resetProjection = true,
		callback = function()
			gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
			
			gl.glGetFloatv(gl.GL_PROJECTION_MATRIX, self.projectionMatrix.ptr)
			self.updateShader:use()
			gl.glUniformMatrix4fv(self.updateShader.uniforms.modelViewProjectionMatrix.loc, 1, 0, self.projectionMatrix.ptr)	-- modelview is ident, so just use projection
			self.noise:prev():bind()
			
			self.updateShader:setAttr('vtx', self.vtxAttr)
			gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, self.vtxBufferCount)
			self.updateShader:unsetAttr'vtx'

			self.noise:prev():unbind()
			self.updateShader:useNone()
		end,
	}
	self.state:swap()
	self.noise:swap()
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	gl.glGetFloatv(gl.GL_MODELVIEW_MATRIX, self.modelViewMatrix.ptr)
	gl.glGetFloatv(gl.GL_PROJECTION_MATRIX, self.projectionMatrix.ptr)
	self.modelViewProjectionMatrix:mul(self.projectionMatrix, self.modelViewMatrix)

	self.drawShader:use()
	gl.glUniformMatrix4fv(self.drawShader.uniforms.modelViewProjectionMatrix.loc, 1, 0, self.modelViewProjectionMatrix.ptr)
	self.state:prev():bind()
	self.drawShader:setAttr('vtx', self.vtxAttr)
	gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, self.vtxBufferCount)
	self.drawShader:unsetAttr'vtx'
	self.drawShader:useNone()
glreport'here'
end

return App():run()
