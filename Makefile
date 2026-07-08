.PHONY: build test wasm migrate clean fmt

build:
	zig build

test:
	zig build test --summary all

wasm:
	zig build wasm

migrate:
	zig build migrate
	./zig-out/bin/atomik-migrate

clean:
	rm -rf zig-out .zig-cache

fmt:
	zig fmt src edge build.zig
