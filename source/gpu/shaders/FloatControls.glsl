// IEEE-754 arithmetic as the CPU does it: denormals kept, round to nearest
// even, signed zeros, infinities and NaNs kept. Each float expression must
// also be `precise` so that it is not contracted into a fused multiply-add or
// reassociated. glslang keeps one execution mode per kind, so only the 32-bit
// modes are declared here; the SPIR-V of modules that use doubles has the
// same modes for 16 and 64 bits added (devices may tie those two together).
#extension GL_EXT_spirv_intrinsics : require

spirv_execution_mode(extensions = ["SPV_KHR_float_controls"], capabilities = [4464], 4459, 32);
spirv_execution_mode(extensions = ["SPV_KHR_float_controls"], capabilities = [4466], 4461, 32);
spirv_execution_mode(extensions = ["SPV_KHR_float_controls"], capabilities = [4467], 4462, 32);
