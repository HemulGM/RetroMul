unit RM.Vulkan.PipelineState;
interface
uses
  RM.Vulkan.Bindings;
const
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT = 1000267000;
  VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT = 1000455000;
  VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE = 1000267006;
  VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE = 1000267007;
  VK_DYNAMIC_STATE_DEPTH_COMPARE_OP = 1000267008;
  VK_DYNAMIC_STATE_COLOR_BLEND_ENABLE_EXT = 1000455010;
  VK_DYNAMIC_STATE_COLOR_BLEND_EQUATION_EXT = 1000455011;
  VK_DYNAMIC_STATE_COLOR_WRITE_MASK_EXT = 1000455012;
type
  TVkDynamicDepth = record
    sType: VkStructureType;
    pNext: Pointer;
    extendedDynamicState: VkBool32;
  end;
  TVkDynamicColor = record
    sType: VkStructureType;
    pNext: Pointer;
    extendedDynamicState3TessellationDomainOrigin: VkBool32;
    extendedDynamicState3DepthClampEnable: VkBool32;
    extendedDynamicState3PolygonMode: VkBool32;
    extendedDynamicState3RasterizationSamples: VkBool32;
    extendedDynamicState3SampleMask: VkBool32;
    extendedDynamicState3AlphaToCoverageEnable: VkBool32;
    extendedDynamicState3AlphaToOneEnable: VkBool32;
    extendedDynamicState3LogicOpEnable: VkBool32;
    extendedDynamicState3ColorBlendEnable: VkBool32;
    extendedDynamicState3ColorBlendEquation: VkBool32;
    extendedDynamicState3ColorWriteMask: VkBool32;
    extendedDynamicState3RasterizationStream: VkBool32;
    extendedDynamicState3ConservativeRasterizationMode: VkBool32;
    extendedDynamicState3ExtraPrimitiveOverestimationSize: VkBool32;
    extendedDynamicState3DepthClipEnable: VkBool32;
    extendedDynamicState3SampleLocationsEnable: VkBool32;
    extendedDynamicState3ColorBlendAdvanced: VkBool32;
    extendedDynamicState3ProvokingVertexMode: VkBool32;
    extendedDynamicState3LineRasterizationMode: VkBool32;
    extendedDynamicState3LineStippleEnable: VkBool32;
    extendedDynamicState3DepthClipNegativeOneToOne: VkBool32;
    extendedDynamicState3ViewportWScalingEnable: VkBool32;
    extendedDynamicState3ViewportSwizzle: VkBool32;
    extendedDynamicState3CoverageToColorEnable: VkBool32;
    extendedDynamicState3CoverageToColorLocation: VkBool32;
    extendedDynamicState3CoverageModulationMode: VkBool32;
    extendedDynamicState3CoverageModulationTableEnable: VkBool32;
    extendedDynamicState3CoverageModulationTable: VkBool32;
    extendedDynamicState3CoverageReductionMode: VkBool32;
    extendedDynamicState3RepresentativeFragmentTestEnable: VkBool32;
    extendedDynamicState3ShadingRateImageEnable: VkBool32;
  end;
  TVkBlendEquation = record
    SourceColor, DestinationColor, ColorOp, SourceAlpha, DestinationAlpha, AlphaOp: Integer;
  end;
  TVkSetDepthState = procedure(Command: VkCommandBuffer; Value: Cardinal); stdcall;
  TVkSetColorState = procedure(Command: VkCommandBuffer; First, Count: Cardinal; Values: Pointer); stdcall;
implementation
end.
