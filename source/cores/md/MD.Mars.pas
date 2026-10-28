unit MD.Mars;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, HW.SH2, HW.SH7604,
  Core.Snapshots;

type
  TMD32X = class
  private
    type
      TPort = record
        Owner: TMD32X;
        Index: Integer;
      end;

      PPort = ^TPort;

      TBoardState = record
        RAM: array[0..$3FFFF] of Byte;
        DRAM: array[0..1, 0..$FFFF] of Word;
        Palette: array[0..255] of Word;
        Registers: array[0..31] of Word;
        Video: array[0..7] of Word;
        CacheRAM: array[0..1, 0..4095] of Byte;
        Peripheral: array[0..1, 0..511] of Byte;
        IRQMask, Pending: array[0..1] of Byte;
        CPUTime: array[0..1] of Int64;
        Time, PWMTime, FillUntil: Int64;
        FrameSelect, RequestedFrame, HCounter, PWMIRQCounter: Integer;
        FIFO: array[0..7] of Word;
        FIFORead, FIFOCount: Integer;
        PWM: array[0..1, 0..2] of Word;
        PWMRead, PWMCount, PWMSample: array[0..1] of Integer;
        LastLine: Integer;
        HintInterval: Word;
        HintVector: Cardinal;
        HBlankEnable: Boolean;
        DMANext, FRTLast: array[0..1] of Int64;
        DMAPriority: array[0..1] of Integer;
        DMARequests: array[0..1, 0..1] of Integer;
        FRC, FRTPhase: array[0..1] of Word;
        OCR: array[0..1, 0..1] of Word;
        FRTTemp, FRTReadFlags: array[0..1] of Byte;
        FillAddress, FillCount, FillBank: Integer;
        CacheTag: array[0..1, 0..3, 0..63] of Cardinal;
        CacheLRU: array[0..1, 0..63] of Byte;
      end;
  private
    FState: TBoardState;
    FCPU: array[0..1] of TSH2;
    // Derived views of live hardware cache RAM; never serialized.
    FDataCache: array[0..1, 0..63] of TSH2DataCacheView;
    FPort: array[0..1] of TPort;
    FROM, FBoot68k: TBytes;
    FBoot: array[0..1] of TBytes;
    FPAL: Boolean;
    FExecutingCPU, FAccessWait: Integer;
    procedure WaitBus(CPU: Integer; Address: Cardinal; Size: Integer; Writing: Boolean);
    function ReadMemory(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteMemory(CPU: Integer; Address, Value: Cardinal; Size: Integer);
    procedure TouchCache(CPU, Entry, Way: Integer);
    function ROMByte(Address: Cardinal): Byte;
    function RegisterRead(Index, CPU: Integer): Word;
    procedure RegisterWrite(Index: Integer; Value, Mask: Word; CPU: Integer);
    function VideoRead(Index: Integer): Word;
    procedure VideoWrite(Index: Integer; Value, Mask: Word);
    procedure UpdateIRQ(CPU: Integer);
    procedure PWMTick(Target: Int64);
    procedure PeripheralWrite(CPU: Integer; Address, Value: Cardinal; Size: Integer);
    function RunDMA(CPU, Channel: Integer): Boolean;
    procedure AdvancePeripherals(CPU: Integer; Target: Int64);
    procedure AdvanceFill(Target: Int64);
    function PeekPeripheral(CPU, Index, Size: Integer): Cardinal;
    procedure StorePeripheral(CPU, Index: Integer; Value: Cardinal; Size: Integer);
    function PeripheralRead(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
  public
    constructor Create(const ROM, Boot68k, BootMaster, BootSlave: TBytes; PAL: Boolean);
    destructor Destroy; override;
    procedure Reset;
    procedure Advance(Target: Int64);
    function MainRead(Address: Cardinal; out Value: Word): Boolean;
    function MainWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    function ReadSH2(CPU: Integer; Address: Cardinal; Size: Integer; Instruction: Boolean = False): Cardinal;
    procedure WriteSH2(CPU: Integer; Address, Value: Cardinal; Size: Integer);
    procedure RenderLine(Line: Integer; var Pixels: TArray<TAlphaColor>; Offset, Width: Integer; const MDIndices: array of Byte; Background: Byte);
    procedure Sample(out Left, Right: Integer);
    procedure SerializeState(Archive: TStateArchive);
    function CPUState(Index: Integer): TSH2State;
  end;

implementation

uses
  System.Math;

function SHRead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var Port := TMD32X.PPort(User)^;
  Result := Port.Owner.ReadSH2(Port.Index, Address, Size);
end;

function SHFetch(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var Port := TMD32X.PPort(User)^;
  Result := Port.Owner.ReadSH2(Port.Index, Address, Size, True);
end;

procedure SHWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  var Port := TMD32X.PPort(User)^;
  Port.Owner.WriteSH2(Port.Index, Address, Value, Size);
end;

constructor TMD32X.Create(const ROM, Boot68k, BootMaster, BootSlave: TBytes; PAL: Boolean);
begin
  inherited Create;
  if (Length(Boot68k) <> 256) or (Length(BootMaster) <> 2048) or (Length(BootSlave) <> 1024) then
    raise EReadError.Create('Invalid 32X BIOS size');
  FExecutingCPU := -1;
  FROM := Copy(ROM);
  FBoot68k := Copy(Boot68k);
  FBoot[0] := Copy(BootMaster);
  FBoot[1] := Copy(BootSlave);
  FPAL := PAL;
  for var I := 0 to 1 do
  begin
    FPort[I].Owner := Self;
    FPort[I].Index := I;
    FCPU[I] := TSH2.Create(SHRead, SHWrite, @FPort[I], SHFetch);
    FCPU[I].SetDataCacheView(@FDataCache[I, 0], True);
  end;
  Reset;
end;

destructor TMD32X.Destroy;
begin
  FCPU[0].Free;
  FCPU[1].Free;
  inherited;
end;

procedure TMD32X.Reset;
begin
  FState := Default(TBoardState);
  FillChar(FDataCache, SizeOf(FDataCache), $FF);
  FState.Registers[0] := $82; // Adapter present, reset released, ADEN clear.
  FState.Registers[8] := $FFFF;
  if not FPAL then
    FState.Video[0] := $8000;
  FState.LastLine := -1;
  for var I := 0 to 1 do
  begin
    FState.OCR[I, 0] := $FFFF;
    FState.OCR[I, 1] := $FFFF;
    FState.Peripheral[I, $10] := 1;
    FState.Peripheral[I, $17] := $E0;
    FState.DMAPriority[I] := 1;
    FCPU[I].Reset;
  end;
end;

function TMD32X.ROMByte(Address: Cardinal): Byte;
begin
  if Address < Cardinal(Length(FROM)) then
    Result := FROM[Address]
  else
    Result := $FF;
end;

function TMD32X.RegisterRead(Index, CPU: Integer): Word;
begin
  Result := FState.Registers[Index];
  case Index of
    0:
      if CPU >= 0 then
        Result := (Result and $8000) or $200 or (Word(Ord(Length(FROM) = 0)) shl 8) or FState.IRQMask[CPU] or (Word(Ord(FState.HBlankEnable)) shl 7);
    2:
      if CPU >= 0 then
        Result := FState.HintInterval;
    3:
      begin
        Result := Result and 7;
        if FState.FIFOCount = 8 then
          Result := Result or $80;
        if CPU >= 0 then
        begin
          Result := Result and 7;
          if FState.FIFOCount = 8 then
            Result := Result or $8000;
          if FState.FIFOCount = 0 then
            Result := Result or $4000;
        end;
      end;
    9:
      if (CPU >= 0) and (FState.FIFOCount > 0) then
      begin
        Result := FState.FIFO[FState.FIFORead];
        FState.FIFORead := (FState.FIFORead + 1) and 7;
        Dec(FState.FIFOCount);
      end;
    26, 27, 28:
      begin
        var Channel := Ord(Index = 27);
        Result := 0;
        if FState.PWMCount[Channel] = 0 then
          Result := $4000;
        if FState.PWMCount[Channel] = 3 then
          Result := $8000;
      end;
  end;
end;

procedure TMD32X.UpdateIRQ(CPU: Integer);
begin
  var Bits := FState.Pending[CPU] and not 2;
  if (FState.Registers[1] and (1 shl CPU) <> 0) and (FState.IRQMask[CPU] and 2 <> 0) then
    Bits := Bits or 2;
  var Level := 0;
  if Bits and $10 <> 0 then
    Level := 14
  else if Bits and 8 <> 0 then
    Level := 12
  else if Bits and 4 <> 0 then
    Level := 10
  else if Bits and 2 <> 0 then
    Level := 8
  else if Bits and 1 <> 0 then
    Level := 6;
  // External sources win ties. Internal vectors are programmed in the INTC.
  var Vector := 64 + Level div 2;
  var Flags := FState.Peripheral[CPU, $10] and FState.Peripheral[CPU, $11] and $8E;
  var Priority := FState.Peripheral[CPU, $60] and 15;
  if (Flags <> 0) and (Priority > Level) then
  begin
    Level := Priority;
    if Flags and $80 <> 0 then
      Vector := FState.Peripheral[CPU, $66] and $7F
    else if Flags and $C <> 0 then
      Vector := FState.Peripheral[CPU, $67] and $7F
    else
      Vector := FState.Peripheral[CPU, $68] and $7F;
  end;
  Priority := FState.Peripheral[CPU, $E2] and 15;
  for var I := 0 to 1 do
    if (FState.Peripheral[CPU, $18F + I * 16] and 6 = 6) and (Priority > Level) then
    begin
      Level := Priority;
      Vector := FState.Peripheral[CPU, $1A3 + I * 8] and $7F;
    end;
  FCPU[CPU].Interrupt(Level, Vector);
end;

procedure TMD32X.RegisterWrite(Index: Integer; Value, Mask: Word; CPU: Integer);
begin
  var Old := FState.Registers[Index];
  var V: Word := (Old and not Mask) or (Value and Mask);
  case Index of
    0:
      if CPU < 0 then
      begin
        FState.Registers[0] := (Old and $80) or (V and $8003);
        if (Old and 2 = 0) and (V and 2 <> 0) then
          for var I := 0 to 1 do
          begin
            FCPU[I].Reset;
            FState.CPUTime[I] := FState.Time * 3 div 7;
          end;
      end
      else
      begin
        if Mask and $FF <> 0 then
        begin
          FState.IRQMask[CPU] := V and $F;
          FState.HBlankEnable := V and $80 <> 0;
        end;
        if Mask and $FF00 <> 0 then
          FState.Registers[0] := (Old and $7FFF) or (V and $8000);
        UpdateIRQ(CPU);
      end;
    1:
      if CPU < 0 then
      begin
        FState.Registers[1] := V and 3;
        for var I := 0 to 1 do
        begin
          if (V and (1 shl I) <> 0) and (FState.IRQMask[I] and 2 <> 0) then
            FState.Pending[I] := FState.Pending[I] or 2;
          UpdateIRQ(I);
        end;
      end;
    2:
      if CPU < 0 then
        FState.Registers[2] := V and 3
      else if Mask and $FF <> 0 then
        FState.HintInterval := V and $FF;
    3:
      begin
        FState.Registers[3] := V and 7;
        if V and 4 = 0 then
        begin
          FState.FIFORead := 0;
          FState.FIFOCount := 0;
        end;
      end;
    4, 6:
      if CPU < 0 then
        FState.Registers[Index] := V and $FF;
    5:
      if CPU < 0 then
        FState.Registers[Index] := V and $FFFE;
    7:
      if CPU < 0 then
        FState.Registers[Index] := V;
    8:
      if CPU < 0 then
        FState.Registers[Index] := V and $FFFC;
    9:
      if (CPU < 0) and (FState.FIFOCount < 8) then
      begin
        FState.FIFO[(FState.FIFORead + FState.FIFOCount) and 7] := V;
        Inc(FState.FIFOCount);
      end;
    10..14:
      if CPU >= 0 then
      begin
        FState.Pending[CPU] := FState.Pending[CPU] and not (1 shl (14 - Index));
        if Index = 13 then
          FState.Registers[1] := FState.Registers[1] and not (1 shl CPU);
        UpdateIRQ(CPU);
      end;
    16..23:
      FState.Registers[Index] := V;
    24:
      begin
        if CPU < 0 then
          V := (Old and $FF00) or (V and $F);
        FState.Registers[Index] := V and $F8F;
        FState.PWMIRQCounter := ((V shr 8) + 15) mod 16 + 1;
      end;
    25:
      FState.Registers[Index] := V and $FFF;
    26..28:
      if Mask and $FF <> 0 then
        for var I := 0 to 1 do
          if (Index = 28) or (I = Index - 26) then
          begin
              // A full PWM FIFO discards its oldest pulse, as on the hardware.
            if FState.PWMCount[I] = 3 then
            begin
              FState.PWMRead[I] := (FState.PWMRead[I] + 1) mod 3;
              Dec(FState.PWMCount[I]);
            end;
            FState.PWM[I, (FState.PWMRead[I] + FState.PWMCount[I]) mod 3] := V and $FFF;
            Inc(FState.PWMCount[I]);
          end;
  end;
end;

function TMD32X.VideoRead(Index: Integer): Word;
begin
  Result := FState.Video[Index];
  if Index = 5 then
  begin
    var Lines := 262 + 51 * Ord(FPAL);
    var Line := (FState.Time div 3420) mod Lines;
    var Visible := 224 + 16 * Ord(FState.Video[0] and $40 <> 0);
    Result := FState.FrameSelect or $2000;
    if Line >= Visible then
      Result := Result or $8000;
    if FState.Time mod 3420 < 860 then
      Result := Result or $4000;
    if FState.FillCount > 0 then
      Result := Result or 2;
  end;
end;

procedure TMD32X.VideoWrite(Index: Integer; Value, Mask: Word);
begin
  var V: Word := (FState.Video[Index] and not Mask) or (Value and Mask);
  case Index of
    0:
      FState.Video[0] := (FState.Video[0] and $8000) or (V and $FF);
    1:
      FState.Video[1] := V and 1;
    2:
      FState.Video[2] := V and $FF;
    3:
      FState.Video[3] := V;
    4:
      begin
        AdvanceFill(FState.Time);
        FState.FillAddress := FState.Video[3];
        FState.FillCount := FState.Video[2] + 1;
        FState.FillBank := FState.FrameSelect xor 1;
        FState.Video[4] := V;
        FState.FillUntil := FState.Time + 4 * 7 div 3;
      end;
    5:
      begin
        FState.RequestedFrame := V and 1;
        if (VideoRead(5) and $8000 <> 0) or (FState.Video[0] and 3 = 0) then
          FState.FrameSelect := FState.RequestedFrame;
      end;
  end;
end;

function TMD32X.MainRead(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := True;
  Value := $FFFF;
  if Address = $A130EC then
    Value := $4D41
  else if Address = $A130EE then
    Value := $5253
  else if (Address >= $A15100) and (Address < $A15140) then
    Value := RegisterRead((Address - $A15100) div 2, -1)
  else if FState.Registers[0] and 1 = 0 then
    Result := False
  else if (Length(FROM) = 0) and (Address < $840000) then
    Result := False
  else if Address = $70 then
    Value := FState.HintVector shr 16
  else if Address = $72 then
    Value := FState.HintVector and $FFFF
  else if Address < 256 then
    Value := (Word(FBoot68k[Address]) shl 8) or FBoot68k[Address + 1]
  else if (Address >= $880000) and (Address < $900000) then
    Value := (Word(ROMByte(Address - $880000)) shl 8) or ROMByte(Address - $880000 + 1)
  else if (Address >= $900000) and (Address < $A00000) then
  begin
    var A := (FState.Registers[2] and 3) * $100000 + Address - $900000;
    Value := (Word(ROMByte(A)) shl 8) or ROMByte(A + 1);
  end
  else if (Address >= $840000) and (Address < $880000) then
    Value := FState.DRAM[FState.FrameSelect xor 1, (Address and $1FFFE) div 2]
  else if (Address >= $A15180) and (Address < $A15190) then
    Value := VideoRead((Address - $A15180) div 2)
  else if (Address >= $A15200) and (Address < $A15400) then
    Value := FState.Palette[(Address and $1FE) div 2]
  else
    Result := False;
end;

function TMD32X.MainWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
begin
  var Mask: Word := 0;
  if HighByte then
    Mask := $FF00;
  if LowByte then
    Mask := Mask or $FF;
  Result := True;
  if (Address >= $A15100) and (Address < $A15140) then
    RegisterWrite((Address - $A15100) div 2, Value, Mask, -1)
  else if FState.Registers[0] and 1 = 0 then
    Result := False
  else if (Length(FROM) = 0) and (Address < $840000) then
    Result := False
  else if (Address = $70) or (Address = $72) then
  begin
    var Shift := 16 * Ord(Address = $70);
    FState.HintVector := (FState.HintVector and not (Cardinal(Mask) shl Shift)) or (Cardinal(Value and Mask) shl Shift);
  end
  else if (Address >= $A15180) and (Address < $A15190) then
  begin
    if FState.Registers[0] and $8000 = 0 then
      VideoWrite((Address - $A15180) div 2, Value, Mask);
  end
  else if (Address >= $A15200) and (Address < $A15400) then
  begin
    var Index := (Address and $1FE) div 2;
    if FState.Registers[0] and $8000 = 0 then
      FState.Palette[Index] := (FState.Palette[Index] and not Mask) or (Value and Mask);
  end
  else if (Address >= $840000) and (Address < $880000) then
  begin
    var Index := (Address and $1FFFE) div 2;
    if Address >= $860000 then
    begin
      if Value and $FF = 0 then
        Mask := Mask and $FF00;
      if Value and $FF00 = 0 then
        Mask := Mask and $FF;
    end;
    FState.DRAM[FState.FrameSelect xor 1, Index] :=
      (FState.DRAM[FState.FrameSelect xor 1, Index] and not Mask) or (Value and Mask);
  end
  else
    Result := False;
end;

function TMD32X.PeekPeripheral(CPU, Index, Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FState.Peripheral[CPU, (Index + I) and $1FF];
end;

procedure TMD32X.StorePeripheral(CPU, Index: Integer; Value: Cardinal; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    FState.Peripheral[CPU, (Index + I) and $1FF] := (Value shr ((Size - I - 1) * 8)) and $FF;
end;

function TMD32X.PeripheralRead(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var Index := Integer((Address + Cardinal(I)) and $1FF);
    var Value := FState.Peripheral[CPU, Index];
    case Index of
      $11:
        FState.FRTReadFlags[CPU] := Value;
      $12:
        begin
          Value := FState.FRC[CPU] shr 8;
          FState.FRTTemp[CPU] := FState.FRC[CPU] and $FF;
        end;
      $13:
        Value := FState.FRTTemp[CPU];
      $14:
        begin
          Value := FState.OCR[CPU, Ord(FState.Peripheral[CPU, $17] and $10 <> 0)] shr 8;
          FState.FRTTemp[CPU] := FState.OCR[CPU, Ord(FState.Peripheral[CPU, $17] and $10 <> 0)] and $FF;
        end;
      $15:
        Value := FState.FRTTemp[CPU];
    end;
    Result := (Result shl 8) or Value;
  end;
end;

procedure TMD32X.PeripheralWrite(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  for var I := 0 to Size - 1 do
  begin
    var R := Integer((Address + Cardinal(I)) and $1FF);
    var B: Byte := (Value shr ((Size - 1 - I) * 8)) and $FF;
    case R of
      $10:
        FState.Peripheral[CPU, R] := (B and $8E) or 1;
      $11:
        begin
          FState.Peripheral[CPU, R] := (FState.Peripheral[CPU, R] and ($8E and not (FState.FRTReadFlags[CPU] and not B))) or (B and 1);
          FState.FRTReadFlags[CPU] := 0;
        end;
      $12, $14:
        FState.FRTTemp[CPU] := B;
      $13:
        FState.FRC[CPU] := (Word(FState.FRTTemp[CPU]) shl 8) or B;
      $15:
        FState.OCR[CPU, Ord(FState.Peripheral[CPU, $17] and $10 <> 0)] := (Word(FState.FRTTemp[CPU]) shl 8) or B;
      $16:
        FState.Peripheral[CPU, R] := B and $83;
      $17:
        FState.Peripheral[CPU, R] := (B and $13) or $E0;
      $18, $19:
        ; // Input capture is read-only.
        $92:
        begin
          FCPU[CPU].InvalidateInstructionLine;
          FillChar(FDataCache[CPU], SizeOf(FDataCache[CPU]), $FF);
          if B and $10 <> 0 then
          begin
            FillChar(FState.CacheTag[CPU], SizeOf(FState.CacheTag[CPU]), 0);
            FillChar(FState.CacheLRU[CPU], SizeOf(FState.CacheLRU[CPU]), 0);
          end;
          FState.Peripheral[CPU, R] := B and $CF;
        end;
    else
      FState.Peripheral[CPU, R] := B;
    end;
  end;
  var Index := Address and $1FF;
  if (Index = $104) or (Index = $114) then
  begin
    var Divisor := Integer(PeripheralRead(CPU, $100, 4));
    var Dividend: Int64 := Integer(Value);
    if Index = $114 then
      Dividend := Int64((UInt64(PeripheralRead(CPU, $110, 4)) shl 32) or Value);
    var Quotient: Int64;
    var Remainder: Int64 := 0;
    if (Divisor = 0) or ((Dividend = Low(Int64)) and (Divisor = -1)) then
      Quotient := Int64(High(Integer)) + 1
    else
    begin
      Quotient := Dividend div Divisor;
      Remainder := Dividend mod Divisor;
    end;
    if (Quotient < Low(Integer)) or (Quotient > High(Integer)) then
    begin
      Quotient := High(Integer);
      if Dividend < 0 then
        Quotient := Low(Integer);
      FState.Peripheral[CPU, $10B] := FState.Peripheral[CPU, $10B] or 1;
    end;
    // Direct writes avoid recursively retriggering the division unit.
    for var I := 0 to 3 do
    begin
      FState.Peripheral[CPU, $104 + I] := (UInt64(Quotient) shr ((3 - I) * 8)) and $FF;
      FState.Peripheral[CPU, $114 + I] := FState.Peripheral[CPU, $104 + I];
      FState.Peripheral[CPU, $11C + I] := FState.Peripheral[CPU, $104 + I];
      FState.Peripheral[CPU, $110 + I] := (UInt64(Remainder) shr ((3 - I) * 8)) and $FF;
      FState.Peripheral[CPU, $118 + I] := FState.Peripheral[CPU, $110 + I];
    end;
  end;
  UpdateIRQ(CPU);
end;

function TMD32X.RunDMA(CPU, Channel: Integer): Boolean;
begin
  Result := False;
  if PeekPeripheral(CPU, $1B0, 4) and 7 <> 1 then
    Exit;
  var Base := $180 + Channel * 16;
  var Control := PeekPeripheral(CPU, Base + 12, 4);
  if Control and 3 <> 1 then
    Exit;
  var Source := PeekPeripheral(CPU, Base, 4);
  var Dest := PeekPeripheral(CPU, Base + 4, 4);
  var Count := PeekPeripheral(CPU, Base + 8, 4) and $FFFFFF;
  var Block := (Control shr 10) and 3 = 3;
  var Size := 1 shl ((Control shr 10) and 3);
  if Block then
    Size := 4;
  var FIFO := Source and $1FFFFFFF = $4012;
  if Control and $200 = 0 then
  begin
    if (Channel <> 0) or not FIFO then
      Exit; // External DREQ0 is driven by the 32X four-word FIFO.
    if FState.Registers[3] and 4 = 0 then
      Exit;
    if FState.DMARequests[CPU, Channel] = 0 then
    begin
      if FState.FIFOCount < 4 then
        Exit;
      FState.DMARequests[CPU, Channel] := 4;
    end;
  end;
  if FIFO and (FState.FIFOCount = 0) then
    Exit;
  if ((Source or Dest) and Cardinal(Size - 1) <> 0) or
    (Block and ((Source or Dest) and 15 <> 0)) then
  begin
    StorePeripheral(CPU, $1B0, PeekPeripheral(CPU, $1B0, 4) or 4, 4);
    Exit;
  end;
  if Count = 0 then
    Count := $1000000;
  var Words := 1;
  if Block then
    Words := Min(4, Integer(Count));
  for var I := 1 to Words do
  begin
    var Data := ReadMemory(CPU, Source, Size);
    WriteMemory(CPU, Dest, Data, Size);
    if Block then
      Source := Cardinal((UInt64(Source) + 4) and $FFFFFFFF)
    else
      case (Control shr 12) and 3 of
        1:
          Source := Cardinal((UInt64(Source) + Cardinal(Size)) and $FFFFFFFF);
        2:
          Source := Cardinal((UInt64(Source) + UInt64($100000000) - Cardinal(Size)) and $FFFFFFFF);
      end;
    case (Control shr 14) and 3 of
      1:
        Dest := Cardinal((UInt64(Dest) + Cardinal(Size)) and $FFFFFFFF);
      2:
        Dest := Cardinal((UInt64(Dest) + UInt64($100000000) - Cardinal(Size)) and $FFFFFFFF);
    end;
    Dec(Count);
    if FIFO then
    begin
      FState.DMARequests[CPU, Channel] := Max(0, FState.DMARequests[CPU, Channel] - 1);
      FState.Registers[8] := (Integer(FState.Registers[8]) + $FFFF) and $FFFF;
      if FState.Registers[8] = 0 then
        FState.Registers[3] := FState.Registers[3] and not 4;
    end;
  end;
  StorePeripheral(CPU, Base, Source, 4);
  StorePeripheral(CPU, Base + 4, Dest, 4);
  StorePeripheral(CPU, Base + 8, Count and $FFFFFF, 4);
  if Count = 0 then
    StorePeripheral(CPU, Base + 12, Control or 2, 4);
  Result := True;
end;

procedure TMD32X.AdvanceFill(Target: Int64);
begin
  while (FState.FillCount > 0) and (FState.FillUntil <= Target) do
  begin
    FState.DRAM[FState.FillBank, FState.FillAddress] := FState.Video[4];
    FState.FillAddress := (FState.FillAddress and $FF00) or ((FState.FillAddress + 1) and $FF);
    Dec(FState.FillCount);
    FState.Video[3] := FState.FillAddress;
    Inc(FState.FillUntil, 7 div 3 + 1);
  end;
end;

procedure TMD32X.AdvancePeripherals(CPU: Integer; Target: Int64);
begin
  var Elapsed := Max(Int64(0), Target - FState.FRTLast[CPU]);
  FState.FRTLast[CPU] := Max(Target, FState.FRTLast[CPU]);
  var Select := FState.Peripheral[CPU, $16] and 3;
  if Select <> 3 then
  begin
    var Divider := 8 shl (Select * 2);
    var Ticks := (Elapsed + FState.FRTPhase[CPU]) div Divider;
    FState.FRTPhase[CPU] := (Elapsed + FState.FRTPhase[CPU]) mod Divider;
    while Ticks > 0 do
    begin
      FState.FRC[CPU] := (Cardinal(FState.FRC[CPU]) + 1) and $FFFF;
      var Flags := FState.Peripheral[CPU, $11];
      if FState.FRC[CPU] = 0 then
        Flags := Flags or 2;
      if FState.FRC[CPU] = FState.OCR[CPU, 1] then
        Flags := Flags or 4;
      if FState.FRC[CPU] = FState.OCR[CPU, 0] then
      begin
        Flags := Flags or 8;
        if Flags and 1 <> 0 then
          FState.FRC[CPU] := 0;
      end;
      FState.Peripheral[CPU, $11] := Flags;
      Dec(Ticks);
    end;
  end;
  if (Target >= FState.DMANext[CPU]) and
    (FState.Peripheral[CPU, $1B3] and 7 = 1) then
  begin
    var Channel := 0;
    if PeekPeripheral(CPU, $1B0, 4) and 8 <> 0 then
      Channel := FState.DMAPriority[CPU];
    var Transferred := RunDMA(CPU, Channel);
    if not Transferred then
    begin
      Channel := Channel xor 1;
      Transferred := RunDMA(CPU, Channel);
    end;
    if Transferred then
    begin
      FState.DMANext[CPU] := Target + 4;
      FState.DMAPriority[CPU] := Channel xor 1;
    end;
  end;
  UpdateIRQ(CPU);
end;

procedure TMD32X.WaitBus(CPU: Integer; Address: Cardinal; Size: Integer; Writing: Boolean);
begin
  if (FExecutingCPU <> CPU) or (Address shr 29 >= 2) then
    Exit;
  Address := Address and $1FFFFFFF;
  var Words := (Size + 1) div 2;
  var Clocks := 0;
  // Nominal bus timings from Sega MAR-32-R4, section 4.4. SDRAM reads
  // always perform an eight-word burst, including cache-through word reads.
  if Address < Cardinal(Length(FBoot[CPU])) then
    Clocks := 3 * Words
  else if (Address >= $06000000) and (Address < $06040000) then
  begin
    if Writing then
      Clocks := 2 * Words
    else
      Clocks := 12;
  end
  else if (Address >= $02000000) and (Address < $02400000) then
    Clocks := 8 * Words
  else if (Address >= $04000000) and (Address < $04040000) then
  begin
    if Writing then
      Clocks := 3 * Words
    else
      Clocks := 7 * Words;
  end
  else if (Address >= $4100) and (Address < $4400) then
    Clocks := 7 * Words
  else if (Address >= $4000) and (Address < $4040) then
    Clocks := 3 * Words;
  // Step includes the issue cycle; accumulate only additional bus clocks.
  Inc(FAccessWait, Max(0, Clocks - 1));
end;

procedure TMD32X.TouchCache(CPU, Entry, Way: Integer);
begin
  SH7604TouchLRU(FState.CacheLRU[CPU, Entry], Way);
end;

function TMD32X.ReadSH2(CPU: Integer; Address: Cardinal; Size: Integer; Instruction: Boolean): Cardinal;
begin
  var Area := Address shr 29;
  var Entry := (Address shr 4) and 63;
  var CCR := FState.Peripheral[CPU, $92];
  if Area = 3 then
    Exit(FState.CacheTag[CPU, (CCR shr 6) and 3, Entry] or (Cardinal(FState.CacheLRU[CPU, Entry]) shl 4));
  if (Area = 0) and (CCR and 1 <> 0) and
    (Address >= $02000000) and (Address < $06040000) then
  begin
    var Tag := (Address and $1FFFFC00) or 2;
    var Way := -1;
    for var I := 0 to 3 do
      if FState.CacheTag[CPU, I, Entry] = Tag then
        Way := I;
    if (Way < 0) and (CCR and (4 shr Ord(Instruction)) = 0) then
    begin
      var LRU := FState.CacheLRU[CPU, Entry];
      if CCR and 8 <> 0 then
        Way := 2 + Ord(LRU and 1 = 0)
      else if LRU and $38 = $38 then
        Way := 0
      else if LRU and $26 = $06 then
        Way := 1
      else if LRU and $15 = $01 then
        Way := 2
      else
        Way := 3;
      var Base := Address and $1FFFFFF0;
      WaitBus(CPU, Base, 16, False);
      // Four longword bus reads fill one 16-byte cache line.
      for var I := 0 to 3 do
      begin
        var V := ReadMemory(CPU, Base + Cardinal(I * 4), 4);
        for var J := 0 to 3 do
          FState.CacheRAM[CPU, Way * 1024 + Integer(Entry) * 16 + I * 4 + J] := (V shr ((3 - J) * 8)) and $FF;
      end;
      FCPU[CPU].InvalidateInstructionLine;
      FDataCache[CPU, Entry].Line := High(Cardinal);
      FState.CacheTag[CPU, Way, Entry] := Tag;
    end;
    if Way >= 0 then
    begin
      TouchCache(CPU, Entry, Way);
      // Keep the interpreter on the bus's live bytes and hardware LRU state.
      var Mask, Bits: Byte;
      case Way of
        0:
          begin
            Mask := $07;
            Bits := $00;
          end;
        1:
          begin
            Mask := $19;
            Bits := $20;
          end;
        2:
          begin
            Mask := $2A;
            Bits := $14;
          end;
      else
        begin
          Mask := $34;
          Bits := $0B;
        end;
      end;
      var Data := @FState.CacheRAM[CPU, Way * 1024 + Integer(Entry) * 16];
      var LRU := @FState.CacheLRU[CPU, Entry];
      if Instruction then
        FCPU[CPU].SetInstructionLine(Address and $FFFFFFF0, Data, LRU, Mask, Bits)
      else
      begin
        FDataCache[CPU, Entry].Line := Address and $FFFFFFF0;
        FDataCache[CPU, Entry].Data := Data;
        FDataCache[CPU, Entry].LRU := LRU;
        FDataCache[CPU, Entry].Mask := Mask;
        FDataCache[CPU, Entry].Bits := Bits;
      end;
      Result := 0;
      for var I := 0 to Size - 1 do
        Result := (Result shl 8) or FState.CacheRAM[CPU, Way * 1024 + Integer(Entry) * 16 + Integer(Address and 15) + I];
      Exit;
    end;
  end;
  WaitBus(CPU, Address, Size, False);
  Result := ReadMemory(CPU, Address, Size);
end;

procedure TMD32X.WriteSH2(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  var Area := Address shr 29;
  var Entry := (Address shr 4) and 63;
  var Tag := Address and $1FFFFC00;
  var CCR := FState.Peripheral[CPU, $92];
  if Area = 2 then
  begin
    FCPU[CPU].InvalidateInstructionLine;
    FDataCache[CPU, Entry].Line := High(Cardinal);
    for var I := 0 to 3 do
      if FState.CacheTag[CPU, I, Entry] and $1FFFFC00 = Tag then
        FState.CacheTag[CPU, I, Entry] := 0;
    Exit;
  end;
  if Area = 3 then
  begin
    FCPU[CPU].InvalidateInstructionLine;
    FDataCache[CPU, Entry].Line := High(Cardinal);
    FState.CacheTag[CPU, (CCR shr 6) and 3, Entry] := Tag or ((Address shr 1) and 2);
    FState.CacheLRU[CPU, Entry] := (Value shr 4) and 63;
    Exit;
  end;
  if (Area = 0) and (CCR and 1 <> 0) then
    for var Way := 0 to 3 do
      if FState.CacheTag[CPU, Way, Entry] = (Tag or 2) then
      begin
        for var I := 0 to Size - 1 do
          FState.CacheRAM[CPU, Way * 1024 + Integer(Entry) * 16 + Integer(Address and 15) + I] := (Value shr ((Size - I - 1) * 8)) and $FF;
        TouchCache(CPU, Entry, Way);
      end;
  WaitBus(CPU, Address, Size, True);
  WriteMemory(CPU, Address, Value, Size);
end;

function TMD32X.ReadMemory(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
begin
  if Address >= $FFFFFE00 then
    Exit(PeripheralRead(CPU, Address, Size));
  if Size = 4 then
    Exit((ReadMemory(CPU, Address, 2) shl 16) or ReadMemory(CPU, Address + 2, 2));
  if (Address and $E0000000) = $C0000000 then
  begin
    Result := FState.CacheRAM[CPU, Address and $FFF];
    if Size = 2 then
      Result := (Result shl 8) or FState.CacheRAM[CPU, (Address + 1) and $FFF];
    Exit;
  end;
  Address := Address and $1FFFFFFF;
  if Address < Cardinal(Length(FBoot[CPU])) then
  begin
    Result := FBoot[CPU][Address];
    if Size = 2 then
      Result := (Result shl 8) or FBoot[CPU][Address + 1];
  end
  else if (Address >= $06000000) and (Address < $06040000) then
  begin
    Result := FState.RAM[Address and $3FFFF];
    if Size = 2 then
      Result := (Result shl 8) or FState.RAM[(Address + 1) and $3FFFF];
  end
  else if (Address >= $02000000) and (Address < $02400000) then
  begin
    Result := ROMByte(Address and $3FFFFF);
    if Size = 2 then
      Result := (Result shl 8) or ROMByte((Address + 1) and $3FFFFF);
  end
  else
  begin
    var V: Word := $FFFF;
    if (Address >= $4000) and (Address < $4040) then
      V := RegisterRead((Address and $3E) div 2, CPU)
    else if (Address >= $4100) and (Address < $4110) then
      V := VideoRead((Address and $E) div 2)
    else if (Address >= $4200) and (Address < $4400) then
      V := FState.Palette[(Address and $1FE) div 2]
    else if (Address >= $04000000) and (Address < $04040000) then
      V := FState.DRAM[FState.FrameSelect xor 1, (Address and $1FFFE) div 2];
    if Size = 2 then
      Result := V
    else if Odd(Address) then
      Result := V and $FF
    else
      Result := V shr 8;
  end;
end;

procedure TMD32X.WriteMemory(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  if Address >= $FFFFFE00 then
  begin
    PeripheralWrite(CPU, Address, Value, Size);
    Exit;
  end;
  if Size = 4 then
  begin
    WriteMemory(CPU, Address, Value shr 16, 2);
    WriteMemory(CPU, Address + 2, Value and $FFFF, 2);
    Exit;
  end;
  if (Address and $E0000000) = $C0000000 then
  begin
    if Size = 2 then
      FState.CacheRAM[CPU, Address and $FFF] := (Value shr 8) and $FF
    else
      FState.CacheRAM[CPU, Address and $FFF] := Value and $FF;
    if Size = 2 then
      FState.CacheRAM[CPU, (Address + 1) and $FFF] := Value and $FF;
    Exit;
  end;
  Address := Address and $1FFFFFFF;
  if (Address >= $06000000) and (Address < $06040000) then
  begin
    if Size = 2 then
      FState.RAM[Address and $3FFFF] := (Value shr 8) and $FF
    else
      FState.RAM[Address and $3FFFF] := Value and $FF;
    if Size = 2 then
      FState.RAM[(Address + 1) and $3FFFF] := Value and $FF;
    Exit;
  end;
  var Mask: Word := $FFFF;
  var Data: Word := Value and $FFFF;
  if Size = 1 then
    if Odd(Address) then
    begin
      Mask := $FF;
      Data := Value and $FF;
    end
    else
    begin
      Mask := $FF00;
      Data := (Value and $FF) shl 8;
    end;
  if (Address >= $4000) and (Address < $4040) then
    RegisterWrite((Address and $3E) div 2, Data, Mask, CPU)
  else if (FState.Registers[0] and $8000 <> 0) and (Address >= $4100) and (Address < $4110) then
    VideoWrite((Address and $E) div 2, Data, Mask)
  else if (FState.Registers[0] and $8000 <> 0) and (Address >= $4200) and (Address < $4400) then
  begin
    var Index := (Address and $1FE) div 2;
    FState.Palette[Index] := (FState.Palette[Index] and not Mask) or (Data and Mask);
  end
  else if (Address >= $04000000) and (Address < $04040000) then
  begin
    var Index := (Address and $1FFFE) div 2;
    if (Size = 1) or (Address and $20000 <> 0) then
    begin
      if Data and $FF = 0 then
        Mask := Mask and $FF00;
      if Data and $FF00 = 0 then
        Mask := Mask and $FF;
    end;
    FState.DRAM[FState.FrameSelect xor 1, Index] := (FState.DRAM[FState.FrameSelect xor 1, Index] and not Mask) or (Data and Mask);
  end;
end;

procedure TMD32X.PWMTick(Target: Int64);
begin
  var Period := (Integer(FState.Registers[25]) - 1) and $FFF;
  if (Period = 0) or (FState.Registers[24] and $F = 0) then
  begin
    FState.PWMTime := Target;
    Exit;
  end;
  while FState.PWMTime + Period <= Target do
  begin
    Inc(FState.PWMTime, Period);
    for var I := 0 to 1 do
      if FState.PWMCount[I] > 0 then
      begin
        FState.PWMSample[I] := EnsureRange(Integer(FState.PWM[I, FState.PWMRead[I]]) - 1, 0, Period);
        FState.PWMRead[I] := (FState.PWMRead[I] + 1) mod 3;
        Dec(FState.PWMCount[I]);
      end;
    Dec(FState.PWMIRQCounter);
    if FState.PWMIRQCounter <= 0 then
    begin
      FState.PWMIRQCounter := ((FState.Registers[24] shr 8) + 15) mod 16 + 1;
      for var I := 0 to 1 do
      begin
        FState.Pending[I] := FState.Pending[I] or (FState.IRQMask[I] and 1);
        UpdateIRQ(I);
      end;
    end;
  end;
end;

procedure TMD32X.Advance(Target: Int64);
begin
  if Target < FState.Time then
    Exit;
  var EndCycle := Target * 3 div 7;
  if FState.Registers[0] and 3 = 3 then
    while Min(FState.CPUTime[0], FState.CPUTime[1]) < EndCycle do
    begin
      var I := Ord(FState.CPUTime[1] < FState.CPUTime[0]);
      FState.Time := FState.CPUTime[I] * 7 div 3;
      PWMTick(FState.CPUTime[I]);
      AdvancePeripherals(I, FState.CPUTime[I]);
      AdvanceFill(FState.Time);
      var Lines := 262 + 51 * Ord(FPAL);
      var Line := Integer((FState.Time div 3420) mod Lines);
      if Line <> FState.LastLine then
      begin
        FState.LastLine := Line;
        var Visible := 224 + 16 * Ord(FState.Video[0] and $40 <> 0);
        if Line = Visible then
          FState.FrameSelect := FState.RequestedFrame;
        if (Line < Visible) or FState.HBlankEnable then
        begin
          Dec(FState.HCounter);
          if FState.HCounter < 0 then
          begin
            FState.HCounter := FState.HintInterval;
            for var C := 0 to 1 do
              FState.Pending[C] := FState.Pending[C] or (FState.IRQMask[C] and 4);
          end;
        end;
        if Line = Visible then
          for var C := 0 to 1 do
            FState.Pending[C] := FState.Pending[C] or (FState.IRQMask[C] and 8);
        UpdateIRQ(0);
        UpdateIRQ(1);
      end;
      FExecutingCPU := I;
      FAccessWait := 0;
      try
        var Cycles := FCPU[I].Step;
        Inc(FState.CPUTime[I], Cycles + FAccessWait);
      finally
        FExecutingCPU := -1;
      end;
    end
  else
  begin
    FState.CPUTime[0] := EndCycle;
    FState.CPUTime[1] := EndCycle;
  end;
  for var I := 0 to 1 do
    AdvancePeripherals(I, EndCycle);
  AdvanceFill(Target);
  PWMTick(EndCycle);
  FState.Time := Target;
end;

procedure TMD32X.RenderLine(Line: Integer; var Pixels: TArray<TAlphaColor>; Offset, Width: Integer; const MDIndices: array of Byte; Background: Byte);
begin
  var Mode := FState.Video[0] and 3;
  if (Mode = 0) or (FState.Registers[0] and 1 = 0) or (Line < 0) or (Line >= 240) then
    Exit;
  var Position := Integer(FState.DRAM[FState.FrameSelect, Line]);
  var Remaining := 0;
  var Colour: Word := 0;
  for var X := 0 to Width - 1 do
  begin
    case Mode of
      1:
        begin
          var P := X + (FState.Video[1] and 1);
          var PixelWord := FState.DRAM[FState.FrameSelect, (Position + P div 2) and $FFFF];
          var Index := PixelWord and $FF;
          if not Odd(P) then
            Index := PixelWord shr 8;
          Colour := FState.Palette[Index];
        end;
      2:
        Colour := FState.DRAM[FState.FrameSelect, (Position + X) and $FFFF];
      3:
        begin
          if Remaining = 0 then
          begin
            var PixelWord := FState.DRAM[FState.FrameSelect, Position and $FFFF];
            Inc(Position);
            Remaining := (PixelWord shr 8) + 1;
            Colour := FState.Palette[PixelWord and $FF];
          end;
          Dec(Remaining);
        end;
    end;
    if (MDIndices[X] and $3F = Background) or
      ((Colour and $8000 <> 0) xor (FState.Video[0] and $80 <> 0)) then
    begin
      var R := Colour and 31;
      var G := (Colour shr 5) and 31;
      var B := (Colour shr 10) and 31;
      Pixels[Offset + X] := $FF000000 or (((R shl 3) or (R shr 2)) shl 16) or
        (((G shl 3) or (G shr 2)) shl 8) or (B shl 3) or (B shr 2);
    end;
  end;
end;

procedure TMD32X.Sample(out Left, Right: Integer);
begin
  Left := 0;
  Right := 0;
  var Period := (Integer(FState.Registers[25]) - 1) and $FFF;
  if Period = 0 then
    Exit;
  var L := (FState.PWMSample[0] * 65535 div Period - 32768) div 4;
  var R := (FState.PWMSample[1] * 65535 div Period - 32768) div 4;
  case FState.Registers[24] and 3 of
    1:
      Left := L;
    2:
      Left := R;
  end;
  case (FState.Registers[24] shr 2) and 3 of
    1:
      Right := R;
    2:
      Right := L;
  end;
end;

procedure TMD32X.SerializeState(Archive: TStateArchive);
begin
  if Archive.Loading then
    FillChar(FDataCache, SizeOf(FDataCache), $FF);
  Archive.Field(FState, SizeOf(FState));
  for var I := 0 to 1 do
    FCPU[I].SerializeState(Archive);
  if (FState.FrameSelect < 0) or (FState.FrameSelect > 1) or
    (FState.Time < 0) or (FState.PWMTime < 0) or (FState.FillCount < 0) or (FState.FillCount > 256) or
    (FState.FillAddress < 0) or (FState.FillAddress > $FFFF) or (FState.FillBank < 0) or (FState.FillBank > 1) or
    (FState.RequestedFrame < 0) or (FState.RequestedFrame > 1) or
    (FState.FIFORead < 0) or (FState.FIFORead > 7) or (FState.FIFOCount < 0) or (FState.FIFOCount > 8) then
    raise EReadError.Create('Invalid snapshot 32X state');
  for var I := 0 to 1 do
    if (FState.PWMRead[I] < 0) or (FState.PWMRead[I] > 2) or
      (FState.DMAPriority[I] < 0) or (FState.DMAPriority[I] > 1) or
      (FState.FRTPhase[I] > 127) or (FState.FRTLast[I] < 0) or (FState.DMANext[I] < 0) or
      (FState.PWMCount[I] < 0) or (FState.PWMCount[I] > 3) or (FState.CPUTime[I] < 0) then
      raise EReadError.Create('Invalid snapshot 32X timing');
end;

function TMD32X.CPUState(Index: Integer): TSH2State;
begin
  Result := FCPU[Index].State;
end;

end.

