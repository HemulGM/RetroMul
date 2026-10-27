unit Core.Emulation;

interface

// Compatibility facade. New hardware code can use Core.Emulation.Types directly.

uses
  System.IniFiles, Core.Emulation.Types, Core.Emulation.Config,
  Core.Emulation.Timing;

type
  TEmulatorButton = Core.Emulation.Types.TEmulatorButton;

  TEmulatorButtons = Core.Emulation.Types.TEmulatorButtons;

  TEmulatorInput = Core.Emulation.Types.TEmulatorInput;

  IEmulatorConfig = Core.Emulation.Types.IEmulatorConfig;

  TEmulatorFrame = Core.Emulation.Types.TEmulatorFrame;

  IEmulationAudioDiagnostics = Core.Emulation.Types.IEmulationAudioDiagnostics;

  IEmulationMouseInput = Core.Emulation.Types.IEmulationMouseInput;

  IEmulationPointerInput = Core.Emulation.Types.IEmulationPointerInput;

  IEmulationMotionInput = Core.Emulation.Types.IEmulationMotionInput;

  IEmulationRotationInput = Core.Emulation.Types.IEmulationRotationInput;

  IEmulationRumbleOutput = Core.Emulation.Types.IEmulationRumbleOutput;

  IEmulationDiscControl = Core.Emulation.Types.IEmulationDiscControl;

  IEmulationSnapshotLocation = Core.Emulation.Types.IEmulationSnapshotLocation;

  IEmulationVirtualControls = Core.Emulation.Types.IEmulationVirtualControls;

  IEmulationLiveSettings = Core.Emulation.Types.IEmulationLiveSettings;

  IEmulationCore = Core.Emulation.Types.IEmulationCore;

  TEmulatorConfigBase = Core.Emulation.Config.TEmulatorConfigBase;

  TEmulationFrameRate = Core.Emulation.Timing.TEmulationFrameRate;

function EmulatorConfigFileName(const EmulatorId: string): string;

function ReadEmulatorKey(Ini: TCustomIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;

implementation

function EmulatorConfigFileName(const EmulatorId: string): string;
begin
  Result := Core.Emulation.Config.EmulatorConfigFileName(EmulatorId);
end;

function ReadEmulatorKey(Ini: TCustomIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;
begin
  Result := Core.Emulation.Config.ReadEmulatorKey(Ini, Section, Name, DefaultValue);
end;

end.

