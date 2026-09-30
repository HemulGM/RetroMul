unit Core.Snapshots;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

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
procedure SaveStreamAtomically(Stream: TMemoryStream; const Path: string);

procedure SaveCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer);

procedure LoadCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer);

procedure SaveSnapshotPreview(const Path: string; Width, Height, Stride: Integer; Pixels: Pointer);

implementation

uses
  System.Hash,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Stdio,
  {$ENDIF}
  System.IOUtils;

type
  THeader = packed record
    Magic: array[0..7] of AnsiChar;
    Version, PayloadSize: Cardinal;
    platform: array[0..7] of AnsiChar;
    ROMHash, Digest: array[0..31] of Byte;
  end;

  TBitmapHeader = packed record
    Signature: Word;
    FileSize, Reserved, PixelOffset, InfoSize: Cardinal;
    Width, Height: Integer;
    Planes, Bits: Word;
    Compression, ImageSize: Cardinal;
    XPels, YPels: Integer;
    Colors, ImportantColors: Cardinal;
  end;

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

procedure SaveStreamAtomically(Stream: TMemoryStream; const Path: string);
begin
  ForceDirectories(ExtractFilePath(ExpandFileName(Path)));
  var Temporary := Path + '.' + TGUID.NewGuid.ToString + '.tmp';
  try
    Stream.SaveToFile(Temporary);
    {$IFDEF MSWINDOWS}
    if not MoveFileEx(PChar(Temporary), PChar(Path), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
    {$ELSE}
    var Source := UTF8String(Temporary);
    var Dest := UTF8String(Path);
    if Posix.Stdio.__rename(PAnsiChar(Source), PAnsiChar(Dest)) <> 0 then
      RaiseLastOSError;
    {$ENDIF}
  finally
    if TFile.Exists(Temporary) then
      TFile.Delete(Temporary);
  end;
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
  var Core := AnsiString(PlatformCore);
  if (Length(Core) = 0) or (Length(Core) > 8) then
    raise EArgumentException.Create('Invalid snapshot platform');
  Move(Core[1], Result.platform, Length(Core));
  var Hash := THashSHA2.Create;
  Hash.Update(ROM);
  var Digest := Hash.HashAsBytes;
  Move(Digest[0], Result.ROMHash, 32);
end;

procedure SaveCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer);
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
    SaveStreamAtomically(Output, Path);
  finally
    Output.Free;
    Payload.Free;
  end;
end;

procedure LoadCoreSnapshot(const Path, platform: string; const ROM: TBytes; const Transfer: TStateTransfer);
begin
  var Input := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
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

procedure SaveSnapshotPreview(const Path: string; Width, Height, Stride: Integer; Pixels: Pointer);
begin
  var Stream := TMemoryStream.Create;
  try
    var Header := Default(TBitmapHeader);
    Header.Signature := $4D42;
    Header.PixelOffset := SizeOf(Header);
    Header.InfoSize := 40;
    Header.Width := Width;
    Header.Height := -Height;
    Header.Planes := 1;
    Header.Bits := 32;
    Header.ImageSize := Width * Height * 4;
    Header.FileSize := Header.PixelOffset + Header.ImageSize;
    Stream.WriteBuffer(Header, SizeOf(Header));
    var Row := PByte(Pixels);
    for var Y := 0 to Height - 1 do
    begin
      Stream.WriteBuffer(Row^, Width * 4);
      Inc(Row, Stride * 4);
    end;
    SaveStreamAtomically(Stream, ChangeFileExt(Path, '.bmp'));
  finally
    Stream.Free;
  end;
end;

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

