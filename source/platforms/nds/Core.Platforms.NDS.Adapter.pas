unit Core.Platforms.NDS.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  System.Types, Core.Storage, Core.Emulation, Core.Snapshots, NDS.Console,
  Core.Platforms.NDS.Display;

const
  NDS_BUTTONS: TEmulatorButtons = [TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.C, TEmulatorButton.Z,
      TEmulatorButton.X, TEmulatorButton.Y];

type
  TNDSKeyMap = array[TEmulatorButton] of UInt32;

  TNDSConfig = class(TEmulatorConfigBase)
  private
    FKeys: TNDSKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    SaveSize: Integer;
    ScreenMode: TNDSDisplayMode;
    ScreenGap: Integer;
    function DisplayLayout: TNDSDisplayLayout;
    constructor Create(const FileName: string; const Storage: IStorage);
    property Keys: TNDSKeyMap read FKeys;
  end;

  TNDSWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FConsole: TNDSConsole;
    FStorage: IStorage;
    FSavePath, FSnapshotDirectory: string;
    FSnapshots: TSnapshotQueue;
    FLastBattery: TBytes;
    FInput: TEmulatorButtons;
    FTouchX, FTouchY: Integer;
    FPen, FPaused, FReset, FAvailable, FAudioEnabled: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError, FSaveError: string;
    procedure Persist;
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; SaveSize: Integer; const Storage: IStorage; const SavePath, SnapshotDirectory: string);
    destructor Destroy; override;
    procedure Join;
    procedure StopAndSave;
    procedure Snapshot(const Name: string; Loading: Boolean);
    procedure Configure(const Input: TEmulatorButtons; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure Touch(X, Y: Integer; Pressed: Boolean);
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
  end;

  TNDSCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationPointerInput, IEmulationMouseInput, IEmulationLiveSettings, IEmulationAudioDiagnostics, IEmulationSnapshotLocation, IEmulationVideoRegions)
  private
    FData: TBytes;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TNDSConfig;
    FWorker: TNDSWorker;
    FKeyboard, FGamepad: TEmulatorButtons;
    FPaused, FPointerValid, FPen: Boolean;
    FPointerX, FPointerY: Integer;
    FSourceFrame: TEmulatorFrame;
    FPresentedLayout: TNDSDisplayLayout;
    FSavePath, FSnapshotDirectory, FError, FAudioError: string;
    procedure Configure;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
    destructor Destroy; override;
    function GetName: string;
    function GetSystemId: string;
    function GetSupportsSnapshots: Boolean;
    function GetSnapshotDirectory: string;
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
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function GetVideoRegions: TArray<TRect>;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function GetUsesPointer: Boolean;
    procedure SetPointer(X, Y: Integer; Valid: Boolean);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    procedure ApplyLiveSettings;
  end;

implementation

uses
  System.UITypes, System.Math, System.Diagnostics, System.Hash, NDS.Cartridge,
  NDS.Sound, Core.SavePaths, Core.PerformanceHints, PCM.Audio;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'L', 'X', 'Y', 'R', 'Mode');

constructor TNDSConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TNDSKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkSpace, vkReturn, vkQ, vkA, vkS, vkW, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  SaveSize := 0;
  ScreenMode := TNDSDisplayMode.Stacked;
  ScreenGap := 0;
end;

function TNDSConfig.DisplayLayout: TNDSDisplayLayout;
begin
  Result := TNDSDisplayLayout.Create(ScreenMode, ScreenGap);
end;

procedure TNDSConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  ScreenMode := TNDSDisplayMode.Stacked;
  if SameText(Ini.ReadString('Video', 'ScreenLayout', 'stacked'), 'side-by-side') then
    ScreenMode := TNDSDisplayMode.SideBySide;
  ScreenGap := EnsureRange(Ini.ReadInteger('Video', 'ScreenGap', 0), 0, NDS_SCREEN_GAP_MAX);
  SaveSize := Ini.ReadInteger('Cartridge', 'SaveSize', 0);
  case SaveSize of
    0, 512, 8192, 65536, 131072, 262144, 524288, 1048576, 8388608:
      ;
  else
    SaveSize := 0;
  end;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    FKeys[B] := ReadEmulatorKey(Ini, 'Keys', KeyNames[B], FKeys[B]);
end;

procedure TNDSConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  var LayoutName := 'stacked';
  if ScreenMode = TNDSDisplayMode.SideBySide then
    LayoutName := 'side-by-side';
  Ini.WriteString('Video', 'ScreenLayout', LayoutName);
  Ini.WriteInteger('Video', 'ScreenGap', DisplayLayout.Gap);
  Ini.WriteInteger('Cartridge', 'SaveSize', SaveSize);
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Ini.WriteInteger('Keys', KeyNames[B], FKeys[B]);
end;

constructor TNDSWorker.Create(const Data: TBytes; SaveSize: Integer; const Storage: IStorage; const SavePath, SnapshotDirectory: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FStorage := Storage;
  FSavePath := SavePath;
  FSnapshotDirectory := SnapshotDirectory;
  FSnapshots := TSnapshotQueue.Create;
  FConsole := TNDSConsole.Create(Data, SaveSize);
  if FStorage.Exists(FSavePath) then
  begin
    FLastBattery := FStorage.ReadBytes(FSavePath);
    FConsole.Cartridge.LoadBattery(FLastBattery);
  end;
end;

destructor TNDSWorker.Destroy;
begin
  Join;
  inherited;
  FConsole.Free;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TNDSWorker.Join;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TNDSWorker.StopAndSave;
begin
  Join;
  Persist;
end;

procedure TNDSWorker.Snapshot(const Name: string; Loading: Boolean);
begin
  FSnapshots.Execute(Self, Name, Loading);
end;

procedure TNDSWorker.Persist;
begin
  if (FConsole = nil) or not FConsole.Cartridge.Dirty then
    Exit;
  var Data := FConsole.Cartridge.BatteryData;
  if (Length(Data) = Length(FLastBattery)) and CompareMem(@Data[0], @FLastBattery[0], Length(Data)) then
    Exit;
  var Stream := TBytesStream.Create(Data);
  try
    SaveStreamAtomically(Stream, FSavePath, FStorage);
    FLastBattery := Data;
    FSaveError := '';
  finally
    Stream.Free;
  end;
end;

procedure TNDSWorker.Configure(const Input: TEmulatorButtons; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Changed: Boolean;
  Volume := EnsureRange(Volume, 0.0, 1.0);
  FLock.Acquire;
  try
    Changed := (FInput <> Input) or (FPaused <> Paused) or
      (FAudioEnabled <> AudioEnabled) or (FVolume <> Volume);
    FInput := Input;
    FPaused := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
  if Changed then
    FWake.SetEvent;
end;

procedure TNDSWorker.Touch(X, Y: Integer; Pressed: Boolean);
begin
  FLock.Acquire;
  try
    FTouchX := X;
    FTouchY := Y;
    FPen := Pressed;
  finally
    FLock.Release;
  end;
end;

procedure TNDSWorker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TNDSWorker.Execute;
const
  FrameRate = NDS_BUS_CLOCK / (2130.0 * 263.0);
var
  Audio: TPCMAudio;
  Performance: TEmulationPerformanceHints;
begin
  Audio := nil;
  Performance := nil;
  var AudioFailed := False;
  var WasPaused := False;
  var Deadline := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
  var StartTime := Deadline;
  var StartFrame := FConsole.FrameNumber;
  try
    try
      Performance := TEmulationPerformanceHints.Create(Round(1000000000.0 / FrameRate), 'Nintendo DS', True);
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
            if Loading then
            begin
              // Parse into an independent machine: even a structurally corrupt payload
              // cannot mutate the running console or its persisted backup.
              var Candidate := TNDSConsole.Create(FConsole.Cartridge.Data);
              try
                LoadCoreSnapshot(Path, 'NDS', FConsole.Cartridge.Data,
                  procedure(State: TStateArchive)
                  begin
                    Candidate.SerializeState(State);
                  end, FStorage);
                var Previous := FConsole;
                FConsole := Candidate;
                Candidate := nil;
                Previous.Free;
                FConsole.Cartridge.MarkBatteryDirty;
              finally
                Candidate.Free;
              end;
              if Audio <> nil then
                Audio.Clear;
              Deadline := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
              StartTime := Deadline;
              StartFrame := FConsole.FrameNumber;
              var Restored: TEmulatorFrame;
              Restored.Width := 256;
              Restored.Height := 384;
              Restored.FrameNumber := StartFrame;
              Restored.FramesPerSecond := 0;
              SetLength(Restored.Pixels, 256 * 384);
              Move(FConsole.Video.Pixels, Restored.Pixels[0], Length(Restored.Pixels) * 4);
              FLock.Acquire;
              try
                FFrame := Restored;
                FAvailable := True;
              finally
                FLock.Release;
              end;
            end
            else
            begin
              SaveCoreSnapshot(Path, 'NDS', FConsole.Cartridge.Data,
                procedure(State: TStateArchive)
                begin
                  FConsole.SerializeState(State);
                end, FStorage);
              SaveSnapshotPreview(Path, 256, 384, 256, @FConsole.Video.Pixels[0], FStorage);
            end;
          end);
        var Input: TEmulatorButtons;
        var Paused, Reset, Enabled, Pen: Boolean;
        var X, Y: Integer;
        var Volume: Single;
        FLock.Acquire;
        try
          Input := FInput;
          Paused := FPaused;
          Reset := FReset;
          FReset := False;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          X := FTouchX;
          Y := FTouchY;
          Pen := FPen;
        finally
          FLock.Release;
        end;
        if Reset then
        begin
          Persist;
          FConsole.Reset;
          if Audio <> nil then
            Audio.Clear;
          Deadline := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
          StartTime := Deadline;
          StartFrame := 0;
          FLock.Acquire;
          try
            FAvailable := False;
          finally
            FLock.Release;
          end;
        end;
        if Audio <> nil then
          Audio.SetPaused(Paused or not Enabled);
        if Paused then
        begin
          if not WasPaused then
          begin
            Performance.Pause;
            Persist;
            if Audio <> nil then
              Audio.Clear;
          end;
          WasPaused := True;
          FWake.WaitFor(20);
          Deadline := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
          StartTime := Deadline;
          StartFrame := FConsole.FrameNumber;
          Continue;
        end;
        WasPaused := False;
        FConsole.SetInput(Input);
        FConsole.SetTouch(X, Y, Pen);
        Performance.BeginWork;
        try
          FConsole.RunFrame;
        finally
          Performance.EndWork;
        end;
        if Terminated then
          Break;
        var Frame: TEmulatorFrame;
        Frame.Width := 256;
        Frame.Height := 384;
        Frame.FrameNumber := FConsole.FrameNumber;
        var Now := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
        Frame.FramesPerSecond := (Frame.FrameNumber - StartFrame) / Max(0.001, Now - StartTime);
        Frame.Pixels := nil;
        SetLength(Frame.Pixels, 256 * 384);
        Move(FConsole.Video.Pixels, Frame.Pixels[0], Length(Frame.Pixels) * 4);
        FLock.Acquire;
        try
          FFrame := Frame;
          FAvailable := True;
        finally
          FLock.Release;
        end;
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
          begin
            var Format: TPCMAudioFormat;
            Format.SampleRate := NDS_SAMPLE_RATE;
            Format.Channels := 2;
            Format.BlockFrames := 2048;
            Format.BlockCount := 4;
            Audio := TPCMAudio.Create(Format);
          end;
          var Samples := Copy(FConsole.Sound.Samples, 0, FConsole.Sound.SampleFrames * 2);
          if Volume <> 1 then
            for var I := 0 to High(Samples) do
              Samples[I] := Round(Samples[I] * Volume);
          Audio.Submit(Samples, Length(Samples) div 2);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := E.ClassName + ': ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioFailed := True;
          end;
        end;
        if FConsole.FrameNumber mod 60 = 0 then
          Persist;
        Deadline := Deadline + 1 / FrameRate;
        while not Terminated do
        begin
          if not Performance.WaitUntil(FWake, Round(Deadline * TStopwatch.Frequency)) then
            Break;
        end;
        Now := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
        if Deadline < Now - 0.1 then
          Deadline := Now;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.ClassName + ': ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    Audio.Free;
    Performance.Free;
    try
      Persist;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FSaveError := E.ClassName + ': ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  end;
end;

function TNDSWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TNDSWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
    if Result = '' then
    begin
      Result := FSaveError;
      FSaveError := '';
    end;
  finally
    FLock.Release;
  end;
end;

function TNDSWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

constructor TNDSCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  if (Stream.Size < $200) or (Stream.Size > NDS_ROM_MAX_SIZE) then
    raise EReadError.Create('Invalid NDS image size');
  SetLength(FData, Stream.Size);
  Stream.Position := 0;
  var Offset := 0;
  while Offset < Length(FData) do
  begin
    TStorage.CheckReadCancelled;
    var Count := Min(65536, Length(FData) - Offset);
    Stream.ReadBuffer(FData[Offset], Count);
    Inc(Offset, Count);
  end;
  if not IsNDSROM(FData) then
    raise EReadError.Create('Invalid Nintendo DS cartridge');
  FConfigObject := TNDSConfig.Create(FStorage.ConfigFile('nds'), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FPresentedLayout := FConfigObject.DisplayLayout;
  var Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSavePath := FStorage.GameSave('nds', RomName, Hash.HashAsString);
  FSnapshotDirectory := FStorage.GameSnapshots('nds', RomName, Hash.HashAsString);
end;

destructor TNDSCoreAdapter.Destroy;
begin
  FWorker.Free;
  inherited;
end;

procedure TNDSCoreAdapter.Configure;
begin
  if FWorker <> nil then
    FWorker.Configure(FKeyboard + FGamepad, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TNDSCoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  FSourceFrame := Default(TEmulatorFrame);
  FPresentedLayout := FConfigObject.DisplayLayout;
  FWorker := TNDSWorker.Create(FData, FConfigObject.SaveSize, FStorage, FSavePath, FSnapshotDirectory);
  Configure;
  FWorker.Touch(FPointerX, FPointerY, FPen and FPointerValid);
  FWorker.Start;
end;

procedure TNDSCoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;
  FWorker.StopAndSave;
  FError := FWorker.TakeError;
  FAudioError := FWorker.TakeAudioError;
  FreeAndNil(FWorker);
end;

procedure TNDSCoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TNDSCoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TNDSCoreAdapter.Reset;
begin
  FPaused := False;
  if FWorker <> nil then
    FWorker.RequestReset;
  Configure;
end;

procedure TNDSCoreAdapter.ClearInput;
begin
  FKeyboard := [];
  FGamepad := [];
  FPen := False;
  if FWorker <> nil then
    FWorker.Touch(0, 0, False);
  Configure;
end;

procedure TNDSCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code <> 0 then
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if (B in NDS_BUTTONS) and (FConfigObject.Keys[B] = Code) then
        if Pressed then
          Include(FKeyboard, B)
        else
          Exclude(FKeyboard, B);
  Configure;
end;

procedure TNDSCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input.Buttons * NDS_BUTTONS;
  Configure;
end;

function TNDSCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  Result.Buttons := FKeyboard + FGamepad;
end;

function TNDSCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Configure;
  Result := False;
  if FWorker = nil then
    Exit;
  var Source: TEmulatorFrame;
  var NewFrame := FWorker.TryGetFrame(Source);
  if NewFrame then
    FSourceFrame := Source;
  var Layout := FConfigObject.DisplayLayout;
  if (Length(FSourceFrame.Pixels) = 0) or (not NewFrame and Layout.SameAs(FPresentedLayout)) then
    Exit;
  Layout.Compose(FSourceFrame, Frame);
  // Pointer coordinates refer to the frame actually delivered to the frontend,
  // including while paused and immediately after a live layout change.
  FPresentedLayout := Layout;
  Result := True;
end;

function TNDSCoreAdapter.GetVideoRegions: TArray<TRect>;
begin
  Result := FPresentedLayout.Screens;
end;

function TNDSCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TNDSCoreAdapter.TakeAudioError: string;
begin
  Result := FAudioError;
  FAudioError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeAudioError;
end;

function TNDSCoreAdapter.GetName: string;
begin
  Result := 'Nintendo DS';
end;

function TNDSCoreAdapter.GetSystemId: string;
begin
  Result := 'nds';
end;

function TNDSCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TNDSCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

function TNDSCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

function TNDSCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TNDSCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

procedure TNDSCoreAdapter.InsertCoin1;
begin
end;

procedure TNDSCoreAdapter.InsertCoin2;
begin
end;

procedure TNDSCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOperation.Create('Nintendo DS core is not running');
  FWorker.Snapshot(Name, False);
end;

procedure TNDSCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOperation.Create('Nintendo DS core is not running');
  FWorker.Snapshot(Name, True);
end;

function TNDSCoreAdapter.GetUsesPointer: Boolean;
begin
  Result := True;
end;

procedure TNDSCoreAdapter.SetPointer(X, Y: Integer; Valid: Boolean);
begin
  FPointerValid := FPresentedLayout.TouchPoint(X, Y, FPointerX, FPointerY) and Valid;
  if FWorker <> nil then
    FWorker.Touch(FPointerX, FPointerY, FPen and FPointerValid);
end;

procedure TNDSCoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  FPen := Buttons and 1 <> 0;
  if FWorker <> nil then
    FWorker.Touch(FPointerX, FPointerY, FPen and FPointerValid);
end;

procedure TNDSCoreAdapter.ApplyLiveSettings;
begin
  if not FPresentedLayout.SameAs(FConfigObject.DisplayLayout) then
  begin
    FPen := False;
    FPointerValid := False;
    if FWorker <> nil then
      FWorker.Touch(0, 0, False);
  end;
  Configure;
end;

end.

