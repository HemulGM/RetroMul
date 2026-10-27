unit ZX.NeoGS;

interface

uses
  System.SysUtils, System.Classes, MD.Z80, Core.Snapshots, ZX.GeneralSound,
  ZX.SDCard, ZX.BlockImage, ZX.VS1011, ZX.AM29F040;

type
  // Standard NedoPC FPGA profile, native VS1011e and programmable flash/CPLD.
  TZXNeoGS = class(TZXGeneralSound)
  private
    FConfig, FSerial, FSDByte, FLED, FIntEnable, FIntRequest, FTimerRate: Byte;
    FPages: array[0..3] of Byte;
    FDMASelect, FIRQAccepted: Byte;
    FDMAAddress: array[1..3] of Cardinal;
    FDMAOn: array[1..3] of Boolean;
    FReadAhead: Byte;
    FPeripheralPhase: UInt64;
    FTimerCounter, FTimerDivider, FSPILeft, FMCLeft, FSDPosition: Integer;
    FSPIOut: Byte;
    FSDData: array[0..511] of Byte;
    FBurstPosition, FBurstCycles: Integer;
    FSD: TZXSDCard;
    FDisk: TZXBlockImage;
    FFlash: TZXAM29F040;
    FVS: TZXVS1011;
    FMCOut, FMCIn, FMDOut: Byte;
    FMDLeft, FMPFill, FMPRead, FMPCycles: Integer;
    FMPData: array[0..511] of Byte;
    FConfigured, FConfigLine, FConfigError, FWasCold, FResetPending, FBootFlash: Boolean;
    FMemConfig: Byte;
    FConfigCount: Integer;
    FBitstream: array[0..59214] of Byte;
    procedure ConfigureByte(Value: Byte);
    procedure StartMD(Value: Byte);
    procedure AdvanceMP3(Cycles: Integer);
    function CPLDOffset(Address: Word): Integer;
    procedure SetBits(var Target: Byte; Value, Mask: Byte);
    procedure StartSPI(Value: Byte);
    procedure FinishSPI;
    procedure CompleteSDDMA;
    procedure UpdateIRQ;
    procedure WarmReset;
    function MemoryOffset(Address: Word): Integer;
  protected
    function ClockHz: Integer; override;
    function ExecuteInstruction: Cardinal; override;
    procedure Clock(Kind: TZ80BusCycle; Count: Cardinal); override;
  public
    constructor Create(RAMKB: Integer);
    destructor Destroy; override;
    procedure Reset; override;
    procedure HostWrite(Address: Word; Value: Byte); override;
    function HostRead(Address: Word; out Value: Byte): Boolean; override;
    function ReadMemory(Address: Word): Byte; override;
    procedure WriteMemory(Address: Word; Value: Byte); override;
    function ReadPort(Address: Word): Byte; override;
    procedure WritePort(Address: Word; Value: Byte); override;
    procedure Levels(out Left, Right: Double); override;
    procedure SerializeState(State: TStateArchive); override;
    function DMARead(Address: Word; ROMSelected: Boolean; out Value: Byte): Boolean;
    procedure DMAWrite(Address: Word; Value: Byte);
    procedure MoveMediaTo(Target: TZXNeoGS);
    procedure Mount(Source: TStream; const KnownHash: TBytes = nil);
    property Disk: TZXBlockImage read FDisk;
    procedure ColdReset;
    procedure LoadFlash(const Data: TBytes);
    function FlashImage: TBytes;
    function FlashDirty: Boolean;
    property FPGAConfigured: Boolean read FConfigured;
    property Frequency: Integer read ClockHz;
  end;

implementation

uses
  System.Hash;

constructor TZXNeoGS.Create(RAMKB: Integer);
begin
  if (RAMKB <> 512) and (RAMKB <> 2048) and (RAMKB <> 4096) then
    raise EArgumentException.Create('Unsupported NeoGS RAM size');
  inherited CreateBoard(RAMKB, 'ZX_NEOGS111', 524288);
  FSD := TZXSDCard.Create;
  FFlash := TZXAM29F040.Create(FROM);
  FVS := TZXVS1011.Create;
  Reset;
end;

destructor TZXNeoGS.Destroy;
begin
  FVS.Free;
  FFlash.Free;
  FSD.Free;
  FDisk.Free;
  inherited;
end;

procedure TZXNeoGS.WarmReset;
begin
  // The hardware reset preserves SDRAM and the card; a motherboard power cycle
  // uses Reset instead. Host port 33 never clears sample/module RAM.
  Z80Reset(FCPU);
  FConfig := $30;
  FPages[0] := 0;
  FPages[1] := 3;
  FStatus := 0;
  FIntEnable := 1;
  FIntRequest := 0;
  FTimerRate := 0;
  FSerial := $0B;
  FLED := 0;
  FDebt := 0;
  FillChar(FDMAOn, SizeOf(FDMAOn), 0);
  FIRQAccepted := 0;
  FSPILeft := 0;
  FMCLeft := 0;
  FSDPosition := -1;
  FBurstPosition := -1;
  FBurstCycles := 0;
  FSD.Select(False);
  FVS.SetReset(False);
  FVS.Select(False);
  FMDLeft := 0;
  FMCIn := $FF;
  FMCOut := $FF;
  FMDOut := 0;
  FMPFill := -1;
  FMPRead := -1;
  FMPCycles := 0;
  FResetPending := False;
end;

procedure TZXNeoGS.Reset;
begin
  inherited;
  FillChar(FPages, SizeOf(FPages), 0);
  FillChar(FDMAAddress, SizeOf(FDMAAddress), 0);
  FillChar(FSDData, SizeOf(FSDData), 0);
  FDMASelect := 0;
  FPeripheralPhase := 0;
  FTimerCounter := 0;
  FTimerDivider := 0;
  FReadAhead := $FF;
  FSDByte := $FF;
  FSPIOut := $FF;
  FSD.Reset;
  FFlash.PowerReset;
  FVS.Reset;
  FConfigured := not FBootFlash and not FFlash.Dirty;
  FConfigLine := FConfigured;
  FConfigError := False;
  FWasCold := False;
  FMemConfig := 0;
  FConfigCount := 0;
  FillChar(FBitstream, SizeOf(FBitstream), 0);
  FillChar(FMPData, SizeOf(FMPData), 0);
  WarmReset;
end;

procedure TZXNeoGS.ColdReset;
begin
  Reset;
  FConfigured := False;
  FConfigLine := False;
end;

procedure TZXNeoGS.LoadFlash(const Data: TBytes);
begin
  FFlash.LoadImage(Data);
  FBootFlash := True;
  ColdReset;
end;

function TZXNeoGS.FlashImage: TBytes;
begin
  Result := FFlash.Image;
end;

function TZXNeoGS.FlashDirty: Boolean;
begin
  Result := FFlash.Dirty;
end;

function TZXNeoGS.ClockHz: Integer;
const
  Frequencies: array[0..3] of Integer = (24000000, 12000000, 20000000, 10000000);
begin
  if not FConfigured then
    Exit(10000000);
  Result := Frequencies[(FConfig shr 4) and 3];
end;

procedure TZXNeoGS.UpdateIRQ;
begin
  Z80Interrupt(FCPU, Ord((FIntEnable and FIntRequest) <> 0));
end;

function TZXNeoGS.ExecuteInstruction: Cardinal;
begin
  if FResetPending then
  begin
    WarmReset;
    Clock(zbcIdle, 16);
    Exit(16);
  end;
  if (FBurstPosition >= 0) or (FMPFill >= 0) then
  begin
    // dma_access.v grants the SD FIFO the Z80 memory bus. A 512-byte burst
    // consumes two selected CPU clocks per byte; the CPU remains in BUSACK.
    Clock(zbcIdle, 2);
    Exit(2);
  end;
  FIRQAccepted := 0;
  var Vector: Byte := $FF;
  var Requests := FIntRequest and FIntEnable;
  if (Requests and 1) <> 0 then
    FIRQAccepted := 1
  else if (Requests and 2) <> 0 then
  begin
    FIRQAccepted := 2;
    Vector := $F7;
  end
  else if (Requests and 4) <> 0 then
  begin
    FIRQAccepted := 4;
    Vector := $EF;
  end;
  Result := Z80DoInstruction(FCPU, FCallbacks, nil, False, Vector);
end;

procedure TZXNeoGS.Clock(Kind: TZ80BusCycle; Count: Cardinal);
const
  Periods: array[0..7] of Integer = (128, 256, 512, 1024, 2048, 8192, 32768, 131072);
begin
  Inc(FClocks, Count);
  if FBurstPosition >= 0 then
  begin
    Inc(FBurstCycles, Integer(Count));
    while (FBurstCycles >= 2) and (FBurstPosition >= 0) do
    begin
      Dec(FBurstCycles, 2);
      FRAM[FDMAAddress[2] and Cardinal(Length(FRAM) - 1)] := FSDData[FBurstPosition];
      FDMAAddress[2] := (FDMAAddress[2] + 1) and $3FFFFF;
      Inc(FBurstPosition);
      if FBurstPosition = 512 then
        CompleteSDDMA;
    end;
  end;
  if Kind = zbcAcknowledge then
    FIntRequest := FIntRequest and (not FIRQAccepted);
  // The timer uses its own 24 MHz crystal. SPI is clocked by clk_fpga,
  // which follows the selected Z80 oscillator (top.v).
  var Hz := Cardinal(ClockHz);
  var Osc: Integer;
  case Hz of
    24000000:
      Osc := Integer(Count); // The saved remainder is already below 24 MHz.
      12000000:
      begin
        Osc := Integer(UInt64(Count) * 2);
        // A frequency change can leave a remainder from the 24 MHz domain.
        if FPeripheralPhase >= 12000000 then
        begin
          Inc(Osc);
          Dec(FPeripheralPhase, 12000000);
        end;
      end;
  else
    begin
      var Phase := FPeripheralPhase + UInt64(Count) * 24000000;
      var Whole := Phase div Hz;
      Osc := Integer(Whole);
      FPeripheralPhase := Phase - Whole * Hz;
    end;
  end;
  if FFlash.Active then
    FFlash.Advance(Osc);
  FVS.Advance(Osc);
  if not FConfigured then
    Exit;
  var TimerClocks := FTimerDivider + Osc;
  var Steps := TimerClocks div 5;
  FTimerDivider := TimerClocks - Steps * 5;
  var Period := Periods[FTimerRate];
  if (FTimerCounter and (Period - 1)) + Steps >= Period then
    FIntRequest := FIntRequest or 1;
  FTimerCounter := (FTimerCounter + Steps) and $1FFFF;
  if FMCLeft > 0 then
  begin
    Dec(FMCLeft, Integer(Count));
    if FMCLeft <= 0 then
    begin
      FMCLeft := 0;
      FMCIn := FVS.Control(FMCOut);
    end;
  end;
  AdvanceMP3(Integer(Count));
  var SPICycles := Integer(Count);
  while (FSPILeft > 0) and (SPICycles >= FSPILeft) do
  begin
    Dec(SPICycles, FSPILeft);
    FSPILeft := 0;
    FinishSPI;
  end;
  if FSPILeft > 0 then
    Dec(FSPILeft, SPICycles);
  UpdateIRQ;
end;

function TZXNeoGS.MemoryOffset(Address: Word): Integer;
begin
  Result := Integer(FPages[Address shr 14]) * $4000 + (Address and $3FFF);
end;

function TZXNeoGS.CPLDOffset(Address: Word): Integer;
begin
  if Address < $4000 then
    Exit($70000 + Address);
  if Address < $8000 then
    Exit(Address and $3FFF);
  Result := (Integer(FMemConfig and 1) shl 15) or (Address and $7FFF);
  if (FMemConfig and $80) = 0 then
    Inc(Result, $70000);
end;

function TZXNeoGS.ReadMemory(Address: Word): Byte;
begin
  if not FConfigured then
  begin
    if (Address < $4000) or ((Address >= $8000) and ((FMemConfig and $80) = 0)) then
      Exit(FFlash.Read(CPLDOffset(Address)));
    Exit(FRAM[CPLDOffset(Address)]);
  end;
  var Offset := MemoryOffset(Address);
  if ((FConfig and 1) = 0) and ((Address shr 14) <> 1) then
    Result := FFlash.Read(Offset and $7FFFF)
  else
    Result := FRAM[Offset and (Length(FRAM) - 1)];
  if (Address and $E000) = $6000 then
  begin
    var Mask := 3;
    if (FConfig and 4) <> 0 then
      Mask := 7;
    FSample[(Address shr 8) and Mask] := Result;
  end;
end;

procedure TZXNeoGS.WriteMemory(Address: Word; Value: Byte);
begin
  if not FConfigured then
  begin
    if (Address < $4000) or ((Address >= $8000) and ((FMemConfig and $80) = 0)) then
      FFlash.Write(CPLDOffset(Address), Value)
    else
      FRAM[CPLDOffset(Address)] := Value;
    Exit;
  end;
  if ((FConfig and 1) = 0) and ((Address shr 14) <> 1) then
  begin
    FFlash.Write(MemoryOffset(Address) and $7FFFF, Value);
    Exit;
  end;
  // Match memmap.v's physical page protection, including A21 aliasing.
  if ((FConfig and 3) = 3) and ((FPages[Address shr 14] and $7E) = 0) then
    Exit;
  FRAM[MemoryOffset(Address) and (Length(FRAM) - 1)] := Value;
end;

function TZXNeoGS.HostRead(Address: Word; out Value: Byte): Boolean;
begin
  if not FConfigured then
  begin
    Value := $FF;
    Exit(False);
  end;
  Result := inherited;
end;

procedure TZXNeoGS.HostWrite(Address: Word; Value: Byte);
begin
  if not FConfigured then
    Exit;
  if (Address and 255) = $33 then
  begin
    case Value and $E0 of
      $80:
        WarmReset;
      $40:
        Z80NonMaskableInterrupt(FCPU);
      $20:
        FLED := FLED xor 1;
    end;
  end
  else
    inherited;
end;

procedure TZXNeoGS.SetBits(var Target: Byte; Value, Mask: Byte);
begin
  if (Value and $80) <> 0 then
    Target := Target or (Value and Mask)
  else
    Target := Target and (not (Value and Mask));
end;

function TZXNeoGS.ReadPort(Address: Word): Byte;
begin
  Result := $FF;
  case Address and $C0 of
    $40:
      Exit(Ord(FWasCold) shl 7);
    $80:
      Exit((Ord(FConfigLine and not FConfigError) shl 7) or Ord(FConfigured));
    $C0:
      Exit($80);
  end;
  if not FConfigured then
    Exit;
  case Address and 255 of
    1:
      Result := FCommand;
    2:
      begin
        Result := FToGS;
        FStatus := FStatus and $7F;
      end;
    4:
      Result := FStatus;
    5:
      FStatus := FStatus and $FE;
    $0A:
      FStatus := (FStatus and $7F) or ((1 - (FPages[2] and 1)) shl 7);
    $0B:
      FStatus := (FStatus and $FE) or (FVolume[3] shr 5);
    $0D:
      Result := FIntRequest;
    $0F:
      Result := FConfig;
    $11:
      Result := FSerial;
    $12:
      begin
        // SD detect/WP follow the programmer's manual (corrected rev. board).
        Result := (Ord(FMCLeft = 0) shl 3) or Ord(FVS.DREQ);
        if FDisk <> nil then
          Result := Result or 2 or (Ord(FDisk.WriteProtected) shl 2);
      end;
    $13:
      Result := FSDByte;
    $14:
      begin
        Result := FSDByte;
        StartSPI($FF);
      end;
    $15:
      Result := FMCIn;
    $1B:
      Result := FDMASelect;
    $1C..$1F:
      if FDMASelect in [1, 2, 3] then
        case Address and 3 of
          0:
            Result := (FDMAAddress[FDMASelect] shr 16) and $3F;
          1:
            Result := (FDMAAddress[FDMASelect] shr 8) and 255;
          2:
            Result := FDMAAddress[FDMASelect] and 255;
          3:
            Result := Ord(FDMAOn[FDMASelect]) shl 7;
        end;
  end;
end;

procedure TZXNeoGS.WritePort(Address: Word; Value: Byte);
begin
  case Address and $C0 of
    $40:
      begin
        FMemConfig := Value and $81;
        Exit;
      end;
    $80:
      begin
        if (Value and $80) <> 0 then
          FWasCold := True;
        FConfigLine := (Value and 1) <> 0;
        if not FConfigLine then
        begin
          FConfigured := False;
          FConfigCount := 0;
          FConfigError := False;
          FResetPending := False;
          Z80Interrupt(FCPU, 0);
          FillChar(FDMAOn, SizeOf(FDMAOn), 0);
          FSPILeft := 0;
          FMCLeft := 0;
          FMDLeft := 0;
          FSDPosition := -1;
          FBurstPosition := -1;
          FBurstCycles := 0;
          FMPFill := -1;
          FMPRead := -1;
          FMPCycles := 0;
          FSD.Select(False);
          FVS.SetReset(False);
        end;
        Exit;
      end;
    $C0:
      begin
        ConfigureByte(Value);
        Exit;
      end;
  end;
  if not FConfigured then
    Exit;
  case Address and 255 of
    0:
      begin
        FPages[2] := (Integer(Value) shl 1) and 255;
        if (FConfig and 8) <> 0 then
          FPages[2] := FPages[2] or (Value shr 7)
        else
          FPages[3] := FPages[2] or 1;
      end;
    1:
      FLED := Value and 1;
    3:
      begin
        FToHost := Value;
        FStatus := FStatus or $80;
      end;
    5:
      FStatus := FStatus and $FE;
    6..9:
      FVolume[(Address and 255) - 6] := Value and 63;
    $0A, $0B:
      ReadPort(Address);
    $0C:
      begin
        SetBits(FIntEnable, Value, 7);
        UpdateIRQ;
      end;
    $0D:
      begin
        SetBits(FIntRequest, Value, 7);
        UpdateIRQ;
      end;
    $0E:
      FTimerRate := Value and 7;
    $0F:
      FConfig := Value;
    $10:
      if (FConfig and 8) <> 0 then
        FPages[3] := ((Integer(Value) shl 1) or (Value shr 7)) and 255;
    $11:
      begin
        SetBits(FSerial, Value, $3F);
        FSD.Select((FSerial and 1) = 0);
        FVS.SetReset((FSerial and 4) <> 0);
        FVS.Select((FSerial and 2) = 0);
      end;
    $13:
      if not FDMAOn[2] then
        StartSPI(Value);
    $14:
      if not FDMAOn[3] then
        StartMD(Value);
    $15:
      if FMCLeft = 0 then
      begin
        FMCOut := Value;
        FMCLeft := 16 shl (((FSerial shr 3) and 1) or ((FSerial shr 4) and 2));
      end;
    $16..$19:
      FVolume[(Address and 255) - $12] := Value and 63;
    $1B:
      FDMASelect := Value and 7;
    $1C..$1F:
      if FDMASelect in [1, 2, 3] then
        case Address and 3 of
          0:
            FDMAAddress[FDMASelect] := (FDMAAddress[FDMASelect] and $FFFF) or (Cardinal(Value and $3F) shl 16);
          1:
            FDMAAddress[FDMASelect] := (FDMAAddress[FDMASelect] and $3F00FF) or (Cardinal(Value) shl 8);
          2:
            FDMAAddress[FDMASelect] := (FDMAAddress[FDMASelect] and $3FFF00) or Value;
          3:
            begin
              FDMAOn[FDMASelect] := (Value and $80) <> 0;
              if FDMASelect = 3 then
              begin
                FMPFill := -1;
                FMPRead := -1;
                FMPCycles := 0;
                if FDMAOn[3] then
                  FMPFill := 0;
              end;
              if FDMASelect = 2 then
              begin
                FSDPosition := -1;
                FBurstPosition := -1;
                FBurstCycles := 0;
                if FDMAOn[2] then
                  StartSPI($FF);
              end;
            end;
        end;
    $20..$23:
      FPages[Address and 3] := Value;
  end;
end;

procedure TZXNeoGS.StartSPI(Value: Byte);
begin
  if FSPILeft <> 0 then
    Exit;
  FSPIOut := Value;
  FSPILeft := 16; // SD SCLK = selected CPU clock / 2, eight bits.
end;

procedure TZXNeoGS.CompleteSDDMA;
begin
  FDMAOn[2] := False;
  FSDPosition := -1;
  FBurstPosition := -1;
  FBurstCycles := 0;
  FIntRequest := FIntRequest or 2;
  UpdateIRQ;
end;

procedure TZXNeoGS.FinishSPI;
begin
  FSDByte := FSD.SPI(FSPIOut);
  if not FDMAOn[2] then
    Exit;
  if FSDPosition = -1 then
  begin
    if FSDByte = $FE then
      FSDPosition := 0
    else if FSDByte <> $FF then
    begin
      CompleteSDDMA;
      Exit;
    end;
  end
  else
  begin
    if FSDPosition < 512 then
      FSDData[FSDPosition] := FSDByte;
    Inc(FSDPosition);
    if FSDPosition = 514 then
    begin
      // The FIFO is now full. BUSRQ begins a separate memory-bus burst.
      FBurstPosition := 0;
      FBurstCycles := 0;
      Exit;
    end;
  end;
  StartSPI($FF);
end;

function TZXNeoGS.DMARead(Address: Word; ROMSelected: Boolean; out Value: Byte): Boolean;
begin
  Value := $FF;
  Result := FConfigured and FDMAOn[1] and (Address < $4000) and ROMSelected;
  if not Result then
    Exit;
  Value := FReadAhead;
  FReadAhead := FRAM[FDMAAddress[1] and Cardinal(Length(FRAM) - 1)];
  FDMAAddress[1] := (FDMAAddress[1] + 1) and $3FFFFF;
end;

procedure TZXNeoGS.DMAWrite(Address: Word; Value: Byte);
begin
  if not FConfigured or not FDMAOn[1] or (Address >= $4000) then
    Exit;
  FRAM[FDMAAddress[1] and Cardinal(Length(FRAM) - 1)] := Value;
  FDMAAddress[1] := (FDMAAddress[1] + 1) and $3FFFFF;
end;

procedure TZXNeoGS.MoveMediaTo(Target: TZXNeoGS);
begin
  if Target = Self then
    Exit;
  Target.FFlash.LoadImage(FFlash.Image);
  Target.FBootFlash := FBootFlash;
  if FFlash.Dirty then
    Target.FFlash.MarkDirty;
  Target.FDisk.Free;
  Target.FDisk := FDisk;
  Target.FSD.Disk := FDisk;
  FDisk := nil;
  FSD.Disk := nil;
end;

procedure TZXNeoGS.Mount(Source: TStream; const KnownHash: TBytes);
begin
  var Disk := TZXBlockImage.Create(Source, KnownHash);
  FSD.Disk := Disk;
  FDisk.Free;
  FDisk := Disk;
  FSD.Reset;
  FSD.Select((FSerial and 1) = 0);
  FSPILeft := 0;
  FSDByte := $FF;
end;

procedure TZXNeoGS.Levels(out Left, Right: Double);

  function Sample(Index: Integer): Integer;
  begin
    var Value := FSample[Index];
    if (FConfig and $80) <> 0 then
      Value := Value xor $80;
    Result := Integer(Value) - 128;
  end;

begin
  Left := 0;
  Right := 0;
  if not FConfigured then
    Exit;
  var ML, MR: Double;
  FVS.Levels(ML, MR);
  var L := Sample(0) * FVolume[0] + Sample(1) * FVolume[1];
  var R := Sample(2) * FVolume[2] + Sample(3) * FVolume[3];
  if (FConfig and 4) <> 0 then
  begin
    Inc(L, Sample(4) * FVolume[4] + Sample(5) * FVolume[5]);
    Inc(R, Sample(6) * FVolume[6] + Sample(7) * FVolume[7]);
  end
  else if (FConfig and $40) <> 0 then
  begin
    Inc(L, Sample(2) * FVolume[4] + Sample(3) * FVolume[5]);
    R := Sample(0) * FVolume[2] + Sample(1) * FVolume[3] +
      Sample(2) * FVolume[6] + Sample(3) * FVolume[7];
  end;
  // Same output reference as GS. Four samples per side can reach twice its peak.
  Left := L / (128.0 * 63 * 2) * 0.25 + ML;
  Right := R / (128.0 * 63 * 2) * 0.25 + MR;
end;

procedure TZXNeoGS.ConfigureByte(Value: Byte);
begin
  if not FConfigLine or FConfigured or FConfigError then
    Exit;
  // Board routing: D0,D1,D2,D3,D4,D5,D6,D7 -> 0,4,1,3,7,2,6,5.
  var B := (Value and $49) or ((Value and 2) shl 3) or
    ((Value and 4) shr 1) or ((Value and $10) shl 3) or
    ((Value and $20) shr 3) or ((Value and $80) shr 2);
  FBitstream[FConfigCount] := B;
  Inc(FConfigCount);
  if FConfigCount <> Length(FBitstream) then
    Exit;
  var Data: TBytes;
  SetLength(Data, Length(FBitstream));
  Move(FBitstream, Data[0], Length(Data));
  var SHA := THashSHA2.Create;
  SHA.Update(Data);
  var Hash := SHA.HashAsString;
  FConfigured := SameText(Hash, '360512cad549af472372789d05a6832af4d6729be6ae26b31fb615ab5d8263de') or
    SameText(Hash, '44311fc479d440ebaff51f0f9d75fee37a265b54d0c657b1d55d54474a22341f') or
    SameText(Hash, 'caa303efefd4ea196a28e652944208fc5657125b55bcbd5a2a1a4bb8c8e0b00a');
  FConfigError := not FConfigured;
  FResetPending := FConfigured;
end;

procedure TZXNeoGS.StartMD(Value: Byte);
begin
  if FMDLeft <> 0 then
    Exit;
  FMDOut := Value;
  FMDLeft := 16;
  if (FSerial and $10) <> 0 then
    FMDLeft := 32;
end;

procedure TZXNeoGS.AdvanceMP3(Cycles: Integer);
begin
  // The memory bus is shared: SD burst wins, then the MP3 FIFO fetch.
  if (FMPFill >= 0) and (FBurstPosition < 0) then
  begin
    var FetchCycles := (512 - FMPFill) * 2 - FMPCycles;
    if FetchCycles > Cycles then
      FetchCycles := Cycles;
    Inc(FMPCycles, FetchCycles);
    Dec(Cycles, FetchCycles);
    while (FMPCycles >= 2) and (FMPFill >= 0) do
    begin
      Dec(FMPCycles, 2);
      FMPData[FMPFill] := FRAM[FDMAAddress[3] and Cardinal(Length(FRAM) - 1)];
      FDMAAddress[3] := (FDMAAddress[3] + 1) and $3FFFFF;
      Inc(FMPFill);
      if FMPFill = 512 then
      begin
        FMPFill := -1;
        FMPRead := 0;
        FMPCycles := 0;
      end;
    end;
  end;
  while Cycles > 0 do
  begin
    if FMDLeft = 0 then
    begin
      if (FMPRead < 0) or not FDMAOn[3] or not FVS.DREQ then
        Exit;
      StartMD(FMPData[FMPRead]);
      Inc(FMPRead);
      if FMPRead = 512 then
      begin
        FMPRead := -1;
        FDMAOn[3] := False;
        FIntRequest := FIntRequest or 4;
      end;
    end;
    var Step := Cycles;
    if Step > FMDLeft then
      Step := FMDLeft;
    Dec(Cycles, Step);
    Dec(FMDLeft, Step);
    if FMDLeft = 0 then
      FVS.Data(FMDOut);
  end;
end;

procedure TZXNeoGS.SerializeState(State: TStateArchive);
begin
  inherited;
  State.Field(FConfig, 1);
  State.Field(FSerial, 1);
  State.Field(FSDByte, 1);
  State.Field(FLED, 1);
  State.Field(FIntEnable, 1);
  State.Field(FIntRequest, 1);
  State.Field(FTimerRate, 1);
  State.Field(FPages, SizeOf(FPages));
  State.Field(FDMASelect, 1);
  State.Field(FIRQAccepted, 1);
  State.Field(FDMAAddress, SizeOf(FDMAAddress));
  State.Field(FDMAOn, SizeOf(FDMAOn));
  State.Field(FReadAhead, 1);
  State.Field(FPeripheralPhase, SizeOf(FPeripheralPhase));
  State.Field(FTimerCounter, SizeOf(FTimerCounter));
  State.Field(FTimerDivider, SizeOf(FTimerDivider));
  State.Field(FSPILeft, SizeOf(FSPILeft));
  State.Field(FMCLeft, SizeOf(FMCLeft));
  State.Field(FSDPosition, SizeOf(FSDPosition));
  State.Field(FSPIOut, 1);
  State.Field(FSDData, SizeOf(FSDData));
  State.Field(FBurstPosition, SizeOf(FBurstPosition));
  State.Field(FBurstCycles, SizeOf(FBurstCycles));
  FFlash.SerializeState(State);
  FVS.SerializeState(State);
  State.Field(FMCOut, 1);
  State.Field(FMCIn, 1);
  State.Field(FMDOut, 1);
  State.Field(FMDLeft, 4);
  State.Field(FMPFill, 4);
  State.Field(FMPRead, 4);
  State.Field(FMPCycles, 4);
  State.Field(FMPData, SizeOf(FMPData));
  State.Field(FConfigured, SizeOf(FConfigured));
  State.Field(FConfigLine, SizeOf(FConfigLine));
  State.Field(FConfigError, SizeOf(FConfigError));
  State.Field(FWasCold, SizeOf(FWasCold));
  State.Field(FResetPending, SizeOf(FResetPending));
  State.Field(FBootFlash, SizeOf(FBootFlash));
  State.Field(FMemConfig, 1);
  State.Field(FConfigCount, 4);
  State.Field(FBitstream, SizeOf(FBitstream));
  if (FMDLeft < 0) or (FMDLeft > 32) or (FMPFill < -1) or (FMPFill > 511) or
    (FMPRead < -1) or (FMPRead > 511) or (FMPCycles < 0) or (FMPCycles > 1) or
    ((FMPFill >= 0) and (FMPRead >= 0)) or
    (((FMPFill >= 0) or (FMPRead >= 0)) and not FDMAOn[3]) or
    ((FMemConfig and $7E) <> 0) or (FConfigCount < 0) or (FConfigCount > 59215) or
    (FConfigured and (FConfigError or not FConfigLine)) or (FResetPending and not FConfigured) then
    raise EReadError.Create('Invalid NeoGS MP3/FPGA state');
  FSD.SerializeState(State);
  var HasDisk := FDisk <> nil;
  State.Field(HasDisk, SizeOf(HasDisk));
  if HasDisk <> (FDisk <> nil) then
    raise EReadError.Create('NeoGS SD source must be mounted before loading state');
  if HasDisk then
    FDisk.SerializeState(State);
  if (FSerial > 63) or (FLED > 1) or (FIntEnable > 7) or (FIntRequest > 7) or
    (FTimerRate > 7) or (FDMASelect > 7) or not (FIRQAccepted in [0, 1, 2, 4]) or
    (FPeripheralPhase >= 24000000) or (FTimerCounter < 0) or (FTimerCounter > $1FFFF) or
    (FTimerDivider < 0) or (FTimerDivider > 4) or (FSPILeft < 0) or (FSPILeft > 16) or
    (FMCLeft < 0) or (FMCLeft > 1024) or (FSDPosition < -1) or (FSDPosition > 514) or
    (FBurstPosition < -1) or (FBurstPosition > 511) or (FBurstCycles < 0) or (FBurstCycles > 1) or
    ((FBurstPosition >= 0) and ((FSDPosition <> 514) or not FDMAOn[2])) or
    ((FSDPosition = 514) and (FBurstPosition < 0)) then
    raise EReadError.Create('Invalid NeoGS peripheral state');
  for var I := 1 to 3 do
    if FDMAAddress[I] > $3FFFFF then
      raise EReadError.Create('Invalid NeoGS DMA address');
end;

end.

