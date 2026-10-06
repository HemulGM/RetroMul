unit Core.Emulation;

interface

uses
  Core.Storage, System.UITypes, System.SysUtils, System.IniFiles, System.IOUtils,
  System.Math;

{$SCOPEDENUMS ON}

type
  // Every frontend supplies the same logical pad.  A core can ignore buttons
  // which do not exist on its hardware.
  TEmulatorButton = (Up, Down, Left, Right, A, B, Select, Start, C, X, Y, Z, Mode);

  TEmulatorButtons = set of TEmulatorButton;

  TEmulatorInput = record
    Buttons: TEmulatorButtons;
    Buttons3, Buttons4: TEmulatorButtons; // NES Four Score controllers.
    Buttons2: TEmulatorButtons; // Second controller; ignored by single-player cores.
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

  // Pixels are premultiplied-alpha FMX colors in row-major order.
  TEmulatorFrame = record
    Width: Integer;
    Height: Integer;
    Pixels: TArray<TAlphaColor>;
    FrameNumber: UInt64;
    FramesPerSecond: Double;
  end;

  // Device warnings do not stop emulation; frontends may report them once.
  IEmulationAudioDiagnostics = interface
    ['{FB3848EA-CA1B-4D12-A7ED-1D31776921A6}']
    function TakeAudioError: string;
  end;

  IEmulationCore = interface
    ['{757D169F-CE44-4B9F-AE15-9D81C6948D0A}']
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    // Read-only feedback for virtual controls. Call on the frontend thread,
    // just like the input setters; implementations synchronize with workers.
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    property Name: string read GetName;
    property SupportsSnapshots: Boolean read GetSupportsSnapshots;
    property UsesSuborKeyboard: Boolean read GetUsesSuborKeyboard;
    // Coin methods do nothing when the loaded ROM has no coin acceptor.
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    property Config: IEmulatorConfig read GetConfig;
    function IsPaused: Boolean;
  end;

function EmulatorConfigFileName(const EmulatorId: string): string;

function ReadEmulatorKey(Ini: TCustomIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;

implementation

uses
  Core.SavePaths;

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

procedure TEmulatorConfigBase.LoadCoreSettings(Ini: TCustomIniFile);
begin

end;

procedure TEmulatorConfigBase.Save;
begin
  var Ini := FStorage.ReadConfig(FFileName);
  try
    Ini.WriteInteger('Video', 'Scale', FScale);
    Ini.WriteString('Video', 'Filter', FFilter);
    Ini.WriteBool('Audio', 'Enabled', FAudioEnabled);
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

