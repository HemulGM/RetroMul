unit MD.Emulation;

interface

uses
  Core.Storage, Core.Snapshots, System.SysUtils, System.Classes, System.SyncObjs,
  Core.Emulation, MD.Console;

const
  MD_SAMPLE_RATE = 44100;
  AUDIO_BLOCK_SAMPLES = 2048;
  AUDIO_BLOCK_COUNT = 4;

type
  TMDWorker = class(TThread)
  private
    FSnapshots: TSnapshotQueue;
    FSnapshotDirectory: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FData: TBytes;
    FSavePath: string;
    FStorage: IStorage;
    FInput, FInput2: TMDButtons;
    FPause, FReset, FAudioEnabled: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FAvailable: Boolean;
    FError: string;
    procedure SetError(const Value: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; const SavePath: string; const Storage: IStorage = nil);
    destructor Destroy; override;
    procedure WakeSetEvent;
    procedure Configure(const Input: TMDButtons; Paused, AudioEnabled: Boolean; Volume: Single; const Input2: TMDButtons = []);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    property SnapshotDirectory: string read FSnapshotDirectory write FSnapshotDirectory;
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
  end;

implementation

uses
  System.IOUtils, System.UITypes, System.Diagnostics, System.Math, PCM.Audio;

{ TMDWorker }

constructor TMDWorker.Create(const Data: TBytes; const SavePath: string; const Storage: IStorage);
begin
  inherited Create(True);
  FStorage := Storage;
  if FStorage = nil then FStorage := TStorage.Default;
  FreeOnTerminate := False;
  FSnapshots := TSnapshotQueue.Create;
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
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TMDWorker.Configure(const Input: TMDButtons; Paused, AudioEnabled: Boolean; Volume: Single; const Input2: TMDButtons);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FInput2 := Input2;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
end;

procedure TMDWorker.SaveSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, False);
end;

procedure TMDWorker.LoadSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, True);
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
      FError := FError + SLineBreak + Value;
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

procedure TMDWorker.WakeSetEvent;
begin
  FWake.SetEvent;
end;

procedure TMDWorker.Execute;

  procedure SaveBattery(Console: TMDConsole; var LastBattery: TBytes);
  begin
    if (Console = nil) or not Console.BatteryDirty then
      Exit;
    var Data := Console.BatteryData;
    if Length(Data) = 0 then
      Exit;
    var Unchanged := Length(Data) = Length(LastBattery);
    if Unchanged then
      for var i := 0 to High(Data) do
        if Data[i] <> LastBattery[i] then
        begin
          Unchanged := False;
          Break;
        end;
    if Unchanged then
      Exit;
    var Stream := TBytesStream.Create(Data);
    try
      SaveStreamAtomically(Stream, FSavePath, FStorage);
      LastBattery := Data;
    finally
      Stream.Free;
    end;
  end;

begin
  var Paused, ResetRequested, Enabled, WasPaused, WasEnabled: Boolean;
  var Volume: Single;
  var Frame: TEmulatorFrame;
  var Samples: TArray<SmallInt>;
  var Watch: TStopwatch;
  var Deadline: Double;
  var WaitMS: Integer;
  var LastBattery: TBytes;
  var LastAudioError: string;
  var Console: TMDConsole := nil;
  var Audio: TPCMAudio := nil;
  try
    try
      Console := TMDConsole.Create(FData, '.md');
      if FStorage.Exists(FSavePath) then
      begin
        LastBattery := FStorage.ReadBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      var Format: TPCMAudioFormat;
      Format.SampleRate := MD_SAMPLE_RATE;
      Format.Channels := 2;
      Format.BlockFrames := AUDIO_BLOCK_SAMPLES;
      Format.BlockCount := AUDIO_BLOCK_COUNT;
      Watch := TStopwatch.StartNew;
      Deadline := 0;
      WasPaused := False;
      WasEnabled := False;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            var Path := TPath.Combine(FSnapshotDirectory, Name + '.snapshot');
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, 'MD', FData, Transfer, FStorage);
              Console.MarkBatteryDirty;
              if Audio <> nil then
                Audio.Clear;
              Frame.Width := Console.Width;
              Frame.Height := Console.Height;
              Frame.FrameNumber := Console.FrameNumber;
              Frame.FramesPerSecond := Console.FramesPerSecond;
              Frame.Pixels := nil;
              SetLength(Frame.Pixels, Frame.Width * Frame.Height);
              for var Y := 0 to Frame.Height - 1 do
                for var X := 0 to Frame.Width - 1 do
                  Frame.Pixels[Y * Frame.Width + X] := Console.Pixels[Y * 320 + X];
              FLock.Acquire;
              try
                FFrame := Frame;
                FAvailable := True;
              finally
                FLock.Release;
              end;
            end
            else
            begin
              SaveCoreSnapshot(Path, 'MD', FData, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.Width, Console.Height, 320, @Console.Pixels[0], FStorage);
            end;
            Deadline := Watch.Elapsed.TotalMilliseconds;
          end);
        var Input, Input2: TMDButtons;
        FLock.Acquire;
        try
          Input := FInput;
          Input2 := FInput2;
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
          SaveBattery(Console, LastBattery);
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
            SaveBattery(Console, LastBattery);
          end;
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := Watch.Elapsed.TotalMilliseconds;
          Continue;
        end;
        WasPaused := False;
        Console.SetInput(Input, Input2);
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
        for var Y := 0 to Frame.Height - 1 do
          for var X := 0 to Frame.Width - 1 do
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
          for var i := 0 to High(Samples) do
            Samples[i] := Round(Console.Samples[i] * Volume);
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
          SaveBattery(Console, LastBattery);
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
      SaveBattery(Console, LastBattery);
    except
      on E: Exception do
        SetError('Mega Drive SRAM: ' + E.Message);
    end;
    Audio.Free;
    Console.Free;
  end;
end;

end.

