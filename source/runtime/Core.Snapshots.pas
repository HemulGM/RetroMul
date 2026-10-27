unit Core.Snapshots;

interface

uses
  Core.RomFormat, Core.Storage, System.SysUtils, System.Classes, System.SyncObjs;

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
    FValidateNames: Boolean;
  public
    constructor Create(ValidateNames: Boolean = True);
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
  Core.SavePaths, System.Hash, System.ZLib;

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
  // MSX v3 adds RTC/calendar, floppy, cassette, Kanji, mouse and slot-2 states.
  // MSX v5 adds SCC+ RAM/clock latches, Y8950/board state and the YJK line latch.
  // MSX v6 adds deferred VRAM transactions, video-fetch latches and CSM phase.
  // MSX v7 adds clocked sprite statuses and positional bitmap fetch latches.
  // MSX v8 adds silicon identity and asynchronous status-read recovery.
  // MSX v9 adds the status transition history for CPU sample/acknowledge timing.
  // MSX v10 adds accepted CPU transactions, request-buffer grants and dummy slots.
  // MSX v11 separates issued RAM transactions from their CAS data completion.
  // MSX v12 keeps the previous R18 latch and the command's memory-clock origin.
  // MSX v13 retains video-read addresses between CAS assertion and release.
  // MSX v14 distinguishes ignored border reads and rebuilds per-line fetch windows.
  // MSX v16 also stores the V9958 WAIT latch and validates motherboard wiring.
  if SameText(PlatformCore, 'MSX1') or SameText(PlatformCore, 'MSX2') or
    SameText(PlatformCore, 'MSX2PLUS') then Result.Version := 16;
  // ZX v16 adds Profi CMR1, DS80 latches/palette and variable-sector disk states.
  // ZX v17 adds Byte PROM gate, VI53, Byte-01 RAM/video and KDI geometry.
  // ZX v18 adds Didaktik Gama 8255 mode, latches and output/interrupt state.
  // ZX v19 adds TK90X/TK95 timing and original ROM language selection.
  // ZX v20 adds the Turbo Sound FM configuration, CPLD and both YM2203 states.
  // ZX v21 adds Next-DAC startup configuration, gates, selector and sample latches.
  // ZX v22 adds the independent General Sound CPU, memory, clocks and DAC state.
  // ZX v23 adds NeoGS and the shared native SPI SD state.
  // ZX v24 stores VS1011e, MP3 DMA, CPLD/FPGA and programmable flash.
  // ZX v25 adds DMA USC controller/timers, physical DMA and bus continuation.
  // ZX v26 adds ZXM-MoonSound and shared 040B/016D flash geometry.
  // ZX v27 adds the eZX/MB SID voices, filters and rational clock phases.
  // ZX v28 adds the SID interface selection and the fixed 1 MHz HardSID clock.
  if SameText(PlatformCore, 'ZX') then
    Result.Version := 28;
  // CPS v2 adds OKI bank state, enlarged sprite buffers and board peripherals.
  if SameText(PlatformCore, 'CPS1') or SameText(PlatformCore, 'CPS2') then
    Result.Version := 2;
  // CPS1 v3 stores medal devices and independent multigame flash selectors.
  if SameText(PlatformCore, 'CPS1') then
    Result.Version := 4;
  // Z80 MEMPTR/Q extend the serialized CPU record; reject older layouts.
  if (PlatformCore = ROM_CORE_ID_SG1000) or (PlatformCore = ROM_CORE_ID_SC3000) then
    Result.Version := 3;
  if (PlatformCore = ROM_CORE_ID_SF7000) or (PlatformCore = ROM_CORE_ID_OMV) or
    (PlatformCore = ROM_CORE_ID_SMS) or (PlatformCore = ROM_CORE_ID_GG) or
    SameText(PlatformCore, 'NGP') or SameText(PlatformCore, 'NGPC') then
    Result.Version := 2;
  // SMS/GG v4 also preserves a partially rendered CRAM transition scanline.
  if (PlatformCore = ROM_CORE_ID_SMS) or (PlatformCore = ROM_CORE_ID_GG) then
    Result.Version := 4;
  if SameText(PlatformCore, 'N64') then
    // N64 v4 preserves the clocked DMA/event queues, hidden RDRAM bits,
    // 64-bit architectural CPU state and the software VI pipeline.
    Result.Version := 4;
  // GB/GBC v5 extends the sprite FIFO selection and stores fractional CPU clocks.
  // Earlier layouts are rejected; host enhancement settings are not restored.
  if (PlatformCore = ROM_CORE_ID_GB) or (PlatformCore = ROM_CORE_ID_GBC) then
    Result.Version := 5;
  // MD v9 also stores Z80 MEMPTR/Q.
  if PlatformCore = ROM_CORE_ID_MD then
    Result.Version := 9;
  // SNES v10 adds the S-DSP phase latches, SPC MMIO latches and PPU mosaic counter.
  if PlatformCore = ROM_CORE_ID_SNES then
    Result.Version := 10;
  // GBA v6 adds the clocked video pipeline and HALT synchronizer.
  if PlatformCore = ROM_CORE_ID_GBA then
    Result.Version := 6;
  // Neo Geo v4 and Neo Geo CD v3 also store Z80 MEMPTR/Q.
  if PlatformCore = ROM_CORE_ID_NEOGEO then
    Result.Version := 4;
  if PlatformCore = ROM_CORE_ID_NEOGEOCD then
    Result.Version := 3;
  // Saturn v5 adds physical presence of the optional offline NetLink cartridge.
  if SameText(PlatformCore, 'SATURN') then
    Result.Version := 5;
  // PS2 v2 adds the GS drawing timeline and FINISH writes not shown yet;
  // v3 the IOP strtok position.
  if PlatformCore = ROM_CORE_ID_PS2 then
    Result.Version := 3;
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
    if SameText(platform, 'N64') and
      CompareMem(@Header.Magic, @Expected.Magic, 8) and
      CompareMem(@Header.platform, @Expected.platform, 8) and
      (Header.Version <> Expected.Version) then
      raise EReadError.CreateFmt('N64 snapshot version %d is unsupported; expected version %d', [Header.Version, Expected.Version]);

    if SameText(platform, 'PS1') and
      CompareMem(@Header.Magic, @Expected.Magic, 8) and
      CompareMem(@Header.platform, @Expected.platform, 8) and
      not CompareMem(@Header.ROMHash, @Expected.ROMHash, 32) then
      raise EReadError.Create('This PS1 snapshot belongs to a different disc. Insert the disc used to save it.');

    if not CompareMem(@Header.Magic, @Expected.Magic, 8) or
      ((Header.Version <> Expected.Version) and not
      (SameText(platform, 'SATURN') and ((Header.Version = 2) or (Header.Version = 3) or (Header.Version = 4)))) or
      not CompareMem(@Header.platform, @Expected.platform, 8) or
      not CompareMem(@Header.ROMHash, @Expected.ROMHash, 32) or
      (Header.PayloadSize = 0) or
      ((Header.PayloadSize > 64 * 1024 * 1024) and not
      (SameText(platform, 'CPS3') and (Header.PayloadSize <= 128 * 1024 * 1024))) or
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
  FValidateNames:=ValidateNames;
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
  if FValidateNames then ValidateSnapshotName(Name);

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

