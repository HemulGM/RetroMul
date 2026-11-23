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
  end;

  TFlashAudioFactory = reference to function(const Format: TPCMAudioFormat): IPCMAudioBackend;

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
    FAudioReset: Boolean;
    FInput: TEmulatorInput;
    FPointerX, FPointerY: Integer;
    FPointerValid: Boolean;
    FPointerDirty: Boolean;
    FButtons: Byte;
    FTouchTracker: TEmulationTouchTracker;
    FTouchOverflow, FSuppressMouse: Boolean;
    function ReadResource(const BaseURI, URL: string; out Data: TBytes; out ResolvedURI: string): Boolean;
    procedure Execute;
    procedure QueueLocked(const Event: TFlashInputEvent);
    procedure Queue(const Event: TFlashInputEvent);
  public
    constructor Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TFlashAudioFactory = nil);
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
  System.Diagnostics, System.IOUtils, System.NetEncoding, System.Math,
  Core.Emulation.Config, SWF.Reader, SWF.Sound, PCM.Audio;

constructor TFlashCoreAdapter.Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TFlashAudioFactory);
var
  S: IStorage;
begin
  inherited Create;
  FAudioFactory := AudioFactory;
  FLock := TCriticalSection.Create;
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
  if not ResolvedURI.StartsWith(FResourceRoot,{$IFDEF MSWINDOWS}True{$ELSE}False{$ENDIF}) then Exit;
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
  finally
    FLock.Release;
  end;
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      Execute;
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TFlashCoreAdapter.Stop;
begin
  FLock.Acquire;
  try
    FStopping := True;
  finally
    FLock.Release;
  end;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
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

procedure TFlashCoreAdapter.Execute;
const
  AudioFrames = 512;
var
  Watch: TStopwatch;
  Deadline, AudioDeadline: Double;
  Events: TArray<TFlashInputEvent>;
  Paused, Stopping, WasPaused, ResetAudio, AudioFailed: Boolean;
  Audio: TPCMAudio;
  Keyboard, Pad: array[0..255] of Boolean;

  procedure PumpAudio;
  var
    Samples: TArray<SmallInt>;
    Format: TPCMAudioFormat;
    Now, Volume: Double;
    I: Integer;
    Enabled: Boolean;
    State: TPCMAudioQueueState;
  begin
    Enabled := FConfig.AudioEnabled;
    if not Enabled then
    begin
      FreeAndNil(Audio);
      AudioFailed := False;
    end;
    Now := Watch.Elapsed.TotalMilliseconds;
    if AudioDeadline < Now - 250 then
      AudioDeadline := Now;
    while AudioDeadline <= Now do
    begin
      Samples := FPlayer.MixAudio(AudioFrames);
      AudioDeadline := AudioDeadline + AudioFrames * 1000 / SWFSoundRate;
      if not Enabled or AudioFailed or (Length(Samples) = 0) then
        Continue;
      try
        Format.SampleRate := SWFSoundRate;
        Format.Channels := 2;
        Format.BlockFrames := AudioFrames;
        Format.BlockCount := 8;
        if Audio = nil then
        begin
          if Assigned(FAudioFactory) then
            Audio := TPCMAudio.Create(Format, FAudioFactory(Format))
          else
            Audio := TPCMAudio.Create(Format);
        end;
        State := Audio.QueueState;
        if Audio.Error <> '' then
          raise EInOutError.Create(Audio.Error);
        if not State.DeviceOpen then
          raise EInOutError.Create('Flash audio output is unavailable');
        if State.QueuedBlocks >= Format.BlockCount then
          Continue;
        Volume := FConfig.AudioVolume;
        if Volume <> 1 then
          for I := 0 to High(Samples) do
            Samples[I] := SmallInt(EnsureRange(Round(Samples[I] * Volume), Int64(-32768), Int64(32767)));
        Audio.Submit(Samples, AudioFrames);
      except
        on E: Exception do
        begin
          FreeAndNil(Audio);
          AudioFailed := True;
          FLock.Acquire;
          try
            FAudioError := E.Message;
          finally
            FLock.Release;
          end;
        end;
      end;
    end;
  end;

begin
  Audio := nil;
  AudioFailed := False;
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
          FAudioReset := False;
        finally
          FLock.Release;
        end;
        if Stopping then
          Exit;
        if ResetAudio then
        begin
          FreeAndNil(Audio);
          AudioFailed := False;
          AudioDeadline := Watch.Elapsed.TotalMilliseconds;
        end;
        if Paused and not WasPaused then
          FPlayer.ClearInput;
        if WasPaused and not Paused then
          for var K := 0 to 255 do
            FPlayer.Key(K, Keyboard[K] or Pad[K]);
        WasPaused := Paused;
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
        FPlayer.Tick;
        PumpAudio;
        var Frame := Default(TEmulatorFrame);
        Frame.Width := FPlayer.Movie.Width;
        Frame.Height := FPlayer.Movie.Height;
        var Pixels := FPlayer.Render;
        SetLength(Frame.Pixels, Length(Pixels));
        if Length(Pixels) > 0 then
          Move(Pixels[0], Frame.Pixels[0], Length(Pixels) * SizeOf(Cardinal));
        Frame.FrameNumber := FPlayer.FrameNumber;
        Frame.FramesPerSecond := FPlayer.Movie.FPS;
        FLock.Acquire;
        try
          FFrame := Frame;
          FReady := True;
        finally
          FLock.Release;
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
    Audio.Free;
  end;
end;

end.

