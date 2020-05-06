#!/usr/bin/env luajit
local class = require 'ext.class'
local table = require 'ext.table'
local bit = require 'bit'
local ffi = require 'ffi'
local gl = require 'gl'
local glreport = require 'gl.report'
local GLTex2D = require 'gl.tex2d'
local GLArrayBuffer = require 'gl.arraybuffer'
local GLAttribute = require 'gl.attribute'
local GLProgram = require 'gl.program'
local Image = require 'image'
local ImGuiApp = require 'imguiapp'

local App = require 'glapp.orbit'(ImGuiApp)

App.title = 'LIC'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.ortho = true 
	self.view.orthoSize = 1

	self.size = 1024
	local image = Image(self.size, self.size, 4, 'float')
	for i=0,self.size*self.size*4-1 do
		image.buffer[i] = math.random()
	end
	self.tex = GLTex2D{
		internalFormat = gl.GL_RGBA,--gl.GL_RGBA32F,
		width = self.size,
		height = self.size,
		format = gl.GL_RGBA,
		type = gl.GL_FLOAT,
		data = image.buffer,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_LINEAR,
	}

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

	self.drawShader = GLProgram{
		vertexCode = [[

attribute vec2 vtx;
varying vec2 tc;
void main() {
	tc = vtx.xy;
	vec4 v = vec4(vtx.xy * 2. - 1., 0., 1.);
	gl_Position = gl_ModelViewProjectionMatrix * v;
}
]],
		fragmentCode = [[
varying vec2 tc;
uniform sampler2D tex;
void main() {
	gl_FragColor = texture2D(tex, tc);
}
]],
		uniforms = {
			tex = 0,
		},
	}

	gl.glEnable(gl.GL_DEPTH_TEST)
	gl.glEnable(gl.GL_CULL_FACE)
end

function App:update()
	App.super.update(self)

	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	self.drawShader:use()
	self.tex:bind()
	self.drawShader:setAttr('vtx', self.vtxAttr)
	gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, self.vtxBufferCount)
	self.drawShader:unsetAttr'vtx'
	self.drawShader:useNone()
glreport'here'
end

return App():run()
