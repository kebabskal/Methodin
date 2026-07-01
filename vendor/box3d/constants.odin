package vendor_box3d

foreign import lib { LIB_PATH }

@(link_prefix="b3", default_calling_convention="c")
foreign lib {
	// Box3D bases all length units on meters, but you may need different units for your game.
	// You can set this value to use different units. This should be done at application startup
	// and only modified once. Default value is 1.
	// @warning This must be modified before any calls to Box3D
	SetLengthUnitsPerMeter :: proc(lengthUnits: f32) ---
	// Get the current length units per meter.
	GetLengthUnitsPerMeter :: proc() -> f32 ---
	// Set the threshold for logging stalls.
	SetStallThreshold :: proc(seconds: f32) ---
	// Get the threshold for logging stalls.
	GetStallThreshold :: proc() -> f32 ---
}
