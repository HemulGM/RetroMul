unit Core.Snapshots;

interface

uses
  Core.Storage, System.SysUtils, System.Classes, System.SyncObjs;

type
  // Persist fields, never object references, callbacks or host audio handles.
  // Bump MakeHeader's version when any core's serialized field order/layout changes.
  TStateArchive = class
  private
    FStream: TStream;
    FLoading: Boolean;
  public
    constructor Create(Stream: TStream; Loading: Boolean);
    procedure Field(var Value; Size: Integer);
    property Loading: Boolean read FLoading;
  end;

  TStateTransfer = reference to procedure(State: TStateArchive);

  TSnapshotAction = reference to procedure(const Name: string; Loading: Boolean);

  // Commands execute only on the owning emulation thread, also while paused.
  TSnapshotQueue = class
  private
    FLock, FCommandLock: TCriticalSection;
    FDone: TEvent;
    FPending, FLoading: Boolean;
    FName, FError: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute(Worker: TThread; const Name: string; Loading: Boolean);
    procedure Process(const Action: TSnapshotAction);
  end;

function SnapshotIdentity(const ROM: TBytes): string;

// Replace in the same directory without requiring a backup filename.
procedure SaveStreamAtomically(Stream: TMemoryStream; const Path: string; const Storage: IStorage = nil);

procedure SaveCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer; const Storage: IStorage = nil);

procedure LoadCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer; const Storage: IStorage = nil);

procedure SaveSnapshotPreview(const Path: string; Width, Height, Stride: Integer; Pixels: Pointer; const Storage: IStorage = nil);

implementation

uses
  System.Hash, System.ZLib;

type
  THeader = packed record
    Magic: array[0..7] of AnsiChar;
    Version, PayloadSize: Cardinal;
    platform: array[0..7] of AnsiChar;
    ROMHash, Digest: array[0..31] of Byte;
  end;

{ TStateArchive }

constructor TStateArchive.Create(Stream: TStream; Loading: Boolean);
begin
  inherited Create;
  FStream := Stream;
  FLoading := Loading;
end;

procedure TStateArchive.Field(var Value; Size: Integer);
begin
  var StoredSize := Size;
  if FLoading then
  begin
    FStream.ReadBuffer(StoredSize, SizeOf(StoredSize));
    if (StoredSize <> Size) or (Size < 0) or (Size > FStream.Size - FStream.Position) then
      raise EReadError.Create('Incompatible or truncated snapshot');
    if Size > 0 then
      FStream.ReadBuffer(Value, Size);
  end
  else
  begin
    FStream.WriteBuffer(StoredSize, SizeOf(StoredSize));
    if Size > 0 then
      FStream.WriteBuffer(Value, Size);
  end;
end;

procedure TransferStream(Stream: TStream; Loading: Boolean; const Transfer: TStateTransfer);
begin
  var State := TStateArchive.Create(Stream, Loading);
  try
    Transfer(State);
  finally
    State.Free;
  end;
end;

procedure SaveStreamAtomically(Stream: TMemoryStream; const Path: string; const Storage: IStorage);
begin
  var TargetStorage := Storage;
  if TargetStorage = nil then
    TargetStorage := TStorage.Default;
  TargetStorage.WriteAtomic(Path, Stream);
end;

function SnapshotIdentity(const ROM: TBytes): string;
begin
  var Hash := THashSHA2.Create;
  Hash.Update(ROM);
  Result := Hash.HashAsString;
end;

function MakeHeader(const PlatformCore: string; const ROM: TBytes): THeader;
begin
  Result := Default(THeader);
  var Magic: AnsiString := 'RMSNAP01';
  Move(Magic[1], Result.Magic, 8);
  Result.Version := 1;
  // GB/GBC v2 adds OAM DMA, serial, timer reload and MBC3 RTC state.
  if (PlatformCore = 'GB') or (PlatformCore = 'GBC') then
    Result.Version := 2;
  // Camera v3 records the latched sensor frame for an in-flight capture.
  // Leave snapshot compatibility unchanged for all other GB/GBC cartridges.
  if ((PlatformCore = 'GB') or (PlatformCore = 'GBC')) and
    (Length(ROM) > $147) and (ROM[$147] = $FC) then
    Result.Version := 3;
  // MD v4 adds Z80 HALT, interrupt mode and EI delay.
  if PlatformCore = 'MD' then
    Result.Version := 4;
  // SNES v8 persists IRQ counters, HDMA scheduling and the partial PPU pipeline.
  if PlatformCore = 'SNES' then
    Result.Version := 8;
  var Core := AnsiString(PlatformCore);
  if (Length(Core) = 0) or (Length(Core) > 8) then
    raise EArgumentException.Create('Invalid snapshot platform');

  Move(Core[1], Result.platform, Length(Core));
  var Hash := THashSHA2.Create;
  Hash.Update(ROM);
  var Digest := Hash.HashAsBytes;
  Move(Digest[0], Result.ROMHash, 32);
end;

procedure SaveCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer; const Storage: IStorage);
begin
  var Payload := TMemoryStream.Create;
  var Output := TMemoryStream.Create;
  try
    TransferStream(Payload, False, Transfer);
    var Header := MakeHeader(platform, ROM);
    Header.PayloadSize := Payload.Size;
    Payload.Position := 0;
    var Digest := THashSHA2.GetHashBytes(Payload);
    Move(Digest[0], Header.Digest, 32);
    Output.WriteBuffer(Header, SizeOf(Header));
    Output.WriteBuffer(Payload.Memory^, Payload.Size);
    SaveStreamAtomically(Output, Path, Storage);
  finally
    Output.Free;
    Payload.Free;
  end;
end;

procedure LoadCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer; const Storage: IStorage);
begin
  var SourceStorage := Storage;
  if SourceStorage = nil then
    SourceStorage := TStorage.Default;
  var Input := SourceStorage.OpenRead(Path);
  var Payload := TMemoryStream.Create;
  var Backup := TMemoryStream.Create;
  try
    var Header: THeader;
    Input.ReadBuffer(Header, SizeOf(Header));
    var Expected := MakeHeader(platform, ROM);
    if not CompareMem(@Header.Magic, @Expected.Magic, 8) or
      (Header.Version <> Expected.Version) or
      not CompareMem(@Header.platform, @Expected.platform, 8) or
      not CompareMem(@Header.ROMHash, @Expected.ROMHash, 32) or
      (Header.PayloadSize = 0) or (Header.PayloadSize > 64 * 1024 * 1024) or
      (Int64(Header.PayloadSize) <> Input.Size - Input.Position) then
      raise EReadError.Create('Snapshot is incompatible with this game or core');

    Payload.CopyFrom(Input, Header.PayloadSize);
    Payload.Position := 0;
    var Digest := THashSHA2.GetHashBytes(Payload);
    if not CompareMem(@Digest[0], @Header.Digest, 32) then
      raise EReadError.Create('Snapshot checksum mismatch');

    TransferStream(Backup, False, Transfer);
    try
      Payload.Position := 0;
      TransferStream(Payload, True, Transfer);
      if Payload.Position <> Payload.Size then
        raise EReadError.Create('Unexpected snapshot data');
    except
      Backup.Position := 0;
      TransferStream(Backup, True, Transfer);
      raise;
    end;
  finally
    Backup.Free;
    Payload.Free;
    Input.Free;
  end;
end;

procedure SaveSnapshotPreview(const Path: string; Width, Height, Stride: Integer; Pixels: Pointer; const Storage: IStorage);
const
  Signature: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
var
  Stream, Compressed: TMemoryStream;

  procedure WriteUInt32(Value: Cardinal);
  begin
    var Bytes: array[0..3] of Byte;
    Bytes[0] := Value shr 24;
    Bytes[1] := (Value shr 16) and $FF;
    Bytes[2] := (Value shr 8) and $FF;
    Bytes[3] := Value and $FF;
    Stream.WriteBuffer(Bytes, SizeOf(Bytes));
  end;

  procedure WriteChunk(const Kind: AnsiString; Data: Pointer; Size: Integer);

    procedure UpdateCRC(var CRC: Cardinal; Buffer: Pointer; Count: Integer);
    begin
      var P := PByte(Buffer);
      for var i := 0 to Count - 1 do
      begin
        CRC := CRC xor P^;
        for var Bit := 0 to 7 do
          if (CRC and 1) <> 0 then
            CRC := (CRC shr 1) xor $EDB88320
          else
            CRC := CRC shr 1;
        Inc(P);
      end;
    end;

  begin
    WriteUInt32(Size);
    Stream.WriteBuffer(Kind[1], 4);
    if Size > 0 then
      Stream.WriteBuffer(Data^, Size);
    var CRC: Cardinal := $FFFFFFFF;
    UpdateCRC(CRC, PAnsiChar(Kind), 4);
    UpdateCRC(CRC, Data, Size);
    WriteUInt32(CRC xor $FFFFFFFF);
  end;

begin
  if (Pixels = nil) or (Width < 1) or (Height < 1) or
    (Width > 2048) or (Height > 2048) or (Stride < Width) or
    (Int64(Stride) * Height * 4 > MaxInt) then
    raise EArgumentOutOfRangeException.Create('Invalid snapshot preview dimensions');
  Stream := TMemoryStream.Create;
  Compressed := TMemoryStream.Create;
  try
    Stream.WriteBuffer(Signature, SizeOf(Signature));
    var Header: array[0..12] of Byte;
    FillChar(Header, SizeOf(Header), 0);
    Header[2] := (Width shr 8) and $FF;
    Header[3] := Width and $FF;
    Header[6] := (Height shr 8) and $FF;
    Header[7] := Height and $FF;
    Header[8] := 8; // Eight-bit RGB; emulator output is opaque ARGB.
    Header[9] := 2;
    WriteChunk('IHDR', @Header, SizeOf(Header));
    var Row: TBytes;
    SetLength(Row, 1 + Width * 3);
    Row[0] := 0; // PNG filter None.
    var Compressor := TZCompressionStream.Create(Compressed);
    try
      var Source := PCardinal(Pixels);
      for var Y := 0 to Height - 1 do
      begin
        for var X := 0 to Width - 1 do
        begin
          var Color := Source^;
          Inc(Source);
          Row[1 + X * 3] := (Color shr 16) and $FF;
          Row[2 + X * 3] := (Color shr 8) and $FF;
          Row[3 + X * 3] := Color and $FF;
        end;
        Compressor.WriteBuffer(Row[0], Length(Row));
        Inc(Source, Stride - Width);
      end;
    finally
      Compressor.Free;
    end;
    WriteChunk('IDAT', Compressed.Memory, Compressed.Size);
    WriteChunk('IEND', nil, 0);
    SaveStreamAtomically(Stream, ChangeFileExt(Path, '.png'), Storage);
  finally
    Compressed.Free;
    Stream.Free;
  end;
end;

{ TSnapshotQueue }

constructor TSnapshotQueue.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FCommandLock := TCriticalSection.Create;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TSnapshotQueue.Destroy;
begin
  FDone.Free;
  FCommandLock.Free;
  FLock.Free;
  inherited;
end;

procedure TSnapshotQueue.Execute(Worker: TThread; const Name: string; Loading: Boolean);
begin
  if (Name = '') or (Length(Name) > 80) then
    raise EArgumentException.Create('Invalid snapshot name');

  for var C in Name do
    if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      raise EArgumentException.Create('Snapshot names use letters, digits, - and _');

  FCommandLock.Enter;
  try
    if (Worker = nil) or Worker.Suspended or Worker.Finished then
      raise EInvalidOpException.Create('Emulation worker is not running');

    FLock.Enter;
    try
      FDone.ResetEvent;
      FName := Name;
      FLoading := Loading;
      FError := '';
      FPending := True;
    finally
      FLock.Leave;
    end;
    while FDone.WaitFor(50) <> wrSignaled do
      if Worker.Finished then
        raise EInvalidOpException.Create('Emulation stopped before completing the snapshot');

    FLock.Enter;
    try
      if FError <> '' then
        raise EReadError.Create(FError);
    finally
      FLock.Leave;
    end;
  finally
    FCommandLock.Leave;
  end;
end;

procedure TSnapshotQueue.Process(const Action: TSnapshotAction);
begin
  FLock.Enter;
  try
    if not FPending then
      Exit;

    try
      Action(FName, FLoading);
    except
      on E: Exception do
        FError := E.Message;
    end;
    FPending := False;
    FDone.SetEvent;
  finally
    FLock.Leave;
  end;
end;

end.

