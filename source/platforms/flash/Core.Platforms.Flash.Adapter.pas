unit Core.Platforms.Flash.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  Core.Storage, Core.Emulation, Core.Input.Touch, Flash.Player,
  PCM.Audio.Backend;

type
  TFlashInputEvent = record
    Kind, Code, X, Y: Integer;
    Pressed, Valid: Boolean;
    Buttons: Byte;
    QueuedAt: Int64;
  end;

  TFlashAudioFactory = reference to function(const Format: TPCMAudioFormat): IPCMAudioBackend;

  TFlashFrameMetrics = record
    FrameNumber: UInt64;
    ClockFrequency, WorkTicks, TickTicks, RenderTicks, AudioTicks, InputTicks: Int64;
    // Time from the oldest dispatched input to frame publication.
    InputLatencyTicks: Int64;
    GCRootTicks, GCMarkTicks, GCSweepTicks: Int64;
    GCPendingObjects: Integer;
    // Live tracked object bodies and ByteArray capacity at the last collection in this frame.
    GCLiveObjectBytes: Int64;
    GCLiveObjects, GCByteArrayCapacity: Integer;
    InputEvents, AudioUnderruns, AudioDroppedBlocks, Collections: Integer;
  end;

  TFlashFrameObserver = reference to procedure(const Metrics: TFlashFrameMetrics);

  TFlashCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationMouseInput, IEmulationPointerInput, IEmulationTouchInput, IEmulationAudioDiagnostics)
  private
    FData: TBytes;
    FStorage: IStorage;
    FOrigin, FResourceRoot: string;
    FPlayer: TFlashPlayer;
    FLock: TCriticalSection;
    FThread: TThread;
    FEvents: TQueue<TFlashInputEvent>;
    FConfig: IEmulatorConfig;
    FFrame: TEmulatorFrame;
    FPaused, FReady, FStopping: Boolean;
    FError: string;
    FAudioError: string;
    FAudioFactory: TFlashAudioFactory;
    FFrameObserver: TFlashFrameObserver;
    FAudioReset, FAudioBroken: Boolean;
    FAudioGeneration: Cardinal;
    FAudioThread: TThread;
    FAudioWake: TEvent;
    FAudioReady: TQueue<TArray<SmallInt>>;
    FAudioUnderruns, FAudioDroppedBlocks: Integer;
    FInput: TEmulatorInput;
    FPointerX, FPointerY: Integer;
    FPointerValid: Boolean;
    FPointerDirty: Boolean;
    FButtons: Byte;
    FTouchTracker: TEmulationTouchTracker;
    FTouchOverflow, FSuppressMouse: Boolean;
    function ReadResource(const BaseURI, URL: string; out Data: TBytes; out ResolvedURI: string): Boolean;
    function SharedSavePath(const Origin, Key: string): string;
    function ReadSharedObject(const Origin, Key: string; out Data: TBytes): Boolean;
    function WriteSharedObject(const Origin, Key: string; const Data: TBytes): Boolean;
    procedure Execute;
    procedure ExecuteAudio;
    procedure InvalidateAudioLocked;
    procedure QueuePCM(const Samples: TArray<SmallInt>; Generation: Cardinal);
    procedure QueueLocked(const Event: TFlashInputEvent);
    procedure Queue(const Event: TFlashInputEvent);
  public
    // Called on the worker after the frame is available to consumers.
    constructor Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TFlashAudioFactory = nil; const FrameObserver: TFlashFrameObserver = nil);
    destructor Destroy; override;
    function GetName: string;
    function GetSystemId: string;
    function GetSupportsSnapshots: Boolean;
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
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    function GetUsesPointer: Boolean;
    procedure SetPointer(X, Y: Integer; Valid: Boolean);
    function GetUsesTouch: Boolean;
    procedure SendTouch(const Event: TEmulationTouchEvent);
  end;

implementation

uses
  System.Hash, System.Diagnostics, System.IOUtils, System.NetEncoding,
  System.Math, System.UITypes, Core.Emulation.Config, SWF.Reader, SWF.Sound,
  PCM.Audio, AVM2.Runtime;

constructor TFlashCoreAdapter.Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TFlashAudioFactory; const FrameObserver: TFlashFrameObserver);
var
  S: IStorage;
begin
  inherited Create;
  FAudioFactory := AudioFactory;
  FFrameObserver := FrameObserver;
  FLock := TCriticalSection.Create;
  FAudioWake := TEvent.Create(nil, False, False, '');
  FAudioReady := TQueue<TArray<SmallInt>>.Create;
  FEvents := TQueue<TFlashInputEvent>.Create;
  if (Input.Size - Input.Position < 8) or (Input.Size - Input.Position > 64 * 1024 * 1024) then
    raise ESWFError.Create('Invalid SWF size');
  SetLength(FData, Input.Size - Input.Position);
  Input.ReadBuffer(FData[0], Length(FData));
  S := Storage;
  if S = nil then
    S := TStorage.Default;
  FStorage := S;
  FOrigin := RomName;
  if (FOrigin <> '') and (Pos('://', FOrigin) = 0) then
  begin
    if not TPath.IsPathRooted(FOrigin) then
      FOrigin := TPath.Combine(S.RomFolder('flash'), FOrigin);
    if Pos('://', FOrigin) = 0 then
    begin
      FOrigin := TPath.GetFullPath(FOrigin);
      FResourceRoot := IncludeTrailingPathDelimiter(ExtractFilePath(FOrigin));
    end;
  end;
  FConfig := TEmulatorConfigBase.Create(S.ConfigFile('flash'), S);
  FConfig.Load;
  FPlayer := TFlashPlayer.Create(FData, FOrigin, ReadResource);
  FPlayer.ReadSharedObject := ReadSharedObject;
  FPlayer.WriteSharedObject := WriteSharedObject;
end;

function TFlashCoreAdapter.SharedSavePath(const Origin, Key: string): string;
begin
  Result := FStorage.GameSave('flash', FOrigin, THashSHA2.GetHashString(Origin + #0 + Key));
end;

function TFlashCoreAdapter.ReadSharedObject(const Origin, Key: string; out Data: TBytes): Boolean;
var
  Stream: TStream;
  Location: string;
begin
  Result := False;
  Data := nil;
  Location := SharedSavePath(Origin, Key);
  try
    if not FStorage.Exists(Location) then
      Exit;
    Stream := FStorage.OpenRead(Location);
    try
      if (Stream.Size <= 0) or (Stream.Size > 1024 * 1024) then
        Exit;
      SetLength(Data, Stream.Size);
      Stream.ReadBuffer(Data[0], Length(Data));
      Result := True;
    finally
      Stream.Free;
    end;
  except
    on E: EInOutError do
      Data := nil;
    on E: EStreamError do
      Data := nil;
  end;
end;

function TFlashCoreAdapter.WriteSharedObject(const Origin, Key: string; const Data: TBytes): Boolean;
var
  Stream: TBytesStream;
  Location: string;
begin
  Result := False;
  Location := SharedSavePath(Origin, Key);
  try
    if Length(Data) = 0 then
    begin
      if FStorage.Exists(Location) then
        FStorage.Delete(Location);
    end
    else
    begin
      Stream := TBytesStream.Create(Data);
      try
        FStorage.WriteAtomic(Location, Stream);
      finally
        Stream.Free;
      end;
    end;
    Result := True;
  except
    on E: EInOutError do
      Exit;
    on E: EStreamError do
      Exit;
    on E: EOSError do
      Exit;
  end;
end;

function TFlashCoreAdapter.ReadResource(const BaseURI, URL: string; out Data: TBytes; out ResolvedURI: string): Boolean;
var
  RelativeName, SourceURI: string;
  I: Integer;
  Stream: TStream;
begin
  Result := False;
  Data := nil;
  ResolvedURI := '';
  if FResourceRoot = '' then
    Exit;
  RelativeName := URL;
  I := Pos('?', RelativeName);
  if I > 0 then
    SetLength(RelativeName, I - 1);
  I := Pos('#', RelativeName);
  if I > 0 then
    SetLength(RelativeName, I - 1);
  RelativeName := TNetEncoding.URL.Decode(RelativeName.Replace('+', '%2B'));
  if (RelativeName = '') or (Pos(':', RelativeName) > 0) or
    TPath.IsPathRooted(RelativeName) or RelativeName.StartsWith('/') or
    RelativeName.StartsWith('\') then
    Exit;
  RelativeName := StringReplace(RelativeName, '/', PathDelim, [rfReplaceAll]);
  SourceURI := BaseURI;
  if SourceURI = '' then
    SourceURI := FOrigin;
  ResolvedURI := TPath.GetFullPath(TPath.Combine(ExtractFilePath(SourceURI), RelativeName));
  {$IFDEF MSWINDOWS}
  var IgnoreCase := True;
  {$ELSE}
  var IgnoreCase := False;
  {$ENDIF}
  if not ResolvedURI.StartsWith(FResourceRoot, IgnoreCase) then
    Exit;
  if not FStorage.Exists(ResolvedURI) then
    Exit;
  Stream := FStorage.OpenRead(ResolvedURI);
  try
    if (Stream.Size < 8) or (Stream.Size > 64 * 1024 * 1024) then
      Exit;
    SetLength(Data, Stream.Size);
    Stream.ReadBuffer(Data[0], Length(Data));
    Result := True;
  finally
    Stream.Free;
  end;
end;

destructor TFlashCoreAdapter.Destroy;
begin
  Stop;
  FPlayer.Free;
  FAudioReady.Free;
  FAudioWake.Free;
  FEvents.Free;
  FLock.Free;
  inherited;
end;

function TFlashCoreAdapter.GetName: string;
begin
  Result := 'Flash (AS1/AS2, initial AS3)';
end;

function TFlashCoreAdapter.GetSystemId: string;
begin
  Result := 'flash';
end;

function TFlashCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := False;
end;

function TFlashCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TFlashCoreAdapter.InsertCoin1;
begin
end;

procedure TFlashCoreAdapter.InsertCoin2;
begin
end;

procedure TFlashCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FLock.Acquire;
  try
    FStopping := False;
    FError := '';
    FAudioError := '';
    FAudioUnderruns := 0;
    FAudioDroppedBlocks := 0;
    FAudioReset := True;
    InvalidateAudioLocked;
  finally
    FLock.Release;
  end;
  FAudioThread := TThread.CreateAnonymousThread(
    procedure
    begin
      ExecuteAudio;
    end);
  FAudioThread.FreeOnTerminate := False;
  FAudioThread.Start;
  try
    FThread := TThread.CreateAnonymousThread(
      procedure
      begin
        Execute;
      end);
    FThread.FreeOnTerminate := False;
    FThread.Start;
  except
    Stop;
    raise;
  end;
end;

procedure TFlashCoreAdapter.Stop;
begin
  if FLock = nil then
    Exit;
  FLock.Acquire;
  try
    FStopping := True;
    if FAudioWake <> nil then
      FAudioWake.SetEvent;
  finally
    FLock.Release;
  end;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  if FAudioThread <> nil then
  begin
    FAudioThread.WaitFor;
    FreeAndNil(FAudioThread);
  end;
end;

procedure TFlashCoreAdapter.Pause;
var
  E: TFlashInputEvent;
  I: Integer;
begin
  FLock.Acquire;
  try
    FPaused := True;
    FAudioReset := True;
    InvalidateAudioLocked;
    // Resume may happen before the worker observes the pause. Discard old pointer
    // events now, preserving the keyboard/gamepad state carried by the queue.
    for I := 1 to FEvents.Count do
    begin
      E := FEvents.Dequeue;
      if not (E.Kind in [1, 4]) then
        FEvents.Enqueue(E);
    end;
    FTouchTracker := Default(TEmulationTouchTracker);
    FTouchOverflow := False;
    FSuppressMouse := True;
    FButtons := 0;
    FPointerDirty := True;
    E := Default(TFlashInputEvent);
    E.Kind := 4;
    QueueLocked(E);
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.Resume;
begin
  FLock.Acquire;
  try
    FPaused := False;
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.Reset;
begin
  Stop;
  FreeAndNil(FPlayer);
  FPlayer := TFlashPlayer.Create(FData, FOrigin, ReadResource);
  FPlayer.ReadSharedObject := ReadSharedObject;
  FPlayer.WriteSharedObject := WriteSharedObject;
  FLock.Acquire;
  try
    FEvents.Clear;
    FFrame := Default(TEmulatorFrame);
    FReady := False;
    FInput := Default(TEmulatorInput);
    FButtons := 0;
    FPointerValid := False;
    FPointerDirty := True;
    FTouchTracker := Default(TEmulationTouchTracker);
    FTouchOverflow := False;
    FSuppressMouse := True;
  finally
    FLock.Release;
  end;
  Start;
end;

procedure TFlashCoreAdapter.QueueLocked(const Event: TFlashInputEvent);
var
  E: TFlashInputEvent;
begin
  if FEvents.Count >= 4096 then
  begin
    FEvents.Clear;
    E := Default(TFlashInputEvent);
    E.Kind := 3;
    FEvents.Enqueue(E);
    FTouchOverflow := FTouchOverflow or FTouchTracker.Down;
    FTouchTracker := Default(TEmulationTouchTracker);
    FButtons := 0;
    FSuppressMouse := True;
    FPointerDirty := True;
  end;
  if (Event.Kind = 4) and FTouchOverflow then
    Exit;
  if Assigned(FFrameObserver) then
  begin
    E := Event;
    E.QueuedAt := TStopwatch.GetTimeStamp;
    FEvents.Enqueue(E);
  end
  else
    FEvents.Enqueue(Event);
end;

procedure TFlashCoreAdapter.Queue(const Event: TFlashInputEvent);
begin
  FLock.Acquire;
  try
    QueueLocked(Event);
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.ClearInput;
begin
  FLock.Acquire;
  try
    FEvents.Clear;
    FInput := Default(TEmulatorInput);
    FButtons := 0;
    FPointerValid := False;
    FPointerDirty := True;
    FTouchTracker := Default(TEmulationTouchTracker);
    FTouchOverflow := False;
    FSuppressMouse := True;
    var E := Default(TFlashInputEvent);
    E.Kind := 3;
    FEvents.Enqueue(E);
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code > 255 then
    Exit;
  var E := Default(TFlashInputEvent);
  E.Kind := 0;
  E.Code := Code;
  E.Pressed := Pressed;
  Queue(E);
end;

procedure TFlashCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Codes: array[TEmulatorButton] of Integer = (38, 40, 37, 39, 32, 88, 16, 13, 90, 65, 83, 68, 27);
begin
  FLock.Acquire;
  try
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if (B in Input.Buttons) <> (B in FInput.Buttons) then
      begin
        var E := Default(TFlashInputEvent);
        E.Kind := 2;
        E.Code := Codes[B];
        E.Pressed := B in Input.Buttons;
        QueueLocked(E);
      end;
    FInput := Input;
  finally
    FLock.Release;
  end;
end;

function TFlashCoreAdapter.GetInputState: TEmulatorInput;
begin
  FLock.Acquire;
  try
    Result := FInput;
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.SaveSnapshot(const Name: string);
begin
  raise ESWFError.Create('Flash snapshots are not implemented');
end;

procedure TFlashCoreAdapter.LoadSnapshot(const Name: string);
begin
  raise ESWFError.Create('Flash snapshots are not implemented');
end;

function TFlashCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FReady;
    if Result then
    begin
      Frame := FFrame;
      FReady := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TFlashCoreAdapter.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TFlashCoreAdapter.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

function TFlashCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TFlashCoreAdapter.IsPaused: Boolean;
begin
  FLock.Acquire;
  try
    Result := FPaused;
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  FLock.Acquire;
  try
    // The common frontend already supplies the primary mouse button as touch.
    // Polling must not press it again or overwrite a held finger's position.
    if FTouchTracker.Down or FTouchOverflow or FSuppressMouse then
    begin
      FButtons := 0;
      if not FTouchTracker.Down and not FTouchOverflow and ((Buttons and 1) = 0) then
        FSuppressMouse := False;
      Exit;
    end;
    if FButtons = Buttons then
      Exit;
    FButtons := Buttons;
    FPointerDirty := True;
  finally
    FLock.Release;
  end;
end;

function TFlashCoreAdapter.GetUsesPointer: Boolean;
begin
  Result := True;
end;

procedure TFlashCoreAdapter.SetPointer(X, Y: Integer; Valid: Boolean);
begin
  FLock.Acquire;
  try
    if FTouchTracker.Down or FTouchOverflow then
      Exit;
    if (X = FPointerX) and (Y = FPointerY) and (Valid = FPointerValid) and not FPointerDirty then
      Exit;
    FPointerDirty := False;
    FPointerX := X;
    FPointerY := Y;
    FPointerValid := Valid;
    var E := Default(TFlashInputEvent);
    E.Kind := 1;
    E.X := X;
    E.Y := Y;
    E.Valid := Valid;
    E.Buttons := FButtons;
    QueueLocked(E);
  finally
    FLock.Release;
  end;
end;

function TFlashCoreAdapter.GetUsesTouch: Boolean;
begin
  Result := True;
end;

procedure TFlashCoreAdapter.SendTouch(const Event: TEmulationTouchEvent);
var
  Mapped: TEmulationTouchEvent;
  E: TFlashInputEvent;
  Valid: Boolean;
begin
  if Event.Contact <> 0 then
    Exit;
  FLock.Acquire;
  try
    if FTouchOverflow then
    begin
      if Event.Phase in [TEmulationTouchPhase.Up, TEmulationTouchPhase.Cancel] then
        FTouchOverflow := False;
      Exit;
    end;
    // Flash publishes the unrotated stage directly in frame pixels.
    Valid := not FPaused and not FStopping and (Event.X >= 0) and (Event.Y >= 0) and
      (Event.X < FPlayer.Movie.Width) and (Event.Y < FPlayer.Movie.Height);
    if not FTouchTracker.Update(Event.Phase, Event.X, Event.Y, Valid, Mapped) then
      Exit;
    FSuppressMouse := True;
    FButtons := 0;
    FPointerDirty := True;
    E := Default(TFlashInputEvent);
    E.Kind := 4;
    E.X := Mapped.X;
    E.Y := Mapped.Y;
    E.Valid := Mapped.Phase <> TEmulationTouchPhase.Cancel;
    if Mapped.Phase in [TEmulationTouchPhase.Down, TEmulationTouchPhase.Move] then
      E.Buttons := 1;
    QueueLocked(E);
  finally
    FLock.Release;
  end;
end;

const
  FlashAudioFrames = 512;
  FlashAudioDeviceBlocks = 12;
  FlashAudioTargetBlocks = 6;
  FlashAudioPreparedBlocks = FlashAudioDeviceBlocks - FlashAudioTargetBlocks;

procedure TFlashCoreAdapter.InvalidateAudioLocked;
begin
  // Pausing or disabling the output invalidates both the producer's blocks
  // and anything the output worker has not yet submitted to its device.
  Inc(FAudioGeneration);
  FAudioReady.Clear;
  FAudioBroken := False;
  FAudioWake.SetEvent;
end;

procedure TFlashCoreAdapter.QueuePCM(const Samples: TArray<SmallInt>; Generation: Cardinal);
begin
  FLock.Acquire;
  try
    if FStopping or FPaused or FAudioBroken or (Generation <> FAudioGeneration) then
      Exit;
    if FAudioReady.Count = FlashAudioPreparedBlocks then
    begin
      FAudioReady.Dequeue;
      Inc(FAudioDroppedBlocks);
    end;
    FAudioReady.Enqueue(Samples);
    FAudioWake.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TFlashCoreAdapter.ExecuteAudio;
var
  Audio: TPCMAudio;
  Silence, Samples: TArray<SmallInt>;
  Format: TPCMAudioFormat;
  State: TPCMAudioQueueState;
  Generation, RequestedGeneration: Cardinal;
  Pending, Primed, Empty, Taken: Boolean;
  WaitMS: Cardinal;
  PendingBlocks, InitialSilence: Integer;

  function OpenDevice: TPCMAudio;
  var
    Backend: IPCMAudioBackend;
  begin
    // Release the factory's interface reference before entering the worker loop.
    if not Assigned(FAudioFactory) then
      Exit(TPCMAudio.Create(Format));
    Backend := FAudioFactory(Format);
    Result := TPCMAudio.Create(Format, Backend);
  end;

  function CanSubmit: Boolean;
  begin
    FLock.Acquire;
    try
      Result := not FStopping and not FPaused and (Generation = FAudioGeneration);
    finally
      FLock.Release;
    end;
  end;

begin
  Audio := nil;
  Generation := 0;
  Primed := False;
  Empty := True;
  Format.SampleRate := SWFSoundRate;
  Format.Channels := 2;
  Format.BlockFrames := FlashAudioFrames;
  Format.BlockCount := FlashAudioDeviceBlocks;
  SetLength(Silence, FlashAudioFrames * Format.Channels);
  try
    while True do
    begin
      FLock.Acquire;
      try
        if FStopping then
          Exit;
        RequestedGeneration := FAudioGeneration;
        Pending := not FPaused and (FAudioReady.Count <> 0);
      finally
        FLock.Release;
      end;
      if Generation <> RequestedGeneration then
      begin
        FreeAndNil(Audio);
        Generation := RequestedGeneration;
        Primed := False;
        Empty := True;
      end;
      WaitMS := UInt32($FFFFFFFF);
      try
        if (Audio = nil) and Pending then
          Audio := OpenDevice;
        if Audio <> nil then
        begin
          WaitMS := 4;
          State := Audio.QueueState;
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
          if not State.DeviceOpen then
            raise EInOutError.Create('Flash audio output is unavailable');
          FLock.Acquire;
          try
            if FStopping then
              Exit;
            if Generation <> FAudioGeneration then
              Continue;
            if Primed and not Empty and (State.QueuedBlocks = 0) then
              Inc(FAudioUnderruns);
            Empty := State.QueuedBlocks = 0;
            PendingBlocks := FAudioReady.Count;
            Taken := not FPaused and (PendingBlocks > 0) and (State.QueuedBlocks < FlashAudioTargetBlocks);
            if Taken then
              Samples := FAudioReady.Dequeue;
          finally
            FLock.Release;
          end;
          if Taken then
          begin
            if not Primed then
            begin
              // Prefer queued sound to startup silence. The combined ready
              // and device queues have the same cap as the previous device.
              InitialSilence := Max(0, FlashAudioTargetBlocks - PendingBlocks);
              for var I := 1 to InitialSilence do
              begin
                if not CanSubmit then
                  Break;
                Audio.Submit(Silence, FlashAudioFrames);
              end;
            end;
            if not CanSubmit then
            begin
              Samples := nil;
              Continue;
            end;
            if Samples = nil then
              Audio.Submit(Silence, FlashAudioFrames)
            else
              Audio.Submit(Samples, FlashAudioFrames);
            Samples := nil;
            Primed := True;
            Empty := False;
            Continue;
          end;
        end;
      except
        on E: Exception do
        begin
          FreeAndNil(Audio);
          Samples := nil;
          FLock.Acquire;
          try
            if Generation = FAudioGeneration then
            begin
              FAudioError := E.Message;
              FAudioBroken := True;
              FAudioReady.Clear;
            end;
          finally
            FLock.Release;
          end;
        end;
      end;
      FAudioWake.WaitFor(WaitMS);
    end;
  finally
    Audio.Free;
  end;
end;

procedure TFlashCoreAdapter.Execute;
var
  Watch: TStopwatch;
  Deadline, AudioDeadline: Double;
  Events: TArray<TFlashInputEvent>;
  Paused, Stopping, WasPaused, ResetAudio, AudioStarted, AudioEnabled: Boolean;
  AudioGeneration: Cardinal;
  Keyboard, Pad: array[0..255] of Boolean;
  Observe: Boolean;
  Metrics: TFlashFrameMetrics;
  OldestInput, InputStarted, FrameStarted, PhaseStarted, PhaseEnded: Int64;

  procedure PumpAudio;
  var
    Samples: TArray<SmallInt>;
    Now, Volume: Double;
    Enabled: Boolean;
  begin
    Enabled := FConfig.AudioEnabled;
    if AudioEnabled and not Enabled then
    begin
      FLock.Acquire;
      try
        InvalidateAudioLocked;
      finally
        FLock.Release;
      end;
      AudioStarted := False;
    end;
    AudioEnabled := Enabled;
    Now := Watch.Elapsed.TotalMilliseconds;
    if AudioDeadline < Now - 250 then
      AudioDeadline := Now;
    Volume := FConfig.AudioVolume;
    while AudioDeadline <= Now do
    begin
      Samples := FPlayer.MixAudio(FlashAudioFrames);
      AudioDeadline := AudioDeadline + FlashAudioFrames * 1000 / SWFSoundRate;
      if not Enabled or (not AudioStarted and (Samples = nil)) then
        Continue;
      AudioStarted := True;
      if Volume <> 1 then
        for var I := 0 to High(Samples) do
          Samples[I] := SmallInt(EnsureRange(Round(Samples[I] * Volume), Int64(-32768), Int64(32767)));
      QueuePCM(Samples, AudioGeneration);
    end;
  end;

begin
  AudioStarted := False;
  AudioEnabled := FConfig.AudioEnabled;
  Observe := Assigned(FFrameObserver);
  Metrics := Default(TFlashFrameMetrics);
  OldestInput := 0;
  InputStarted := 0;
  PhaseStarted := 0;
  FrameStarted := 0;
  if Observe then
  begin
    FPlayer.OnAVM2Collection :=
      procedure(const Stats: TAVM2CollectionStats)
      begin
        Inc(Metrics.Collections);
        Inc(Metrics.GCRootTicks, Stats.RootTicks);
        Inc(Metrics.GCMarkTicks, Stats.MarkTicks);
        Inc(Metrics.GCSweepTicks, Stats.SweepTicks);
        Metrics.GCLiveObjectBytes := Stats.ObjectBytesAfter;
        Metrics.GCLiveObjects := Stats.LiveObjects;
        Metrics.GCByteArrayCapacity := Stats.ByteArrayCapacityAfter;
        Metrics.GCPendingObjects := Stats.PendingObjects;
      end;
    FPlayer.OnAVM2Reclaim :=
      procedure(SweepTicks: Int64; PendingObjects: Integer)
      begin
        Inc(Metrics.GCSweepTicks, SweepTicks);
        Metrics.GCPendingObjects := PendingObjects;
      end;
  end;
  try
    try
      FillChar(Keyboard, SizeOf(Keyboard), 0);
      FillChar(Pad, SizeOf(Pad), 0);
      WasPaused := False;
      Watch := TStopwatch.StartNew;
      Deadline := 0;
      AudioDeadline := 0;
      while True do
      begin
        FLock.Acquire;
        try
          Stopping := FStopping;
          Paused := FPaused;
          Events := FEvents.ToArray;
          FEvents.Clear;
          ResetAudio := FAudioReset;
          AudioGeneration := FAudioGeneration;
          FAudioReset := False;
        finally
          FLock.Release;
        end;
        if Stopping then
          Exit;
        if ResetAudio then
        begin
          AudioStarted := False;
          AudioDeadline := Watch.Elapsed.TotalMilliseconds;
        end;
        if Paused and not WasPaused then
        begin
          FPlayer.ClearInput;
          Metrics := Default(TFlashFrameMetrics);
          OldestInput := 0;
        end;
        if WasPaused and not Paused then
          for var K := 0 to 255 do
            FPlayer.Key(K, Keyboard[K] or Pad[K]);
        WasPaused := Paused;
        if Observe and (Length(Events) <> 0) and not Paused then
        begin
          InputStarted := TStopwatch.GetTimeStamp;
          Inc(Metrics.InputEvents, Length(Events));
          for var E in Events do
            if (E.QueuedAt <> 0) and ((OldestInput = 0) or (E.QueuedAt < OldestInput)) then
              OldestInput := E.QueuedAt;
        end;
        for var E in Events do
          case E.Kind of
            0, 2:
              begin
                if E.Kind = 0 then
                  Keyboard[E.Code] := E.Pressed
                else
                  Pad[E.Code] := E.Pressed;
                if not Paused then
                  FPlayer.Key(E.Code, Keyboard[E.Code] or Pad[E.Code]);
              end;
            1, 4:
              if not Paused then
                FPlayer.Pointer(E.X, E.Y, E.Valid, E.Buttons);
            3:
              begin
                FPlayer.ClearInput;
                FillChar(Keyboard, SizeOf(Keyboard), 0);
                FillChar(Pad, SizeOf(Pad), 0);
              end;
          end;
        if Observe and (Length(Events) <> 0) and not Paused then
          Inc(Metrics.InputTicks, TStopwatch.GetTimeStamp - InputStarted);
        if Paused then
        begin
          Deadline := Watch.Elapsed.TotalMilliseconds;
          AudioDeadline := Deadline;
          TThread.Sleep(2);
          Continue;
        end;
        if Watch.Elapsed.TotalMilliseconds < Deadline then
        begin
          PumpAudio;
          TThread.Sleep(1);
          Continue;
        end;
        if Observe then
          FrameStarted := TStopwatch.GetTimeStamp;
        FPlayer.Tick;
        if Observe then
        begin
          PhaseStarted := TStopwatch.GetTimeStamp;
          Metrics.TickTicks := PhaseStarted - FrameStarted;
        end;
        PumpAudio;
        if Observe then
        begin
          PhaseEnded := TStopwatch.GetTimeStamp;
          Metrics.AudioTicks := PhaseEnded - PhaseStarted;
          PhaseStarted := PhaseEnded;
        end;
        var Frame := Default(TEmulatorFrame);
        Frame.Width := FPlayer.Movie.Width;
        Frame.Height := FPlayer.Movie.Height;
        // Render returns a new ARGB buffer. Publish that buffer directly.
        Frame.Pixels := TArray<TAlphaColor>(FPlayer.Render);
        if Observe then
        begin
          PhaseEnded := TStopwatch.GetTimeStamp;
          Metrics.RenderTicks := PhaseEnded - PhaseStarted;
          PhaseStarted := PhaseEnded;
        end;
        // Prepare blocks that became due during rendering before the next Tick.
        PumpAudio;
        if Observe then
          Inc(Metrics.AudioTicks, TStopwatch.GetTimeStamp - PhaseStarted);
        Frame.FrameNumber := FPlayer.FrameNumber;
        Frame.FramesPerSecond := FPlayer.Movie.FPS;
        FLock.Acquire;
        try
          FFrame := Frame;
          FReady := True;
          if Observe then
          begin
            Metrics.AudioUnderruns := FAudioUnderruns;
            Metrics.AudioDroppedBlocks := FAudioDroppedBlocks;
          end;
          FAudioUnderruns := 0;
          FAudioDroppedBlocks := 0;
        finally
          FLock.Release;
        end;
        if Observe then
        begin
          PhaseEnded := TStopwatch.GetTimeStamp;
          Metrics.FrameNumber := Frame.FrameNumber;
          Metrics.ClockFrequency := TStopwatch.Frequency;
          Metrics.WorkTicks := Metrics.InputTicks + PhaseEnded - FrameStarted;
          if OldestInput <> 0 then
            Metrics.InputLatencyTicks := PhaseEnded - OldestInput;
          FFrameObserver(Metrics);
          Metrics := Default(TFlashFrameMetrics);
          OldestInput := 0;
        end;
        Deadline := Deadline + 1000 / FPlayer.Movie.FPS;
        if Deadline < Watch.Elapsed.TotalMilliseconds - 250 then
          Deadline := Watch.Elapsed.TotalMilliseconds;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    if Observe then
    begin
      FPlayer.OnAVM2Reclaim := nil;
      FPlayer.OnAVM2Collection := nil;
    end;
  end;
end;

end.

