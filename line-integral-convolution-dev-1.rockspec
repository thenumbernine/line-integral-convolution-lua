package = "line-integral-convolution"
version = "dev-1"
source = {
	url = "git+https://github.com/thenumbernine/line-integral-convolution-lua"
}
description = {
	detailed = "Line Integral Convolution",
	homepage = "https://github.com/thenumbernine/line-integral-convolution-lua",
	license = "MIT"
}
dependencies = {
	"lua >= 5.1"
}
build = {
	type = "builtin",
	modules = {
		["line-integral-convolution.run"] = "run.lua"
	}
}
