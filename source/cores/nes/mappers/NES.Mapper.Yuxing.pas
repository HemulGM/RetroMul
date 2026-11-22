unit NES.Mapper.Yuxing;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Mmc3, NES.Controller;

type
  TYuxingFloppy = class
  private
    type
      TPhase = (Command, ReadData, Response);
  private
    FPhase: TPhase;
    FDisk: TByteArray;
    FDiskDigest: array[0..19] of Byte;
    FCommand: array[0..8] of Byte;
    FReply: array[0..9] of Byte;
    FCommandLength, FReplyLength, FReplyIndex: Integer;
    FOffset, FEndOffset, FDelay, FResetInterrupts: Integer;
    FTracks, FHeads, FSectors: Integer;
    FDor, FRate, FCylinder, FSeekStatus, FSeekDrive: Byte;
    FSeekPending, FInserted: Boolean;
    FName, FDriveName: string;
    FNextSectorInResult: Boolean;
    procedure SetInserted(Value: Boolean);
    procedure Reply(const Bytes: array of Byte);
    procedure Execute;
    procedure ResultTransfer(Status0, Status1, Status2: Byte);
    function Ready(Drive: Integer): Boolean;
  public
    constructor Create(const ADriveName: string = 'Yuxing floppy drive'; NextSectorInResult: Boolean = False);
    procedure Reset;
    procedure Mount(const Image: TByteArray; const DisplayName: string);
    property Inserted: Boolean read FInserted write SetInserted;
    property Name: string read FName;
    property DriveName: string read FDriveName;
    function ReadDigitalInput: Byte;
    function PeekData: Byte;
    function IrqPending: Boolean;
    procedure Serialize(State: TNesStateArchive);
    procedure ClockCpu;
    function ReadStatus: Byte;
    function ReadData: Byte;
    procedure WriteData(Value: Byte);
    procedure WriteControl(Value: Byte);
    procedure WriteDigitalOutput(Value: Byte);
  end;

  TMapperYuxing = class(TMapperMmc3)
  private
    FWorkRam: TByteArray;
    FSaveOffset: Integer;
    FRomControl, FRamControl, FChrControl, FRamLatch: Byte;
    FKeyboardRows: Word;
    FKeyboard: TSuborKeyboard;
    FFloppy: TYuxingFloppy;
    FLastA13, FOneBitPlane, FOneBitPage, FSplitFetched: Boolean;
    FSplitAddress: UInt16;
    function Mmc3Mode: Boolean; inline;
    function WorkRamOffset(Address: UInt16): Integer;
    function ChrRamAddress(Address: UInt16; Reading: Boolean): Integer;
    procedure ObservePpu(Address: UInt16);
    function ReadKeyboard: Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure ConfigureMemory(PrgRam, PrgNvRam, ChrRam: UInt64; Battery: Boolean);
    procedure ConnectKeyboard(Keyboard: TSuborKeyboard);
    property Floppy: TYuxingFloppy read FFloppy;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
  end;

implementation

uses
  System.Hash;

const
  YUXING_KEYS: array[0..13, 0..7] of TSuborKey = (
    (SkEsc, SkF9, SkNum7, SkR, SkA, SkNone, SkNone, SkShift),
    (SkNone, SkNumpadEnter, SkNone, SkNumpadMultiply, SkNumpadDivide, SkUp, SkBackspace, SkF12),
    (SkNone, SkNone, SkNone, SkNumpadPlus, SkNumLock, SkLeft, SkDown, SkRight),
    (SkNone, SkNumpad7, SkNumpad8, SkNumpadMinus, SkNumpad9, SkF11, SkEnd, SkPageDown),
    (SkF8, SkNum6, SkE, SkRightBracket, SkL, SkZ, SkN, SkSpace),
    (SkF7, SkNum5, SkW, SkLeftBracket, SkK, SkDelete, SkB, SkSlash),
    (SkF6, SkNum4, SkQ, SkP, SkJ, SkBackslash, SkV, SkDot),
    (SkF5, SkNum3, SkEqual, SkO, SkH, SkApostrophe, SkC, SkComma),
    (SkF4, SkNum2, SkMinus, SkI, SkG, SkSemiColon, SkX, SkM),
    (SkF3, SkNum1, SkNum0, SkU, SkF, SkCapsLock, SkUnknown1, SkNone),
    (SkF2, SkGrave, SkNum9, SkY, SkD, SkCtrl, SkAlt, SkUnknown2),
    (SkF1, SkEnter, SkNum8, SkT, SkS, SkNone, SkUnknown3, SkPageUp),
    (SkNumpadDot, SkF10, SkNumpad4, SkNumpad6, SkNumpad5, SkIns, SkHome, SkNone),
    (SkNone, SkNumpad0, SkNumpad1, SkNumpad2, SkNumpad3, SkNone, SkTab, SkPause));

constructor TYuxingFloppy.Create(const ADriveName: string; NextSectorInResult: Boolean);
begin
  inherited Create;
  FNextSectorInResult := NextSectorInResult;
  FDriveName := ADriveName;
end;

function TYuxingFloppy.ReadDigitalInput: Byte;
begin
  Result := Ord(not FInserted) shl 7;
end;

function TYuxingFloppy.PeekData: Byte;
begin
  if FDelay = 0 then
    case FPhase of
      TPhase.ReadData:
        Exit(FDisk[FOffset]);
      TPhase.Response:
        Exit(FReply[FReplyIndex]);
    end;
  Result := $FF;
end;

function TYuxingFloppy.IrqPending: Boolean;
begin
  Result := (FDor and 8 <> 0) and ((FResetInterrupts <> 0) or FSeekPending or
    (FPhase = TPhase.ReadData) or ((FPhase = TPhase.Response) and
    ((FCommand[0] and $1F) in [$02, $05, $06, $09, $0A, $0C, $0D])));
end;

procedure TYuxingFloppy.Reset;
begin
  FPhase := TPhase.Command;
  FCommandLength := 0;
  FReplyLength := 0;
  FReplyIndex := 0;
  FOffset := 0;
  FEndOffset := 0;
  FDelay := 0;
  FResetInterrupts := 0;
  FSeekPending := False;
end;

procedure TYuxingFloppy.Mount(const Image: TByteArray; const DisplayName: string);
begin
  // Raw double-sided PC floppy geometries with 512-byte sectors.
  var Sectors: Integer;
  case Length(Image) of
    737280:
      Sectors := 9;
    1228800:
      Sectors := 15;
    1474560:
      Sectors := 18;
  else
    raise ENesException.Create('Expected a raw 720 KB, 1.2 MB or 1.44 MB floppy image');
  end;
  var Hash := THashSHA1.Create;
  Hash.Update(Image[0], Length(Image));
  var Digest := Hash.HashAsBytes;
  FDisk := Copy(Image);
  Move(Digest[0], FDiskDigest, SizeOf(FDiskDigest));
  FTracks := 80;
  FHeads := 2;
  FSectors := Sectors;
  FName := DisplayName;
  FInserted := True;
  FCylinder := 0;
  Reset;
end;

procedure TYuxingFloppy.SetInserted(Value: Boolean);
begin
  if Value and (Length(FDisk) = 0) then
    raise ENesException.Create('Select a floppy image first');
  if FInserted = Value then
    Exit;
  Reset;
  FInserted := Value;
end;

procedure TYuxingFloppy.Serialize(State: TNesStateArchive);
begin
  var Digest := FDiskDigest;
  State.Field(Digest, SizeOf(Digest));
  if State.Loading then
    for var i := Low(Digest) to High(Digest) do
      if Digest[i] <> FDiskDigest[i] then
        raise ENesException.Create('Snapshot requires the original floppy image');
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FReply, SizeOf(FReply));
  State.Field(FCommandLength, SizeOf(FCommandLength));
  State.Field(FReplyLength, SizeOf(FReplyLength));
  State.Field(FReplyIndex, SizeOf(FReplyIndex));
  State.Field(FOffset, SizeOf(FOffset));
  State.Field(FEndOffset, SizeOf(FEndOffset));
  State.Field(FDelay, SizeOf(FDelay));
  State.Field(FResetInterrupts, SizeOf(FResetInterrupts));
  State.Field(FDor, SizeOf(FDor));
  State.Field(FRate, SizeOf(FRate));
  State.Field(FCylinder, SizeOf(FCylinder));
  State.Field(FSeekStatus, SizeOf(FSeekStatus));
  State.Field(FSeekDrive, SizeOf(FSeekDrive));
  State.Field(FSeekPending, SizeOf(FSeekPending));
  State.Field(FInserted, SizeOf(FInserted));
  if State.Loading then
  begin
    var ValidCommand := (FCommandLength >= 0) and (FCommandLength < Length(FCommand));
    var ValidReply := (FReplyLength >= 0) and (FReplyLength <= Length(FReply)) and
      (FReplyIndex >= 0) and (FReplyIndex <= FReplyLength);
    if FPhase = TPhase.Response then
      ValidReply := ValidReply and (FReplyIndex < FReplyLength);
    var ValidTransfer := (FPhase <> TPhase.ReadData) or
      (FInserted and (FOffset >= 0) and (FOffset < FEndOffset) and (FEndOffset <= Length(FDisk)));
    if (Ord(FPhase) > Ord(High(TPhase))) or not (ValidCommand and ValidReply and ValidTransfer) then
      raise ENesException.Create('Invalid floppy controller state');
  end;
end;

function TYuxingFloppy.Ready(Drive: Integer): Boolean;
begin
  Result := (Drive = 0) and FInserted and ((FDor and $10) <> 0);
end;

procedure TYuxingFloppy.ClockCpu;
begin
  if FDelay > 0 then
    Dec(FDelay);
end;

procedure TYuxingFloppy.Reply(const Bytes: array of Byte);
begin
  FReplyLength := Length(Bytes);
  FReplyIndex := 0;
  for var i := 0 to High(Bytes) do
    FReply[i] := Bytes[i];
  FPhase := TPhase.Response;
end;

procedure TYuxingFloppy.ResultTransfer(Status0, Status1, Status2: Byte);
begin
  Reply([Status0, Status1, Status2, FCommand[2], FCommand[3], FCommand[4], FCommand[5]]);
end;

function TYuxingFloppy.ReadStatus: Byte;
begin
  case FPhase of
    TPhase.Response:
      Result := $D0;
    TPhase.ReadData:
      Result := $F0;
  else
    Result := $80;
    if FCommandLength > 0 then
      Result := Result or $10;
  end;
  if FDelay > 0 then
    Result := Result and $7F;
end;

function TYuxingFloppy.ReadData: Byte;
begin
  if FDelay > 0 then
    Exit($FF);
  case FPhase of
    TPhase.ReadData:
      begin
        Result := FDisk[FOffset];
        Inc(FOffset);
        if FOffset = FEndOffset then
        begin
          var Status0 := (FCommand[1] and 3) or (FCommand[3] shl 2);
          FCommand[4] := FCommand[6];
          if FNextSectorInResult then
          begin
            Inc(FCommand[4]);
            if FCommand[4] > FSectors then
            begin
              FCommand[4] := 1;
              Inc(FCommand[3]);
              if FCommand[3] = FHeads then
              begin
                FCommand[3] := 0;
                FCommand[2] := (FCommand[2] + 1) mod FTracks;
              end;
            end;
            ResultTransfer(Status0 or $40, $80, 0);
          end
          else
            ResultTransfer(Status0, 0, 0);
        end
        else
          case FRate and 3 of
            0:
              FDelay := 28;
            1:
              FDelay := 47;
            2:
              FDelay := 56;
          else
            FDelay := 14;
          end;
      end;
    TPhase.Response:
      begin
        Result := FReply[FReplyIndex];
        Inc(FReplyIndex);
        if FReplyIndex = FReplyLength then
          FPhase := TPhase.Command;
      end;
  else
    Result := $FF;
  end;
end;

procedure TYuxingFloppy.WriteDigitalOutput(Value: Byte);
begin
  if ((FDor xor Value) and 4) <> 0 then
  begin
    Reset;
    if (Value and 4) <> 0 then
      FResetInterrupts := 4;
  end;
  FDor := Value;
end;

procedure TYuxingFloppy.WriteControl(Value: Byte);
begin
  if (Value and $80) <> 0 then
  begin
    Reset;
    FResetInterrupts := 4;
  end;
  FRate := Value and 3;
end;

procedure TYuxingFloppy.WriteData(Value: Byte);
const
  CommandSize: array[0..31] of Byte = (1, 1, 9, 3, 2, 9, 9, 2, 1, 9, 2, 1, 9, 6, 1, 3,
    1, 9, 2, 4, 1, 1, 9, 1, 1, 9, 1, 1, 1, 1, 1, 1);
begin
  if (FPhase <> TPhase.Command) or ((FDor and 4) = 0) then
    Exit;
  FCommand[FCommandLength] := Value;
  Inc(FCommandLength);
  if FCommandLength = CommandSize[FCommand[0] and $1F] then
  begin
    FCommandLength := 0;
    Execute;
  end;
end;

procedure TYuxingFloppy.Execute;
begin
  var UnitHead := FCommand[1] and 7;
  var Drive := UnitHead and 3;
  case FCommand[0] and $1F of
    $03, $12, $13:
      Exit; // Specify, perpendicular mode and configure have no result bytes.
      $04:
      begin
        var Status := $40 or UnitHead; // Mounted files are read-only.
        if FCylinder = 0 then
          Status := Status or $10;
        if Ready(Drive) then
          Status := Status or $28;
        Reply([Status]);
      end;
    $07, $0F:
      begin
        FSeekDrive := Drive;
        FSeekStatus := $20 or UnitHead;
        FSeekPending := True;
        if Drive = 0 then
          if (FCommand[0] and $1F) = $07 then
            FCylinder := 0
          else
            FCylinder := FCommand[2];
        if not Ready(Drive) then
          FSeekStatus := FSeekStatus or $48;
      end;
    $08:
      if FResetInterrupts > 0 then
      begin
        var ResetDrive := 4 - FResetInterrupts;
        Dec(FResetInterrupts);
        Reply([$C0 or ResetDrive, 0]);
      end
      else if FSeekPending then
      begin
        FSeekPending := False;
        if FSeekDrive = 0 then
          Reply([FSeekStatus, FCylinder])
        else
          Reply([FSeekStatus, 0]);
      end
      else
        Reply([$80]);
    $0A:
      if Ready(Drive) then
        Reply([UnitHead, 0, 0, FCylinder, UnitHead shr 2, 1, 2])
      else
        Reply([$48 or UnitHead, 0, 0, 0, 0, 0, 0]);
    $02, $06, $0C:
      begin
        if not Ready(Drive) then
        begin
          ResultTransfer($48 or UnitHead, 0, 0);
          Exit;
        end;
        var Cylinder := FCommand[2];
        var Head := FCommand[3];
        var Sector := FCommand[4];
        var Last := FCommand[6];
        if (Cylinder >= FTracks) or (Cylinder <> FCylinder) or (Head >= FHeads) or
          (Sector = 0) or (Last < Sector) or (Last > FSectors) or (FCommand[5] <> 2) then
        begin
          ResultTransfer($40 or UnitHead, 4, 0);
          Exit;
        end;
        FOffset := ((Cylinder * FHeads + Head) * FSectors + (Sector - 1)) * 512;
        FEndOffset := FOffset + (Last - Sector + 1) * 512;
        if ((FCommand[0] and $80) <> 0) and (Head = 0) then
        begin
          FEndOffset := ((Cylinder * FHeads + 1) * FSectors + Last) * 512;
          FCommand[3] := 1;
        end;
        FPhase := TPhase.ReadData;
      end;
    $05, $09, $0D:
      ResultTransfer($40 or UnitHead, 2, 0);
    $0E:
      Reply([FCylinder, 0, 0, 0, 0, 0, FSectors, 0, 0, 0]);
    $10:
      Reply([$90]);
  else
    Reply([$80]);
  end;
end;

constructor TMapperYuxing.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, True, MirrorMode);
  FFloppy := TYuxingFloppy.Create;
  ConfigureMemory($80000, 0, $8000, False);
  PowerOn;
end;

destructor TMapperYuxing.Destroy;
begin
  FFloppy.Free;
  inherited;
end;

procedure TMapperYuxing.ConfigureMemory(PrgRam, PrgNvRam, ChrRam: UInt64; Battery: Boolean);
begin
  if (PrgRam > $100000) or (PrgNvRam > $100000) or (PrgRam + PrgNvRam < $8000) or
    (PrgRam + PrgNvRam > $100000) or (((PrgRam + PrgNvRam) and $7FFF) <> 0) or
    (ChrRam < $8000) or (ChrRam > $40000) or ((ChrRam and $1FFF) <> 0) then
    raise ENesException.Create('Invalid memory size for NES 2.0 mapper 169');
  SetLength(FWorkRam, Integer(PrgRam + PrgNvRam));
  SetLength(FChrMemory, Integer(ChrRam));
  FSaveOffset := Length(FWorkRam);
  if PrgNvRam > 0 then
    FSaveOffset := Integer(PrgRam)
  else if Battery then
    FSaveOffset := 0;
end;

procedure TMapperYuxing.ConnectKeyboard(Keyboard: TSuborKeyboard);
begin
  FKeyboard := Keyboard;
end;

function TMapperYuxing.GetSaveMemory: TByteArray;
begin
  Result := Copy(FWorkRam, FSaveOffset, Length(FWorkRam) - FSaveOffset);
end;

procedure TMapperYuxing.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FWorkRam) - FSaveOffset then
    raise ENesException.Create('Invalid Yuxing save size');
  if Length(Data) > 0 then
    Move(Data[0], FWorkRam[FSaveOffset], Length(Data));
end;

procedure TMapperYuxing.PowerOn;
begin
  FRomControl := 0;
  FRamControl := 0;
  FChrControl := 0;
  FRamLatch := 0;
  FKeyboardRows := 0;
  FLastA13 := False;
  FOneBitPlane := False;
  FOneBitPage := False;
  FSplitFetched := False;
  FSplitAddress := 0;
  Reset;
end;

procedure TMapperYuxing.Reset;
begin
  inherited;
  FIrqRequiresCounterTransition := True;
  if FFloppy <> nil then
    FFloppy.Reset;
end;

procedure TMapperYuxing.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FWorkRam[0], Length(FWorkRam));
  State.Field(FRomControl, SizeOf(FRomControl));
  State.Field(FRamControl, SizeOf(FRamControl));
  State.Field(FChrControl, SizeOf(FChrControl));
  State.Field(FRamLatch, SizeOf(FRamLatch));
  State.Field(FKeyboardRows, SizeOf(FKeyboardRows));
  State.Field(FLastA13, SizeOf(FLastA13));
  State.Field(FOneBitPlane, SizeOf(FOneBitPlane));
  State.Field(FOneBitPage, SizeOf(FOneBitPage));
  State.Field(FSplitFetched, SizeOf(FSplitFetched));
  State.Field(FSplitAddress, SizeOf(FSplitAddress));
  FFloppy.Serialize(State);
end;

function TMapperYuxing.Mmc3Mode: Boolean;
begin
  Result := (FChrControl and $80) <> 0;
end;

function TMapperYuxing.WorkRamOffset(Address: UInt16): Integer;
begin
  var Bank: Integer;
  if Address < $8000 then
  begin
    Bank := FRamControl and 3;
    if Bank = 0 then
      Bank := $3C;
    Result := Bank * $2000 + (Address and $1FFF);
  end
  else if Mmc3Mode then
    Result := (PrgRegisterBank((Address - $8000) shr 13) and $3F) * $2000 + (Address and $1FFF)
  else if (FRamControl and $40) <> 0 then
    Result := (FRamLatch shr 1) * $8000 + (Address and $7FFF)
  else
  begin
    Bank := FRamLatch;
    if Address >= $C000 then
      Bank := $FF;
    Result := Bank * $4000 + (Address and $3FFF);
  end;
  Result := Result mod Length(FWorkRam);
end;

function TMapperYuxing.ReadKeyboard: Byte;
begin
  Result := 0;
  if FKeyboard = nil then
    Exit;
  var Keys := FKeyboard.GetPressedKeys;
  for var Row := High(YUXING_KEYS) downto Low(YUXING_KEYS) do
    if (FKeyboardRows and (1 shl Row)) <> 0 then
    begin
      for var Column := 0 to 7 do
        if (YUXING_KEYS[Row, Column] <> SkNone) and (YUXING_KEYS[Row, Column] in Keys) then
          Result := Result or (1 shl Column);
      Exit;
    end;
end;

function TMapperYuxing.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address of
    $4204, $4304:
      Value := FFloppy.ReadStatus;
    $4205, $4305:
      Value := FFloppy.ReadData;
    $4207:
      Value := ReadKeyboard;
    $5002:
      Value := 2; // No external VCD transport attached.
      $6000..$7FFF:
      Value := FWorkRam[WorkRamOffset(Address)];
    $8000..$FFFF:
      if Mmc3Mode or ((FRamControl and 4) <> 0) then
        Value := FWorkRam[WorkRamOffset(Address)]
      else
        Value := FPrgRom[(((FRomControl and $1F) * $8000) + (Address and $7FFF)) mod Length(FPrgRom)];
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperYuxing.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $4200, $4300:
      FFloppy.WriteControl(Value);
    $4201, $4301:
      FFloppy.WriteDigitalOutput(Value);
    $4202, $4302, $5004:
      FKeyboardRows := (FKeyboardRows and $FF00) or Value;
    $4203, $4303, $5005:
      FKeyboardRows := (FKeyboardRows and $FF) or (UInt16(Value) shl 8);
    $4205, $4305:
      FFloppy.WriteData(Value);
    $4800:
      begin
        FRomControl := Value;
        FSplitFetched := False;
      end;
    $5500:
      begin
        FRamControl := Value;
        FSplitFetched := False;
      end;
    $5501:
      begin
        FChrControl := Value;
        FSplitFetched := False;
      end;
    $6000..$7FFF:
      FWorkRam[WorkRamOffset(Address)] := Value;
    $8000..$FFFF:
      if Mmc3Mode then
        Exit(inherited CpuWrite(Address, Value))
      else if (FRamControl and 4) <> 0 then
        if (FRomControl and $20) <> 0 then
          FRamLatch := Value
        else
          FWorkRam[WorkRamOffset(Address)] := Value;
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperYuxing.ChrRamAddress(Address: UInt16; Reading: Boolean): Integer;
begin
  if Mmc3Mode then
    Exit(GetChrOffset(Address));
  if (FRomControl and $80) <> 0 then
  begin
    if (FRamControl and $80) = 0 then
    begin
      if Reading then
        Address := (Address and not $1008) or (Ord(FOneBitPage) shl 12) or (Ord(FOneBitPlane) shl 3);
    end
    else if Reading and FSplitFetched then
    begin
      var Bank := (FChrControl shl 3) and $18;
      if Address < $1000 then
        Bank := Bank or ((FChrControl shr 1) and 6)
      else
        Bank := Bank or ((FSplitAddress shr 7) and 6) or 1;
      Exit((Bank * $1000 + (Address and $FFF)) mod Length(FChrMemory));
    end;
  end;
  var Page := (FChrControl and $10) or ((FChrControl shl 2) and $0C) or ((FChrControl shr 2) and 3);
  Result := (Page * $2000 + Address) mod Length(FChrMemory);
end;

procedure TMapperYuxing.ObservePpu(Address: UInt16);
begin
  if Mmc3Mode or ((FRomControl and $80) = 0) or ((FRamControl and $80) <> 0) then
    Exit;
  var A13 := (Address and $2000) <> 0;
  if A13 and not FLastA13 then
  begin
    FOneBitPlane := (Address and 1) <> 0;
    FOneBitPage := (Address and $200) <> 0;
  end;
  FLastA13 := A13;
end;

function TMapperYuxing.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[ChrRamAddress(Address, True)];
end;

function TMapperYuxing.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  ObservePpu(Address);
  if (Address >= $2000) and (Address < $3F00) and ((Address and $FF) = 0) and
    not Mmc3Mode and ((FRomControl and FRamControl and $80) <> 0) then
  begin
    FSplitAddress := Address;
    FSplitFetched := True;
  end;
  Result := PpuPeek(Address, False, Value, False);
end;

function TMapperYuxing.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  ObservePpu(Address);
  if (FRomControl and FRamControl and $80) <> 0 then
    FSplitFetched := False;
  Result := Address < $2000;
  if Result then
    FChrMemory[ChrRamAddress(Address, False)] := Value;
end;

function TMapperYuxing.GetMirrorMode: TMirrorMode;
begin
  if Mmc3Mode then
    Exit(inherited GetMirrorMode);
  if (FRamControl and 8) <> 0 then
    Result := TMirrorMode.Horizontal
  else
    Result := TMirrorMode.Vertical;
end;

procedure TMapperYuxing.ClockCpu;
begin
  FFloppy.ClockCpu;
end;

procedure TMapperYuxing.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if Mmc3Mode then
    inherited;
end;

function TMapperYuxing.IrqPending: Boolean;
begin
  Result := Mmc3Mode and inherited IrqPending;
end;

end.

