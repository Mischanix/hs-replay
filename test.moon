{ :LogParser } = require "parse"
{ :HistCoder } = require "coder"
inspect = require "inspect"

args = { ... }

if #args < 1
	error("usage: test <Power.log>")

log_file = io.open(args[1], "r")
log_buf = log_file\read("*a")
parser = LogParser!

hists = parser\parse(log_buf)

compressor = HistCoder!
compressor\encode(hists)

io.write("len = #{#compressor.coder.buf.data}\n")

decompressor = HistCoder(compressor.coder.buf)
decompressor.nhists = #hists
hists2 = decompressor\decode!
io.write(inspect(hists2) .. "\n")
