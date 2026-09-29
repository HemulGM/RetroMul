unit Core.Adapter.GBC;

interface

uses
  System.Classes, System.IniFiles, Core.Emulation, GBC.EmulationThread, GBC.Joypad;

type
  TGBCKeyMap = record
    A, B, Select, Start, Up, Down, Left, Right: UInt32;
  end;

  IGBCEmulatorConfig = interface(IEmulatorConfig)
    ['{A222ECCD-315C-49EF-8B71-E25A2369E045}']
    function GetKeys: TGBCKeyMap;
    procedure SetKeys(const Value: TGBCKeyMap);
    property Keys: TGBCKeyMap read GetKeys write SetKeys;
  end;

  TGBCEmulatorConfig = class(TEmulatorConfigBase, IGBCEmulatorConfig)
  private
    FKeys: TGBCKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TIniFile); override;
    procedure SaveCoreSettings(Ini: TIniFile); override;
  public
    constructor Create(const AFileName: string);
    function GetKeys: TGBCKeyMap;
    procedure SetKeys(const Value: TGBCKeyMap);
  end;

  TGBCCoreAdapter = class(TInterfacedObject, IEmulationCore)
  private
    FThread: TGBCEmulationThread;
    FROMData: TArray<Byte>;
    FGamepadInput: TEmulatorInput;
    FKeyboardInput: TEmulatorInput;
    FConfig: IGBCEmulatorConfig;
    FFrameNumber: UInt64;
    procedure CreateThread;
    procedure ApplyInput;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
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
    function IsPaused: Boolean;
  end;

implementation

uses
  System.SysUtils, System.UITypes, GBC.GPU, GBC.ROM, GBC.MBC;

constructor TGBCCoreAdapter.Create(const FileName: string);
begin
  inherited Create;
  FConfig := TGBCEmulatorConfig.Create(EmulatorConfigFileName('gbc'));
  FConfig.Load;
  var ROM := TGBCROM.Create;
  try
    var Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      ROM.ReadROM(Stream);
    finally
      Stream.Free;
    end;
    FROMData := ROM.ROMData;
    // Validate mapper support before the frontend replaces the active session.
    TGBCMBC.Create(ROM).Free;
  finally
    ROM.Free;
  end;
  CreateThread;
end;

procedure TGBCCoreAdapter.CreateThread;
begin
  FThread := TGBCEmulationThread.Create(FROMData, FConfig.AudioEnabled);
  FThread.SoundVolume := FConfig.AudioVolume;
end;

destructor TGBCCoreAdapter.Destroy;
begin
  Stop;
  FThread.Free;
  inherited;
end;

procedure TGBCCoreAdapter.ApplyInput;
const
  ButtonKeys: array[TEmulatorButton] of TGBCKey =
    (TGBCKey.Up, TGBCKey.Down, TGBCKey.Left, TGBCKey.Right,
    TGBCKey.A, TGBCKey.B, TGBCKey.Select, TGBCKey.Start);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    FThread.SetKeyState(ButtonKeys[Button],
      (Button in FGamepadInput.Buttons) or (Button in FKeyboardInput.Buttons));
end;

procedure TGBCCoreAdapter.ClearInput;
begin
  FGamepadInput := Default(TEmulatorInput);
  FKeyboardInput := Default(TEmulatorInput);
  FThread.ReleaseKeys;
end;

function TGBCCoreAdapter.GetName: string;
begin
  Result := 'Game Boy Color';
end;

function TGBCCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := False;
end;

function TGBCCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TGBCCoreAdapter.IsPaused: Boolean;
begin
  Result := FThread.PauseRequested;
end;

procedure TGBCCoreAdapter.LoadSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('Game Boy Color snapshots are not implemented');
end;

procedure TGBCCoreAdapter.Pause;
begin
  FThread.RequestPause;
end;

procedure TGBCCoreAdapter.Reset;
begin
  // The Game Boy Color core has no in-place reset path. Recreate its worker so all
  // singleton CPU, GPU and memory state is returned to the power-on state.
  FreeAndNil(FThread);
  CreateThread;
  FFrameNumber := 0;
  FThread.Start;
  ApplyInput;
end;

procedure TGBCCoreAdapter.Resume;
begin
  FThread.RequestResume;
end;

procedure TGBCCoreAdapter.SaveSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('Game Boy Color snapshots are not implemented');
end;

procedure TGBCCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepadInput := Input;
  ApplyInput;
end;

procedure TGBCCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  var Keys := FConfig.Keys;
  if Code = Keys.A then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.A)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.A);
  if Code = Keys.B then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.B)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.B);
  if Code = Keys.Select then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Select)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Select);
  if Code = Keys.Start then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Start)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Start);
  if Code = Keys.Up then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Up)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Up);
  if Code = Keys.Down then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Down)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Down);
  if Code = Keys.Left then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Left)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Left);
  if Code = Keys.Right then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Right)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Right);
  ApplyInput;
end;

procedure TGBCCoreAdapter.Start;
begin
  FThread.Start;
end;

procedure TGBCCoreAdapter.Stop;
begin
  if (FThread <> nil) and not FThread.Finished then
    FThread.RequestStop;
end;

function TGBCCoreAdapter.TakeError: string;
begin
  Result := FThread.TakeError;
end;

function TGBCCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TGBCCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
var
  Screen: TScreenArray;
  X, Y, Index: Integer;
  FramesPerSecond: Double;
begin
  Result := FThread.TryGetFrame(Screen, FramesPerSecond);
  if not Result then
    Exit;
  Frame.Width := 160;
  Frame.Height := 144;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  for Y := 0 to Frame.Height - 1 do
    for X := 0 to Frame.Width - 1 do
    begin
      Index := Screen[Y * Frame.Width + X];
      // GBC pixels are stored as ARGB bit patterns.  With range checks enabled
      // a direct Integer -> TAlphaColor conversion rejects every opaque color
      // (the high alpha bit makes its signed Integer value negative).
      Move(Index, Frame.Pixels[Y * Frame.Width + X], SizeOf(Index));
    end;
  Inc(FFrameNumber);
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := FramesPerSecond;
end;

{ TGBCEmulatorConfig }

constructor TGBCEmulatorConfig.Create(const AFileName: string);
begin
  inherited Create(AFileName);
  FKeys.A := Ord('Z');
  FKeys.B := Ord('X');
  FKeys.Select := vkSpace;
  FKeys.Start := vkReturn;
  FKeys.Up := vkUp;
  FKeys.Down := vkDown;
  FKeys.Left := vkLeft;
  FKeys.Right := vkRight;
end;

procedure TGBCEmulatorConfig.LoadCoreSettings(Ini: TIniFile);
begin
  FKeys.A := ReadEmulatorKey(Ini, 'Controls', 'A', FKeys.A);
  FKeys.B := ReadEmulatorKey(Ini, 'Controls', 'B', FKeys.B);
  FKeys.Select := ReadEmulatorKey(Ini, 'Controls', 'Select', FKeys.Select);
  FKeys.Start := ReadEmulatorKey(Ini, 'Controls', 'Start', FKeys.Start);
  FKeys.Up := ReadEmulatorKey(Ini, 'Controls', 'Up', FKeys.Up);
  FKeys.Down := ReadEmulatorKey(Ini, 'Controls', 'Down', FKeys.Down);
  FKeys.Left := ReadEmulatorKey(Ini, 'Controls', 'Left', FKeys.Left);
  FKeys.Right := ReadEmulatorKey(Ini, 'Controls', 'Right', FKeys.Right);
end;

procedure TGBCEmulatorConfig.SaveCoreSettings(Ini: TIniFile);
begin
  Ini.WriteInteger('Controls', 'A', FKeys.A);
  Ini.WriteInteger('Controls', 'B', FKeys.B);
  Ini.WriteInteger('Controls', 'Select', FKeys.Select);
  Ini.WriteInteger('Controls', 'Start', FKeys.Start);
  Ini.WriteInteger('Controls', 'Up', FKeys.Up);
  Ini.WriteInteger('Controls', 'Down', FKeys.Down);
  Ini.WriteInteger('Controls', 'Left', FKeys.Left);
  Ini.WriteInteger('Controls', 'Right', FKeys.Right);
end;

function TGBCEmulatorConfig.GetKeys: TGBCKeyMap;
begin
  Result := FKeys;
end;

procedure TGBCEmulatorConfig.SetKeys(const Value: TGBCKeyMap);
begin
  FKeys := Value;
end;

end.

