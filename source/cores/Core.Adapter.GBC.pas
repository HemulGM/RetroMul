unit Core.Adapter.GBC;

interface

uses
  System.IniFiles, Core.Emulation, Core.Adapter.GB, GB.EmulationThread, GB.GPU;

type
  TGBCKeyMap = Core.Adapter.GB.TGBKeyMap;

  IGBCEmulatorConfig = interface(IEmulatorConfig)
    ['{A222ECCD-315C-49EF-8B71-E25A2369E045}']
    function GetKeys: TGBCKeyMap;
    procedure SetKeys(const Value: TGBCKeyMap);
    property Keys: TGBCKeyMap read GetKeys write SetKeys;
  end;

  TGBCEmulatorConfig = class(TGBEmulatorConfig, IGBCEmulatorConfig)
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  end;

  TGBCCoreAdapter = class(TGBCoreAdapter)
  protected
    function ConfigPrefix: string; override;
    function CreateConfig(const FileName: string): IGBEmulatorConfig; override;
    function CreateWorker: TGBEmulationThread; override;
    procedure CopyFrame(const Screen: TScreenArray; var Frame: TEmulatorFrame); override;
    function GetName: string; override;
  end;

implementation

uses
  Core.RomFormat, GBC.EmulationThread;

function TGBCCoreAdapter.ConfigPrefix: string;
begin
  Result := ROM_SYSTEM_GBC;
end;

function TGBCCoreAdapter.CreateConfig(const FileName: string): IGBEmulatorConfig;
begin
  Result := TGBCEmulatorConfig.Create(FileName, FStorage);
end;

function TGBCCoreAdapter.CreateWorker: TGBEmulationThread;
begin
  Result := TGBCEmulationThread.Create(FROMData, FConfig.AudioEnabled);
end;

procedure TGBCCoreAdapter.CopyFrame(const Screen: TScreenArray; var Frame: TEmulatorFrame);
begin
  // Preserve signed ARGB bit patterns, including when range checking is enabled.
  Move(Screen[0], Frame.Pixels[0], SizeOf(Screen));
end;

function TGBCCoreAdapter.GetName: string;
begin
  Result := 'Game Boy Color';
end;

procedure TGBCEmulatorConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  LoadControls(Ini);
end;

procedure TGBCEmulatorConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  SaveControls(Ini);
end;

end.

