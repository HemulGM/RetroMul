unit Core.Platforms.GBC.Adapter;

interface

uses
  System.IniFiles, Core.Emulation, Core.Platforms.GB.Adapter, GB.EmulationThread,
  GB.GPU;

type
  TGBCKeyMap = Core.Platforms.GB.Adapter.TGBKeyMap;

  IGBCEmulatorConfig = interface(IEmulatorConfig)
    ['{A222ECCD-315C-49EF-8B71-E25A2369E045}']
    function GetKeys: TGBCKeyMap;
    procedure SetKeys(const Value: TGBCKeyMap);
    property Keys: TGBCKeyMap read GetKeys write SetKeys;
  end;

  TGBCEmulatorConfig = class(TGBEmulatorConfig, IGBCEmulatorConfig)
  public
    ColorCorrection: Boolean;
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
  RM.Platforms.GBC, GBC.EmulationThread;

{ TGBCCoreAdapter }

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
  Result := inherited CreateWorker;
end;

procedure TGBCCoreAdapter.CopyFrame(const Screen: TScreenArray; var Frame: TEmulatorFrame);
begin
  if not FColorHardware then
  begin
    inherited;
    Exit;
  end;

  // Resolve optional monochrome palette tags before applying LCD color correction.
  inherited CopyFrame(Screen, Frame);
  if (FConfig as TGBCEmulatorConfig).ColorCorrection then
    for var I := 0 to High(Frame.Pixels) do
    begin
      var C := Frame.Pixels[I];
      var R := Integer((C shr 16) and $FF);
      var G := Integer((C shr 8) and $FF);
      var B := Integer(C and $FF);

      // Approximate LCD channel mixing; preserve alpha and the uncorrected core frame.
      Frame.Pixels[I] := (C and $FF000000) or
        (UInt32((26 * R + 4 * G + 2 * B) div 32) shl 16) or
        (UInt32((24 * G + 8 * B) div 32) shl 8) or UInt32((6 * R + 4 * G + 22 * B) div 32);
    end;
end;

function TGBCCoreAdapter.GetName: string;
begin
  Result := 'Game Boy Color';
end;

procedure TGBCEmulatorConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  inherited;
  ColorCorrection := Ini.ReadBool('Video', 'ColorCorrection', False);
end;

procedure TGBCEmulatorConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  inherited;
  Ini.WriteBool('Video', 'ColorCorrection', ColorCorrection);
end;

end.

