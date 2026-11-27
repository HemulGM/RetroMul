unit INTV.KeyboardPeripherals;

interface

uses
  System.SysUtils, System.Classes, Core.Storage, Core.Snapshots, Audio.Types;

const
  IntvKeyboardTapeLimit = 4 * 1024 * 1024;
  IntvKeyboardAudioLimit = 256 * 1024 * 1024;

type
  TIntvKeyboardPeripherals = class
  private
    FStorage: IStorage;
    FRecordingPath, FAnalogPath, FPrintPath: string;
    FAnalog: TBytes;
    FAnalogDirty: Boolean;
    FLastAnalogFrame: Integer;
    FClock: Integer;
    FImage: TBytes;
    FPrinter: TMemoryStream;
    FAudio: IAudioSource;
    FAudioSeek: IAudioSeekSource;
    FAudioRate, FAudioChannels, FCachedFrames: Integer;
    FCachedStart: Int64;
    FAudioCache: array[0..4095] of SmallInt;
    FPosition, FPhase, FPrinterBusy: Integer;
    FDrive, FWriteBit: Byte;
    FMounted, FDataIRQ, FIRQEnabled, FPrinterStatus, FDirty: Boolean;
    FExternalIRQEnabled: Boolean;
    function InterruptPending: Boolean; inline;
    function MotorMode: Byte; inline;
    function AtLeader: Boolean;
    function ReadCell: Byte;
    procedure WriteCell;
    function TapeFrame(Rate: Integer): Integer;
    function AnalogSize: Integer;
    function ReadAnalog(Frame: Integer): Word;
    procedure RecordAnalog(Frame: Integer; Sample: SmallInt);
  public
    constructor Create(Clock: Integer);
    destructor Destroy; override;
    procedure Attach(const Image: TBytes; const Storage: IStorage; const RecordingPath, PrintPath: string);
    procedure AttachAudio(const Wave: TBytes);
    procedure Reset;
    procedure Clock;
    procedure Flush;
    procedure FlushWhenIdle;
    function IsRecordingAudio: Boolean;
    function AudioSample(Input: SmallInt = 0): Integer;
    function ReadTape(Address: Word): Byte;
    procedure WriteTape(Address: Word; Value: Byte);
    function ReadPrinter: Byte;
    procedure WritePrinter(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property IRQ: Boolean read InterruptPending;
  end;

implementation

uses
  System.Math, Audio.Format.WAV;

const
  TapeBitRate = 3000;
  SeekSpeed = 27; // Up to 50 inches/sec versus 1 7/8 inches/sec in play.
  LeaderCells = 600;
  MaxPrintBuffer = 65536;
  AudioBlockFrames = 2048;
  AnalogRecordingRate = 11025;

constructor TIntvKeyboardPeripherals.Create(Clock: Integer);
begin
  inherited Create;
  FClock := Clock;
  FPrinter := TMemoryStream.Create;
end;

destructor TIntvKeyboardPeripherals.Destroy;
begin
  FPrinter.Free;
  inherited;
end;

procedure TIntvKeyboardPeripherals.Attach(const Image: TBytes; const Storage: IStorage; const RecordingPath, PrintPath: string);
begin
  if (Length(Image) > IntvKeyboardTapeLimit) or Odd(Length(Image)) or
    ((Image <> nil) and (Length(Image) < LeaderCells + 2)) then
    raise EReadError.Create('Invalid Keyboard Component digital tape image length');
  AttachAudio(nil);
  FStorage := Storage;
  FImage := Copy(Image);
  FMounted := FImage <> nil;
  FRecordingPath := RecordingPath;
  FAnalog := nil;
  FAnalogDirty := False;
  FAnalogPath := '';
  if FRecordingPath <> '' then
  begin
    FAnalogPath := FRecordingPath + '.pcm';
    if (FStorage <> nil) and FStorage.Exists(FAnalogPath) then
    begin
      var Stream := FStorage.OpenRead(FAnalogPath);
      try
        if (Stream.Size <> 0) and (Stream.Size <> AnalogSize) then
          raise EReadError.Create('Invalid Keyboard Component recording size');
        SetLength(FAnalog, Stream.Size);
        if FAnalog <> nil then
          Stream.ReadBuffer(FAnalog[0], Length(FAnalog));
      finally
        Stream.Free;
      end;
    end;
  end;
  FPrintPath := PrintPath;
  FPosition := 0;
  FDirty := False;
  Reset;
end;

procedure TIntvKeyboardPeripherals.AttachAudio(const Wave: TBytes);
begin
  FAudioSeek := nil;
  FAudio := nil;
  FAudioRate := 0;
  FAudioChannels := 0;
  FCachedStart := -AudioBlockFrames;
  FCachedFrames := 0;
  if Wave = nil then
    Exit;
  if FImage = nil then
    raise EReadError.Create('Keyboard Component audio needs a digital tape image');
  FAudio := OpenWav(Wave);
  if not Supports(FAudio, IAudioSeekSource, FAudioSeek) then
    raise EReadError.Create('Keyboard Component tape audio must be seekable');
  var Format := FAudio.GetFormat;
  FAudioRate := Format.SampleRate;
  FAudioChannels := Format.Channels;
end;

procedure TIntvKeyboardPeripherals.Reset;
begin
  FPhase := 0;
  FPrinterBusy := 0;
  FLastAnalogFrame := -1;
  FDrive := 0;
  FWriteBit := 0;
  FDataIRQ := False;
  FIRQEnabled := False;
  FPrinterStatus := False;
  FExternalIRQEnabled := True;
end;

function TIntvKeyboardPeripherals.MotorMode: Byte;
begin
  Result := FDrive and 7;
end;

function TIntvKeyboardPeripherals.AtLeader: Boolean;
begin
  Result := (FPosition < LeaderCells) or (FPosition >= Length(FImage) * 2 - LeaderCells);
end;

function TIntvKeyboardPeripherals.ReadCell: Byte;
begin
  Result := 0;
  if not FMounted or (MotorMode < 5) or AtLeader then
    Exit;
  // Each pair of bytes holds four chronological two-bit cells per track.
  // The low bit is the value and the high bit denotes carrier.
  var Track := 1 - ((FDrive shr 6) and 1);
  var Shift := (3 - (FPosition and 3)) * 2;
  Result := (FImage[(FPosition div 4) * 2 + Track] shr Shift) and 3;
end;

procedure TIntvKeyboardPeripherals.WriteCell;
begin
  // Only track B is recordable. In record mode the selector instead chooses audio.
  if (FRecordingPath = '') or (FDrive and $48 <> $08) or AtLeader then
    Exit;
  var Index := (FPosition div 4) * 2 + 1;
  var Shift := (3 - (FPosition and 3)) * 2;
  var Cell: Byte := 0;
  if FDrive and $80 <> 0 then
    Cell := 2 or FWriteBit;
  var Updated := (FImage[Index] and not (3 shl Shift)) or (Cell shl Shift);
  if Updated <> FImage[Index] then
  begin
    FImage[Index] := Updated;
    FDirty := True;
  end;
end;

procedure TIntvKeyboardPeripherals.Clock;
begin
  if FPrinterBusy > 0 then
    Dec(FPrinterBusy);
  if not FMounted or (MotorMode < 5) then
    Exit;
  Inc(FPhase, TapeBitRate);
  if FPhase < FClock then
    Exit;
  Dec(FPhase, FClock);
  var EndPosition := Length(FImage) * 2 - 1;
  case MotorMode of
    5:
      begin
        FPosition := Min(EndPosition, FPosition + 1);
        WriteCell;
        // The bit clock continues through unrecorded gaps inside the optical leaders.
        if FIRQEnabled and not AtLeader then
          FDataIRQ := True;
      end;
    6:
      FPosition := Max(0, FPosition - SeekSpeed);
    7:
      FPosition := Min(EndPosition, FPosition + SeekSpeed);
  end;
end;

function TIntvKeyboardPeripherals.InterruptPending: Boolean;
begin
  Result := FDataIRQ or (FExternalIRQEnabled and FPrinterStatus and
    (FPrintPath <> '') and (FPrinterBusy = 0));
end;

function TIntvKeyboardPeripherals.ReadTape(Address: Word): Byte;
begin
  case Address of
    $4000:
      Result := (ReadCell and 1) shl 7;
    $4001:
      Result := $80;
    $4002:
      Result := Ord(FMounted and AtLeader) shl 7;
    $4003:
      Result := Ord(not FMounted) shl 7;
    $4004:
      Result := Ord(ReadCell and 2 <> 0) shl 7;
    $4005:
      Result := Ord(ReadCell and 2 = 0) shl 7;
    $4007:
      Result := Ord(not FDataIRQ) shl 7;
  else
    Result := 0;
  end;
end;

procedure TIntvKeyboardPeripherals.WriteTape(Address: Word; Value: Byte);
begin
  case Address of
    $4020..$4027:
      begin
        var Bit := Address - $4020;
        if Bit < 3 then
          Bit := 2 - Bit;
        FLastAnalogFrame := -1;
        var PriorMode := MotorMode;
        FDrive := (FDrive and not (1 shl Bit)) or ((Value and 1) shl Bit);
        if (PriorMode <> 4) and (MotorMode = 4) then
          FMounted := False;
      end;
    $4040:
      FWriteBit := Value and 1;
    $4041:
      begin
        FIRQEnabled := Value and 1 <> 0;
        if not FIRQEnabled then
          FDataIRQ := False;
      end;
    $4042:
      FExternalIRQEnabled := Value and 1 = 0;
    $4080:
      FDataIRQ := False;
  end;
end;

function TIntvKeyboardPeripherals.ReadPrinter: Byte;
begin
  if FPrintPath = '' then
    Exit($10);
  Result := Ord(FPrinterStatus and (FPrinterBusy = 0)) shl 7;
end;

procedure TIntvKeyboardPeripherals.WritePrinter(Address: Word; Value: Byte);
begin
  if Address = $B7FE then
    FPrinterStatus := Value and $20 <> 0
  else if FPrintPath <> '' then
  begin
    FPrinter.WriteBuffer(Value, 1);
    FPrinterBusy := Max(1, FClock div 100);
    if FPrinter.Size >= MaxPrintBuffer then
      Flush;
  end;
end;

function TIntvKeyboardPeripherals.TapeFrame(Rate: Integer): Integer;
begin
  Result := ((Int64(FPosition) * FClock + FPhase) * Rate) div (Int64(FClock) * TapeBitRate);
end;

function TIntvKeyboardPeripherals.AnalogSize: Integer;
begin
  Result := ((Int64(Length(FImage)) * 2 * AnalogRecordingRate + TapeBitRate - 1) div TapeBitRate) * 2;
end;

function TIntvKeyboardPeripherals.ReadAnalog(Frame: Integer): Word;
begin
  Result := 0;
  if Frame * 2 + 1 < Length(FAnalog) then
    Result := FAnalog[Frame * 2] or (FAnalog[Frame * 2 + 1] shl 8);
end;

procedure TIntvKeyboardPeripherals.RecordAnalog(Frame: Integer; Sample: SmallInt);
begin
  if (FAnalogPath = '') or (Frame = FLastAnalogFrame) then
    Exit;
  if FAnalog = nil then
    SetLength(FAnalog, AnalogSize);
  // Unsigned little-endian PCM. Code zero means this position has no overlay.
  var Code := Max(Integer(Sample), -32767) + 32768;
  if FDrive and $80 <> 0 then
    Code := 32768;
  if ReadAnalog(Frame) <> Code then
  begin
    FAnalog[Frame * 2] := Byte(Code);
    FAnalog[Frame * 2 + 1] := Byte(Code shr 8);
    FAnalogDirty := True;
  end;
  FLastAnalogFrame := Frame;
end;

function TIntvKeyboardPeripherals.IsRecordingAudio: Boolean;
begin
  Result := FMounted and (MotorMode = 5) and (FDrive and $48 = $48) and
    (FDrive and $80 = 0) and (FAnalogPath <> '');
end;

function TIntvKeyboardPeripherals.AudioSample(Input: SmallInt): Integer;
begin
  Result := 0;
  if not FMounted or (MotorMode < 5) or AtLeader then
    Exit;
  var AnalogFrame := TapeFrame(AnalogRecordingRate);
  if FDrive and $48 = $48 then
    RecordAnalog(AnalogFrame, Input);
  if FDrive and $30 = $30 then
    Exit;

  var A := 0;
  var B := 0;
  var HasTrackB := FAudioChannels = 2;
  var Frame := TapeFrame(FAudioRate);
  if (FAudio <> nil) and ((Frame < FCachedStart) or (Frame >= FCachedStart + AudioBlockFrames)) then
  begin
    FCachedStart := Frame - (Frame mod AudioBlockFrames);
    FCachedFrames := 0;
    if FAudioSeek.SeekFrame(FCachedStart, nil) = FCachedStart then
      FCachedFrames := FAudio.Render(FAudioCache, AudioBlockFrames);
  end;
  if (FAudio <> nil) and (Frame < FCachedStart + FCachedFrames) then
  begin
    var Offset := Integer(Frame - FCachedStart) * FAudioChannels;
    A := FAudioCache[Offset];
    if HasTrackB then
      B := FAudioCache[Offset + 1];
  end;
  var Recorded := ReadAnalog(AnalogFrame);
  if Recorded <> 0 then
  begin
    B := Integer(Recorded) - 32768;
    HasTrackB := True;
  end;
  if FDrive and $20 = 0 then
    Inc(Result, A);
  if FDrive and $10 = 0 then
    Inc(Result, B);
  if HasTrackB and (FAudio <> nil) then
    Result := Result div 2;
end;

procedure TIntvKeyboardPeripherals.FlushWhenIdle;
begin
  if not FMounted or (MotorMode < 5) then
    Flush;
end;

procedure TIntvKeyboardPeripherals.Flush;
begin
  if FStorage = nil then
    Exit;
  if FDirty and (FRecordingPath <> '') then
  begin
    FStorage.WriteBytes(FRecordingPath, FImage);
    FDirty := False;
  end;
  if FAnalogDirty then
  begin
    FStorage.WriteBytes(FAnalogPath, FAnalog);
    FAnalogDirty := False;
  end;
  if (FPrintPath = '') or (FPrinter.Size = 0) then
    Exit;
  var Output := TMemoryStream.Create;
  try
    if FStorage.Exists(FPrintPath) then
    begin
      var Previous := FStorage.OpenRead(FPrintPath);
      try
        Output.CopyFrom(Previous, 0);
      finally
        Previous.Free;
      end;
    end;
    FPrinter.Position := 0;
    try
      Output.CopyFrom(FPrinter, FPrinter.Size);
      FStorage.WriteAtomic(FPrintPath, Output);
      FPrinter.Size := 0;
    finally
      FPrinter.Position := FPrinter.Size;
    end;
  finally
    Output.Free;
  end;
end;

procedure TIntvKeyboardPeripherals.SerializeState(State: TStateArchive);
begin
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FDrive, SizeOf(FDrive));
  State.Field(FWriteBit, SizeOf(FWriteBit));
  State.Field(FMounted, SizeOf(FMounted));
  State.Field(FDataIRQ, SizeOf(FDataIRQ));
  State.Field(FIRQEnabled, SizeOf(FIRQEnabled));
  State.Field(FPrinterStatus, SizeOf(FPrinterStatus));
  State.Field(FExternalIRQEnabled, SizeOf(FExternalIRQEnabled));
  State.Field(FPrinterBusy, SizeOf(FPrinterBusy));
  var PreviousImage: TBytes;
  if State.Loading then
    PreviousImage := Copy(FImage);
  if FImage <> nil then
    State.Field(FImage[0], Length(FImage));
  var PreviousAnalog: TBytes;
  if State.Loading then
    PreviousAnalog := FAnalog;
  if (State.Version = 0) or (State.Version >= 6) then
    State.OptionalBytes(FAnalog, AnalogSize)
  else if State.Loading then
    FAnalog := nil;
  if State.Loading then
  begin
    if ((FAnalog <> nil) and (Length(FAnalog) <> AnalogSize)) or
      (FPosition < 0) or (FPosition >= Max(1, Length(FImage) * 2)) or
      (FPhase < 0) or (FPhase >= FClock) or (FWriteBit > 1) or
      (FPrinterBusy < 0) or (FPrinterBusy > Max(1, FClock div 100)) or
      (FMounted and (FImage = nil)) then
      raise EReadError.Create('Invalid Keyboard Component peripheral state');
    // Printed bytes are host output. The tape's writable image follows guest time.
    FCachedStart := -AudioBlockFrames;
    FCachedFrames := 0;
    FLastAnalogFrame := -1;
    if FAnalogPath <> '' then
      FAnalogDirty := FAnalogDirty or (Length(FAnalog) <> Length(PreviousAnalog)) or
        ((FAnalog <> nil) and not CompareMem(Pointer(FAnalog), Pointer(PreviousAnalog), Length(FAnalog)));
    if (FImage <> nil) and (FRecordingPath <> '') then
      FDirty := FDirty or not CompareMem(Pointer(FImage), Pointer(PreviousImage), Length(FImage));
  end;
end;

end.

