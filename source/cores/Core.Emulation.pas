unit Core.Emulation;

interface

uses
  System.UITypes, System.SysUtils, System.IniFiles, System.IOUtils, System.Math;

{$SCOPEDENUMS ON}

type
  // Every frontend supplies the same logical pad.  A core can ignore buttons
  // which do not exist on its hardware.
  TEmulatorButton = (Up, Down, Left, Right, A, B, Select, Start);

  TEmulatorButtons = set of TEmulatorButton;

  TEmulatorInput = record
    Buttons: TEmulatorButtons;
  end;

  IEmulatorConfig = interface
    ['{CDB768C2-70EE-4F51-AEFE-C59985CE04C9}']
    function GetAudioEnabled: Boolean;
    procedure SetAudioEnabled(const Value: Boolean);
    function GetAudioVolume: Single;
    procedure SetAudioVolume(const Value: Single);
    function GetFilter: string;
    procedure SetFilter(const Value: string);
    function GetScale: Integer;
    procedure SetScale(const Value: Integer);
    function GetFileName: string;
    procedure Load;
    procedure Save;
    property AudioEnabled: Boolean read GetAudioEnabled write SetAudioEnabled;
    property AudioVolume: Single read GetAudioVolume write SetAudioVolume;
    property Filter: string read GetFilter write SetFilter;
    property Scale: Integer read GetScale write SetScale;
    property FileName: string read GetFileName;
  end;

  // Common settings are persisted by every core in its own INI file. Descendants
  // add hardware-specific options in LoadCoreSettings / SaveCoreSettings.
  TEmulatorConfigBase = class(TInterfacedObject, IEmulatorConfig)
  private
    FFileName: string;
    FAudioEnabled: Boolean;
    FAudioVolume: Single;
    FFilter: string;
    FScale: Integer;
  protected
    procedure LoadCoreSettings(Ini: TIniFile); virtual;
    procedure SaveCoreSettings(Ini: TIniFile); virtual;
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
    constructor Create(const AFileName: string);
    procedure Load;
    procedure Save;
  end;

  // Pixels are premultiplied-alpha FMX colors in row-major order.
  TEmulatorFrame = record
    Width: Integer;
    Height: Integer;
    Pixels: TArray<TAlphaColor>;
    FrameNumber: UInt64;
    FramesPerSecond: Double;
  end;

  IEmulationCore = interface
    ['{757D169F-CE44-4B9F-AE15-9D81C6948D0A}']
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    property Name: string read GetName;
    property SupportsSnapshots: Boolean read GetSupportsSnapshots;
    property UsesSuborKeyboard: Boolean read GetUsesSuborKeyboard;
    property Config: IEmulatorConfig read GetConfig;
    function IsPaused: Boolean;
  end;

function EmulatorConfigFileName(const EmulatorId: string): string;

function ReadEmulatorKey(Ini: TIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;

implementation

uses
  Core.SavePaths;

function ReadEmulatorKey(Ini: TIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;
begin
  var Value := Ini.ReadInteger(Section, Name, Integer(DefaultValue and $FFFF));
  if (Value < 0) or (Value > $FFFF) then
    Result := DefaultValue
  else
    Result := Value;
end;

function EmulatorConfigFileName(const EmulatorId: string): string;
begin
  Result := TPath.Combine(GetDocumentsDirectory, EmulatorId + '.ini');
end;

{ TEmulatorConfigBase }

constructor TEmulatorConfigBase.Create(const AFileName: string);
begin
  inherited Create;
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
  if TFile.Exists(FFileName) then
  begin
    var Ini := TIniFile.Create(FFileName);
    try
      SetScale(Ini.ReadInteger('Video', 'Scale', FScale));
      FFilter := Ini.ReadString('Video', 'Filter', FFilter).Trim;
      if FFilter.IsEmpty then
        FFilter := 'nearest';
      FAudioEnabled := Ini.ReadBool('Audio', 'Enabled', FAudioEnabled);
      SetAudioVolume(Ini.ReadFloat('Audio', 'Volume', FAudioVolume));
      LoadCoreSettings(Ini);
    finally
      Ini.Free;
    end;
  end
  else
    Save;
end;

procedure TEmulatorConfigBase.LoadCoreSettings(Ini: TIniFile);
begin

end;

procedure TEmulatorConfigBase.Save;
begin
  TDirectory.CreateDirectory(ExtractFilePath(FFileName));
  var Ini := TIniFile.Create(FFileName);
  try
    Ini.WriteInteger('Video', 'Scale', FScale);
    Ini.WriteString('Video', 'Filter', FFilter);
    Ini.WriteBool('Audio', 'Enabled', FAudioEnabled);
    Ini.WriteFloat('Audio', 'Volume', FAudioVolume);
    SaveCoreSettings(Ini);
  finally
    Ini.Free;
  end;
end;

procedure TEmulatorConfigBase.SaveCoreSettings(Ini: TIniFile);
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

