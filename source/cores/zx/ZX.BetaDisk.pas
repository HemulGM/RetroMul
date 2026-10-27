unit ZX.BetaDisk;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TZXDisk = class
  private
    FData: TBytes;
    FCylinders, FHeads: Integer;
    FSectorSize, FSectorsPerTrack: Integer;
    FDirty, FProtected, FProfiBoot: Boolean;
    FRevision: Cardinal;
    procedure ContentChanged; inline;
  public
    constructor Create(const Data: TBytes; SCL: Boolean; ProfiMedia: Boolean = False; KDI: Boolean = False);
    constructor CreateRaw(const Data: TBytes; Cylinders, Heads, Sectors, SectorSize: Integer);
    function SectorId(Cylinder, Head, Position: Integer): Integer;
    function Offset(Cylinder, Head, Sector: Integer): Integer;
    procedure SerializeState(State: TStateArchive);
    function Image: TBytes;
    property SectorSize: Integer read FSectorSize;
    property Cylinders: Integer read FCylinders;
    property Heads: Integer read FHeads;
    property Dirty: Boolean read FDirty write FDirty;
    property WriteProtected: Boolean read FProtected write FProtected;
  end;

  TZXFDCPhase = (fdcIdle, fdcSeek, fdcFind, fdcRead, fdcWrite, fdcCRC, fdcFailure);

  TZXBetaDisk = class
  private
    const
      RotationT = 700000;
  protected
    FDisks: array[0..3] of TZXDisk;
    FPhysicalTrack: array[0..3] of Integer;
    FControl, FCommand, FTrack, FSector, FData, FError, FForce: Byte;
    FBusy, FDRQ, FINTRQ, FTypeI, FHeadLoaded, FFormatCRCWait: Boolean;
    FPhase: TZXFDCPhase;
    FTimer, FRotation, FDirection, FPosition, FLength, FOffset: Integer;
    FBuffer: TBytes;
    FReadSectors, FWrittenSectors: UInt64;
    FTrackCache: TBytes;
    FTrackCacheValid: Boolean;
    FTrackCacheDrive, FTrackCacheCylinder, FTrackCacheHead: Integer;
    FTrackCacheRevision: Cardinal;
    procedure InvalidateTrackCache;
    procedure BuildReadTrack(D: TZXDisk; Cylinder, Side: Integer);
    procedure ProcessPhase;
    function Selected: Integer; virtual;
    function Head: Integer; virtual;
    function Ready: Boolean; virtual;
    procedure Finish(Error: Byte = 0);
    procedure Command(Value: Byte);
    procedure FindSector;
    procedure StartTransfer;
    procedure EndTransfer;
    procedure FormatTrack;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Mount(const Data: TBytes; SCL: Boolean; Drive: Integer = 0; ProfiMedia: Boolean = False; KDI: Boolean = False);
    procedure MountRaw(const Data: TBytes; Cylinders, Heads, Sectors, SectorSize, Drive: Integer);
    procedure Reset; virtual;
    procedure EjectAll;
    procedure Tick; inline;
    procedure Advance(Cycles: Integer);
    function ReadPort(Port: Byte): Byte;
    procedure WritePort(Port, Value: Byte);
    procedure SerializeState(State: TStateArchive);
    function Disk(Drive: Integer = 0): TZXDisk;
    property DRQ: Boolean read FDRQ;
    property INTRQ: Boolean read FINTRQ;
    property ReadSectors: UInt64 read FReadSectors;
    property WrittenSectors: UInt64 read FWrittenSectors;
  end;

implementation

uses
  System.Math;

const
  ByteT = 112;
  SectorT = TZXBetaDisk.RotationT div 16;
  Rates: array[0..3] of Integer = (21000, 42000, 70000, 105000);

constructor TZXDisk.Create(const Data: TBytes; SCL: Boolean; ProfiMedia: Boolean; KDI: Boolean);
begin
  inherited Create;
  FSectorSize := 256;
  FSectorsPerTrack := 16;
  if (ProfiMedia or KDI) and not SCL and ((Length(Data) = 409600) or (Length(Data) = 819200)) then
  begin
    FProfiBoot := ProfiMedia;
    FSectorSize := 1024;
    FSectorsPerTrack := 5;
    FCylinders := 80;
    FHeads := Length(Data) div 409600;
    FData := Copy(Data);
    Exit;
  end;
  if SCL then
  begin
    if (Length(Data) < 9) or (TEncoding.ASCII.GetString(Data, 0, 8) <> 'SINCLAIR') or
      (Data[8] > 128) then
      raise EReadError.Create('Invalid SCL directory');
    var Count := Integer(Data[8]);
    var P := 9 + Count * 14;
    if P > Length(Data) then
      raise EReadError.Create('Truncated SCL directory');
    var Sectors := 0;
    for var i := 0 to Count - 1 do
      Inc(Sectors, Data[9 + i * 14 + 13]);
    var EndPos := P + Sectors * 256;
    if (Sectors > 2544) or ((Length(Data) <> EndPos) and (Length(Data) <> EndPos + 4)) then
      raise EReadError.Create('Invalid SCL payload size');
    if Length(Data) = EndPos + 4 then
    begin
      var Sum: Cardinal := 0;
      for var i := 0 to EndPos - 1 do
        Inc(Sum, Data[i]);
      var LE := Cardinal(Data[EndPos]) or (Cardinal(Data[EndPos + 1]) shl 8) or
        (Cardinal(Data[EndPos + 2]) shl 16) or (Cardinal(Data[EndPos + 3]) shl 24);
      var BE := Cardinal(Data[EndPos + 3]) or (Cardinal(Data[EndPos + 2]) shl 8) or
        (Cardinal(Data[EndPos + 1]) shl 16) or (Cardinal(Data[EndPos]) shl 24);

      // Both orders occur in existing SCL writers (ATARIN uses big endian).
      if (LE <> Sum) and (BE <> Sum) then
        raise EReadError.Create('Invalid SCL checksum');
    end;
    SetLength(FData, 655360);
    var Next := 16;
    for var i := 0 to Count - 1 do
    begin
      Move(Data[9 + i * 14], FData[i * 16], 14);
      FData[i * 16 + 14] := Next mod 16;
      FData[i * 16 + 15] := Next div 16;
      var Size := Integer(Data[9 + i * 14 + 13]) * 256;
      if Size > 0 then
        Move(Data[P], FData[Next * 256], Size);
      Inc(P, Size);
      Inc(Next, Size div 256);
    end;
    FData[$8E1] := Next mod 16;
    FData[$8E2] := Next div 16;
    FData[$8E3] := $16;
    FData[$8E4] := Count;
    var FreeSectors := 2560 - Next;
    FData[$8E5] := FreeSectors and 255;
    FData[$8E6] := FreeSectors shr 8;
    FData[$8E7] := $10;
    FData[$8F5] := Ord('R');
    FData[$8F6] := Ord('M');
  end
  else
    FData := Copy(Data);
  if (Length(FData) < 4096) or (Length(FData) > 86 * 2 * 4096) or ((Length(FData) mod 4096) <> 0) then
    raise EReadError.Create('TRD must contain complete 16-sector tracks');

  FHeads := 2;
  FCylinders := Length(FData) div 8192;
  case FData[$8E3] of
    $16:
      begin
        FHeads := 2;
        FCylinders := 80;
      end;
    $17:
      begin
        FHeads := 2;
        FCylinders := 40;
      end;
    $18:
      begin
        FHeads := 1;
        FCylinders := 80;
      end;
    $19:
      begin
        FHeads := 1;
        FCylinders := 40;
      end;
  end;
  if Length(FData) > FCylinders * FHeads * 4096 then
    raise EReadError.Create('TRD geometry/size mismatch');

  for var i := 0 to 127 do
  begin
    var P := i * 16;
    if FData[P] = 0 then
      Break;
    if FData[P] = 1 then
      Continue;
    var Start: Integer := FData[P + 15] * 16 + FData[P + 14];
    if (FData[P + 14] > 15) or (Start < 16) or (Start + FData[P + 13] > Length(FData) div 256) then
      raise EReadError.Create('TRD file exceeds disk bounds');
  end;
  SetLength(FData, FCylinders * FHeads * 4096);
end;

function TZXDisk.SectorId(Cylinder, Head, Position: Integer): Integer;
begin
  Result := Position;
  // Native .pro media reserve ID 9 for the boot sector on track 0, side 0.
  if FProfiBoot and (Cylinder = 0) and (Head = 0) and (Position = 5) then
    Result := 9;
end;

function TZXDisk.Offset(Cylinder, Head, Sector: Integer): Integer;
begin
  Result := -1;
  if FProfiBoot and (Cylinder = 0) and (Head = 0) then
    if Sector = 9 then
      Sector := 5
    else if Sector = 5 then
      Exit;

  if (Cylinder >= 0) and (Cylinder < FCylinders) and (Head >= 0) and (Head < FHeads) and
    (Sector >= 1) and (Sector <= FSectorsPerTrack) then
    Result := ((Cylinder * FHeads + Head) * FSectorsPerTrack + Sector - 1) * FSectorSize;
end;

function TZXDisk.Image: TBytes;
begin
  Result := Copy(FData);
end;

constructor TZXDisk.CreateRaw(const Data: TBytes; Cylinders, Heads, Sectors, SectorSize: Integer);
begin
  inherited Create;
  if (Cylinders < 1) or (Cylinders > 86) or not (Heads in [1, 2]) or
    not (((SectorSize = 256) and (Sectors = 16)) or ((SectorSize = 512) and (Sectors in [8, 9])) or
    ((SectorSize = 1024) and (Sectors = 5))) or
    (Length(Data) <> Cylinders * Heads * Sectors * SectorSize) then
    raise EReadError.Create('Invalid raw floppy geometry');
  FCylinders := Cylinders;
  FHeads := Heads;
  FSectorsPerTrack := Sectors;
  FSectorSize := SectorSize;
  FData := Copy(Data);
end;

procedure TZXDisk.ContentChanged;
begin
  FRevision := Cardinal((UInt64(FRevision) + 1) and $FFFFFFFF);
end;

procedure TZXDisk.SerializeState(State: TStateArchive);
begin
  if State.Loading then
    ContentChanged;
  State.Field(FProfiBoot, SizeOf(FProfiBoot));
  State.Field(FSectorSize, SizeOf(FSectorSize));
  State.Field(FSectorsPerTrack, SizeOf(FSectorsPerTrack));
  if not (((FSectorSize = 256) and (FSectorsPerTrack = 16)) or
    ((FSectorSize = 512) and (FSectorsPerTrack in [8, 9])) or
    ((FSectorSize = 1024) and (FSectorsPerTrack = 5))) then
    raise EReadError.Create('Invalid disk sector geometry');

  var N := Length(FData);
  State.Field(N, SizeOf(N));
  if (N < 4096) or (N > 86 * 2 * 6 * 1024) or (N mod (FSectorsPerTrack * FSectorSize) <> 0) then
    raise EReadError.Create('Invalid disk state size');

  if State.Loading then
    SetLength(FData, N);
  State.Field(FData[0], N);
  State.Field(FCylinders, SizeOf(FCylinders));
  State.Field(FHeads, SizeOf(FHeads));
  State.Field(FDirty, SizeOf(FDirty));
  State.Field(FProtected, SizeOf(FProtected));
  if (FCylinders < 1) or (FCylinders > 86) or not (FHeads in [1, 2]) or
    (N <> FCylinders * FHeads * FSectorsPerTrack * FSectorSize) then
    raise EReadError.Create('Invalid disk state geometry');
end;

constructor TZXBetaDisk.Create;
begin
  inherited;
  Reset;
end;

destructor TZXBetaDisk.Destroy;
begin
  for var D in FDisks do
    D.Free;
  inherited;
end;

procedure TZXBetaDisk.Mount(const Data: TBytes; SCL: Boolean; Drive: Integer; ProfiMedia: Boolean; KDI: Boolean);
begin
  if not (Drive in [0..3]) then
    raise EArgumentOutOfRangeException.Create('Beta drive');
  var NewDisk := TZXDisk.Create(Data, SCL, ProfiMedia, KDI);
  if FBusy and (Selected = Drive) then
    Finish($10);
  FDisks[Drive].Free;
  FDisks[Drive] := NewDisk;
  InvalidateTrackCache;
end;

procedure TZXBetaDisk.EjectAll;
begin
  for var i := 0 to 3 do
    FreeAndNil(FDisks[i]);
  Reset;
end;

procedure TZXBetaDisk.MountRaw(const Data: TBytes; Cylinders, Heads, Sectors, SectorSize, Drive: Integer);
begin
  if not (Drive in [0..3]) then
    raise EArgumentOutOfRangeException.Create('Floppy drive');
  var NewDisk := TZXDisk.CreateRaw(Data, Cylinders, Heads, Sectors, SectorSize);
  if FBusy and (Selected = Drive) then
    Finish($10);
  FDisks[Drive].Free;
  FDisks[Drive] := NewDisk;
  InvalidateTrackCache;
end;

function TZXBetaDisk.Disk(Drive: Integer): TZXDisk;
begin
  if not (Drive in [0..3]) then
    raise EArgumentOutOfRangeException.Create('Beta drive');
  Result := FDisks[Drive];
end;

function TZXBetaDisk.Selected: Integer;
begin
  Result := FControl and 3;
end;

function TZXBetaDisk.Head: Integer;
begin
  Result := Ord((FControl and $10) = 0);
end; // Beta's side line is inverted.

function TZXBetaDisk.Ready: Boolean;
begin
  Result := (FDisks[Selected] <> nil) and ((FControl and 4) <> 0);
end;

procedure TZXBetaDisk.InvalidateTrackCache;
begin
  FTrackCacheValid := False;
  FTrackCache := nil;
end;

procedure TZXBetaDisk.Reset;
begin
  InvalidateTrackCache;
  FControl := $3C;
  FCommand := 0;
  FTrack := 0;
  FSector := 1;
  FData := 0;
  FError := 0;
  FForce := 0;
  FBusy := False;
  FDRQ := False;
  FINTRQ := False;
  FTypeI := True;
  FHeadLoaded := False;
  FFormatCRCWait := False;
  FPhase := fdcIdle;
  FTimer := 0;
  FRotation := 0;
  FDirection := 1;
  FillChar(FPhysicalTrack, SizeOf(FPhysicalTrack), 0);
  FBuffer := nil;
  FPosition := 0;
  FLength := 0;
  FOffset := -1;
  FReadSectors := 0;
  FWrittenSectors := 0;
end;

procedure TZXBetaDisk.Finish(Error: Byte);
begin
  FError := FError or Error;
  FBusy := False;
  FDRQ := False;
  FINTRQ := True;
  FPhase := fdcIdle;
  FTimer := 0;
end;

procedure TZXBetaDisk.FindSector;
begin
  FPhase := fdcFind;
  var Count := 16;
  if FDisks[Selected] <> nil then
    Count := FDisks[Selected].FSectorsPerTrack;
  var R := Integer(FSector);
  var SearchRotation := FRotation;
  // Read Address finds the next physical ID, independently of Sector Register.
  // Selecting by FSector would repeatedly return the same ID after C is copied
  // into that register, trapping loaders that wait for rotational ID changes.
  if (FCommand and $F0) = $C0 then
  begin
    if (FCommand and 4) <> 0 then
      SearchRotation := (SearchRotation + 52500) mod RotationT;
    R := (SearchRotation div (RotationT div Count) + 1) mod Count + 1;
  end;
  if (FDisks[Selected] <> nil) and FDisks[Selected].FProfiBoot and (Count = 5) and (FPhysicalTrack[Selected] = 0) and (Head = 0) and (R = 9) then
    R := 5;
  var Target := ((R - 1 + Count) mod Count) * (RotationT div Count);
  FTimer := (Target - SearchRotation + RotationT) mod RotationT + 28 * ByteT;
  if (FCommand and 4) <> 0 then
    Inc(FTimer, 52500);
end;

procedure TZXBetaDisk.Command(Value: Byte);
begin
  if (Value and $F0) = $D0 then
  begin
    FCommand := Value;
    FBusy := False;
    FDRQ := False;
    FINTRQ := (Value and 8) <> 0;
    FForce := Value and 7;
    FPhase := fdcIdle;
    FTimer := 0;
    Exit;
  end;
  if FBusy or ((FControl and 4) = 0) then
    Exit;
  FCommand := Value;
  FFormatCRCWait := False;
  FError := 0;
  FDRQ := False;
  FINTRQ := False;
  FBusy := True;
  FForce := 0;
  FBuffer := nil;
  FPosition := 0;
  FLength := 0;
  FOffset := -1;
  FTypeI := (Value and $80) = 0;
  if FTypeI then
  begin
    var Old := FPhysicalTrack[Selected];
    var Dest := Old;
    case Value shr 4 of
      0:
        begin
          Dest := 0;
          FTrack := 0;
          FDirection := -1;
        end;
      1:
        begin
          Dest := FData;
          if Dest <> Old then
            FDirection := Sign(Dest - Old);
          FTrack := FData;
        end;
      2, 3:
        Inc(Dest, FDirection);
      4, 5:
        begin
          FDirection := 1;
          Inc(Dest);
        end;
      6, 7:
        begin
          FDirection := -1;
          Dec(Dest);
        end;
    end;
    Dest := EnsureRange(Dest, 0, 85);
    FPhysicalTrack[Selected] := Dest;
    if ((Value and $E0) <> 0) and ((Value and $10) <> 0) then
      FTrack := (Integer(FTrack) + FDirection + 256) and 255;
    FTimer := Max(1, Abs(Old - Dest)) * Rates[Value and 3];
    FPhase := fdcSeek;
    FHeadLoaded := (Value and 8) <> 0;
  end
  else if not Ready then
  begin
    FPhase := fdcFailure;
    FTimer := RotationT;
  end
  else if ((Value and $E0) = $A0) and FDisks[Selected].WriteProtected then
    Finish($40)
  else if ((Value and $F0) = $F0) and FDisks[Selected].WriteProtected then
    Finish($40)
  else
    FindSector;
end;

function CRC(const B: TBytes): Word;
begin
  var C: Cardinal := $FFFF;
  for var V in B do
  begin
    C := C xor (Cardinal(V) shl 8);
    for var i := 1 to 8 do
      if (C and $8000) <> 0 then
        C := ((C shl 1) xor $1021) and $FFFF
      else
        C := (C shl 1) and $FFFF;
  end;
  Result := C;
end;

procedure TZXBetaDisk.BuildReadTrack(D: TZXDisk; Cylinder, Side: Integer);
begin
  if FTrackCacheValid and (FTrackCacheDrive = Selected) and
    (FTrackCacheCylinder = Cylinder) and (FTrackCacheHead = Side) and
    (FTrackCacheRevision = D.FRevision) then
  begin
    FBuffer := Copy(FTrackCache);
    Exit;
  end;
  // Exactly the same reconstructed MFM bytes as before; only allocation changes.
  var Size := Max(6250, D.FSectorsPerTrack * (96 + D.FSectorSize));
  SetLength(FBuffer, Size);
  FillChar(FBuffer[0], Size, $4E);
  var Offset := 0;
  var N := 1;
  if D.FSectorSize = 512 then
    N := 2;
  if D.FSectorSize = 1024 then
    N := 3;
  for var Position := 1 to D.FSectorsPerTrack do
  begin
    var R := D.SectorId(Cylinder, Side, Position);
    var Header := TBytes.Create($A1, $A1, $A1, $FE, Byte(Cylinder), Byte(Side), Byte(R), Byte(N));
    var Check := CRC(Header);
    Inc(Offset, 40);
    Move(Header[0], FBuffer[Offset], 8);
    Inc(Offset, 8);
    FBuffer[Offset] := Check shr 8;
    FBuffer[Offset + 1] := Check and 255;
    Inc(Offset, 42); // ID CRC plus the following 40-byte gap.
    Header := TBytes.Create($A1, $A1, $A1, $FB) + Copy(D.FData, D.Offset(Cylinder, Side, R), D.FSectorSize);
    Check := CRC(Header);
    Move(Header[0], FBuffer[Offset], Length(Header));
    Inc(Offset, Length(Header));
    FBuffer[Offset] := Check shr 8;
    FBuffer[Offset + 1] := Check and 255;
    Inc(Offset, 2);
  end;
  FTrackCache := Copy(FBuffer);
  FTrackCacheDrive := Selected;
  FTrackCacheCylinder := Cylinder;
  FTrackCacheHead := Side;
  FTrackCacheRevision := D.FRevision;
  FTrackCacheValid := True;
end;

procedure TZXBetaDisk.StartTransfer;
begin
  if not Ready then
  begin
    Finish($80);
    Exit;
  end;
  if (FControl and $20) = 0 then
  begin
    FPhase := fdcFailure;
    FTimer := 5 * RotationT;
    Exit;
  end;
  var D := FDisks[Selected];
  var C := FPhysicalTrack[Selected];
  FOffset := D.Offset(C, Head, FSector);
  FPosition := 0;
  FLength := 0;
  FBuffer := nil;
  if (FCommand and $F0) = $C0 then
  begin
    var R := (FRotation div (RotationT div D.FSectorsPerTrack)) mod D.FSectorsPerTrack + 1;
    R := D.SectorId(C, Head, R);
    var N := 1;
    if D.FSectorSize = 512 then
      N := 2;
    if D.FSectorSize = 1024 then
      N := 3;
    if D.Offset(C, Head, R) < 0 then
    begin
      FPhase := fdcFailure;
      FTimer := 5 * RotationT;
      Exit;
    end;
    var Check := CRC(TBytes.Create($A1, $A1, $A1, $FE, Byte(C), Byte(Head), Byte(R), Byte(N)));
    FBuffer := TBytes.Create(Byte(C), Byte(Head), Byte(R), Byte(N), Check shr 8, Check and 255);
    FSector := C;
    FLength := 6;
    FPhase := fdcRead;
  end
  else if (FCommand and $E0) = $E0 then
  begin
    if D.Offset(C, Head, 1) < 0 then
    begin
      FPhase := fdcFailure;
      FTimer := 5 * RotationT;
      Exit;
    end;
    FOffset := D.Offset(C, Head, 1);
    if (FCommand and $10) <> 0 then
    begin
      SetLength(FBuffer, 6250);
      FLength := 6250;
      FPhase := fdcWrite;
      FDRQ := True;
      FData := 0;
    end
    else
    begin
      BuildReadTrack(D, C, Head);
      FLength := Length(FBuffer);
      FPhase := fdcRead;
    end;
  end
  else
  begin
    var CompareSide := ((FCommand and 2) <> 0) and (((FCommand shr 3) and 1) <> Head);
    if (FOffset < 0) or (FTrack <> C) or CompareSide then
    begin
      FPhase := fdcFailure;
      FTimer := 5 * RotationT;
      Exit;
    end;
    FLength := D.FSectorSize;
    SetLength(FBuffer, FLength);
    if (FCommand and $20) = 0 then
    begin
      Move(D.FData[FOffset], FBuffer[0], FLength);
      FPhase := fdcRead;
    end
    else
    begin
      FPhase := fdcWrite;
      FDRQ := True;
      FData := 0;
    end;
  end;
  FTimer := ByteT;
end;

procedure TZXBetaDisk.FormatTrack;
begin
  var D := FDisks[Selected];
  if D = nil then
    Exit;
  var P := 0;
  var C := -1;
  var H := -1;
  var R := -1;
  var N := -1;
  while P < Length(FBuffer) do
  begin
    if (FBuffer[P] = $FE) and (P + 4 < Length(FBuffer)) then
    begin
      C := FBuffer[P + 1];
      H := FBuffer[P + 2];
      R := FBuffer[P + 3];
      N := FBuffer[P + 4];
      Inc(P, 5);
    end
    else if (FBuffer[P] in [$FB, $F8]) and (N in [1, 2, 3]) and ((128 shl N) = D.FSectorSize) and (C = FPhysicalTrack[Selected]) and
      (H = Head) and (D.Offset(C, H, R) >= 0) and (P + D.FSectorSize < Length(FBuffer)) then
    begin
      Move(FBuffer[P + 1], D.FData[D.Offset(C, H, R)], D.FSectorSize);
      D.FDirty := True;
      D.ContentChanged;
      InvalidateTrackCache;
      Inc(FWrittenSectors);
      Inc(P, D.FSectorSize + 1);
      N := -1;
    end
    else
      Inc(P);
  end;
end;

procedure TZXBetaDisk.EndTransfer;
begin
  if ((FCommand and $E0) = $A0) and (FOffset >= 0) then
  begin
    var D := FDisks[Selected];
    if (D = nil) or D.WriteProtected then
    begin
      Finish($40);
      Exit;
    end;
    Move(FBuffer[0], D.FData[FOffset], FLength);
    D.FDirty := True;
    D.ContentChanged;
    InvalidateTrackCache;
    Inc(FWrittenSectors);
  end
  else if (FCommand and $F0) = $F0 then
    FormatTrack
  else if (FCommand and $E0) = $80 then
    Inc(FReadSectors);
  if ((FCommand and $C0) = $80) and ((FCommand and $10) <> 0) then
  begin
    FSector := (Integer(FSector) + 1) and 255;
    FindSector;
  end
  else
    Finish;
end;

procedure TZXBetaDisk.ProcessPhase;
begin
  case FPhase of
    fdcSeek:
      begin
        if ((FCommand and 4) <> 0) and (not Ready or (FPhysicalTrack[Selected] <> FTrack) or
          (FTrack >= FDisks[Selected].Cylinders)) then
          Finish($10)
        else
          Finish;
      end;
    fdcFind:
      StartTransfer;
    fdcFailure:
      if Ready then
        Finish($10)
      else
        Finish($80);
    fdcRead:
      begin
        if FDRQ then
          FError := FError or 4;
        if FPosition >= FLength then
        begin
          FDRQ := False;
          FPhase := fdcCRC;
          FTimer := 2 * ByteT;
        end
        else
        begin
          FData := FBuffer[FPosition];
          Inc(FPosition);
          FDRQ := True;
          FTimer := ByteT;
        end;
      end;
    fdcWrite:
      begin
        if FFormatCRCWait then
        begin
          FFormatCRCWait := False;
          FDRQ := True;
          FData := 0;
          FTimer := ByteT;
          Exit;
        end;
        if FDRQ then
        begin
          FError := FError or 4;
          FData := 0;
        end;
        var V := FData;
        var Format := (FCommand and $F0) = $F0;
        if Format and (V = $F5) then
          V := $A1;
        if Format and (V = $F6) then
          V := $C2;
        FBuffer[FPosition] := V;
        Inc(FPosition);
        if Format and (V = $F7) and (FPosition < FLength) then
        begin
          FBuffer[FPosition] := 0;
          Inc(FPosition);
          FFormatCRCWait := True;
        end;
        if FPosition >= FLength then
        begin
          FDRQ := False;
          FFormatCRCWait := False;
          FPhase := fdcCRC;
          FTimer := 2 * ByteT;
        end
        else if FFormatCRCWait then
        begin
          FDRQ := False;
          FTimer := ByteT;
        end
        else
        begin
          FDRQ := True;
          FData := 0;
          FTimer := ByteT;
        end;
      end;
    fdcCRC:
      EndTransfer;
  end;
end;

procedure TZXBetaDisk.Tick;
begin
  Inc(FRotation);
  if FRotation = RotationT then
  begin
    FRotation := 0;
    if (FForce and 4) <> 0 then
      FINTRQ := True;
  end;
  if not FBusy then
    Exit;
  Dec(FTimer);
  if FTimer > 0 then
    Exit;
  ProcessPhase;
end;

procedure TZXBetaDisk.Advance(Cycles: Integer);
begin
  if Cycles < 0 then
    raise EArgumentOutOfRangeException.Create('FDC clocks');
  // Same state transitions as Tick, stopping at timer/index boundaries.
  // Floppy users running at a different host clock can scale their time once
  // per bus access, without a 3.5-million-iteration loop for an idle drive.
  while Cycles > 0 do
  begin
    var Chunk := Min(Cycles, RotationT - FRotation);
    if FBusy then
      Chunk := Min(Chunk, Max(1, FTimer));
    Dec(Cycles, Chunk);
    Inc(FRotation, Chunk);
    if FRotation = RotationT then
    begin
      FRotation := 0;
      if FForce and 4 <> 0 then
        FINTRQ := True;
    end;
    if FBusy then
    begin
      Dec(FTimer, Chunk);
      if FTimer <= 0 then
        ProcessPhase;
    end;
  end;
end;

function TZXBetaDisk.ReadPort(Port: Byte): Byte;
begin
  case Port of
    $1F:
      begin
        FINTRQ := False;
        Result := FError;
        if FBusy then
          Result := Result or 1;
        if not Ready then
          Result := Result or $80;
        if FTypeI then
        begin
          if FRotation < 14000 then
            Result := Result or 2;
          if FPhysicalTrack[Selected] = 0 then
            Result := Result or 4;
          if FHeadLoaded or ((FControl and 8) <> 0) then
            Result := Result or $20;
          if (FDisks[Selected] <> nil) and FDisks[Selected].WriteProtected then
            Result := Result or $40;
        end
        else if FDRQ then
          Result := Result or 2;
      end;
    $3F:
      Result := FTrack;
    $5F:
      Result := FSector;
    $7F:
      begin
        Result := FData;
        if FPhase = fdcRead then
          FDRQ := False;
      end;
    $FF:
      Result := Ord(FDRQ) * $40 or Ord(FINTRQ) * $80;
  else
    Result := $FF;
  end;
end;

procedure TZXBetaDisk.WritePort(Port, Value: Byte);
begin
  case Port of
    $1F:
      Command(Value);
    $3F:
      FTrack := Value;
    $5F:
      FSector := Value;
    $7F:
      begin
        FData := Value;
        if FPhase = fdcWrite then
          FDRQ := False;
      end;
    $FF:
      begin
        var WasReady := Ready;
        var Old := FControl;
        FControl := Value;
        if FBusy and (((Old xor Value) and $13) <> 0) then
          Finish($10);
        if (Value and 4) = 0 then
        begin
          FBusy := False;
          FDRQ := False;
          FINTRQ := False;
          FPhase := fdcIdle;
          FTimer := 0;
          FFormatCRCWait := False;
          FError := 0;
          FTrack := 0;
          FTypeI := True;
        end
        else if (Old and 4) = 0 then
          Command(0);
        if ((FForce and 1) <> 0) and not WasReady and Ready then
          FINTRQ := True;
        if ((FForce and 2) <> 0) and WasReady and not Ready then
          FINTRQ := True;
      end;
  end;
end;

procedure TZXBetaDisk.SerializeState(State: TStateArchive);
begin
  if State.Loading then
    InvalidateTrackCache;
  for var i := 0 to 3 do
  begin
    var Present := FDisks[i] <> nil;
    State.Field(Present, SizeOf(Present));
    if State.Loading then
      if Present and (FDisks[i] = nil) then
      begin
        var Blank: TBytes;
        SetLength(Blank, 655360);
        FDisks[i] := TZXDisk.Create(Blank, False);
      end
      else if not Present then
        FreeAndNil(FDisks[i]);
    if Present then
      FDisks[i].SerializeState(State);
  end;
  State.Field(FPhysicalTrack, SizeOf(FPhysicalTrack));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FTrack, SizeOf(FTrack));
  State.Field(FSector, SizeOf(FSector));
  State.Field(FData, SizeOf(FData));
  State.Field(FError, SizeOf(FError));
  State.Field(FForce, SizeOf(FForce));
  State.Field(FBusy, SizeOf(FBusy));
  State.Field(FDRQ, SizeOf(FDRQ));
  State.Field(FINTRQ, SizeOf(FINTRQ));
  State.Field(FTypeI, SizeOf(FTypeI));
  State.Field(FHeadLoaded, SizeOf(FHeadLoaded));
  State.Field(FFormatCRCWait, SizeOf(FFormatCRCWait));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FRotation, SizeOf(FRotation));
  State.Field(FDirection, SizeOf(FDirection));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FLength, SizeOf(FLength));
  State.Field(FOffset, SizeOf(FOffset));
  var N := Length(FBuffer);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > 16384) then
    raise EReadError.Create('Invalid FDC buffer state');
  if State.Loading then
    SetLength(FBuffer, N);
  if N > 0 then
    State.Field(FBuffer[0], N);
  State.Field(FReadSectors, SizeOf(FReadSectors));
  State.Field(FWrittenSectors, SizeOf(FWrittenSectors));
  if State.Loading then
    if (Ord(FPhase) > Ord(High(TZXFDCPhase))) or (FTimer < 0) or (FTimer > 10000000) or
      (FRotation < 0) or (FRotation >= RotationT) or (FPosition < 0) or (FPosition > N) or
      (FLength < 0) or (FLength > N) or ((FDirection <> -1) and (FDirection <> 1)) then
      raise EReadError.Create('Invalid FDC transfer state');
  if State.Loading then
  begin
    for var Track in FPhysicalTrack do
      if (Track < 0) or (Track > 85) then
        raise EReadError.Create('Invalid FDC physical track');
    if FBusy and ((FPhase = fdcIdle) or (FTimer = 0)) then
      raise EReadError.Create('Invalid FDC busy state');
    if not FBusy and FDRQ then
      raise EReadError.Create('Invalid FDC data request state');
  end;
  if State.Loading and FBusy and (FPhase in [fdcRead, fdcWrite, fdcCRC]) then
  begin
    if not Ready or (FLength = 0) then
      raise EReadError.Create('FDC transfer without media');
    if ((FCommand and $E0) = $A0) and ((FLength <> FDisks[Selected].FSectorSize) or (FOffset < 0) or (FOffset > Length(FDisks[Selected].FData) - FLength)) then
      raise EReadError.Create('Invalid FDC sector state');
  end;
end;

end.

