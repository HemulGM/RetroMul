unit Core.Snapshots;

interface

uses
  Core.Storage, System.SysUtils, System.Classes, System.SyncObjs;

type
  // Persist fields, never object references, callbacks or host audio handles.
  // Each platform registers its own serialized layout version.
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
    FValidateNames: Boolean;
  public
    constructor Create(ValidateNames: Boolean = True);
    destructor Destroy; override;
    procedure Execute(Worker: TThread; const Name: string; Loading: Boolean);
    procedure Process(const Action: TSnapshotAction);
  end;

type
  TSnapshotPolicy = record
    Version: Cardinal;
    AcceptedVersions: TArray<Cardinal>;
    MaximumSize: Cardinal;
    VersionError, IdentityError: string;
    class function Create(Version: Cardinal; MaximumSize: Cardinal = 64 * 1024 * 1024): TSnapshotPolicy; static;
    function Accepts(Value: Cardinal): Boolean;
  end;

procedure RegisterSnapshotPolicy(const CoreId: string; const Policy: TSnapshotPolicy);

function SnapshotPolicy(const CoreId: string): TSnapshotPolicy;

function SnapshotIdentity(const ROM: TBytes): string;

// Replace in the same directory without requiring a backup filename.
procedure SaveStreamAtomically(Stream: TMemoryStream; const Path: string; const Storage: IStorage = nil);

procedure SaveCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer; const Storage: IStorage = nil);

procedure LoadCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer; const Storage: IStorage = nil);

procedure SaveSnapshotPreview(const Path: string; Width, Height, Stride: Integer; Pixels: Pointer; const Storage: IStorage = nil);

implementation

uses
  Core.SavePaths, System.Hash, System.ZLib, System.Generics.Collections,
  System.Generics.Defaults;

type
  THeader = packed record
    Magic: array[0..7] of AnsiChar;
    Version, PayloadSize: Cardinal;
    platform: array[0..7] of AnsiChar;
    ROMHash, Digest: array[0..31] of Byte;
  end;

var
  Policies: TDictionary<string, TSnapshotPolicy>;

class function TSnapshotPolicy.Create(Version, MaximumSize: Cardinal): TSnapshotPolicy;
begin
  Result := Default(TSnapshotPolicy);
  Result.Version := Version;
  Result.MaximumSize := MaximumSize;
end;

function TSnapshotPolicy.Accepts(Value: Cardinal): Boolean;
begin
  Result := Value = Version;
  for var Accepted in AcceptedVersions do
    Result := Result or (Accepted = Value);
end;

procedure RegisterSnapshotPolicy(const CoreId: string; const Policy: TSnapshotPolicy);
begin
  if (CoreId.Trim = '') or (Policy.Version = 0) or (Policy.MaximumSize = 0) then
    raise EArgumentException.Create('Invalid snapshot policy');
  var Value := Policy;
  Value.AcceptedVersions := Copy(Policy.AcceptedVersions);
  Policies.Add(CoreId.Trim, Value);
end;

function SnapshotPolicy(const CoreId: string): TSnapshotPolicy;
begin
  if not Policies.TryGetValue(CoreId.Trim, Result) then
    Result := TSnapshotPolicy.Create(1);
  Result.AcceptedVersions := Copy(Result.AcceptedVersions);
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
  Result.Version := SnapshotPolicy(PlatformCore).Version;
  var Core := AnsiString(PlatformCore);
  var Utf8Id := TEncoding.UTF8.GetBytes(PlatformCore);
  if (Length(Utf8Id) = 0) or (Length(Utf8Id) > 4096) then
    raise EArgumentException.Create('Invalid snapshot platform');
  var LegacyId := Length(PlatformCore) <= 8;
  for var Character in PlatformCore do
    LegacyId := LegacyId and (Ord(Character) >= 32) and (Ord(Character) <= 126);
  if LegacyId then
    Move(Core[1], Result.platform, Length(Core))
  else
  begin
    Magic := 'RMSNAP02';
    Move(Magic[1], Result.Magic, 8);
  end;
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
    if Header.Magic[7] = '2' then
    begin
      var Id := TEncoding.UTF8.GetBytes(platform);
      var IdSize := Cardinal(Length(Id));
      Output.WriteBuffer(IdSize, SizeOf(IdSize));
      Output.WriteBuffer(Id[0], IdSize);
    end;
    if Payload.Size > 0 then
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
    var PlatformMatches := True;
    if CompareMem(@Header.Magic, PAnsiChar(AnsiString('RMSNAP02')), 8) then
    begin
      var IdSize: Cardinal;
      Input.ReadBuffer(IdSize, SizeOf(IdSize));
      if (IdSize = 0) or (IdSize > 4096) or (IdSize > Input.Size - Input.Position) then
        raise EReadError.Create('Invalid snapshot platform ID');
      var Id: TBytes;
      SetLength(Id, IdSize);
      Input.ReadBuffer(Id[0], IdSize);
      var ExpectedId := TEncoding.UTF8.GetBytes(platform);
      PlatformMatches := (Length(Id) = Length(ExpectedId)) and
        CompareMem(@Id[0], @ExpectedId[0], Length(Id));
    end;
    var Policy := SnapshotPolicy(platform);
    if PlatformMatches and CompareMem(@Header.Magic, @Expected.Magic, 8) and
      CompareMem(@Header.platform, @Expected.platform, 8) then
    begin
      if (Header.Version <> Expected.Version) and (Policy.VersionError <> '') then
        raise EReadError.CreateFmt(Policy.VersionError, [Header.Version, Expected.Version]);
      if not CompareMem(@Header.ROMHash, @Expected.ROMHash, 32) and (Policy.IdentityError <> '') then
        raise EReadError.Create(Policy.IdentityError);
    end;
    if not PlatformMatches or not CompareMem(@Header.Magic, @Expected.Magic, 8) or
      not Policy.Accepts(Header.Version) or
      not CompareMem(@Header.platform, @Expected.platform, 8) or
      not CompareMem(@Header.ROMHash, @Expected.ROMHash, 32) or
      (Header.PayloadSize = 0) or (Header.PayloadSize > Policy.MaximumSize) or
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

  procedure WriteChunk(const Kind: AnsiString; const Data: TBytes);
  var
    CRC: Cardinal;

    procedure UpdateCRC(Value: Byte);
    begin
      CRC := CRC xor Value;
      for var Bit := 0 to 7 do
        if (CRC and 1) <> 0 then
          CRC := (CRC shr 1) xor $EDB88320
        else
          CRC := CRC shr 1;
    end;

  begin
    WriteUInt32(Length(Data));
    Stream.WriteBuffer(Kind[1], 4);
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[0], Length(Data));
    CRC := $FFFFFFFF;
    for var I := 1 to 4 do
      UpdateCRC(Ord(Kind[I]));
    for var Value in Data do
      UpdateCRC(Value);
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
    var Header: TBytes;
    SetLength(Header, 13);
    Header[2] := (Width shr 8) and $FF;
    Header[3] := Width and $FF;
    Header[6] := (Height shr 8) and $FF;
    Header[7] := Height and $FF;
    Header[8] := 8; // Eight-bit RGB; emulator output is opaque ARGB.
    Header[9] := 2;
    WriteChunk('IHDR', Header);
    var Row: TBytes;
    SetLength(Row, 1 + Width * 3);
    Row[0] := 0; // PNG filter None.
    var Compressor := TZCompressionStream.Create(Compressed);
    try
      // Copy the host framebuffer once; all traversal uses checked array indices.
      var Source: TArray<Cardinal>;
      SetLength(Source, (Height - 1) * Stride + Width);
      Move(Pixels^, Source[0], Length(Source) * SizeOf(Cardinal));
      for var Y := 0 to Height - 1 do
      begin
        for var X := 0 to Width - 1 do
        begin
          var Color := Source[Y * Stride + X];
          Row[1 + X * 3] := (Color shr 16) and $FF;
          Row[2 + X * 3] := (Color shr 8) and $FF;
          Row[3 + X * 3] := Color and $FF;
        end;
        Compressor.WriteBuffer(Row[0], Length(Row));
      end;
    finally
      Compressor.Free;
    end;
    var Payload: TBytes;
    SetLength(Payload, Compressed.Size);
    Compressed.Position := 0;
    if Length(Payload) > 0 then
      Compressed.ReadBuffer(Payload[0], Length(Payload));
    WriteChunk('IDAT', Payload);
    WriteChunk('IEND', nil);
    SaveStreamAtomically(Stream, ChangeFileExt(Path, '.png'), Storage);
  finally
    Compressed.Free;
    Stream.Free;
  end;
end;

{ TSnapshotQueue }

constructor TSnapshotQueue.Create(ValidateNames: Boolean);
begin
  inherited Create;
  FValidateNames := ValidateNames;
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
  // Peripheral workers can reuse the synchronous command transport for media
  // locations. Snapshot clients retain strict name validation by default.
  if FValidateNames then
    ValidateSnapshotName(Name);

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

initialization
  Policies := TDictionary<string, TSnapshotPolicy>.Create(TIStringComparer.Ordinal);

finalization
  Policies.Free;

end.

