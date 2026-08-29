init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build macos/DerivedData \
		macos/CostbarKit.xcframework \
		dist/out
.PHONY: clean
