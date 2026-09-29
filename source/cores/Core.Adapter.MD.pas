unit Core.Adapter.MD;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IniFiles,
  Core.Emulation, MD.Console;

type
  TMDKeyMap = array[TMDButton] of UInt32;

  TMDConfig = class(TEmulatorConfigBase)
  private
    FKeys: TMDKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TIniFile); override;
    procedure SaveCoreSettings(Ini: TIniFile); override;
  public
    constructor Create(const FileName: string);
    property Keys: TMDKeyMap read FKeys;
  end;

  TMDWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FData: TBytes;
    FSavePath: string;
    FInput: TMDButtons;
    FPause, FReset, FAudioEnabled: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FAvailable: Boolean;
    FError: string;
    procedure SetError(const Value: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; const SavePath: string);
    destructor Destroy; override;
    procedure Configure(const Input: TMDButtons; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
  end;

  TMDCoreAdapter = class(TInterfacedObject, IEmulationCore)
  private
    FThread: TMDWorker;
    FData: TBytes;
    FSavePath, FError: string;
    FConfig: IEmulatorConfig;
    FKeys: TMDKeyMap;
    FKeyboard, FGamepad: TMDButtons;
    FPaused: Boolean;
    procedure ApplySettings;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
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
    function IsPaused: Boolean;
  end;

implementation

uses
  System.IOUtils, System.Hash, System.Diagnostics, System.Math, PCM.Audio,
  MD.Cartridge;

const
  KeyNames: array[TMDButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'C', 'Start', 'X', 'Y', 'Z', 'Mode');

constructor TMDConfig.Create(const FileName: string);
const
  Defaults: TMDKeyMap = (38, 40, 37, 39, Ord('Z'), Ord('X'), Ord('C'), 13, Ord('A'), Ord('S'), Ord('D'), 16);
begin
  inherited Create(FileName);
  FKeys := Defaults;
end;

procedure TMDConfig.LoadCoreSettings(Ini: TIniFile);
var
  Button: TMDButton;
begin
  for Button := Low(TMDButton) to High(TMDButton) do
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
end;

procedure TMDConfig.SaveCoreSettings(Ini: TIniFile);
var
  Button: TMDButton;
begin
  for Button := Low(TMDButton) to High(TMDButton) do
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
end;

constructor TMDWorker.Create(const Data: TBytes; const SavePath: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FData := Copy(Data);
  FSavePath := SavePath;
end;

destructor TMDWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  inherited Destroy;
  FWake.Free;
  FLock.Free;
end;

procedure TMDWorker.Configure(const Input: TMDButtons; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
end;

procedure TMDWorker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
    FAvailable := False;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TMDWorker.SetError(const Value: string);
begin
  FLock.Acquire;
  try
    if FError = '' then
      FError := Value
    else
      FError := FError + sLineBreak + Value;
  finally
    FLock.Release;
  end;
end;

function TMDWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TMDWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      FAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TMDWorker.Execute;
var
  Console: TMDConsole;
  Audio: TPCMAudio;
  Format: TPCMAudioFormat;
  Input: TMDButtons;
  Paused, ResetRequested, Enabled, WasPaused, WasEnabled: Boolean;
  Volume: Single;
  Frame: TEmulatorFrame;
  Samples: TArray<SmallInt>;
  Watch: TStopwatch;
  Deadline: Double;
  WaitMS, X, Y, I: Integer;
  LastBattery: TBytes;
  LastAudioError: string;

  procedure SaveBattery;
  begin
    if (Console = nil) or not Console.BatteryDirty then
      Exit;
    var Data := Console.BatteryData;
    if Length(Data) = 0 then
      Exit;
    if (Length(Data) = Length(LastBattery)) and CompareMem(@Data[0], @LastBattery[0], Length(Data)) then
      Exit;
    ForceDirectories(ExtractFilePath(FSavePath));
    var TempName := FSavePath + '.' + TGUID.NewGuid.ToString + '.tmp';
    try
      TFile.WriteAllBytes(TempName, Data);
      if TFile.Exists(FSavePath) then
        TFile.Replace(TempName, FSavePath, '')
      else
        TFile.Move(TempName, FSavePath);
      LastBattery := Data;
    finally
      if TFile.Exists(TempName) then
        TFile.Delete(TempName);
    end;
  end;

begin
  Console := nil;
  Audio := nil;
  try
    try
      Console := TMDConsole.Create(FData, '.md');
      if TFile.Exists(FSavePath) then
      begin
        LastBattery := TFile.ReadAllBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 2048;
      Format.BlockCount := 4;
      Watch := TStopwatch.StartNew;
      Deadline := 0;
      WasPaused := False;
      WasEnabled := False;
      while not Terminated do
      begin
        FLock.Acquire;
        try
          Input := FInput;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release;
        end;
        if ResetRequested then
        begin
          SaveBattery;
          Console.Reset;
          if Audio <> nil then
            Audio.Clear;
          Deadline := Watch.Elapsed.TotalMilliseconds;
        end;
        if Paused then
        begin
          if not WasPaused then
          begin
            if Audio <> nil then
              Audio.Clear;
            SaveBattery;
          end;
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := Watch.Elapsed.TotalMilliseconds;
          Continue;
        end;
        WasPaused := False;
        Console.SetInput(Input);
        Console.RunFrame;
        if Terminated then
          Break;
        Frame.Width := Console.Width;
        Frame.Height := Console.Height;
        Frame.FrameNumber := Console.FrameNumber;
        Frame.FramesPerSecond := Console.FramesPerSecond;
        // Allocate a new publication buffer: previously delivered frames remain immutable.
        Frame.Pixels := nil;
        SetLength(Frame.Pixels, Frame.Width * Frame.Height);
        for Y := 0 to Frame.Height - 1 do
          for X := 0 to Frame.Width - 1 do
            Frame.Pixels[Y * Frame.Width + X] := Console.Pixels[Y * 320 + X];
        FLock.Acquire;
        try
          FFrame := Frame;
          FAvailable := True;
        finally
          FLock.Release;
        end;
        if Enabled then
        begin
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          SetLength(Samples, Console.SampleFrames * 2);
          for I := 0 to High(Samples) do
            Samples[I] := Round(Console.Samples[I] * Volume);
          Audio.Submit(Samples, Console.SampleFrames);
          if (Audio.Error <> '') and (Audio.Error <> LastAudioError) then
          begin
            LastAudioError := Audio.Error;
            SetError('Mega Drive audio: ' + LastAudioError);
          end;
        end
        else if WasEnabled and (Audio <> nil) then
          Audio.Clear;
        WasEnabled := Enabled;
        if Console.FrameNumber mod 120 = 0 then
          SaveBattery;
        Deadline := Deadline + 1000 / Console.FramesPerSecond;
        if Watch.Elapsed.TotalMilliseconds - Deadline > 100 then
          Deadline := Watch.Elapsed.TotalMilliseconds;
        WaitMS := Floor(Deadline - Watch.Elapsed.TotalMilliseconds);
        if WaitMS > 0 then
          FWake.WaitFor(WaitMS);
      end;
    except
      on E: Exception do
        SetError('Mega Drive: ' + E.Message);
    end;
  finally
    try
      SaveBattery;
    except
      on E: Exception do
        SetError('Mega Drive SRAM: ' + E.Message);
    end;
    Audio.Free;
    Console.Free;
  end;
end;

constructor TMDCoreAdapter.Create(const FileName: string);
var
  Cart: TMDCartridge;
  Config: TMDConfig;
  Root: string;
  Hash: THashSHA2;
begin
  inherited Create;
  Cart := TMDCartridge.Create(FileName);
  try
    FData := Copy(Cart.Data);
  finally
    Cart.Free;
  end;
  Config := TMDConfig.Create(EmulatorConfigFileName('md'));
  FConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  Root := TPath.GetDocumentsPath;
  if (Root = '') or not TPath.IsPathRooted(Root) then
    Root := TPath.GetHomePath;
  if (Root = '') or not TPath.IsPathRooted(Root) then
    raise EInOutError.Create('Cannot determine Mega Drive save directory');
  FSavePath := TPath.Combine(TPath.Combine(Root, 'RetroMul'), 'Saves');
  Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSavePath := TPath.Combine(FSavePath, 'MD-' + Hash.HashAsString + '.sav');
end;

destructor TMDCoreAdapter.Destroy;
begin
  Stop;
  inherited;
end;

procedure TMDCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(FKeyboard + FGamepad, FPaused,
      FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TMDCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FThread := TMDWorker.Create(FData, FSavePath);
  ApplySettings;
  FThread.Start;
end;

procedure TMDCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.Terminate;
  FThread.FWake.SetEvent;
  FThread.WaitFor;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TMDCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TMDCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TMDCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TMDCoreAdapter.ClearInput;
begin
  FKeyboard := [];
  FGamepad := [];
  ApplySettings;
end;

procedure TMDCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TMDButton;
begin
  for Button := Low(TMDButton) to High(TMDButton) do
    if Code = FKeys[Button] then
      if Pressed then
        Include(FKeyboard, Button)
      else
        Exclude(FKeyboard, Button);
  ApplySettings;
end;

procedure TMDCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TEmulatorButton] of TMDButton =
    (TMDButton.Up, TMDButton.Down, TMDButton.Left, TMDButton.Right,
    TMDButton.A, TMDButton.B, TMDButton.C, TMDButton.Start);
var
  Button: TEmulatorButton;
begin
  FGamepad := [];
  for Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if Button in Input.Buttons then
      Include(FGamepad, Mapping[Button]);
  ApplySettings;
end;

function TMDCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TMDCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TMDCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TMDCoreAdapter.GetName: string;
begin
  Result := 'SEGA Genesis / Mega Drive';
end;

function TMDCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := False;
end;

function TMDCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TMDCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

procedure TMDCoreAdapter.SaveSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('Mega Drive snapshots are not implemented');
end;

procedure TMDCoreAdapter.LoadSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('Mega Drive snapshots are not implemented');
end;

end.

