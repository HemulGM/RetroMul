unit NES.DiskSystem;

interface

uses
  System.SysUtils, NES.Types, NES.Mapper, NES.State, NES.Audio.FDS;

const
  FDS_SIGNATURE: AnsiString = 'FDS' + #$1A;
  FDS_SIDE_SIZE = 65500;
  QD_SIDE_SIZE = 65536;
  FDS_MAPPER_ID = 20;

type
  // Bytes on the magnetic track, including sync marks, gaps and CRCs. Writes
  // stay in this representation so new files and changed block sizes survive.
  TFdsMedia = class
  private
    FSides: TArray<NES.Types.TByteArray>;
    FIdentity: string;
    procedure DecodeSide(const Data: NES.Types.TByteArray; Offset, Capacity: Integer; HasCRC: Boolean);
  public
    constructor Create(const Data: NES.Types.TByteArray; QuickDisk: Boolean = False);
    class function HasSignature(const Data: TBytes): Boolean; static;
    function SideCount: Integer;
    function SideName(Index: Integer): string;
    function SaveMemory: NES.Types.TByteArray;
    procedure LoadMemory(const Data: NES.Types.TByteArray);
    procedure SerializeState(State: TNesStateArchive);
    property Identity: string read FIdentity;
  end;

  TMapperFds = class(TMapper)
  private
    FMedia: TFdsMedia;
    FAudio: TFdsAudio;
    FBios: NES.Types.TByteArray;
    FRam: array[0..$7FFF] of Byte;
    FChr: array[0..$1FFF] of Byte;
    FReload, FCounter: Integer;
    FRefreshCounter, FRefreshTimer: Integer;
    FRefreshIRQ: Boolean;
    FTimerEnabled, FRepeat, FTimerIRQ, FDiskIRQ, FTransfer: Boolean;
    FIO, FControl, FExternal, FReadData, FWriteData: Byte;
    FSide, FPendingSide, FInsertDelay, FPosition, FDelay, FBytePhase: Integer;
    FScanning, FEndOfHead, FGapEnded, FBadCRC, FPreviousCRC, FWriteProtected: Boolean;
    FCRC: Word;
    FHeadBit, FReadBits, FReadShift, FWriteShift, FWriteModeControl: Byte;
    procedure TransferBit(MoveHead: Boolean);
    function MotorOn: Boolean;
    procedure StopDrive;
  public
    constructor Create(Media: TFdsMedia; const Bios: NES.Types.TByteArray);
    destructor Destroy; override;
    // Ownership passes only after success. CPU RAM and sound are preserved.
    procedure ReplaceMedia(Media: TFdsMedia);
    procedure InsertSide(Index: Integer);
    procedure Eject;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    procedure ClockCpuBus(Address: UInt16); override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    function GetSaveMemory: NES.Types.TByteArray; override;
    procedure SetSaveMemory(const Data: NES.Types.TByteArray); override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure Reset; override;
    property Media: TFdsMedia read FMedia;
    property Side: Integer read FSide;
    property WriteProtected: Boolean read FWriteProtected write FWriteProtected;
  end;

function FdsCRC(CRC: Word; Value: Byte): Word;

function FdsCRCBit(CRC: Word; Value: Byte): Word;

implementation

uses
  System.Classes, System.Hash, System.Math;

function FdsCRCBit(CRC: Word; Value: Byte): Word;
begin
  if ((CRC xor Value) and 1) <> 0 then
    Result := (CRC shr 1) xor $8408
  else
    Result := CRC shr 1;
end;

function FdsCRC(CRC: Word; Value: Byte): Word;
begin
  Result := CRC xor Value;
  for var i := 0 to 7 do
    if (Result and 1) <> 0 then
      Result := (Result shr 1) xor $8408
    else
      Result := Result shr 1;
end;

class function TFdsMedia.HasSignature(const Data: TBytes): Boolean;
begin
  Result := ((Length(Data) >= 4) and CompareMem(@Data[0], PAnsiChar(FDS_SIGNATURE), 4)) or
    ((Length(Data) >= 15) and (Data[0] = 1) and
    CompareMem(@Data[1], PAnsiChar(AnsiString('*NINTENDO-HVC*')), 14));
end;

constructor TFdsMedia.Create(const Data: NES.Types.TByteArray; QuickDisk: Boolean);
begin
  inherited Create;
  var Offset := 0;
  var Count: Integer;
  if (Length(Data) >= 16) and CompareMem(@Data[0], PAnsiChar(FDS_SIGNATURE), 4) then
    Offset := 16;
  // Archive sessions retain the archive filename, so identify QD by capacity
  // as well as extension. Neither format permits incomplete disk sides.
  if not QuickDisk and ((Length(Data) - Offset) mod FDS_SIDE_SIZE <> 0) and
    ((Length(Data) - Offset) mod QD_SIDE_SIZE = 0) then
    QuickDisk := True;
  Offset := 0;
  var Capacity := FDS_SIDE_SIZE;
  if QuickDisk then
    Capacity := QD_SIDE_SIZE;
  if (Length(Data) >= 4) and CompareMem(@Data[0], PAnsiChar(FDS_SIGNATURE), 4) then
  begin
    if Length(Data) < 16 then
      raise ENesException.Create('Truncated FDS header');
    Offset := 16;
    Count := Data[4];
    if (Count = 0) or (Length(Data) <> Offset + Count * Capacity) then
      raise ENesException.Create('FDS side count does not match the image size');
  end
  else
  begin
    if (Length(Data) = 0) or (Length(Data) mod Capacity <> 0) then
      raise ENesException.Create('Invalid FDS/QD side size');
    Count := Length(Data) div Capacity;
    if Count > 255 then
      raise ENesException.Create('Too many FDS disk sides');
  end;
  var Hash := THashSHA2.Create;
  Hash.Update(TBytes(Data));
  FIdentity := Hash.HashAsString;
  for var i := 0 to Count - 1 do
    DecodeSide(Data, Offset + i * Capacity, Capacity, QuickDisk);
end;

procedure TFdsMedia.DecodeSide(const Data: NES.Types.TByteArray; Offset, Capacity: Integer; HasCRC: Boolean);
begin
  var Track := TMemoryStream.Create;
  try
    var Zero: Byte := 0;
    var Sync: Byte := $80;
    // 28300 bit lead-in, followed by 976 bit inter-block gaps (byte aligned).
    for var i := 1 to 3537 do
      Track.WriteBuffer(Zero, 1);
    var Position := 0;
    var FileSize := 0;
    while Position < Capacity do
    begin
      var BlockSize := 0;
      case Data[Offset + Position] of
        1:
          BlockSize := 56;
        2:
          BlockSize := 2;
        3:
          BlockSize := 16;
        4:
          BlockSize := FileSize + 1;
      end;
      // Retain unrecognized tail bytes (hidden/protection data) verbatim.
      if BlockSize = 0 then
      begin
        var HasTailData := False;
        for var i := Position to Capacity - 1 do
          if Data[Offset + i] <> 0 then
          begin
            HasTailData := True;
            Break;
          end;
        if HasTailData then
          Track.WriteBuffer(Sync, 1);
        Track.WriteBuffer(Data[Offset + Position], Capacity - Position);
        Break;
      end;
      var StoredSize := BlockSize + Ord(HasCRC) * 2;
      if StoredSize > Capacity - Position then
      begin
        // An oversized file declaration can be deliberate protection, or an
        // incomplete write. Preserve the recorded bytes and let the BIOS
        // observe CRC/end-of-head instead of rejecting the entire disk.
        if Data[Offset + Position] <> 4 then
          raise ENesException.Create('Truncated FDS disk block');
        Track.WriteBuffer(Sync, 1);
        Track.WriteBuffer(Data[Offset + Position], Capacity - Position);
        Break;
      end;
      if Data[Offset + Position] = 3 then
        FileSize := Data[Offset + Position + 13] or (Data[Offset + Position + 14] shl 8);
      Track.WriteBuffer(Sync, 1);
      Track.WriteBuffer(Data[Offset + Position], StoredSize);
      if not HasCRC then
      begin
        var CRC := FdsCRC(0, Sync);
        for var i := 0 to BlockSize - 1 do
          CRC := FdsCRC(CRC, Data[Offset + Position + i]);
        var LowCRC := Byte(CRC and $FF);
        var HighCRC := Byte(CRC shr 8);
        Track.WriteBuffer(LowCRC, 1);
        Track.WriteBuffer(HighCRC, 1);
      end;
      for var i := 1 to 122 do
        Track.WriteBuffer(Zero, 1);
      // Bound malformed images containing thousands of tiny pseudo-blocks.
      // This still accommodates 255 files and oversized/protected disk sides.
      if Track.Size > $20000 then
        raise ENesException.Create('FDS track exceeds the supported physical capacity');
      Inc(Position, StoredSize);
    end;
    var SideData: NES.Types.TByteArray;
    SetLength(SideData, Max(75500, Integer(Track.Size)));
    Move(Track.Memory^, SideData[0], Track.Size);
    FSides := FSides + TArray<NES.Types.TByteArray>.Create(SideData);
  finally
    Track.Free;
  end;
end;

function TFdsMedia.SideCount: Integer;
begin
  Result := Length(FSides);
end;

function TFdsMedia.SideName(Index: Integer): string;
begin
  if (Index < 0) or (Index >= SideCount) then
    raise EArgumentOutOfRangeException.Create('FDS side index');
  Result := Format('Disk %d · Side %s', [Index div 2 + 1, Char(Ord('A') + (Index and 1))]);
end;

function TFdsMedia.SaveMemory: NES.Types.TByteArray;
begin
  var Size := 0;
  for var SideData in FSides do
    Inc(Size, Length(SideData));
  SetLength(Result, Size);
  var Position := 0;
  for var SideData in FSides do
  begin
    Move(SideData[0], Result[Position], Length(SideData));
    Inc(Position, Length(SideData));
  end;
end;

procedure TFdsMedia.LoadMemory(const Data: NES.Types.TByteArray);
begin
  var Size := 0;
  for var SideData in FSides do
    Inc(Size, Length(SideData));
  if Length(Data) <> Size then
    raise ENesException.Create('Incompatible FDS disk save');
  var Position := 0;
  for var i := 0 to High(FSides) do
  begin
    Move(Data[Position], FSides[i][0], Length(FSides[i]));
    Inc(Position, Length(FSides[i]));
  end;
end;

procedure TFdsMedia.SerializeState(State: TNesStateArchive);
begin
  // Refuse a different inserted image before accepting its mutable track data.
  var Identity := TEncoding.ASCII.GetBytes(FIdentity);
  State.Field(Identity[0], Length(Identity));
  if TEncoding.ASCII.GetString(Identity) <> FIdentity then
    raise ENesException.Create('Insert the FDS image used by this snapshot');
  for var i := 0 to High(FSides) do
    State.Field(FSides[i][0], Length(FSides[i]));
end;

constructor TMapperFds.Create(Media: TFdsMedia; const Bios: NES.Types.TByteArray);
begin
  inherited Create;
  if Length(Bios) <> $2000 then
    raise ENesException.Create('FDS BIOS must be exactly 8192 bytes');
  FBios := Copy(Bios);
  FAudio := TFdsAudio.Create;
  FMedia := Media;
  FSide := 0;
  FPendingSide := -1;
  Reset;
end;

destructor TMapperFds.Destroy;
begin
  FAudio.Free;
  FMedia.Free;
  inherited;
end;

procedure TMapperFds.StopDrive;
begin
  FPosition := 0;
  FDelay := 50000;
  FHeadBit := 0;
  FReadBits := 0;
  FReadShift := 0;
  FScanning := False;
  FEndOfHead := True;
  FGapEnded := False;
  FTransfer := False;
  FDiskIRQ := False;
  FCRC := 0;
  FBadCRC := False;
  FPreviousCRC := False;
end;

procedure TMapperFds.Reset;
begin
  FReload := 0;
  FCounter := 0;
  FBytePhase := 0;
  FWriteShift := 0;
  FWriteModeControl := 0;
  FTimerEnabled := False;
  FRepeat := False;
  FTimerIRQ := False;
  FRefreshCounter := 0;
  FRefreshTimer := $FFF;
  FRefreshIRQ := False;
  FIO := 0;
  FControl := $06;
  FExternal := $7F;
  FReadData := 0;
  FWriteData := 0;
  StopDrive;
  // Reset holds the generators silent; it does not erase wavetable RAM.
  FAudio.Write($4023, 0);
  // RAM, disk writes and the inserted side survive the reset button.
end;

procedure TMapperFds.ReplaceMedia(Media: TFdsMedia);
begin
  FMedia.Free;
  FMedia := Media;
  Eject;
  InsertSide(0);
end;

procedure TMapperFds.Eject;
begin
  FSide := -1;
  FPendingSide := -1;
  FInsertDelay := 0;
  StopDrive;
end;

procedure TMapperFds.InsertSide(Index: Integer);
begin
  if (Index < 0) or (Index >= FMedia.SideCount) then
    raise EArgumentOutOfRangeException.Create('FDS side index');
  if (Index = FSide) and (FPendingSide < 0) then
    Exit;
  Eject;
  FPendingSide := Index;
  // Keep the disk absent long enough for software to observe removal.
  FInsertDelay := 1789773;
end;

function TMapperFds.MotorOn: Boolean;
begin
  Result := (FControl and 2) = 0;
end;

function TMapperFds.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $E000 then
    Value := FBios[Address - $E000]
  else if Address >= $6000 then
    Value := FRam[Address - $6000]
  else if ((Address >= $4040) and (Address <= $407F)) or
    ((Address >= $4090) and (Address <= $4097)) then
  begin
    Value := FAudio.Read(Address);
    case Address of
      $4091, $4094: // All eight bits are driven.
        ;
      $4093, $4097:
        Value := (Value and $7F) or (FCpuOpenBus and $80);
      $4095:
        Value := (Value and $0F) or (FCpuOpenBus and $F0);
    else
      Value := (Value and $3F) or (FCpuOpenBus and $C0);
    end;
  end
  else
    case Address of
      $4030:
        begin
          Value := Integer(FCpuOpenBus and $24) or Ord(FTimerIRQ) or
            (Ord(FRefreshIRQ) shl 1) or
            (FControl and 8) or (Ord(FBadCRC) shl 4) or
            (Ord(FEndOfHead) shl 6) or (Ord(FTransfer) shl 7);
          // The transfer flag is acknowledged by $4031/$4024, not $4030.
          FTimerIRQ := False;
          FRefreshIRQ := False;
        end;
      $4031:
        begin
          Value := FReadData;
          FTransfer := False;
          FDiskIRQ := False;
        end;
      $4032:
        Value := Integer(FCpuOpenBus and $F8) or Ord(FSide < 0) or
          (Ord((FSide < 0) or not FScanning) shl 1) or
          (Ord((FSide < 0) or FWriteProtected) shl 2);
      $4033:
        Value := FExternal or (Ord(MotorOn) shl 7);
    else
      Result := False;
    end;
end;

function TMapperFds.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  if Address >= $E000 then
    Exit;
  if Address >= $6000 then
  begin
    FRam[Address - $6000] := Value;
    Exit;
  end;
  if (Address >= $4040) and (Address <= $408A) then
  begin
    FAudio.Write(Address, Value);
    Exit;
  end;
  if ((FIO and 1) = 0) and (Address >= $4024) and (Address <= $4026) then
    Exit;
  case Address of
    $4020:
      FReload := (FReload and $FF00) or Value;
    $4021:
      FReload := (FReload and $FF) or (Value shl 8);
    $4022:
      begin
        FRepeat := (Value and 1) <> 0;
        FTimerEnabled := ((Value and 2) <> 0) and ((FIO and 1) <> 0);
        if FTimerEnabled then
          FCounter := FReload
        else
          FTimerIRQ := False;
      end;
    $4023:
      begin
        FIO := Value;
        FAudio.Write(Address, Value);
        if (Value and $80) = 0 then
          FRefreshIRQ := False;
        if (Value and 1) = 0 then
        begin
          FTimerEnabled := False;
          FTimerIRQ := False;
          FRefreshCounter := 0;
          FRefreshTimer := $FFF;
          FRefreshIRQ := False;
          FControl := $06;
          FBytePhase := 0;
          FWriteShift := 0;
          FWriteModeControl := 0;
          FExternal := $7F;
          StopDrive;
        end;
      end;
    $4024:
      begin
        FWriteData := Value;
        FTransfer := False;
        FDiskIRQ := False;
      end;
    $4025:
      begin
        FControl := Value;
        FDiskIRQ := False;
        if (Value and $40) = 0 then
        begin
          // CRC/reset is a register signal, not an operation deferred until
          // the next disk bit. A short disable/enable pulse must reset it too.
          FCRC := 0;
          FBadCRC := False;
          FGapEnded := False;
          FReadBits := 0;
          FReadShift := 0;
          FPreviousCRC := False;
        end;
        // Scan reset also stops writes while the motor is still spinning.
        // Unlicensed loaders use $68 to change mirroring after boot; treating
        // that value as an active write command destroys the following block.
        if not MotorOn or ((Value and 1) = 0) then
          StopDrive;
      end;
    $4026:
      FExternal := Value and $7F;
  else
    Result := False;
  end;
end;

function TMapperFds.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChr[Address];
end;

function TMapperFds.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    FChr[Address] := Value;
end;

function TMapperFds.GetMirrorMode: TMirrorMode;
begin
  if (FControl and 8) <> 0 then
    Result := TMirrorMode.Horizontal
  else
    Result := TMirrorMode.Vertical;
end;

procedure TMapperFds.TransferBit(MoveHead: Boolean);
begin
  var AtEnd := True;
  if FSide >= 0 then
    AtEnd := FPosition >= Length(FMedia.FSides[FSide]);
  var DataBit: Byte := 0;
  if MoveHead and not AtEnd then
    DataBit := (FMedia.FSides[FSide][FPosition] shr FHeadBit) and 1;
  var CRCMode := (FControl and $10) <> 0;
  var Enabled := (FControl and $40) <> 0;
  if (FControl and 4) <> 0 then
  begin
    if not Enabled then
    begin
      FGapEnded := False;
      FReadBits := 0;
      FReadShift := 0;
      FCRC := 0;
      FBadCRC := False;
    end
    else if not FGapEnded then
    begin
      // The end of a gap is a single set bit, not a nonzero byte. Data
      // starts immediately after it, even when the gap is not byte aligned.
      if DataBit <> 0 then
      begin
        FGapEnded := True;
        FCRC := FdsCRCBit(0, 1);
        FPreviousCRC := CRCMode;
        FReadShift := 0;
        FReadBits := 0;
      end;
    end
    else
    begin
      FReadShift := (FReadShift shr 1) or (DataBit shl 7);
      if not FPreviousCRC then
        FCRC := FdsCRCBit(FCRC, DataBit);
      Inc(FReadBits);
      if FReadBits = 8 then
      begin
        FReadBits := 0;
        FReadData := FReadShift;
        FTransfer := True;
        FDiskIRQ := (FControl and $80) <> 0;
        if CRCMode and not FPreviousCRC then
          FBadCRC := FCRC <> 0;
        FPreviousCRC := CRCMode;
      end;
    end;
  end
  else
  begin
    // CPU writes fill the holding register. A separate shift register owns
    // the byte already in flight; subsequent writes cannot replace its tail.
    DataBit := FWriteShift and 1;
    FWriteShift := FWriteShift shr 1;
    if not Enabled or ((FWriteModeControl and $40) = 0) then
      FCRC := 0
    else if (FWriteModeControl and $10) = 0 then
      FCRC := FdsCRCBit(FCRC, DataBit);
    if MoveHead and not FWriteProtected and not AtEnd then
    begin
      var Mask := Byte(1 shl FHeadBit);
      FMedia.FSides[FSide][FPosition] :=
        (FMedia.FSides[FSide][FPosition] and (Mask xor $FF)) or (DataBit shl FHeadBit);
    end;
    if FBytePhase < 3 then
    begin
      FWriteModeControl := FControl;
      if not Enabled then
      begin
        FWriteShift := 0;
        FCRC := 0;
      end
      else if CRCMode then
      begin
        FWriteShift := FCRC and $FF;
        FCRC := FCRC shr 8;
      end
      else
        FWriteShift := FWriteData;
      if not CRCMode then
      begin
        FTransfer := Enabled and ((FControl and $20) <> 0);
        FDiskIRQ := FTransfer and ((FControl and $80) <> 0);
      end;
      FPreviousCRC := CRCMode;
    end;
    FGapEnded := False;
    FBadCRC := False;
  end;
  if not MoveHead then
    Exit;
  FHeadBit := (FHeadBit + 1) and 7;
  if FHeadBit = 0 then
  begin
    if not AtEnd then
      Inc(FPosition);
    if FPosition >= Length(FMedia.FSides[FSide]) then
    begin
      FEndOfHead := True;
      FScanning := False;
      // The adapter clock continues after the physical drive stops. This
      // lets BIOS finish an oversized block before reporting end-of-head.
      if Enabled and ((FControl and 4) <> 0) and not FGapEnded then
      begin
        FGapEnded := True;
        FReadBits := 0;
        FReadShift := 0;
      end;
    end;
  end;
end;

procedure TMapperFds.ClockCpu;
begin
  FAudio.Clock;
  if FTimerEnabled then
    if FCounter = 0 then
    begin
      FTimerIRQ := True;
      FCounter := FReload;
      if not FRepeat then
        FTimerEnabled := False;
    end
    else
      Dec(FCounter);
  if FInsertDelay > 0 then
  begin
    Dec(FInsertDelay);
    if FInsertDelay = 0 then
    begin
      FSide := FPendingSide;
      FPendingSide := -1;
      StopDrive;
    end;
  end;
  // The adapter's write clock is independent of disk presence and motor
  // readiness, including spin-up. Shifting and CRC continue while the head
  // is parked; only the mechanical head and magnetic writes stay still.
  if ((FIO and 1) <> 0) and ((FControl and 4) = 0) and
    ((FSide < 0) or not MotorOn or ((FControl and 1) = 0) or (FDelay > 0)) then
  begin
    if (FSide >= 0) and MotorOn and ((FControl and 1) <> 0) and (FDelay > 0) then
      Dec(FDelay);
    var PreviousBit := FBytePhase div 56;
    Inc(FBytePhase, 3);
    if FBytePhase >= 448 then
      Dec(FBytePhase, 448);
    if FBytePhase div 56 <> PreviousBit then
      TransferBit(False);
    Exit;
  end;
  if (FSide < 0) or not MotorOn then
    Exit;
  if ((FControl and 1) = 0) and not FScanning then
    Exit;
  if FDelay > 0 then
  begin
    Dec(FDelay);
    Exit;
  end;
  FEndOfHead := FPosition >= Length(FMedia.FSides[FSide]);
  FScanning := not FEndOfHead;
  // 224 master clocks per bit = 56/3 CPU clocks. Preserve the
  // fractional phase across bits and bytes instead of rounding each delay.
  var PreviousBit := FBytePhase div 56;
  Inc(FBytePhase, 3);
  if FBytePhase >= 448 then
    Dec(FBytePhase, 448);
  if FBytePhase div 56 <> PreviousBit then
    TransferBit(True);
end;

procedure TMapperFds.ClockCpuBus(Address: UInt16);
begin
  if (FIO and 1) = 0 then
    Exit;
  // The 2C33 refreshes one DRAM row on every cycle outside PRG RAM.
  // Completing all 128 rows reloads the watchdog, including during DMA.
  if (Address < $6000) or (Address >= $E000) then
  begin
    FRefreshCounter := (FRefreshCounter + 1) and $7F;
    if FRefreshCounter = 0 then
    begin
      FRefreshTimer := 3245;
      Exit;
    end;
  end;
  if (FRefreshTimer = 0) and ((FIO and $80) <> 0) then
    FRefreshIRQ := True;
  FRefreshTimer := (FRefreshTimer - 1) and $FFF;
end;

function TMapperFds.IrqPending: Boolean;
begin
  Result := FTimerIRQ or FDiskIRQ or FRefreshIRQ;
end;

function TMapperFds.ExpansionAudio: Double;
begin
  Result := FAudio.Output;
end;

function TMapperFds.GetSaveMemory: NES.Types.TByteArray;
begin
  Result := FMedia.SaveMemory;
end;

procedure TMapperFds.SetSaveMemory(const Data: NES.Types.TByteArray);
begin
  FMedia.LoadMemory(Data);
end;

procedure TMapperFds.SerializeState(State: TNesStateArchive);
begin
  inherited;
  var Hash := THashSHA2.Create;
  Hash.Update(TBytes(FBios));
  var BiosHash := TEncoding.ASCII.GetBytes(Hash.HashAsString);
  var ExpectedHash := Copy(BiosHash);
  State.Field(BiosHash[0], Length(BiosHash));
  if not CompareMem(@BiosHash[0], @ExpectedHash[0], Length(BiosHash)) then
    raise ENesException.Create('FDS snapshot uses a different BIOS');
  FMedia.SerializeState(State);
  State.Field(FRam, SizeOf(FRam));
  State.Field(FChr, SizeOf(FChr));
  State.Field(FReload, SizeOf(FReload));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FTimerEnabled, SizeOf(FTimerEnabled));
  State.Field(FRepeat, SizeOf(FRepeat));
  State.Field(FTimerIRQ, SizeOf(FTimerIRQ));
  State.Field(FDiskIRQ, SizeOf(FDiskIRQ));
  State.Field(FTransfer, SizeOf(FTransfer));
  State.Field(FIO, SizeOf(FIO));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FExternal, SizeOf(FExternal));
  State.Field(FReadData, SizeOf(FReadData));
  State.Field(FWriteData, SizeOf(FWriteData));
  State.Field(FSide, SizeOf(FSide));
  State.Field(FPendingSide, SizeOf(FPendingSide));
  State.Field(FInsertDelay, SizeOf(FInsertDelay));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FDelay, SizeOf(FDelay));
  State.Field(FBytePhase, SizeOf(FBytePhase));
  State.Field(FScanning, SizeOf(FScanning));
  State.Field(FEndOfHead, SizeOf(FEndOfHead));
  State.Field(FGapEnded, SizeOf(FGapEnded));
  State.Field(FBadCRC, SizeOf(FBadCRC));
  State.Field(FPreviousCRC, SizeOf(FPreviousCRC));
  State.Field(FWriteProtected, SizeOf(FWriteProtected));
  State.Field(FCRC, SizeOf(FCRC));
  FAudio.SerializeState(State);
  if State.Version >= 23 then
  begin
    State.Field(FRefreshCounter, SizeOf(FRefreshCounter));
    State.Field(FRefreshTimer, SizeOf(FRefreshTimer));
    State.Field(FRefreshIRQ, SizeOf(FRefreshIRQ));
  end
  else if State.Loading then
  begin
    FRefreshCounter := 0;
    FRefreshTimer := $FFF;
    FRefreshIRQ := False;
  end;
  if State.Version >= 24 then
  begin
    State.Field(FHeadBit, SizeOf(FHeadBit));
    State.Field(FReadBits, SizeOf(FReadBits));
    State.Field(FReadShift, SizeOf(FReadShift));
    State.Field(FWriteShift, SizeOf(FWriteShift));
    State.Field(FWriteModeControl, SizeOf(FWriteModeControl));
  end
  else if State.Loading then
  begin
    // Older versions processed whole bytes. Recover the elapsed prefix of
    // the current byte without changing the saved magnetic track.
    FHeadBit := FBytePhase div 56;
    FReadBits := 0;
    FReadShift := 0;
    FWriteShift := FWriteData shr FHeadBit;
    FWriteModeControl := FControl;
    if (FSide >= 0) and (FSide < FMedia.SideCount) and
      (FPosition >= 0) and (FPosition < Length(FMedia.FSides[FSide])) and FGapEnded then
      for var i := 0 to Integer(FHeadBit) - 1 do
      begin
        var DataBit := (FMedia.FSides[FSide][FPosition] shr i) and 1;
        FReadShift := (FReadShift shr 1) or (DataBit shl 7);
        Inc(FReadBits);
        if not FPreviousCRC then
          FCRC := FdsCRCBit(FCRC, DataBit);
      end;
  end;
  if State.Loading then
    if (FHeadBit > 7) or (FReadBits > 7) or (FRefreshCounter < 0) or (FRefreshCounter > $7F) or
      (FRefreshTimer < 0) or (FRefreshTimer > $FFF) or (FSide < -1) or (FSide >= FMedia.SideCount) or
      (FPendingSide < -1) or (FPendingSide >= FMedia.SideCount) or
      (FInsertDelay < 0) or (FInsertDelay > 1789773) or
      (FPosition < 0) or ((FSide >= 0) and (FPosition > Length(FMedia.FSides[FSide]))) or
      (FBytePhase < 0) or (FBytePhase >= 448) or (FDelay < 0) or (FDelay > 50000) or
      (FCounter < 0) or (FCounter > $FFFF) or (FReload < 0) or (FReload > $FFFF) then
      raise EReadError.Create('Invalid FDS snapshot state');
end;

end.

