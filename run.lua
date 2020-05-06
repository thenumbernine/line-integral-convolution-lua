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
	self.view.orthoSize = 1

	--self.size = 128
	--self.size = 256
	--self.size = 512
	self.size = 1024
	local image = Image(self.size, self.size, 4, 'float')
	for i=0,self.size*self.size-1 do
		local l = math.floor(math.random(0,3)/3)
		for j=0,3 do
			image.buffer[j+4*i] = l
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
	}

	self.random = GLPingPong{
		internalFormat = gl.GL_RGBA32F,
		width = self.size,
		height = self.size,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
		data = image.buffer,
		numBuffers = 1,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
	}
	for i=1,#self.random.hist do
		for i=0,self.size*self.size-1 do
			local l = math.floor(math.random(0,3)/3)
			for j=0,3 do
				image.buffer[j+4*i] = l
			end
		end
		local tex = self.random.hist[i]
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


	local theta = math.rad(.1)
	local blendCoeff = .01
	self.updateShader = GLProgram{
		vertexCode = [[
varying vec2 tc;
void main() {
	tc = gl_Vertex.xy;
	gl_Position = gl_ProjectionMatrix * gl_Vertex;
}
]],
		fragmentCode = template([[
varying vec2 tc;
uniform sampler2D randomTex;
uniform sampler2D stateTex;
void main() {
	vec4 colorHere = texture2D(randomTex, tc);

#if 1
	vec2 src = tc - vec2(.5, .5);
	vec2 rot = vec2(<?=clnumber(math.cos(theta))?>, <?=clnumber(math.sin(theta))?>);
	src = vec2(src.x * rot.x - src.y * rot.y, src.x * rot.y + src.y * rot.x);
	src += vec2(.5, .5);
#else
	vec2 src = tc + vec2(.01, .005);
#endif
	vec4 colorThere = texture2D(stateTex, src);
	gl_FragColor = mix(colorThere, colorHere, <?=clnumber(blendCoeff)?>);

	//vec4 greyscale = vec4(.3, .6, .1, 0.);
	//float l = dot(greyscale, gl_FragColor);
	//gl_FragColor = vec4(l, l, l, 1.);
}
]],			{
				clnumber = clnumber,
				theta = theta,
				blendCoeff = blendCoeff,
			}),
		uniforms = {
			stateTex = 0,
			randomTex = 1,
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
	vec4 v = vec4(vtx.xy * 2. - 1., 0., 1.);
	gl_Position = modelViewProjectionMatrix * v;
}
]],
		fragmentCode = [[
#version 460
varying vec2 tc;
uniform sampler2D stateTex;
out vec4 fragColor;
void main() {
	fragColor = texture2D(stateTex, tc);
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
		dest = self.state:cur(),
		texs = {self.state:prev(), self.random:prev()},
		shader = self.updateShader,
		callback = function()
			gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
			-- TODO use buffered geometry here.   and saved matrices.  just because.
			self.state.fbo.drawScreenQuad()
		end,
	}
	self.state:swap()
	self.random:swap()
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
