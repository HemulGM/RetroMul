unit Saturn.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, Saturn.Console,
  Saturn.SMPC, Core.CD.Disc;

type
  TSaturnWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FBIOS, FIdentity: TBytes;
    FDisc: TCDDisc;
    FRAMCart: Integer;
    FAudioEnabled: Boolean;
    FVolume: Single;
    FRegion: Byte;
    FPAL: Boolean;
    FInput: TEmulatorInput;
    FPause, FReset, FAvailable: Boolean;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TSaturnConsole);
  protected
    procedure Execute; override;
  public
    CartROM: TBytes;
    UseSH1, Protection: Boolean;
    SnapshotDirectory, SaveFile: string;
    CartSaveFile: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const BIOS: TBytes; const Storage: IStorage; Region: Byte; PAL: Boolean; Disc: TCDDisc = nil; RAMCart: Integer = 0; const Identity: TBytes = nil);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
    procedure StopAndSave;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
  end;

implementation

uses
  System.Diagnostics, System.Math, Core.SavePaths, Core.PerformanceHints,
  PCM.Audio, Saturn.Audio;

function TSaturnWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TSaturnWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TSaturnWorker.Create(const BIOS: TBytes; const Storage: IStorage; Region: Byte; PAL: Boolean; Disc: TCDDisc; RAMCart: Integer; const Identity: TBytes);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FBIOS := Copy(BIOS);
  FRegion := Region;
  FPAL := PAL;
  FDisc := Disc;
  FRAMCart := RAMCart;
  FIdentity := Copy(Identity);
  if Length(FIdentity) = 0 then
    FIdentity := Copy(BIOS);
  FStorage := Storage;
end;

destructor TSaturnWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;

  // Join before freeing synchronization objects used by Execute.
  inherited;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TSaturnWorker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TSaturnWorker.RequestReset;
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

procedure TSaturnWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TSaturnWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TSaturnWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TSaturnWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TSaturnWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TSaturnWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TSaturnWorker.Publish(Console: TSaturnConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := Console.FrameWidth;
  Frame.Height := Console.FrameHeight;
  Frame.Pixels := Copy(Console.Pixels);
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

function SaturnPad(const Buttons: TEmulatorButtons): TSaturnButtons;
const
  Map: array[TEmulatorButton] of TSaturnButton = (TSaturnButton.Up, TSaturnButton.Down, TSaturnButton.Left, TSaturnButton.Right,
    TSaturnButton.A, TSaturnButton.B, TSaturnButton.L, TSaturnButton.Start, TSaturnButton.C, TSaturnButton.X, TSaturnButton.Y, TSaturnButton.Z, TSaturnButton.R);
begin
  Result := [];
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    if B in Buttons then
      Include(Result, Map[B]);
end;

procedure TSaturnWorker.Execute;
var
  Console: TSaturnConsole;
  Hints: TEmulationPerformanceHints;
  Audio: TPCMAudio;
  AudioFailed, AudioPrimed: Boolean;
  PendingAudio: TArray<SmallInt>;
  PendingFrames: Integer;
  AudioEpoch: UInt64;
  Stretch: TSaturnAudioStretch;
  SmoothWork, SmoothAudio, PostWork: Double;
  WorkStarted, CoreFinished: Int64;

  procedure ClearAudio;
  begin
    PendingFrames := 0;
    AudioPrimed := False;
    Stretch.Reset;
    SmoothWork := 0;
    SmoothAudio := 0;
    PostWork := 0;
    if Audio <> nil then
    begin
      Audio.Clear;
      Audio.SetPaused(True);
      AudioEpoch := Audio.QueueState.SubmittedSamples;
    end;
  end;

  function QueuedFrames: Integer;
  begin
    Result := 0;
    if Audio = nil then
      Exit;

    var Q := Audio.QueueState;
    if not Q.DeviceOpen then
      Exit;

    if Q.PositionKnown then
    begin
      var Submitted := Q.SubmittedSamples - AudioEpoch;
      var Delta := (Submitted + UInt64($100000000) - Q.PlayedSamples) and $FFFFFFFF;
      if Delta <= 8192 then
        Result := Delta;
    end
    else
      Result := Q.QueuedBlocks * 738;
  end;

begin
  Console := nil;
  Hints := nil;
  Audio := nil;
  AudioFailed := False;
  AudioPrimed := False;
  PendingFrames := 0;
  AudioEpoch := 0;
  Stretch := TSaturnAudioStretch.Create;
  SmoothWork := 0;
  SmoothAudio := 0;
  PostWork := 0;
  try
    try
      Console := TSaturnConsole.Create(FBIOS, FRegion, FPAL, FDisc, FRAMCart, CartROM);
      Console.ThreadedVideo := TThread.ProcessorCount > 1;
      Console.CD.UseSH1(UseSH1);
      Console.CD.Protection := Protection;
      if (SaveFile <> '') and FStorage.Exists(SaveFile) then
        Console.LoadBackup(FStorage.ReadBytes(SaveFile));
      if (CartSaveFile <> '') and FStorage.Exists(CartSaveFile) and (FRAMCart in [$21..$24]) then
        Console.Cartridge.LoadBackup(FStorage.ReadBytes(CartSaveFile));
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 1024;
      Format.BlockCount := 8;
      var Rate: Double := Console.FramesPerSecond;
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Rate), 'SATURN');
      var Deadline: Double := TStopwatch.GetTimeStamp;
      while not Terminated do
      begin
        FInputPortsCommand.Process(nil);
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            Hints.Pause;
            PendingFrames := 0;
            AudioPrimed := False;
            Stretch.Reset;
            SmoothWork := 0;
            SmoothAudio := 0;
            PostWork := 0;
            if Audio <> nil then
            begin
              Audio.Clear;
              Audio.SetPaused(True);
              AudioEpoch := Audio.QueueState.SubmittedSamples;
            end;
            var Path := ResolveSnapshotPath(SnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, 'SATURN', FIdentity, Transfer, FStorage);
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, 'SATURN', FIdentity, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.FrameWidth, Console.FrameHeight, Console.FrameWidth, @Console.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        var Input: TEmulatorInput;
        var Paused, ResetRequested, Enabled: Boolean;
        var Volume: Single;
        try
          Input := FInput;
          Paused := FPause;
          ResetRequested := FReset;
          FReset := False;
          Enabled := FAudioEnabled;
          Volume := FVolume;
        finally
          FLock.Release;
        end;
        if ResetRequested then
        begin
          Console.Reset;
          ClearAudio;
          Hints.Pause;
          Deadline := TStopwatch.GetTimeStamp;
        end;
        if Paused then
        begin
          Hints.Pause;
          ClearAudio;
          FWake.WaitFor(10);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;
        var StartingPlayback := False;
        WorkStarted := TStopwatch.GetTimeStamp;
        Hints.BeginWork;
        var Ports := InputPorts;
        var Pads: array[0..11] of TEmulatorButtons;
        Pads[0] := Input.Buttons;
        Pads[1] := Input.Buttons2;
        Pads[2] := Input.Buttons3;
        Pads[3] := Input.Buttons4;
        Pads[4] := Input.Buttons5;
        Pads[5] := Input.Buttons6;
        Pads[6] := Input.Buttons7;
        Pads[7] := Input.Buttons8;
        Pads[8] := Input.Buttons9;
        Pads[9] := Input.Buttons10;
        Pads[10] := Input.Buttons11;
        Pads[11] := Input.Buttons12;
        for var Port := 0 to 1 do
        begin
          Console.SMPC.SetMultitap(Port, Ports.Multitap[Port]);
          for var Slot := 0 to 5 do
          begin
            // Preserve physical port 1/2 as players 1/2. Additional slots
            // occupy players 3..7 then 8..12 when both taps are attached.
            var Player := Port;
            if Slot > 0 then
            begin
              Player := Slot + 1;
              if Port = 1 then
              begin
                if Ports.Multitap[0] then
                  Inc(Player, 5);
              end;
            end;
            var Kind: Integer := 1;
            if Ports.Devices[Player] = 'none' then
              Kind := 0
            else if Ports.Devices[Player] = 'pad-analog' then
              Kind := 2;
            var X: Byte := 128;
            var Y: Byte := 128;
            var L: Byte := 0;
            var R: Byte := 0;
            if Input.Analog[Player].Valid then
            begin
              X := (Integer(Input.Analog[Player].X) + 32768) shr 8;
              Y := (Integer(Input.Analog[Player].Y) + 32768) shr 8;
              L := Input.Analog[Player].LeftTrigger;
              R := Input.Analog[Player].RightTrigger;
            end
            else
            begin
              if TEmulatorButton.Left in Pads[Player] then
                X := 0
              else if TEmulatorButton.Right in Pads[Player] then
                X := 255;
              if TEmulatorButton.Up in Pads[Player] then
                Y := 0
              else if TEmulatorButton.Down in Pads[Player] then
                Y := 255;
              if TEmulatorButton.Select in Pads[Player] then
                L := 255;
              if TEmulatorButton.Mode in Pads[Player] then
                R := 255;
            end;
            Console.SMPC.SetPeripheral(Port, Slot, Kind, SaturnPad(Pads[Player]), X, Y, R, L);
          end;
        end;
        var FrameStartedAt := Console.Time;
        var FrameClock := Console.ClockFrequency;
        Console.RunFrame;
        CoreFinished := TStopwatch.GetTimeStamp;
        Rate := Console.FramesPerSecond;
        if Terminated then
          Break;

        if Enabled and not AudioFailed then
        try
          if Audio = nil then
          begin
            Audio := TPCMAudio.Create(Format);
            StartingPlayback := True;
            Audio.SetPaused(True);
            AudioEpoch := Audio.QueueState.SubmittedSamples;
          end;

          // Estimate sustained producer speed from work only, never limiter
          // sleep. Preserve pitch when a heavy scene cannot supply 44.1 kHz.
          var NativeSeconds := Console.SampleFrames / Format.SampleRate;
          if NativeSeconds > 0 then
          begin
            var WorkSeconds: Double := (CoreFinished - WorkStarted) / TStopwatch.Frequency + PostWork;
            if SmoothAudio = 0 then
            begin
              SmoothWork := WorkSeconds;
              SmoothAudio := NativeSeconds;
            end
            else
            begin
              SmoothWork := SmoothWork * 0.8 + WorkSeconds * 0.2;
              SmoothAudio := SmoothAudio * 0.8 + NativeSeconds * 0.2;
            end;
          end;
          var NativeSamples: TArray<SmallInt>;
          SetLength(NativeSamples, Console.SampleFrames * Format.Channels);
          for var I := 0 to High(NativeSamples) do
            NativeSamples[I] := Round(Console.Samples[I] * Volume);
          var SamplesOut: TArray<SmallInt>;
          if Audio.QueueState.DeviceOpen then
          begin
            var StretchRatio: Double := 1;
            if SmoothAudio > 0 then
              StretchRatio := Max(1.0, SmoothWork / SmoothAudio);
            if AudioPrimed then
            begin
              var Expected := QueuedFrames + Console.SampleFrames * StretchRatio;
              var Correction := EnsureRange((Format.SampleRate * 0.064 - Expected) / (Format.SampleRate / 5), -0.15, 0.15);
              StretchRatio := StretchRatio * (1 + Correction);
            end;
            StretchRatio := EnsureRange(StretchRatio, 0.95, 1.75);
            Stretch.Process(NativeSamples, Console.SampleFrames, StretchRatio, SamplesOut);
          end
          else
            SamplesOut := NativeSamples;
          var CountOut := Length(SamplesOut) div Format.Channels;
          SetLength(PendingAudio, (PendingFrames + CountOut) * Format.Channels);
          if CountOut > 0 then
            Move(SamplesOut[0], PendingAudio[PendingFrames * Format.Channels], CountOut * Format.Channels * SizeOf(SmallInt));
          Inc(PendingFrames, CountOut);
          if AudioPrimed or (PendingFrames >= Format.SampleRate * 64 div 1000) then
          begin
            StartingPlayback := StartingPlayback or not AudioPrimed;
            var Offset := 0;
            while Offset < PendingFrames do
            begin
              var Count := Min(Format.BlockFrames, PendingFrames - Offset);
              var Samples := Copy(PendingAudio, Offset * Format.Channels, Count * Format.Channels);
              Audio.Submit(Samples, Count);
              Inc(Offset, Count);
            end;
            PendingFrames := 0;
            if not AudioPrimed then
              Audio.SetPaused(False);
            AudioPrimed := True;
          end;
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := 'Saturn audio: ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioPrimed := False;
            PendingFrames := 0;
            Stretch.Reset;
            AudioFailed := True;
          end;
        end
        else if not Enabled then
        begin
          ClearAudio;
          AudioFailed := False;
        end;
        Publish(Console);
        Hints.EndWork;
        PostWork := (TStopwatch.GetTimeStamp - CoreFinished) / TStopwatch.Frequency;

        // Opening/starting a host device is not sustained emulation work.
        if StartingPlayback then
          PostWork := 0;

        // Use the field actually emulated: interlace alternates field lengths,
        // and a loaded snapshot may start part-way through a field.
        var FieldSeconds := 1.0 / Rate;
        if (Console.ClockFrequency = FrameClock) and (Console.Time > FrameStartedAt) then
          FieldSeconds := (Console.Time - FrameStartedAt) / FrameClock;
        Deadline := Deadline + TStopwatch.Frequency * FieldSeconds;
        if TStopwatch.GetTimeStamp - Deadline > TStopwatch.Frequency div 10 then
          Deadline := TStopwatch.GetTimeStamp;
        if Enabled and not AudioFailed and AudioPrimed and (Audio <> nil) and Audio.QueueState.DeviceOpen then
        begin
          // Pace from the device clock with a 64 ms lead. A late field uses
          // the cushion and the next fast field replenishes it without sleep.
          Deadline :=
            TStopwatch.GetTimeStamp +
            (QueuedFrames - Format.SampleRate * 64 div 1000) * (TStopwatch.Frequency / Format.SampleRate);
        end;
        Hints.WaitUntil(FWake, Round(Deadline));
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'SATURN: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    if (Console <> nil) and (CartSaveFile <> '') and Console.Cartridge.Dirty then
    try
      FStorage.WriteBytes(CartSaveFile, Console.Cartridge.Backup);
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'SATURN cartridge save: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (SaveFile <> '') and Console.BackupDirty then
    try
      FStorage.WriteBytes(SaveFile, Console.Backup);
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'SATURN save: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    Audio.Free;
    Stretch.Free;
    Console.Free;
    Hints.Free;
  end;
end;

end.

