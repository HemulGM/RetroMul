unit NES.FamicomDataRecorder;

interface

uses
  Core.Storage, System.SysUtils, NES.State;

type
  TTapeAction = (TapePlay, TapeRecord, TapeStop, TapeRewind, TapeForward,
    TapeSelectFile, TapeDefaultFile, TapeSaveAs);

  TTapeState = (TapeStopped, TapePlaying, TapeRecording);

  TTapeProgress = record
    State: TTapeState;
    Connected, InputEnabled, Reading, Writing: Boolean;
    PositionBytes, TapeBytes, CapacityBytes: UInt64;
    ReadBytes, WrittenBytes, ReadAccesses, WriteAccesses: UInt64;
    LastReadByte, LastWrittenByte: Byte;
    FileName: string;
    DefaultFile: Boolean;
    SignalMap: array[0..255] of Byte;
  end;

  TFamicomDataRecorder = class
  private
    FData: TBytes;
    FStorage: IStorage;
    FConnected, FEnabled, FPlaying, FRecording: Boolean;
    FClock, FStartClock, FSampleClock: UInt64;
    FSampleCount: Integer;
    FOutput: Byte;
    FPath: string;
    FReadBytes, FReadAccesses, FWriteAccesses: UInt64;
    FLastReadPosition, FLastReadClock, FLastWriteClock: UInt64;
    FLastReadByte: Byte;
    FPlaybackOffset: UInt64;
    FSignalChunks: array[0..32767] of Byte; // One activity flag per 512 tape bytes.
    procedure ClearActivity;
    procedure BuildSignalMap;
    function GetPlaybackPosition: UInt64;
    procedure Capture(Value: Byte);
    function GetState: TTapeState;
  public
    property Storage: IStorage read FStorage write FStorage;
    procedure Clock(MasterClock: UInt64);
    procedure Write(Value: Byte);
    function Read: Byte;
    procedure Play(const FileName: string);
    procedure LoadTape(const FileName: string; AllowMissing: Boolean = False);
    procedure ResumeTape;
    procedure SeekRelative(ByteOffset: Int64);
    procedure RecordTape(const FileName: string);
    procedure Stop;
    procedure SaveCopy(const FileName: string);
    procedure Reset(DiscardRecording: Boolean = False);
    procedure SerializeState(State: TNesStateArchive);
    function GetProgress: TTapeProgress;
    property Connected: Boolean read FConnected write FConnected;
    property Playing: Boolean read FPlaying;
    property Recording: Boolean read FRecording;
    property TransportState: TTapeState read GetState;
  end;

implementation

uses
  System.Classes, System.IOUtils;

const
  SAMPLE_CLOCKS = 88;
  MAX_TAPE_BYTES = 16 * 1024 * 1024;

function TFamicomDataRecorder.GetState: TTapeState;
begin
  if FRecording then
    Result := TapeRecording
  else if FPlaying then
    Result := TapePlaying
  else
    Result := TapeStopped;
end;

procedure TFamicomDataRecorder.ClearActivity;
begin
  FReadBytes := 0;
  FReadAccesses := 0;
  FWriteAccesses := 0;
  FLastReadPosition := High(UInt64);
  FLastReadClock := 0;
  FLastWriteClock := 0;
  FLastReadByte := 0;
end;

function TFamicomDataRecorder.GetPlaybackPosition: UInt64;
begin
  Result := FPlaybackOffset;
  if FPlaying then
    Inc(Result, (FClock - FStartClock) div SAMPLE_CLOCKS);
  if Result > UInt64(Length(FData)) * 8 then
    Result := UInt64(Length(FData)) * 8;
end;

procedure TFamicomDataRecorder.BuildSignalMap;
begin
  FillChar(FSignalChunks, SizeOf(FSignalChunks), 0);
  var Count := Length(FData);
  if FRecording or (FSampleCount > 0) then
    Count := (FSampleCount + 7) div 8;
  for var i := 0 to Count - 1 do
    if ((FData[i] <> 0) and (FData[i] <> $FF)) or ((i > 0) and ((FData[i - 1] shr 7) <> (FData[i] and 1))) then
      FSignalChunks[i div 512] := 1;
end;

function TFamicomDataRecorder.GetProgress: TTapeProgress;
const
  ACTIVITY_CLOCKS = 2000000; // About 0.1 seconds on either console crystal.
begin
  Result := Default(TTapeProgress);
  Result.State := GetState;
  Result.Connected := FConnected;
  Result.InputEnabled := FEnabled;
  Result.CapacityBytes := MAX_TAPE_BYTES;
  Result.ReadBytes := FReadBytes;
  Result.ReadAccesses := FReadAccesses;
  Result.WriteAccesses := FWriteAccesses;
  Result.LastReadByte := FLastReadByte;
  Result.FileName := FPath;
  Result.WrittenBytes := (UInt64(FSampleCount) + 7) div 8;
  if FSampleCount > 0 then
    Result.LastWrittenByte := FData[(FSampleCount - 1) div 8];
  if FRecording then
  begin
    Result.PositionBytes := Result.WrittenBytes;
    Result.TapeBytes := Result.WrittenBytes;
  end
  else
  begin
    Result.TapeBytes := Length(FData);
    Result.PositionBytes := GetPlaybackPosition div 8;
    if Result.PositionBytes > Result.TapeBytes then
      Result.PositionBytes := Result.TapeBytes;
  end;
  Result.Reading := FPlaying and (FReadAccesses > 0) and (FClock - FLastReadClock < ACTIVITY_CLOCKS);
  Result.Writing := FRecording and (FWriteAccesses > 0) and (FClock - FLastWriteClock < ACTIVITY_CLOCKS);
  if Result.TapeBytes > 0 then
    for var Chunk := 0 to Integer((Result.TapeBytes - 1) div 512) do
      if FSignalChunks[Chunk] <> 0 then
      begin
        var First := UInt64(Chunk) * 512 * 256 div Result.TapeBytes;
        var Last := (UInt64(Chunk) * 512 + 511) * 256 div Result.TapeBytes;
        if Last > 255 then
          Last := 255;
        for var Bin := Integer(First) to Integer(Last) do
          Result.SignalMap[Bin] := 1;
      end;
end;

procedure TFamicomDataRecorder.Clock(MasterClock: UInt64);
begin
  FClock := MasterClock;
end;

procedure TFamicomDataRecorder.Capture(Value: Byte);
begin
  // Match Mesen's strict > 88 boundary and packed bit order.
  while FClock - FSampleClock > SAMPLE_CLOCKS do
  begin
    if FSampleCount div 8 >= MAX_TAPE_BYTES then
      raise EInvalidOperation.Create('Virtual tape is full');

    if FSampleCount div 8 >= Length(FData) then
      SetLength(FData, Length(FData) + 4096);
    if FSampleCount mod 8 = 0 then
      FData[FSampleCount div 8] := 0;
    if (FSampleCount > 0) and (((FData[(FSampleCount - 1) div 8] shr ((FSampleCount - 1) mod 8)) and 1) <> (Value and 1)) then
      FSignalChunks[FSampleCount div (8 * 512)] := 1;
    FData[FSampleCount div 8] := FData[FSampleCount div 8] or ((Value and 1) shl (FSampleCount mod 8));
    Inc(FSampleCount);
    Inc(FSampleClock, SAMPLE_CLOCKS);
  end;
end;

procedure TFamicomDataRecorder.Write(Value: Byte);
begin
  if not FConnected then
    Exit;

  FEnabled := (Value and 4) <> 0;
  if FRecording then
  begin
    Inc(FWriteAccesses);
    FLastWriteClock := FClock;
    Capture(Value);
  end;
  FOutput := Value and 1;
end;

function TFamicomDataRecorder.Read: Byte;
begin
  Result := 0;
  if not FConnected or not FPlaying then
    Exit;

  var Position := GetPlaybackPosition;
  if Position >= UInt64(Length(FData)) * 8 then
  begin
    FPlaybackOffset := Position;
    FPlaying := False
  end
  else if FEnabled then
  begin
    Inc(FReadAccesses);
    FLastReadClock := FClock;
    var BytePosition := Position div 8;
    if BytePosition <> FLastReadPosition then
    begin
      Inc(FReadBytes);
      FLastReadPosition := BytePosition;
    end;
    FLastReadByte := FData[Integer(BytePosition)];
    Result := ((FData[Integer(Position div 8)] shr (Position mod 8)) and 1) shl 1;
  end;
end;

procedure TFamicomDataRecorder.Play(const FileName: string);
begin
  LoadTape(FileName);
  ResumeTape;
end;

procedure TFamicomDataRecorder.LoadTape(const FileName: string; AllowMissing: Boolean);
begin
  if FStorage = nil then
    FStorage := TStorage.Default;
  if not FConnected then
    raise EInvalidOperation.Create('No data recorder connected');

  // Flush a recording before reopening the same cassette from disk.
  if FRecording and SameFileName(FileName, FPath) then
    Stop;
  var Data: TBytes;
  if not AllowMissing or FStorage.Exists(FileName) then
  begin
    var Input := FStorage.OpenRead(FileName);
    try
      if Input.Size > MAX_TAPE_BYTES then
        raise EReadError.Create('Virtual tape is too large');

      SetLength(Data, Input.Size);
      if Length(Data) > 0 then
        Input.ReadBuffer(Data[0], Length(Data));
    finally
      Input.Free;
    end;
  end;
  Stop;
  FData := Data;
  FPath := FileName;
  FSampleCount := 0;
  ClearActivity;
  FPlaybackOffset := 0;
  FStartClock := FClock;
  BuildSignalMap;
end;

procedure TFamicomDataRecorder.ResumeTape;
begin
  if not FConnected then
    raise EInvalidOperation.Create('No data recorder connected');

  if FRecording then
    Stop;

  if Length(FData) = 0 then
    raise EInvalidOperation.Create('The cassette is empty');

  if FPlaying then
    Exit;

  // Recording has allocated slack; trim it before treating it as a loaded tape.
  if FSampleCount > 0 then
    SetLength(FData, (FSampleCount + 7) div 8);
  FSampleCount := 0;
  if FPlaybackOffset >= UInt64(Length(FData)) * 8 then
    FPlaybackOffset := 0;
  FStartClock := FClock;
  FPlaying := True;
end;

procedure TFamicomDataRecorder.SeekRelative(ByteOffset: Int64);
begin
  if FRecording then
    raise EInvalidOperation.Create('Stop recording before seeking');

  var Position := Int64(GetPlaybackPosition div 8);
  var Target := Position + ByteOffset;
  if Target < 0 then
    Target := 0;
  if Target > Length(FData) then
    Target := Length(FData);
  FPlaybackOffset := UInt64(Target) * 8;
  FStartClock := FClock;
  ClearActivity;
end;

procedure TFamicomDataRecorder.RecordTape(const FileName: string);
begin
  if FStorage = nil then
    FStorage := TStorage.Default;
  if not FConnected then
    raise EInvalidOperation.Create('No data recorder connected');

  if FileName = '' then
    raise EArgumentException.Create('A tape filename is required');

  Stop;
  FPath := FileName;
  FData := nil;
  FSampleCount := 0;
  FSampleClock := FClock;
  FPlaybackOffset := 0;
  FillChar(FSignalChunks, SizeOf(FSignalChunks), 0);
  ClearActivity;
  FRecording := True;
end;

procedure TFamicomDataRecorder.Stop;
begin
  if FPlaying then
    FPlaybackOffset := GetPlaybackPosition;
  if FRecording then
  begin
    // A full tape must still be stoppable and savable after Capture reports it.
    if FSampleCount < MAX_TAPE_BYTES * 8 then
      Capture(FOutput);
    // Preserve the final partial byte; Mesen drops it on stop.
    var Data := Copy(FData, 0, (FSampleCount + 7) div 8);
    FStorage.WriteBytes(FPath, Data);
    FRecording := False;
    SetLength(FData, Length(Data));
    FPlaybackOffset := FSampleCount;
  end;
  FPlaying := False;
end;

procedure TFamicomDataRecorder.SaveCopy(const FileName: string);
begin
  if not FConnected then
    raise EInvalidOperation.Create('No data recorder connected');

  if FileName = '' then
    raise EArgumentException.Create('A cassette filename is required');

  if FRecording and (FSampleCount < MAX_TAPE_BYTES * 8) then
    Capture(FOutput);
  var Data := FData;
  if FRecording then
    Data := Copy(FData, 0, (FSampleCount + 7) div 8);
  if FStorage = nil then
    FStorage := TStorage.Default;
  FStorage.WriteBytes(FileName, Data);
end;

procedure TFamicomDataRecorder.Reset(DiscardRecording: Boolean);
begin
  if DiscardRecording then
  begin
    // Snapshot loads must have no filesystem side effects, including rollback.
    FRecording := False;
    FPlaying := False;
  end
  else
    Stop;
  FClock := 0;
  FStartClock := 0;
  FSampleClock := 0;
  FEnabled := False;
  FOutput := 0;
  FData := nil;
  FSampleCount := 0;
  FPath := '';
  FPlaybackOffset := 0;
  FillChar(FSignalChunks, SizeOf(FSignalChunks), 0);
  ClearActivity;
end;

procedure TFamicomDataRecorder.SerializeState(State: TNesStateArchive);
begin
  State.Field(FConnected, SizeOf(FConnected));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FRecording, SizeOf(FRecording));
  State.Field(FClock, SizeOf(FClock));
  State.Field(FStartClock, SizeOf(FStartClock));
  State.Field(FSampleClock, SizeOf(FSampleClock));
  State.Field(FSampleCount, SizeOf(FSampleCount));
  State.Field(FOutput, SizeOf(FOutput));
  var Size := Length(FData);
  State.Field(Size, SizeOf(Size));
  if (Size < 0) or (Size > MAX_TAPE_BYTES) then
    raise EReadError.Create('Invalid tape size');

  if State.Loading then
    SetLength(FData, Size);
  if Size > 0 then
    State.Field(FData[0], Size);
  var PathData := TEncoding.UTF8.GetBytes(FPath);
  Size := Length(PathData);
  State.Field(Size, SizeOf(Size));
  if (Size < 0) or (Size > 32768) then
    raise EReadError.Create('Invalid tape path');

  if State.Loading then
    SetLength(PathData, Size);
  if Size > 0 then
    State.Field(PathData[0], Size);
  if State.Version >= 14 then
    State.Field(FPlaybackOffset, SizeOf(FPlaybackOffset))
  else if State.Loading then
    FPlaybackOffset := 0;
  if State.Loading then
  begin
    FPath := TEncoding.UTF8.GetString(PathData);

    // UI-only counters do not affect snapshots or device behavior.
    ClearActivity;
    if (FSampleCount < 0) or (Int64(FSampleCount) > Int64(Length(FData)) * 8) or
      (FStartClock > FClock) or (FSampleClock > FClock) or
      (FRecording and ((FPath = '') or FPlaying)) then
      raise EReadError.Create('Invalid tape state');

    if FPlaybackOffset > UInt64(Length(FData)) * 8 then
      raise EReadError.Create('Invalid tape position');

    BuildSignalMap;
  end;
end;

end.

