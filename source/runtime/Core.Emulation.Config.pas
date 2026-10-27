unit Core.Emulation.Config;

interface

uses
  System.SysUtils, System.IniFiles, Core.Storage, Core.Emulation.Types;

type
  // Common settings are persisted by every core in its own INI file. Descendants
  // add hardware-specific options in LoadCoreSettings / SaveCoreSettings.
  TEmulatorConfigBase = class(TInterfacedObject, IEmulatorConfig)
  private
    FFileName: string;
    FStorage: IStorage;
    FAudioEnabled: Boolean;
    FAudioVolume: Single;
    FFilter: string;
    FScale: Integer;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); virtual;
    procedure SaveCoreSettings(Ini: TCustomIniFile); virtual;
    function GetAudioEnabled: Boolean;
    procedure SetAudioEnabled(const Value: Boolean);
    function GetAudioVolume: Single;
    procedure SetAudioVolume(const Value: Single);
    function GetFilter: string;
    procedure SetFilter(const Value: string);
    function GetScale: Integer;
    procedure SetScale(const Value: Integer);
    function GetFileName: string;
  public
    constructor Create(const AFileName: string; const Storage: IStorage = nil);
    procedure Load;
    procedure Save;
  end;

function EmulatorConfigFileName(const EmulatorId: string): string;

function ReadEmulatorKey(Ini: TCustomIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;

implementation

uses System.Math;

function ReadEmulatorKey(Ini: TCustomIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;
begin
  var Value := Ini.ReadInteger(Section, Name, Integer(DefaultValue and $FFFF));
  if (Value < 0) or (Value > $FFFF) then
    Result := DefaultValue
  else
    Result := Value;
end;

function EmulatorConfigFileName(const EmulatorId: string): string;
begin
  Result := TStorage.Default.ConfigFile(EmulatorId);
end;

{ TEmulatorConfigBase }

constructor TEmulatorConfigBase.Create(const AFileName: string; const Storage: IStorage);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FFileName := AFileName;
  FAudioEnabled := True;
  FAudioVolume := 0.5;
  FFilter := 'nearest';
  FScale := 2;
end;

function TEmulatorConfigBase.GetAudioEnabled: Boolean;
begin
  Result := FAudioEnabled;
end;

function TEmulatorConfigBase.GetAudioVolume: Single;
begin
  Result := FAudioVolume;
end;

function TEmulatorConfigBase.GetFileName: string;
begin
  Result := FFileName;
end;

function TEmulatorConfigBase.GetFilter: string;
begin
  Result := FFilter;
end;

function TEmulatorConfigBase.GetScale: Integer;
begin
  Result := FScale;
end;

procedure TEmulatorConfigBase.Load;
begin
  if FStorage.Exists(FFileName) then
  begin
    var Ini := FStorage.ReadConfig(FFileName);
    try
      SetScale(Ini.ReadInteger('Video', 'Scale', FScale));
      FFilter := Ini.ReadString('Video', 'Filter', FFilter).Trim;
      if FFilter.IsEmpty then
        FFilter := 'nearest';
      FAudioEnabled := True;
      SetAudioVolume(Ini.ReadFloat('Audio', 'Volume', FAudioVolume));
      LoadCoreSettings(Ini);
    finally
      Ini.Free;
    end;
  end
  else
    Save;
end;

procedure TEmulatorConfigBase.LoadCoreSettings(Ini: TCustomIniFile);
begin

end;

procedure TEmulatorConfigBase.Save;
begin
  var Ini := FStorage.ReadConfig(FFileName);
  try
    Ini.WriteInteger('Video', 'Scale', FScale);
    Ini.WriteString('Video', 'Filter', FFilter);
    Ini.DeleteKey('Audio', 'Enabled');
    Ini.WriteFloat('Audio', 'Volume', FAudioVolume);
    SaveCoreSettings(Ini);
    FStorage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
end;

procedure TEmulatorConfigBase.SaveCoreSettings(Ini: TCustomIniFile);
begin

end;

procedure TEmulatorConfigBase.SetAudioEnabled(const Value: Boolean);
begin
  FAudioEnabled := Value;
end;

procedure TEmulatorConfigBase.SetAudioVolume(const Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) then
    FAudioVolume := 0.5
  else
    FAudioVolume := EnsureRange(Value, 0.0, 1.0);
end;

procedure TEmulatorConfigBase.SetFilter(const Value: string);
begin
  FFilter := Value.Trim;
  if FFilter = '' then
    FFilter := 'nearest';
end;

procedure TEmulatorConfigBase.SetScale(const Value: Integer);
begin
  FScale := EnsureRange(Value, 1, 8);
end;

end.
