unit NDS.Console;

interface

uses
  System.SysUtils, System.Classes, System.Math, HW.ARM, NDS.Cartridge, NDS.Video,
  NDS.Sound, NDS.RTC, Core.Emulation.Types, Core.Snapshots;

type
  TNDSTrace = procedure(const Text: string) of object;

  TNDSTimer = record
    Reload, Counter, Control: Word;
    Divider: Integer;
  end;

  PNDSTimer = ^TNDSTimer;

  TNDSDMA = record
    Source, Destination, Control, CurrentSource, CurrentDestination: Cardinal;
    Pending: Boolean;
  end;

  PNDSDMA = ^TNDSDMA;

  TNDSFIFO = record
    Words: array[0..15] of Cardinal;
    Head, Count: Integer;
    Last: Cardinal;
  end;

  PNDSFIFO = ^TNDSFIFO;

  TNDSConsole = class
  private
    FCPU: array[0..1] of TARMProcessor;
    FCallbackDepth: Integer;
    FMain: array[0..$3FFFFF] of Byte;
    FShared: array[0..$7FFF] of Byte;
    FPrivate: array[0..$FFFF] of Byte;
    FITCM: array[0..$7FFF] of Byte;
    FDTCM: array[0..$3FFF] of Byte;
    FBIOS9: array[0..$FFF] of Byte;
    FBIOS7: array[0..$3FFF] of Byte;
    FIO: array[0..1, 0..$10FF] of Byte;
    FTimers: array[0..1, 0..3] of TNDSTimer;
    FDMA: array[0..1, 0..3] of TNDSDMA;
    // Derived dispatch masks, rebuilt after register writes and snapshot loads.
    FTimerMask, FDMATimingMask: array[0..1] of Byte;
    FTimerPending, FTimerDeadline: array[0..1] of Integer;
    FFIFO: array[0..1] of TNDSFIFO;
    FFIFOControl: array[0..1] of Word;
    FFIFOIRQ: array[0..1, 0..1] of Boolean;
    FIME, FIE, FIF, FWaitMask: array[0..1] of Cardinal;
    FHalted, FCodeAccess, FDMABusy: array[0..1] of Boolean;
    FCPUTime: array[0..1] of Int64;
    FBusTime: Int64;
    FBusPending, FBusBudget: Integer;
    FCPControl, FDTCMControl, FITCMControl: Cardinal;
    FCPRegs: array[0..15, 0..7] of Cardinal;
    FWRAM: Byte;
    FLine, FLineClock: Integer;
    FFrameNumber: UInt64;
    FKeys: Word;
    FExtKeys: Byte;
    FTouchX, FTouchY: Integer;
    FPen: Boolean;
    FSPIPosition, FSPIAddress, FSPICommand, FTSCValue: Integer;
    FPowerRegisters: array[0..7] of Byte;
    FFirmware: TBytes;
    FFirmwareStatus: Byte;
    FFirmwareWriting: Boolean;
    FCardRemaining, FCardAddress: Cardinal;
    FCardCommand, FCardOwner: Integer;
    function CPU9: TARMProcessor;
    function CPU7: TARMProcessor;
    function Read9(Address: Cardinal; Size: Integer): Cardinal;
    function Read7(Address: Cardinal; Size: Integer): Cardinal;
    function ReadAudio(Address: Cardinal; Size: Integer): Cardinal;
    function ReadCode9(Address: Cardinal; Size: Integer): Cardinal;
    function ReadCode7(Address: Cardinal; Size: Integer): Cardinal;
    function CodePage9(Address: Cardinal): PByte;
    function CodePage7(Address: Cardinal): PByte;
    function DataPage9(Address: Cardinal; Writing: Boolean): PByte;
    function DataPage7(Address: Cardinal; Writing: Boolean): PByte;
    function ReadCPU(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal; inline;
    procedure WriteCPU(CPU: Integer; Address, Value: Cardinal; Size: Integer); inline;
    procedure Write9(Address, Value: Cardinal; Size: Integer);
    procedure Write7(Address, Value: Cardinal; Size: Integer);
    function CP15(Op: Cardinal; var Value: Cardinal): Boolean;
    function BIOSCall(CPU: Integer; Address, R0, R1, R2: Cardinal): Cardinal;
    function BIOSCall9(Address, R0, R1, R2: Cardinal): Cardinal;
    function BIOSCall7(Address, R0, R1, R2: Cardinal): Cardinal;
    procedure SWI9(Number: Byte);
    procedure SWI7(Number: Byte);
    procedure SoftwareInterrupt(CPU, Number: Integer);
    function ReadByte(CPU: Integer; Address: Cardinal): Byte;
    procedure WriteByte(CPU: Integer; Address: Cardinal; Value: Byte);
    function DirectMemory(CPU: Integer; Address: Cardinal; Writing: Boolean): PByte; inline;
    function ReadIO(CPU, Offset: Integer): Byte;
    procedure WriteIO(CPU, Offset: Integer; Value: Byte);
    function IO16(CPU, Offset: Integer): Word;
    function IO32(CPU, Offset: Integer): Cardinal;
    procedure PutIO32(CPU, Offset: Integer; Value: Cardinal);
    procedure RequestIRQ(CPU, Bit: Integer);
    procedure UpdateFIFOIRQ;
    procedure SendFIFO(CPU: Integer; Value: Cardinal);
    function ReceiveFIFO(CPU: Integer): Cardinal;
    procedure StartCard(CPU: Integer);
    function ReadCard: Cardinal;
    procedure TransferSPI(Value: Byte);
    procedure DisplayFIFO(Sender: TObject);
    procedure TriggerDMA(CPU, Timing: Integer);
    procedure RefreshEventMasks(CPU: Integer);
    procedure FlushTimers(CPU: Integer);
    procedure TimerDeadline(CPU: Integer);
    procedure RunDMA(CPU, Channel: Integer);
    function CopyDMABlock(CPU: Integer; D: PNDSDMA; Remaining: Cardinal; Size, SourceMode, DestinationMode: Integer): Cardinal;
    procedure MathUnit;
    procedure Tick(Cycles: Integer);
    procedure ScheduleBus;
    procedure FlushBus;
    procedure AdvanceBus(Cycles: Integer); inline;
    procedure BIOSStub(CPU: Integer);
    procedure StepCPU(CPU: Integer); inline;
    function SharedClock: Int64; inline;
  public
    Trace: TNDSTrace;
    Cartridge: TNDSCartridge;
    Video: TNDSVideo;
    Sound: TNDSSound;
    RTC: TNDSRTC;
    constructor Create(const Data: TBytes; SaveSize: Integer = 0);
    destructor Destroy; override;
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    procedure Step; inline;
    procedure RunFrame;
    procedure SetInput(const Buttons: TEmulatorButtons);
    procedure SetTouch(X, Y: Integer; Pressed: Boolean);
    function DiagnosticState: string;
    function ReadBus(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBus(CPU: Integer; Address, Value: Cardinal; Size: Integer);
    property ARM9: TARMProcessor read CPU9;
    property ARM7: TARMProcessor read CPU7;
    property FrameNumber: UInt64 read FFrameNumber;
    property Scanline: Integer read FLine;
  end;

implementation

uses
  NDS.BIOS;

function TNDSConsole.CPU9: TARMProcessor;
begin
  Result := FCPU[0];
end;

function TNDSConsole.CPU7: TARMProcessor;
begin
  Result := FCPU[1];
end;

function TNDSConsole.CodePage9(Address: Cardinal): PByte;
begin
  Result := nil;
  if Address shr 24 = 2 then
    Exit(@FMain[Address and $3FFFFF]);
  if (Address < $02000000) and (FCPControl and $40000 <> 0) then
    Exit(@FITCM[Address and $7FFF]);
end;

function TNDSConsole.DataPage9(Address: Cardinal; Writing: Boolean): PByte;
begin
  Result := DirectMemory(0, Address, Writing);
end;

function TNDSConsole.DataPage7(Address: Cardinal; Writing: Boolean): PByte;
begin
  Result := DirectMemory(1, Address, Writing);
end;

function TNDSConsole.CodePage7(Address: Cardinal): PByte;
begin
  Result := nil;
  if Address shr 24 = 2 then
    Exit(@FMain[Address and $3FFFFF]);
  if Address and $FF800000 = $03800000 then
    Exit(@FPrivate[Address and $FFFF]);
end;

function TNDSConsole.Read9(Address: Cardinal; Size: Integer): Cardinal;
begin
  FCodeAccess[0] := False;
  Result := ReadCPU(0, Address, Size);
end;

function TNDSConsole.ReadCode9(Address: Cardinal; Size: Integer): Cardinal;
begin
  FCodeAccess[0] := True;
  if (Address shr 24 = 2) and (Size in [2, 4]) and (Address and Cardinal(Size - 1) = 0) then
  begin
    if Size = 4 then
      Exit(PCardinal(@FMain[Address and $3FFFFF])^);
    Exit(PWord(@FMain[Address and $3FFFFF])^);
  end;
  if (Address < $02000000) and (FCPControl and $40000 <> 0) and
    not FDMABusy[0] and (Size in [2, 4]) and (Address and Cardinal(Size - 1) = 0) then
  begin
    if Size = 4 then
      Exit(PCardinal(@FITCM[Address and $7FFF])^);
    Exit(PWord(@FITCM[Address and $7FFF])^);
  end;
  Result := ReadBus(0, Address, Size);
end;

function TNDSConsole.Read7(Address: Cardinal; Size: Integer): Cardinal;
begin
  FCodeAccess[1] := False;
  Result := ReadCPU(1, Address, Size);
end;

function TNDSConsole.ReadAudio(Address: Cardinal; Size: Integer): Cardinal;
begin
  // The sound engine shares ARM7 memory, not its CPU instruction/data bus
  // phase. Keep that phase untouched, including in mid-frame snapshots.
  Result := ReadBus(1, Address, Size);
end;

function TNDSConsole.ReadCode7(Address: Cardinal; Size: Integer): Cardinal;
begin
  FCodeAccess[1] := True;
  if (Address and $FF800000 = $03800000) and (Size in [2, 4]) and (Address and Cardinal(Size - 1) = 0) then
  begin
    if Size = 4 then
      Exit(PCardinal(@FPrivate[Address and $FFFF])^);
    Exit(PWord(@FPrivate[Address and $FFFF])^);
  end;
  Result := ReadBus(1, Address, Size);
end;

procedure TNDSConsole.Write9(Address, Value: Cardinal; Size: Integer);
begin
  FCodeAccess[0] := False;
  WriteCPU(0, Address, Value, Size);
end;

procedure TNDSConsole.Write7(Address, Value: Cardinal; Size: Integer);
begin
  FCodeAccess[1] := False;
  WriteCPU(1, Address, Value, Size);
end;

function TNDSConsole.ReadCPU(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var Memory := DirectMemory(CPU, Address and not Cardinal(Size - 1), False);
  if (Memory = nil) or not (Size in [1, 2, 4]) then
    Exit(ReadBus(CPU, Address, Size));
  case Size of
    1:
      Result := Memory^;
    2:
      Result := PWord(Memory)^;
  else
    Result := PCardinal(Memory)^;
  end;
  if (Size = 4) and (Address and 3 <> 0) then
  begin
    var Shift := (Address and 3) * 8;
    Result := (Result shr Shift) or (Result shl (32 - Shift));
  end;
end;

procedure TNDSConsole.WriteCPU(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  if (Size = 1) and (((Address shr 24) in [5, 7]) or ((CPU = 0) and (Address shr 24 = 6))) then
    Exit;
  var Memory := DirectMemory(CPU, Address and not Cardinal(Size - 1), True);
  if (Memory = nil) or not (Size in [1, 2, 4]) then
  begin
    WriteBus(CPU, Address, Value, Size);
    Exit;
  end;
  case Size of
    1:
      Memory^ := Byte(Value);
    2:
      PWord(Memory)^ := Word(Value);
    4:
      PCardinal(Memory)^ := Value;
  end;
end;

function TNDSConsole.IO16(CPU, Offset: Integer): Word;
begin
  Result := FIO[CPU, Offset] or (Word(FIO[CPU, Offset + 1]) shl 8);
end;

function TNDSConsole.IO32(CPU, Offset: Integer): Cardinal;
begin
  Result := IO16(CPU, Offset) or (Cardinal(IO16(CPU, Offset + 2)) shl 16);
end;

procedure TNDSConsole.PutIO32(CPU, Offset: Integer; Value: Cardinal);
begin
  for var i := 0 to 3 do
    FIO[CPU, Offset + i] := Byte(Value shr (i * 8));
end;

constructor TNDSConsole.Create(const Data: TBytes; SaveSize: Integer);
begin
  inherited Create;
  Cartridge := TNDSCartridge.Create(Data, SaveSize);
  Video := TNDSVideo.Create;
  Video.OnDisplayFIFO := DisplayFIFO;
  RTC := TNDSRTC.Create;
  FCPU[0] := TARMProcessor.Create(Read9, Write9);
  FCPU[1] := TARMProcessor.Create(Read7, Write7);
  FCPU[0].MemoryReadCode := ReadCode9;
  FCPU[1].MemoryReadCode := ReadCode7;
  FCPU[0].InstructionPageRead := CodePage9;
  FCPU[1].InstructionPageRead := CodePage7;
  FCPU[0].CodeAccessFlag := @FCodeAccess[0];
  FCPU[1].CodeAccessFlag := @FCodeAccess[1];
  FCPU[0].MemoryPageRead := DataPage9;
  FCPU[1].MemoryPageRead := DataPage7;
  FCPU[0].MemoryPageLimit := $04000000;
  FCPU[1].MemoryPageLimit := $04000000;
  FCPU[0].ARMv5 := True;
  FCPU[0].Coprocessor := CP15;
  FCPU[0].SoftwareInterrupt := SWI9;
  FCPU[1].SoftwareInterrupt := SWI7;
  Sound := TNDSSound.Create(ReadAudio);
  SetLength(FFirmware, $40000);

  // A small, original firmware settings image for direct boot and SPI reads.
  FFirmware[$20] := $C0;
  FFirmware[$21] := $7F; // user data at 0x3FE00
  FFirmware[$36] := $02;
  FFirmware[$3B] := 1;
  FFirmware[$3C] := $FE;
  FFirmware[$3D] := $3F;
  for var Page := 0 to 1 do
  begin
    var P := $3FE00 + Page * $100;
    FFirmware[P] := 5;
    FFirmware[P + 2] := 1;
    FFirmware[P + 3] := 1;
    FFirmware[P + $58] := $00;
    FFirmware[P + $59] := $02;
    FFirmware[P + $5A] := $00;
    FFirmware[P + $5B] := $02;
    FFirmware[P + $5C] := 0;
    FFirmware[P + $5D] := 0;
    FFirmware[P + $5E] := $00;
    FFirmware[P + $5F] := $0E;
    FFirmware[P + $60] := $00;
    FFirmware[P + $61] := $0E;
    FFirmware[P + $62] := 255;
    FFirmware[P + $63] := 191;
    FFirmware[P + $64] := 1;
    // The SDK rereads both flash pages and discards their calibration unless
    // the user-settings CRC is valid, even on a direct boot.
    FFirmware[P + $70] := Byte(Page);
    var CRC: Word := $FFFF;
    for var I := 0 to $6F do
    begin
      CRC := CRC xor FFirmware[P + I];
      for var Bit := 0 to 7 do
        if CRC and 1 <> 0 then
          CRC := (CRC shr 1) xor $A001
        else
          CRC := CRC shr 1;
    end;
    FFirmware[P + $72] := Byte(CRC);
    FFirmware[P + $73] := Byte(CRC shr 8);
  end;
  Reset;
end;

destructor TNDSConsole.Destroy;
begin
  RTC.Free;
  Sound.Free;
  FCPU[1].Free;
  FCPU[0].Free;
  Video.Free;
  Cartridge.Free;
  inherited;
end;

procedure TNDSConsole.BIOSStub(CPU: Integer);

  procedure Store(Offset: Integer; Value: Cardinal);
  begin
    for var i := 0 to 3 do
      if CPU = 0 then
        FBIOS9[Offset + i] := Byte(Value shr (i * 8))
      else
        FBIOS7[Offset + i] := Byte(Value shr (i * 8));
  end;

begin
  // Original ARM exception trampoline. The game supplies its own IRQ handler.
  Store($18, $EA000038); // B 0x100
  Store($100, $E92D500F); // PUSH {r0-r3,r12,lr}
  Store($104, $E59FC01C); // LDR r12,[pc,#0x1C] -> pointer address
  Store($108, $E59CC000); // LDR r12,[r12]
  Store($10C, $E35C0000); // CMP r12,#0
  Store($110, $0A000002); // BEQ return
  Store($114, $E3A00301); // MOV r0,#0x04000000 (BIOS IRQ calling convention)
  Store($118, $E28FE000); // ADR lr,return
  Store($11C, $E12FFF1C); // BX r12
  Store($120, $E8BD500F); // POP
  Store($124, $E25EF004); // SUBS pc,lr,#4
  if CPU = 0 then
    Store($128, (FDTCMControl and $FFFFF000) + $3FFC)
  else
    Store($128, $0380FFFC);
end;

procedure TNDSConsole.Reset;

  procedure LoadExecutable(CPU: Integer; const E: TNDSExecutable);
  begin
    for var i: Cardinal := 0 to E.Size - 1 do
      WriteByte(CPU, E.Address + i, Cartridge.Data[E.Offset + i]);
    FCPU[CPU].SetStatus($D2);
    if CPU = 0 then
      FCPU[CPU].R[13] := $03003F80
    else
      FCPU[CPU].R[13] := $0380FF80;
    FCPU[CPU].SetStatus($D3);
    if CPU = 0 then
      FCPU[CPU].R[13] := $03003FC0
    else
      FCPU[CPU].R[13] := $0380FFC0;
    FCPU[CPU].SetStatus($DF);
    if CPU = 0 then
      FCPU[CPU].R[13] := $03002F7C
    else
      FCPU[CPU].R[13] := $0380FD80;
    FCPU[CPU].R[12] := E.Entry;
    FCPU[CPU].R[14] := E.Entry;
    FCPU[CPU].R[15] := E.Entry and $FFFFFFFC;
    if E.Entry and 1 <> 0 then
    begin
      FCPU[CPU].SetStatus($FF);
      FCPU[CPU].R[15] := E.Entry and $FFFFFFFE;
    end;
  end;

begin
  FillChar(FMain, SizeOf(FMain), 0);
  FillChar(FShared, SizeOf(FShared), 0);
  FillChar(FPrivate, SizeOf(FPrivate), 0);
  FillChar(FITCM, SizeOf(FITCM), 0);
  FillChar(FDTCM, SizeOf(FDTCM), 0);
  FillChar(FIO, SizeOf(FIO), 0);
  FillChar(FBIOS9, SizeOf(FBIOS9), 0);
  FillChar(FBIOS7, SizeOf(FBIOS7), 0);
  FillChar(FTimers, SizeOf(FTimers), 0);
  FillChar(FDMA, SizeOf(FDMA), 0);
  FillChar(FTimerMask, SizeOf(FTimerMask), 0);
  FillChar(FTimerPending, SizeOf(FTimerPending), 0);
  FillChar(FDMATimingMask, SizeOf(FDMATimingMask), 0);
  FillChar(FFIFO, SizeOf(FFIFO), 0);
  FillChar(FFIFOControl, SizeOf(FFIFOControl), 0);
  FillChar(FFIFOIRQ, SizeOf(FFIFOIRQ), 0);
  FillChar(FIME, SizeOf(FIME), 0);
  FillChar(FIE, SizeOf(FIE), 0);
  FillChar(FIF, SizeOf(FIF), 0);
  FillChar(FWaitMask, SizeOf(FWaitMask), 0);
  FillChar(FHalted, SizeOf(FHalted), 0);
  FillChar(FCPUTime, SizeOf(FCPUTime), 0);
  FillChar(FCodeAccess, SizeOf(FCodeAccess), 0);
  FillChar(FDMABusy, SizeOf(FDMABusy), 0);
  FillChar(FCPRegs, SizeOf(FCPRegs), 0);
  FCPControl := $0005707D;
  FDTCMControl := $0300000A;
  FITCMControl := $20;
  FCPU[0].Reset;
  FCPU[1].Reset;
  FCPU[0].VectorBase := $FFFF0000;
  FWRAM := 3;
  FBusTime := 0;
  FBusPending := 0;
  FBusBudget := 0;
  FLine := 0;
  FLineClock := 0;
  FFrameNumber := 0;
  FCardRemaining := 0;
  FCardAddress := 0;
  FCardCommand := 0;
  FCardOwner := 0;
  FSPIPosition := 0;
  FSPIAddress := 0;
  FSPICommand := 0;
  FTSCValue := 0;
  FFirmwareStatus := 0;
  FFirmwareWriting := False;
  FillChar(FPowerRegisters, SizeOf(FPowerRegisters), 0);
  FPowerRegisters[0] := $0D;
  Cartridge.ResetSPI;
  Video.Reset;
  Sound.Reset;
  RTC.Reset;
  for var C := 0 to 1 do
  begin
    PutIO32(C, $204, $E880);
    FIO[C, $300] := 1;
    BIOSStub(C);
  end;
  LoadExecutable(0, Cartridge.Header.ARM9);
  LoadExecutable(1, Cartridge.Header.ARM7);
  for var i := 0 to $16F do
    FMain[$3FFE00 + i] := Cartridge.Data[i];
  for var i := 0 to $6F do
    FMain[$3FFC80 + i] := FFirmware[$3FE00 + i];
  for var Address in [$027FF800, $027FF804, $027FFC00, $027FFC04] do
    WriteBus(0, Address, $00001FC2, 4);
  WriteBus(0, $027FF808, NDSRead32(Cartridge.Data, $15C) shr 16, 2);
  WriteBus(0, $027FFC08, NDSRead32(Cartridge.Data, $15C) shr 16, 2);
  WriteBus(0, $027FF850, $5835, 2);
  WriteBus(0, $027FFC10, $5835, 2);
  WriteBus(0, $027FF880, 7, 4);
  WriteBus(0, $027FF884, 6, 4);
  WriteBus(0, $027FF890, $B0002A22, 4);
  WriteBus(0, $027FFC40, 1, 2);
  WriteBus(0, $027FF868, $3FE00, 4);
  SetInput([]);
  SetTouch(0, 0, False);
end;

function TNDSConsole.CP15(Op: Cardinal; var Value: Cardinal): Boolean;
begin
  Result := ((Op shr 8) and 15) = 15;
  if not Result then
    Exit;
  var N := (Op shr 16) and 15;
  var M := Op and 15;
  var O := (Op shr 5) and 7;
  if Op and $00100000 <> 0 then
    case N of
      0:
        if O = 1 then
          Value := $0F0D2112
        else
          Value := $41059461;
      1:
        Value := FCPControl;
      9:
        if M = 1 then
          if O = 0 then
            Value := FDTCMControl
          else
            Value := FITCMControl
        else
          Value := 0;
    else
      Value := FCPRegs[N, O];
    end
  else
  begin
    FCPRegs[N, O] := Value;
    case N of
      1:
        begin
          FCPControl := Value;
          FCPU[0].InvalidateMemoryPages;
          if Value and $2000 <> 0 then
            FCPU[0].VectorBase := $FFFF0000
          else
            FCPU[0].VectorBase := 0;
        end;
      7:
        if (M = 0) and (O = 4) then
          FHalted[0] := True;
      9:
        if M = 1 then
          if O = 0 then
          begin
            FDTCMControl := Value;
            FCPU[0].InvalidateMemoryPages;
            BIOSStub(0);
          end
          else if O = 1 then
          begin
            FITCMControl := Value;
            FCPU[0].InvalidateMemoryPages;
          end;
    end;
  end;
end;

function TNDSConsole.DirectMemory(CPU: Integer; Address: Cardinal; Writing: Boolean): PByte;
begin
  Result := nil;
  if CPU = 0 then
  begin
    if not FDMABusy[0] and (FCPControl and $10000 <> 0) and (Writing or not FCodeAccess[0]) and
      (Address >= FDTCMControl and $FFFFF000) and (UInt64(Address) < UInt64(FDTCMControl and $FFFFF000) + $4000) then
      Exit(@FDTCM[Address and $3FFF]);
    if not FDMABusy[0] and (FCPControl and $40000 <> 0) and (Address < $02000000) then
      Exit(@FITCM[Address and $7FFF]);
    if not Writing and (Address and $FFFFF000 = $FFFF0000) then
      Exit(@FBIOS9[Address and $FFF]);
  end
  else if not Writing and (Address < $4000) then
    Exit(@FBIOS7[Address]);
  case Address shr 24 of
    2:
      Result := @FMain[Address and $3FFFFF];
    5:
      if CPU = 0 then
        Result := @Video.Palette[Address and $7FF];
    6:
      Result := Video.DirectMemory(Address, CPU);
    7:
      if CPU = 0 then
        Result := @Video.OAM[Address and $7FF];
    3:
      if CPU = 0 then
        case FWRAM of
          0:
            Result := @FShared[Address and $7FFF];
          1:
            Result := @FShared[$4000 + (Address and $3FFF)];
          2:
            Result := @FShared[Address and $3FFF];
        end
      else if (Address >= $03800000) or (FWRAM = 0) then
        Result := @FPrivate[Address and $FFFF]
      else
        case FWRAM of
          1:
            Result := @FShared[Address and $3FFF];
          2:
            Result := @FShared[$4000 + (Address and $3FFF)];
          3:
            Result := @FShared[Address and $7FFF];
        end;
  end;
end;

function TNDSConsole.ReadByte(CPU: Integer; Address: Cardinal): Byte;
begin
  Result := 0;
  if CPU = 0 then
  begin
    // TCM is private to the ARM9 core. DMA uses the external system bus,
    // including the underlying RAM when a DTCM window overlaps main RAM.
    if not FDMABusy[0] and (FCPControl and $10000 <> 0) and not FCodeAccess[0] and
      (Address >= FDTCMControl and $FFFFF000) and (UInt64(Address) < UInt64(FDTCMControl and $FFFFF000) + $4000) then
      Exit(FDTCM[Address and $3FFF]);
    if not FDMABusy[0] and (FCPControl and $40000 <> 0) and (Address < $02000000) then
      Exit(FITCM[Address and $7FFF]);
    if Address and $FFFFF000 = $FFFF0000 then
      Exit(FBIOS9[Address and $FFF]);
  end
  else if Address < $4000 then
    Exit(FBIOS7[Address]);
  case Address shr 24 of
    2:
      Result := FMain[Address and $3FFFFF];
    3:
      if CPU = 0 then
        case FWRAM of
          0:
            Result := FShared[Address and $7FFF];
          1:
            Result := FShared[$4000 + (Address and $3FFF)];
          2:
            Result := FShared[Address and $3FFF];
        end
      else if Address >= $03800000 then
        Result := FPrivate[Address and $FFFF]
      else
        case FWRAM of
          0:
            Result := FPrivate[Address and $FFFF];
          1:
            Result := FShared[Address and $3FFF];
          2:
            Result := FShared[$4000 + (Address and $3FFF)];
          3:
            Result := FShared[Address and $7FFF];
        end;
    4:
      if Address < $04001100 then
        Result := ReadIO(CPU, Address and $FFFF);
    5:
      if CPU = 0 then
        Result := Video.Palette[Address and $7FF];
    6:
      Result := Video.ReadMemory(Address, CPU);
    7:
      if CPU = 0 then
        Result := Video.OAM[Address and $7FF];
    8, 9:
      if ((IO16(0, $204) shr 7) and 1) = CPU then
        Result := Byte((Address shr 1) shr ((Address and 1) * 8));
    10:
      if ((IO16(0, $204) shr 7) and 1) = CPU then
        Result := $FF;
  end;
end;

procedure TNDSConsole.WriteByte(CPU: Integer; Address: Cardinal; Value: Byte);
begin
  if CPU = 0 then
  begin
    if not FDMABusy[0] and (FCPControl and $10000 <> 0) and (Address >= FDTCMControl and $FFFFF000) and
      (UInt64(Address) < UInt64(FDTCMControl and $FFFFF000) + $4000) then
    begin
      FDTCM[Address and $3FFF] := Value;
      Exit;
    end;
    if not FDMABusy[0] and (FCPControl and $40000 <> 0) and (Address < $02000000) then
    begin
      FITCM[Address and $7FFF] := Value;
      Exit;
    end;
  end;
  case Address shr 24 of
    2:
      FMain[Address and $3FFFFF] := Value;
    3:
      if CPU = 0 then
        case FWRAM of
          0:
            FShared[Address and $7FFF] := Value;
          1:
            FShared[$4000 + (Address and $3FFF)] := Value;
          2:
            FShared[Address and $3FFF] := Value;
        end
      else if Address >= $03800000 then
        FPrivate[Address and $FFFF] := Value
      else
        case FWRAM of
          0:
            FPrivate[Address and $FFFF] := Value;
          1:
            FShared[Address and $3FFF] := Value;
          2:
            FShared[$4000 + (Address and $3FFF)] := Value;
          3:
            FShared[Address and $7FFF] := Value;
        end;
    4:
      if Address < $04001100 then
        WriteIO(CPU, Address and $FFFF, Value);
    5:
      if CPU = 0 then
        Video.Palette[Address and $7FF] := Value;
    6:
      Video.WriteMemory(Address, Value, CPU);
    7:
      if CPU = 0 then
        Video.OAM[Address and $7FF] := Value;
  end;
end;

function TNDSConsole.ReadBus(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
begin
  if (CPU < 0) or (CPU > 1) or not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('Invalid NDS bus read');
  if Address shr 24 = 4 then
  begin
    FlushBus;
    FBusBudget := 0;
  end;
  var Aligned := Address and not Cardinal(Size - 1);
  if Aligned = $04100000 then
    Exit(ReceiveFIFO(CPU));
  if Aligned = $04100010 then
  begin
    if CPU = FCardOwner then
      Exit(ReadCard)
    else
      Exit(0);
  end;
  // RAM/TCM accesses have no byte-level side effects. Decode their mapping
  // once per bus transaction; retain byte transactions for IO and VRAM.
  var Memory := DirectMemory(CPU, Aligned, False);
  if Memory <> nil then
    case Size of
      1:
        Result := Memory^;
      2:
        Result := PWord(Memory)^;
    else
      Result := PCardinal(Memory)^;
    end
  else
  begin
    Result := 0;
    for var i := 0 to Size - 1 do
      Result := Result or (Cardinal(ReadByte(CPU, Aligned + Cardinal(i))) shl (i * 8));
  end;
  if (Size = 4) and (Address and 3 <> 0) then
  begin
    var Shift := (Address and 3) * 8;
    Result := (Result shr Shift) or (Result shl (32 - Shift));
  end;
end;

procedure TNDSConsole.WriteBus(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  if (CPU < 0) or (CPU > 1) or not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('Invalid NDS bus write');
  if Address shr 24 = 4 then
  begin
    FlushBus;
    FBusBudget := 0;
  end;
  Address := Address and not Cardinal(Size - 1);
  if (Size = 1) and (((Address shr 24) in [5, 7]) or ((CPU = 0) and (Address shr 24 = 6))) then
    Exit;
  if (CPU = 0) and (Address = $04000068) then
  begin
    Video.WriteDisplayFIFO(Value, Size);
    Exit;
  end;
  if (CPU = 0) and (Size = 4) and (Address >= $04000400) and (Address <= $040005C8) then
  begin
    // Command ports have no byte-write side effects. Preserve their IO
    // mirror, then submit the word once instead of decoding four IO bytes.
    PCardinal(@FIO[0, Address and $FFF])^ := Value;
    if Address < $04000440 then
      Video.Geometry.FIFO(Value)
    else
      Video.Geometry.Direct((Address - $04000400) div 4, Value);
    Exit;
  end;
  if Address = $04000188 then
  begin
    if Size = 4 then
      SendFIFO(CPU, Value);
    Exit;
  end;
  var Memory := DirectMemory(CPU, Address, True);
  if Memory <> nil then
  begin
    case Size of
      1:
        Memory^ := Byte(Value);
      2:
        PWord(Memory)^ := Word(Value);
      4:
        PCardinal(Memory)^ := Value;
    end;
    Exit;
  end;
  for var i := 0 to Size - 1 do
    WriteByte(CPU, Address + Cardinal(i), Byte(Value shr (i * 8)));
  if (Address >= $04000280) and (Address < $040002C0) and (CPU = 0) then
    MathUnit;
end;

procedure TNDSConsole.RequestIRQ(CPU, Bit: Integer);
begin
  FIF[CPU] := FIF[CPU] or (Cardinal(1) shl Bit);
end;

procedure TNDSConsole.UpdateFIFOIRQ;
begin
  for var C := 0 to 1 do
  begin
    var Empty := (FFIFOControl[C] and 4 <> 0) and (FFIFO[C].Count = 0);
    var Receive := (FFIFOControl[C] and $400 <> 0) and (FFIFO[1 - C].Count <> 0);
    if Empty and not FFIFOIRQ[C, 0] then
      RequestIRQ(C, 17);
    if Receive and not FFIFOIRQ[C, 1] then
      RequestIRQ(C, 18);
    FFIFOIRQ[C, 0] := Empty;
    FFIFOIRQ[C, 1] := Receive;
  end;
end;

procedure TNDSConsole.SendFIFO(CPU: Integer; Value: Cardinal);
begin
  if Assigned(Trace) then
    Trace(Format('IPC cpu=%d tx=%.8x pc=%.8x', [CPU, Value, FCPU[CPU].R[15]]));
  if FFIFOControl[CPU] and $8000 = 0 then
    Exit;
  var Q: PNDSFIFO := @FFIFO[CPU];
  if Q.Count = 16 then
    FFIFOControl[CPU] := FFIFOControl[CPU] or $4000
  else
  begin
    Q.Words[(Q.Head + Q.Count) and 15] := Value;
    Inc(Q.Count);
  end;
  UpdateFIFOIRQ;
end;

function TNDSConsole.ReceiveFIFO(CPU: Integer): Cardinal;
begin
  var Q: PNDSFIFO := @FFIFO[1 - CPU];
  Result := Q.Last;
  if Q.Count = 0 then
    FFIFOControl[CPU] := FFIFOControl[CPU] or $4000
  else
  begin
    Result := Q.Words[Q.Head];
    if FFIFOControl[CPU] and $8000 <> 0 then
    begin
      Q.Last := Result;
      Q.Head := (Q.Head + 1) and 15;
      Dec(Q.Count);
    end;
  end;
  UpdateFIFOIRQ;
end;

function TNDSConsole.ReadIO(CPU, Offset: Integer): Byte;
begin
  Result := FIO[CPU, Offset];
  if ((Offset < $70) or ((Offset >= $1000) and (Offset < $1070))) and (CPU = 0) then
    Result := Video.Registers[Offset shr 12, Offset and $FFF];
  case Offset of
    4, 5:
      begin
        var V := IO16(CPU, 4) and $FFF8;
        if (FLine >= 192) and (FLine < 262) then
          V := V or 1;
        if FLineClock >= 1606 then
          V := V or 2;
        if FLine = ((V shr 8) or ((V and $80) shl 1)) then
          V := V or 4;
        Result := Byte(V shr ((Offset and 1) * 8));
      end;
    6, 7:
      Result := Byte(FLine shr ((Offset and 1) * 8));
    $100..$10F:
      begin
        FlushTimers(CPU);
        var T: PNDSTimer := @FTimers[CPU, (Offset - $100) div 4];
        if Offset and 3 < 2 then
          Result := Byte(T.Counter shr ((Offset and 1) * 8))
        else
          Result := Byte(T.Control shr ((Offset and 1) * 8));
      end;
    $130, $131:
      Result := Byte(FKeys shr ((Offset and 1) * 8));
    $136:
      if CPU = 1 then
        Result := FExtKeys;
    $137:
      Result := 0;
    $138:
      if CPU = 1 then
        Result := RTC.Read;
    $180:
      Result := FIO[1 - CPU, $181] and 15;
    $181:
      Result := FIO[CPU, $181] and $4F;
    $184, $185:
      begin
        var V := FFIFOControl[CPU] and $C404;
        if FFIFO[CPU].Count = 0 then
          V := V or 1;
        if FFIFO[CPU].Count = 16 then
          V := V or 2;
        if FFIFO[1 - CPU].Count = 0 then
          V := V or $100;
        if FFIFO[1 - CPU].Count = 16 then
          V := V or $200;
        Result := Byte(V shr ((Offset and 1) * 8));
      end;
    $204:
      if CPU = 1 then
        Result := (FIO[1, $204] and $7F) or (FIO[0, $204] and $80);
    $205:
      if CPU = 1 then
        Result := FIO[0, $205];
    $208..$20B:
      Result := Byte(FIME[CPU] shr ((Offset and 3) * 8));
    $210..$213:
      Result := Byte(FIE[CPU] shr ((Offset and 3) * 8));
    $214..$217:
      Result := Byte(FIF[CPU] shr ((Offset and 3) * 8));
    $240:
      if CPU = 1 then
      begin
        Result := 0;
        for var B := 2 to 3 do
          if Video.BankControl[B] and $87 = $82 then
            Result := Result or (1 shl (B - 2));
      end
      else
        Result := Video.BankControl[0];
    $241:
      if CPU = 1 then
        Result := FWRAM
      else
        Result := Video.BankControl[1];
    $242..$246:
      if CPU = 0 then
        Result := Video.BankControl[Offset - $240];
    $247:
      if CPU = 0 then
        Result := FWRAM;
    $248, $249:
      if CPU = 0 then
        Result := Video.BankControl[Offset - $241];
    $304, $305:
      if CPU = 0 then
        Result := Byte(Video.Power shr ((Offset and 1) * 8));
    $400..$51F:
      if CPU = 1 then
        Result := Sound.ReadRegister(Offset)
      else if Offset = $400 then
        Result := 0;
    $600..$6A3:
      if CPU = 0 then
        Result := Byte(Video.Geometry.ReadRegister(Offset and not 3) shr ((Offset and 3) * 8));
  end;
end;

procedure TNDSConsole.WriteIO(CPU, Offset: Integer; Value: Byte);
begin
  if (Offset >= $100) and (Offset < $110) then
    FlushTimers(CPU);
  var Old := FIO[CPU, Offset];
  case Offset of
    4:
      Value := (Value and $F8) or (Old and 7);
    6, 7, $130, $131, $136, $137, $180:
      Exit;
    $181:
      begin
        FIO[CPU, Offset] := Value and $4F;
        if (Value and $20 <> 0) and (FIO[1 - CPU, Offset] and $40 <> 0) then
          RequestIRQ(1 - CPU, 16);
        Exit;
      end;
    $184, $185:
      begin
        var V := FFIFOControl[CPU];
        if Offset = $184 then
        begin
          V := (V and not Word(4)) or (Value and 4);
          if Value and 8 <> 0 then
            FillChar(FFIFO[CPU], SizeOf(TNDSFIFO), 0);
        end
        else
        begin
          V := (V and not Word($8400)) or (Word(Value and $84) shl 8);
          if Value and $40 <> 0 then
            V := V and not Word($4000);
        end;
        FFIFOControl[CPU] := V;
        UpdateFIFOIRQ;
        Exit;
      end;
    $208..$20B:
      begin
        if Offset = $208 then
          FIME[CPU] := Value and 1;
        Exit;
      end;
    $210..$213:
      begin
        var S := (Offset and 3) * 8;
        FIE[CPU] := (FIE[CPU] and not (Cardinal($FF) shl S)) or (Cardinal(Value) shl S);
        Exit;
      end;
    $214..$217:
      begin
        FIF[CPU] := FIF[CPU] and not (Cardinal(Value) shl ((Offset and 3) * 8));
        Exit;
      end;
    $240..$246:
      begin
        if CPU = 0 then
          Video.BankControl[Offset - $240] := Value;
        Exit;
      end;
    $247:
      begin
        if CPU = 0 then
        begin
          FWRAM := Value and 3;
          FCPU[0].InvalidateMemoryPages;
          FCPU[1].InvalidateMemoryPages;
        end;
        Exit;
      end;
    $248, $249:
      begin
        if CPU = 0 then
          Video.BankControl[Offset - $241] := Value;
        Exit;
      end;
    $304, $305:
      if CPU = 0 then
      begin
        Video.Power := (Video.Power and not (Word($FF) shl ((Offset and 1) * 8))) or (Word(Value) shl ((Offset and 1) * 8));
        Exit;
      end;
    $301:
      begin
        if CPU = 1 then
          FHalted[CPU] := True;
        Exit;
      end;
    $138:
      if CPU = 1 then
      begin
        RTC.Write(Value);
        Exit;
      end;
    $400..$51F:
      if CPU = 1 then
      begin
        Sound.WriteRegister(Offset, Value);
        Exit;
      end;
  end;
  FIO[CPU, Offset] := Value;
  if CPU = 0 then
    Video.Geometry.WriteRegister(Offset, Value);
  if CPU = 0 then
    case Offset of
      $350..$353:
        Video.Geometry.ClearColor := IO32(0, $350);
      $354, $355:
        Video.Geometry.ClearDepth := IO16(0, $354) and $7FFF;
      $603:
        Video.Geometry.IRQMode := Value shr 6;
    end;
  if ((Offset < $70) or ((Offset >= $1000) and (Offset < $1070))) and (CPU = 0) then
    Video.WriteRegister(Offset shr 12, Offset and $FFF, Value);
  if (Offset >= $100) and (Offset < $110) then
  begin
    var T: PNDSTimer := @FTimers[CPU, (Offset - $100) div 4];
    var Base := Offset and not 3;
    T.Reload := IO16(CPU, Base);
    if Offset and 3 = 2 then
    begin
      var Prior := T.Control;
      T.Control := Value and $C7;
      if (Prior and $80 = 0) and (T.Control and $80 <> 0) then
      begin
        T.Counter := T.Reload;
        T.Divider := 0;
      end;
      RefreshEventMasks(CPU);
      TimerDeadline(CPU);
    end;
  end;
  if (Offset >= $B0) and (Offset < $E0) then
  begin
    var N := (Offset - $B0) div 12;
    var Base := $B0 + N * 12;
    var D: PNDSDMA := @FDMA[CPU, N];
    var Prior := D.Control;
    D.Source := IO32(CPU, Base);
    D.Destination := IO32(CPU, Base + 4);
    D.Control := IO32(CPU, Base + 8);
    RefreshEventMasks(CPU);
    if (Prior and $80000000 = 0) and (D.Control and $80000000 <> 0) then
    begin
      D.CurrentSource := D.Source and $0FFFFFFF;
      D.CurrentDestination := D.Destination and $0FFFFFFF;
      var Timing := (D.Control shr 27) and 7;
      if CPU = 1 then
        Timing := (D.Control shr 28) and 3;
      if Timing = 0 then
        D.Pending := True;
    end;
    if not FDMABusy[CPU] then
      for var i := 0 to 3 do
        if FDMA[CPU, i].Pending then
          RunDMA(CPU, i);
  end;
  if (Offset = $1A7) and (Value and $80 <> 0) and (Old and $80 = 0) then
    StartCard(CPU);
  if (Offset = $1A2) and (((IO16(0, $204) shr 11) and 1) = CPU) then
  begin
    FIO[CPU, Offset] := Cartridge.Transfer(Value);
    if Assigned(Trace) then
      Trace(Format('BACKUP cpu=%d ctl=%.4x tx=%.2x rx=%.2x pc=%.8x', [CPU, IO16(CPU, $1A0), Value, FIO[CPU, Offset], FCPU[CPU].R[15]]));
    if IO16(CPU, $1A0) and $40 = 0 then
      Cartridge.ResetSPI;
  end;
  if (Offset = $1A1) and (Value and $80 = 0) then
    Cartridge.ResetSPI;
  if (Offset = $1C2) and (CPU = 1) then
    TransferSPI(Value);
end;

procedure TNDSConsole.StartCard(CPU: Integer);
begin
  if Assigned(Trace) then
    Trace(Format('CARD cpu=%d owner=%d cnt=%.8x cmd=%.8x %.8x pc=%.8x',
        [CPU, (IO16(0, $204) shr 11) and 1, IO32(CPU, $1A4), IO32(CPU, $1A8), IO32(CPU, $1AC), FCPU[CPU].R[15]]));
  if ((IO16(0, $204) shr 11) and 1) <> CPU then
    Exit;

  FCardOwner := CPU;
  FCardCommand := FIO[CPU, $1A8];
  FCardAddress := (Cardinal(FIO[CPU, $1A9]) shl 24) or (Cardinal(FIO[CPU, $1AA]) shl 16) or
    (Cardinal(FIO[CPU, $1AB]) shl 8) or FIO[CPU, $1AC];
  var Block := (IO32(CPU, $1A4) shr 24) and 7;
  FCardRemaining := 0;
  if Block = 7 then
    FCardRemaining := 4
  else if Block <> 0 then
    FCardRemaining := $100 shl Block;
  if FCardCommand = 0 then
    FCardAddress := 0;
  if FCardRemaining = 0 then
  begin
    FIO[CPU, $1A7] := FIO[CPU, $1A7] and $7F;
    if FIO[CPU, $1A1] and $40 <> 0 then
      RequestIRQ(CPU, 19);
  end
  else
  begin
    FIO[CPU, $1A6] := FIO[CPU, $1A6] or $80;
    TriggerDMA(CPU, 5);
  end;
end;

function TNDSConsole.ReadCard: Cardinal;
begin
  Result := $FFFFFFFF;
  if FCardRemaining = 0 then
    Exit;
  if FCardCommand in [$90, $B8] then
    Result := $00001FC2
  else if FCardCommand in [0, $B7] then
  begin
    Result := 0;
    var Address := FCardAddress;
    if (FCardCommand = $B7) and (Address < $8000) then
      Address := $8000 + (Address and $1FF);
    for var i := 0 to 3 do
      Result := Result or (Cardinal(Cartridge.ReadROM(Address + Cardinal(i))) shl (i * 8));
    Inc(FCardAddress, 4);
  end;
  Dec(FCardRemaining, 4);
  if FCardRemaining = 0 then
  begin
    FIO[FCardOwner, $1A7] := FIO[FCardOwner, $1A7] and $7F;
    FIO[FCardOwner, $1A6] := FIO[FCardOwner, $1A6] and $7F;
    if FIO[FCardOwner, $1A1] and $40 <> 0 then
      RequestIRQ(FCardOwner, 19);
  end;
end;

procedure TNDSConsole.TransferSPI(Value: Byte);
begin
  var Control := IO16(1, $1C0);
  if Control and $8000 = 0 then
    Exit;
  var Device := (Control shr 8) and 3;
  var Response := 0;
  case Device of
    0:
      if FSPIPosition = 0 then
        FSPICommand := Value
      else if FSPICommand and $80 <> 0 then
        Response := FPowerRegisters[FSPICommand and 7]
      else
        FPowerRegisters[FSPICommand and 7] := Value;
    1:
      begin
        if FSPIPosition = 0 then
        begin
          FSPICommand := Value;
          FSPIAddress := 0;
          FFirmwareWriting := False;
          if Value = 6 then
            FFirmwareStatus := FFirmwareStatus or 2;
          if Value = 4 then
            FFirmwareStatus := FFirmwareStatus and not Byte(2);
        end
        else if (FSPICommand in [2, 3, $0A, $DB, $D8]) and (FSPIPosition <= 3) then
        begin
          FSPIAddress := (FSPIAddress shl 8) or Value;
          if (FSPIPosition = 3) and (FSPICommand in [$DB, $D8]) and (FFirmwareStatus and 2 <> 0) then
          begin
            var Length := 256;
            if FSPICommand = $D8 then
              Length := $10000;
            var Base := FSPIAddress and ($40000 - Length);
            FillChar(FFirmware[Base], Length, $FF);
            FFirmwareWriting := True;
          end;
        end
        else if FSPICommand = 3 then
        begin
          Response := FFirmware[FSPIAddress and $3FFFF];
          Inc(FSPIAddress);
        end
        else if FSPICommand = 5 then
          Response := FFirmwareStatus
        else if (FSPICommand in [2, $0A]) and (FFirmwareStatus and 2 <> 0) then
        begin
          var Address := FSPIAddress and $3FFFF;
          if FSPICommand = 2 then
            FFirmware[Address] := FFirmware[Address] and Value
          else
            FFirmware[Address] := Value;
          FSPIAddress := (FSPIAddress and not 255) or ((FSPIAddress + 1) and 255);
          FFirmwareWriting := True;
        end;
      end;
    2:
      begin
        Response := (FTSCValue shr 8) and $FF;
        FTSCValue := (FTSCValue shl 8) and $FFFF;
        if Value and $80 <> 0 then
        begin
          var Sample := 0;
          case (Value shr 4) and 7 of
            1:
              if FPen then
                Sample := 512 + FTouchY * 3072 div 191
              else
                Sample := 4095;
            3:
              if FPen then
                Sample := 400;
            4:
              if FPen then
                Sample := 1200;
            5:
              if FPen then
                Sample := 512 + FTouchX * 3072 div 255;
            6:
              Sample := 2048; // disconnected microphone at its midpoint
          end;
          FTSCValue := Sample shl 3;
        end;
      end;
  end;
  FIO[1, $1C2] := Byte(Response);
  Inc(FSPIPosition);
  if Assigned(Trace) and ((FSPIPosition = 1) or ((Control and $800 = 0) and (Device = 1))) then
    Trace(Format('SPI dev=%d ctl=%.4x cmd=%.2x addr=%.6x count=%d tx=%.2x rx=%.2x', [Device, Control, FSPICommand, FSPIAddress, FSPIPosition, Value, Response]));
  if Control and $800 = 0 then
  begin
    FSPIPosition := 0;
    if (Device = 1) and FFirmwareWriting then
    begin
      FFirmwareStatus := FFirmwareStatus and not Byte(2);
      FFirmwareWriting := False;
    end;
  end;
  if Control and $4000 <> 0 then
    RequestIRQ(1, 23);
end;

procedure TNDSConsole.DisplayFIFO(Sender: TObject);
begin
  TriggerDMA(0, 4);
end;

procedure TNDSConsole.RefreshEventMasks(CPU: Integer);
begin
  FTimerMask[CPU] := 0;
  FDMATimingMask[CPU] := 0;
  for var N := 0 to 3 do
  begin
    if FTimers[CPU, N].Control and $80 <> 0 then
      FTimerMask[CPU] := FTimerMask[CPU] or (1 shl N);
    var Control := FDMA[CPU, N].Control;
    if Control and $80000000 = 0 then
      Continue;
    var Timing := (Control shr 27) and 7;
    if CPU = 1 then
    begin
      Timing := (Control shr 28) and 3;
      if Timing = 2 then
        Timing := 5;
    end;
    FDMATimingMask[CPU] := FDMATimingMask[CPU] or (1 shl Timing);
  end;
end;

procedure TNDSConsole.TriggerDMA(CPU, Timing: Integer);
begin
  if FDMATimingMask[CPU] and (1 shl Timing) = 0 then
    Exit;

  for var N := 0 to 3 do
  begin
    var D: PNDSDMA := @FDMA[CPU, N];
    if D.Control and $80000000 = 0 then
      Continue;
    var T := Integer((D.Control shr 27) and 7);
    if CPU = 1 then
    begin
      T := Integer((D.Control shr 28) and 3);
      if T = 2 then
        T := 5;
    end;
    if T = Timing then
    begin
      D.Pending := True;
      if not FDMABusy[CPU] then
        RunDMA(CPU, N);
    end;
  end;
end;

function TNDSConsole.CopyDMABlock(CPU: Integer; D: PNDSDMA; Remaining: Cardinal; Size, SourceMode, DestinationMode: Integer): Cardinal;
begin
  Result := 0;
  if not (D.CurrentDestination shr 24 in [2, 3, 5, 6, 7]) then
    Exit;

  if not (DestinationMode in [0, 3]) or (SourceMode = 1) or
    ((D.CurrentSource or D.CurrentDestination) and Cardinal(Size - 1) <> 0) then
    Exit;

  var Source := DirectMemory(CPU, D.CurrentSource, False);
  var Destination := DirectMemory(CPU, D.CurrentDestination, True);
  if (Source = nil) or (Destination = nil) then
    Exit;

  var Limit := Cardinal($4000 - (D.CurrentDestination and $3FFF));
  if D.CurrentDestination shr 24 in [5, 7] then
    Limit := $800 - (D.CurrentDestination and $7FF);
  if SourceMode = 0 then
  begin
    var SourceLimit := Cardinal($4000 - (D.CurrentSource and $3FFF));
    if D.CurrentSource shr 24 in [5, 7] then
      SourceLimit := $800 - (D.CurrentSource and $7FF);
    if D.CurrentSource and $FFFFF000 = $FFFF0000 then
      SourceLimit := $1000 - (D.CurrentSource and $FFF);
    Limit := Min(Limit, SourceLimit);
  end;

  Result := Min(Remaining, Limit div Cardinal(Size));
  if Result < 2 then
  begin
    Result := 0;
    Exit;
  end;

  var Bytes := Result * Cardinal(Size);
  if SourceMode = 0 then
  begin
    if (NativeUInt(Destination) > NativeUInt(Source)) and (NativeUInt(Destination) < NativeUInt(Source) + Bytes) then
    begin
      // Forward DMA overlap propagates newly written words, unlike memmove.
      for var i: Cardinal := 1 to Result do
      begin
        if Size = 4 then
          PCardinal(Destination)^ := PCardinal(Source)^
        else
          PWord(Destination)^ := PWord(Source)^;
        Inc(Source, Size);
        Inc(Destination, Size);
      end;
    end
    else
      Move(Source^, Destination^, Bytes);
    D.CurrentSource := ARMAdd(D.CurrentSource, Bytes);
  end
  else if Size = 4 then
  begin
    var Value := PCardinal(Source)^;
    for var i: Cardinal := 1 to Result do
    begin
      PCardinal(Destination)^ := Value;
      Inc(Destination, 4);
    end;
  end
  else
  begin
    var Value := PWord(Source)^;
    for var i: Cardinal := 1 to Result do
    begin
      PWord(Destination)^ := Value;
      Inc(Destination, 2);
    end;
  end;
  D.CurrentDestination := ARMAdd(D.CurrentDestination, Bytes);
end;

procedure TNDSConsole.RunDMA(CPU, Channel: Integer);
begin
  var D: PNDSDMA := @FDMA[CPU, Channel];
  D.Pending := False;
  if D.Control and $80000000 = 0 then
    Exit;

  var Count := D.Control and $1FFFFF;
  if CPU = 1 then
  begin
    Count := Count and $FFFF;
    if Channel < 3 then
      Count := Count and $3FFF;
  end;
  if Count = 0 then
    if CPU = 0 then
      Count := $200000
    else if Channel = 3 then
      Count := $10000
    else
      Count := $4000;
  var Size := 2;
  if D.Control and $04000000 <> 0 then
    Size := 4;
  var SourceMode := (D.Control shr 23) and 3;
  var DestinationMode := (D.Control shr 21) and 3;
  var Bulk := (DestinationMode in [0, 3]) and (SourceMode <> 1) and (D.CurrentDestination shr 24 in [2, 3, 5, 6, 7]);
  FDMABusy[CPU] := True;
  try
    var Remaining := Count;
    while Remaining <> 0 do
    begin
      var Copied: Cardinal := 0;
      if Bulk and (Remaining > 1) then
        Copied := CopyDMABlock(CPU, D, Remaining, Size, SourceMode, DestinationMode);
      if Copied <> 0 then
      begin
        Dec(Remaining, Copied);
        Continue;
      end;
      var Value := ReadBus(CPU, D.CurrentSource, Size);
      WriteBus(CPU, D.CurrentDestination, Value, Size);
      case SourceMode of
        0:
          D.CurrentSource := ARMAdd(D.CurrentSource, Size);
        1:
          D.CurrentSource := ARMSub(D.CurrentSource, Size);
      end;
      case DestinationMode of
        0, 3:
          D.CurrentDestination := ARMAdd(D.CurrentDestination, Size);
        1:
          D.CurrentDestination := ARMSub(D.CurrentDestination, Size);
      end;
      Dec(Remaining);
    end;
    if D.Control and $40000000 <> 0 then
      RequestIRQ(CPU, 8 + Channel);
    var RepeatTransfer := D.Control and $02000000 <> 0;
    var Timing := (D.Control shr 27) and 7;
    if CPU = 1 then
      Timing := (D.Control shr 28) and 3;
    if RepeatTransfer and (Timing <> 0) then
    begin
      if DestinationMode = 3 then
        D.CurrentDestination := D.Destination;
    end
    else
    begin
      D.Control := D.Control and $7FFFFFFF;
      PutIO32(CPU, $B8 + Channel * 12, D.Control);
      RefreshEventMasks(CPU);
    end;
  finally
    FDMABusy[CPU] := False;
  end;
end;

procedure TNDSConsole.MathUnit;

  function Signed32(V: Cardinal): Int64;
  begin
    Result := V;
    if V and $80000000 <> 0 then
      Dec(Result, $100000000);
  end;

  procedure Store64(Offset: Integer; Value: Int64);
  begin
    PutIO32(0, Offset, Cardinal(Value and $FFFFFFFF));
    PutIO32(0, Offset + 4, Cardinal(UInt64(Value) shr 32));
  end;

begin
  var Numer := Int64(UInt64(IO32(0, $290)) or (UInt64(IO32(0, $294)) shl 32));
  var Denom := Int64(UInt64(IO32(0, $298)) or (UInt64(IO32(0, $29C)) shl 32));
  var Mode := IO16(0, $280) and 3;
  if Mode = 0 then
    Numer := Signed32(Cardinal(UInt64(Numer) and $FFFFFFFF));
  if Mode <> 2 then
    Denom := Signed32(Cardinal(UInt64(Denom) and $FFFFFFFF));
  var Quotient, Remainder: Int64;
  FIO[0, $281] := FIO[0, $281] and $3F;
  if Denom = 0 then
  begin
    FIO[0, $281] := FIO[0, $281] or $40;
    Remainder := Numer;
    if Numer < 0 then
      Quotient := 1
    else
      Quotient := -1;
    if Mode = 0 then
      Quotient := Quotient xor  - Int64($100000000);
  end
  else if (Numer = Low(Int64)) and (Denom = -1) then
  begin
    Quotient := Numer;
    Remainder := 0;
  end
  else
  begin
    Quotient := Numer div Denom;
    Remainder := Numer mod Denom;
  end;
  Store64($2A0, Quotient);
  Store64($2A8, Remainder);
  var Parameter := UInt64(IO32(0, $2B8));
  if FIO[0, $2B0] and 1 <> 0 then
    Parameter := Parameter or (UInt64(IO32(0, $2BC)) shl 32);
  var Root: UInt64 := 0;
  var Bit: UInt64 := UInt64(1) shl 62;
  while Bit > Parameter do
    Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Parameter >= Root + Bit then
    begin
      Dec(Parameter, Root + Bit);
      Root := (Root shr 1) + Bit;
    end
    else
      Root := Root shr 1;
    Bit := Bit shr 2;
  end;
  PutIO32(0, $2B4, Cardinal(Root));
end;

procedure TNDSConsole.TimerDeadline(CPU: Integer);
const
  TimerShift: array[0..3] of Integer = (0, 6, 8, 10);
begin
  // Bound accumulation even when all enabled timers are cascaded and have
  // no running predecessor. This sentinel exceeds every hardware period.
  var Next: Integer := $10000000;
  for var N := 0 to 3 do
  begin
    var T: PNDSTimer := @FTimers[CPU, N];
    if (T.Control and $80 = 0) or ((N > 0) and (T.Control and 4 <> 0)) then
      Continue;
    Next := Min(Next, ((65536 - Integer(T.Counter)) shl TimerShift[T.Control and 3]) - T.Divider);
  end;
  FTimerDeadline[CPU] := Next;
end;

procedure TNDSConsole.FlushTimers(CPU: Integer);
const
  TimerShift: array[0..3] of Integer = (0, 6, 8, 10);
begin
  var Cycles := FTimerPending[CPU];
  if Cycles = 0 then
    Exit;

  FTimerPending[CPU] := 0;
  var Carry := 0;
  for var N := 0 to 3 do
  begin
    var T: PNDSTimer := @FTimers[CPU, N];
    var Pulses := 0;
    if T.Control and $80 <> 0 then
    begin
      if (N > 0) and (T.Control and 4 <> 0) then
        Pulses := Carry
      else
      begin
        Inc(T.Divider, Cycles);
        var Shift := TimerShift[T.Control and 3];
        Pulses := T.Divider shr Shift;
        T.Divider := T.Divider and ((1 shl Shift) - 1);
      end;
    end;
    Carry := 0;
    while Pulses > 0 do
    begin
      var Remaining := 65536 - Integer(T.Counter);
      if Pulses < Remaining then
      begin
        T.Counter := T.Counter + Pulses;
        Break;
      end;

      Dec(Pulses, Remaining);
      T.Counter := T.Reload;
      Inc(Carry);
      if T.Control and $40 <> 0 then
        RequestIRQ(CPU, 3 + N);
    end;
  end;
  TimerDeadline(CPU);
end;

procedure TNDSConsole.ScheduleBus;
begin
  // Level-sensitive FIFO/card DMA and geometry IRQs retain the old per-slice
  // service. Otherwise nothing observable happens before these boundaries.
  if ((FCardRemaining <> 0) and (FDMATimingMask[FCardOwner] and $20 <> 0)) or
    ((Video.Geometry.IRQMode <> 0) and (FIF[0] and $200000 = 0)) or
    (FDMATimingMask[0] and $80 <> 0) then
  begin
    FBusBudget := 1;
    Exit;
  end;

  FBusBudget := 32 - Sound.PendingCycles;
  if FLineClock < 1606 then
    FBusBudget := Min(FBusBudget, 1606 - FLineClock)
  else
    FBusBudget := Min(FBusBudget, 2130 - FLineClock);
  for var C := 0 to 1 do
    if FTimerMask[C] <> 0 then
      FBusBudget := Min(FBusBudget, FTimerDeadline[C]);
  FBusBudget := Max(1, Min(FBusBudget, RTC.CyclesUntilTick));
end;

procedure TNDSConsole.FlushBus;
begin
  var Cycles := FBusPending;
  FBusPending := 0;
  FBusBudget := 0;
  if Cycles <> 0 then
    Tick(Cycles);
end;

procedure TNDSConsole.AdvanceBus(Cycles: Integer);
begin
  if FBusBudget <= 0 then
    ScheduleBus;
  Inc(FBusPending, Cycles);
  Dec(FBusBudget, Cycles);
  if FBusBudget <= 0 then
    FlushBus;
end;

procedure TNDSConsole.Tick(Cycles: Integer);
begin
  if RTC.Tick(Cycles) then
    RequestIRQ(1, 7);
  if FCardRemaining <> 0 then
    TriggerDMA(FCardOwner, 5);
  if Video.Geometry.IRQMode <> 0 then
    RequestIRQ(0, 21);
  TriggerDMA(0, 7);
  for var C := 0 to 1 do
  begin
    if FTimerMask[C] = 0 then
      Continue;
    Inc(FTimerPending[C], Cycles);
    Dec(FTimerDeadline[C], Cycles);
    if FTimerDeadline[C] <= 0 then
      FlushTimers(C);
  end;
  Sound.Tick(Cycles);

  var OldClock := FLineClock;
  Inc(FLineClock, Cycles);
  if (OldClock < 1606) and (FLineClock >= 1606) then
  begin
    if FLine < 192 then
      Video.RenderLine(FLine);
    for var C := 0 to 1 do
      if FIO[C, 4] and $10 <> 0 then
        RequestIRQ(C, 1);
    if FLine < 192 then
      TriggerDMA(0, 2);
  end;

  if FLineClock >= 2130 then
  begin
    Dec(FLineClock, 2130);
    Inc(FLine);
    if FLine = 263 then
    begin
      FLine := 0;
      Inc(FFrameNumber);
    end;
    if FLine = 192 then
    begin
      Video.VBlank;
      Video.Geometry.SwapBuffers;
      for var C := 0 to 1 do
      begin
        if FIO[C, 4] and 8 <> 0 then
          RequestIRQ(C, 0);
        TriggerDMA(C, 1);
      end;
    end;

    // The rendering engine starts after the geometry-buffer swap, at line 214.
    // VBlank handlers and DMA must finish updating texture/palette VRAM first.
    if FLine = 214 then
      Video.Geometry.Render;
    for var C := 0 to 1 do
      if (FLine = ((IO16(C, 4) shr 8) or ((IO16(C, 4) and $80) shl 1))) and (FIO[C, 4] and $20 <> 0) then
        RequestIRQ(C, 2);
  end;
end;

procedure TNDSConsole.StepCPU(CPU: Integer);
begin
  if (FCPU[CPU].PSR and 31 = $1B) and (FCPU[CPU].R[15] = FCPU[CPU].VectorBase + 4) then
    raise ENotSupportedException.CreateFmt('Undefined NDS ARM%d instruction at %.8x', [9 - CPU * 2, ARMSub(FCPU[CPU].R[14], 4)]);

  FCodeAccess[CPU] := False;
  var Pending := FIE[CPU] and FIF[CPU] <> 0;
  if Pending then
    FHalted[CPU] := False;
  if FWaitMask[CPU] <> 0 then
  begin
    var Address: Cardinal := $0380FFF8;
    if CPU = 0 then
      Address := (FDTCMControl and $FFFFF000) + $3FF8;
    var Flags := ReadBus(CPU, Address, 4);
    if Flags and FWaitMask[CPU] <> 0 then
    begin
      WriteBus(CPU, Address, Flags and not FWaitMask[CPU], 4);
      FWaitMask[CPU] := 0;
    end;

    // Let interrupts execute while IntrWait is sleeping.
    if (FWaitMask[CPU] <> 0) and (FCPU[CPU].PSR and 31 <> $12) and not (Pending and (FIME[CPU] <> 0)) then
    begin
      Inc(FCPUTime[CPU], 32);
      Exit;
    end;
  end;

  if FHalted[CPU] then
  begin
    Inc(FCPUTime[CPU], 32);
    Exit;
  end;

  var Cycles := Max(1, FCPU[CPU].Step(Pending and (FIME[CPU] <> 0)));
  Inc(FCPUTime[CPU], Cycles * (CPU + 1));
end;

procedure TNDSConsole.Step;
begin
  if FCPUTime[0] <= FCPUTime[1] then
    StepCPU(0)
  else
    StepCPU(1);
  var Now := SharedClock;
  while Now > FBusTime do
  begin
    var Slice := Min(Int64(16), Now - FBusTime);
    AdvanceBus(Slice);
    Inc(FBusTime, Slice);
  end;
end;

function TNDSConsole.SharedClock: Int64;
begin
  Result := FCPUTime[0];
  if Result > FCPUTime[1] then
    Result := FCPUTime[1];

  // Processor timestamps are nonnegative. Avoid signed Int64 division in
  // the Win32 instruction loop while retaining exactly the same bus clock.
  Result := Result shr 1;
end;

procedure TNDSConsole.RunFrame;
begin
  Sound.BeginFrame;
  var Target := FFrameNumber + 1;
  while FFrameNumber < Target do
    Step;
  Sound.Flush;
end;

procedure TNDSConsole.SetInput(const Buttons: TEmulatorButtons);
const
  Bits: array[TEmulatorButton] of Word = ($40, $80, $20, $10, 1, 2, 4, 8, $200, 0, 0, $100, 0);
begin
  FKeys := $3FF;
  FExtKeys := $7F;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    if B in Buttons then
      FKeys := FKeys and not Bits[B];
  if TEmulatorButton.X in Buttons then
    FExtKeys := FExtKeys and not Byte(1);
  if TEmulatorButton.Y in Buttons then
    FExtKeys := FExtKeys and not Byte(2);
  if FPen then
    FExtKeys := FExtKeys and not Byte($40);
  for var C := 0 to 1 do
  begin
    var Control := IO16(C, $132);
    var Selected := Control and $3FF;
    var Match := (not FKeys and Selected) <> 0;
    if Control and $8000 <> 0 then
      Match := (not FKeys and Selected) = Selected;
    if Match and (Control and $4000 <> 0) then
      RequestIRQ(C, 12);
  end;
end;

procedure TNDSConsole.SetTouch(X, Y: Integer; Pressed: Boolean);
begin
  FTouchX := EnsureRange(X, 0, 255);
  FTouchY := EnsureRange(Y, 0, 191);
  FPen := Pressed;
  if Pressed then
    FExtKeys := FExtKeys and not Byte($40)
  else
    FExtKeys := FExtKeys or $40;
end;

function TNDSConsole.BIOSCall9(Address, R0, R1, R2: Cardinal): Cardinal;
begin
  Result := BIOSCall(0, Address, R0, R1, R2);
end;

function TNDSConsole.BIOSCall7(Address, R0, R1, R2: Cardinal): Cardinal;
begin
  Result := BIOSCall(1, Address, R0, R1, R2);
end;

function TNDSConsole.BIOSCall(CPU: Integer; Address, R0, R1, R2: Cardinal): Cardinal;
begin
  if FCallbackDepth >= 8 then
    raise EReadError.Create('NDS BIOS callback nesting limit exceeded');

  Inc(FCallbackDepth);
  var C := FCPU[CPU];
  var Saved: TARMCheckpoint;
  C.Capture(Saved);
  try
    C.SetStatus((C.PSR and $F80000C0) or $1F or ((Address and 1) shl 5));
    var ReturnAddress := C.VectorBase + $300;
    C.R[0] := R0;
    C.R[1] := R1;
    C.R[2] := R2;
    C.R[14] := ReturnAddress;
    C.R[15] := Address and $FFFFFFFE;
    for var i := 1 to 65536 do
    begin
      if C.R[15] = ReturnAddress then
        Exit(C.R[0]);

      StepCPU(CPU);

      // The other processor and peripherals keep running while a callback
      // polls IPC, the game card, timers or firmware SPI.
      if FCallbackDepth = 1 then
      begin
        while FCPUTime[1 - CPU] < FCPUTime[CPU] do
          StepCPU(1 - CPU);
        var Now := SharedClock;
        while Now > FBusTime do
        begin
          var Slice := Min(Int64(16), Now - FBusTime);
          AdvanceBus(Slice);
          Inc(FBusTime, Slice);
        end;
      end;
    end;
    raise EReadError.CreateFmt('NDS BIOS callback did not return (%.8x)', [Address]);
  finally
    Saved.PipelineValid := False;
    C.Restore(Saved);
    Dec(FCallbackDepth);
  end;
end;

procedure TNDSConsole.SWI9(Number: Byte);
begin
  SoftwareInterrupt(0, Number);
end;

procedure TNDSConsole.SWI7(Number: Byte);
begin
  SoftwareInterrupt(1, Number);
end;

function TNDSConsole.DiagnosticState: string;
begin
  FCodeAccess[0] := False;
  Result := Format('cp15=%.8x dtcm=%.8x wait9=%.8x wait7=%.8x halt9=%d halt7=%d flags9=%.8x flags7=%.8x counter=%.8x times=%d/%d',
    [FCPControl, FDTCMControl, FWaitMask[0], FWaitMask[1], Ord(FHalted[0]), Ord(FHalted[1]),
      ReadBus(0, (FDTCMControl and $FFFFF000) + $3FF8, 4), ReadBus(1, $0380FFF8, 4), ReadBus(0, $027FFC3C, 4), FCPUTime[0], FCPUTime[1]]);
end;

procedure TNDSConsole.SoftwareInterrupt(CPU, Number: Integer);
begin
  var C := FCPU[CPU];
  FCodeAccess[CPU] := False;
  case Number of
    0:
      begin
        var Entry := ReadBus(CPU, $027FFE24 + Cardinal(CPU) * $10, 4);
        C.Reset;
        if CPU = 0 then
        begin
          FillChar(FDTCM[$3E00], $200, 0);
          FCPControl := $12078;
          C.VectorBase := $FFFF0000;
          C.SetStatus($D3);
          C.R[13] := $00803FC0;
          C.SetStatus($D2);
          C.R[13] := $00803FA0;
          C.SetStatus($DF);
          C.R[13] := $00803EC0;
        end
        else
        begin
          FillChar(FPrivate[$FE00], $200, 0);
          C.SetStatus($D3);
          C.R[13] := $0380FFDC;
          C.SetStatus($D2);
          C.R[13] := $0380FFB0;
          C.SetStatus($DF);
          C.R[13] := $0380FF00;
        end;
        C.R[14] := Entry;
        C.R[15] := Entry and $FFFFFFFE;
        if Entry and 1 <> 0 then
          C.SetStatus($FF);
        FHalted[CPU] := False;
        FWaitMask[CPU] := 0;
      end;
    3:
      begin
        var Count := Max(Int64(1), Int64(Integer(C.R[0])));
        var Cycles := 4;
        if (CPU = 0) and (FCPControl and $1000 = 0) then
          Cycles := 16;
        Inc(FCPUTime[CPU], Count * Cycles * (CPU + 1));
        if Integer(C.R[0]) > 0 then
          C.R[0] := 0
        else
          C.R[0] := ARMSub(C.R[0], 1);
      end;
    4, 5:
      begin
        var Mask := C.R[1];
        if Number = 5 then
          Mask := 1;
        var Address: Cardinal := $0380FFF8;
        if CPU = 0 then
          Address := (FDTCMControl and $FFFFF000) + $3FF8;
        if (C.R[0] <> 0) or (Number = 5) then
          WriteBus(CPU, Address, ReadBus(CPU, Address, 4) and not Mask, 4);
        FWaitMask[CPU] := Mask;
        FIME[CPU] := 1;
      end;
    6, 7:
      FHalted[CPU] := True;
    8:
      Sound.Bias := Ord(C.R[0] <> 0) * $200;
    9:
      begin
        var N := Int64(Integer(C.R[0]));
        var D := Int64(Integer(C.R[1]));
        if D = 0 then
        begin
          C.R[0] := $FFFFFFFF;
          if N < 0 then
            C.R[0] := 1;
          C.R[1] := Cardinal(N and $FFFFFFFF);
        end
        else
        begin
          C.R[0] := Cardinal((N div D) and $FFFFFFFF);
          C.R[1] := Cardinal((N mod D) and $FFFFFFFF);
        end;
        C.R[3] := C.R[0];
        if C.R[3] and $80000000 <> 0 then
          C.R[3] := ARMSub(0, C.R[3]);
      end;
    $B, $C:
      begin
        var Size := 2;
        if (Number = $C) or (C.R[2] and $04000000 <> 0) then
          Size := 4;
        var Count := C.R[2] and $1FFFFF;
        var Source := C.R[0] and not Cardinal(Size - 1);
        var Destination := C.R[1] and not Cardinal(Size - 1);
        var Fill := C.R[2] and $01000000 <> 0;
        var Value: Cardinal := 0;
        for var i: Cardinal := 1 to Count do
        begin
          if not Fill or (i = 1) then
            Value := ReadBus(CPU, Source, Size);
          WriteBus(CPU, Destination, Value, Size);
          if not Fill then
            Inc(Source, Size);
          Inc(Destination, Size);
        end;
      end;
    $D:
      C.R[0] := Trunc(Sqrt(C.R[0]));
    $E:
      begin
        var CRC := C.R[0] and $FFFF;
        if C.R[2] <> 0 then
          for var i: Cardinal := 0 to C.R[2] - 1 do
          begin
            CRC := CRC xor ReadBus(CPU, C.R[1] + i, 1);
            for var Bit := 0 to 7 do
              if CRC and 1 <> 0 then
                CRC := (CRC shr 1) xor $A001
              else
                CRC := CRC shr 1;
          end;
        C.R[0] := CRC;
      end;
    $F:
      C.R[0] := 0;
    $10..$16, $18:
      if CPU = 0 then
        TNDSBIOS.Unpack(Number, C, Read9, Write9, BIOSCall9)
      else
        TNDSBIOS.Unpack(Number, C, Read7, Write7, BIOSCall7);
    $1A:
      C.R[0] := Trunc(Sin((C.R[0] and 63) * Pi / 128) * 32768);
    $1B:
      C.R[0] := Trunc((Power(2, (C.R[0] mod 768) / 768) - 1) * 65536);
    $1C:
      begin
        var Attenuation := 723 - Integer(Min(C.R[0], Cardinal(723)));
        if Attenuation >= 240 then
          Dec(Attenuation, 240)
        else if Attenuation >= 120 then
          Dec(Attenuation, 120)
        else if Attenuation >= 60 then
          Dec(Attenuation, 60);
        C.R[0] := EnsureRange(Round(127 * Power(10, -Attenuation / 200.0)), 0, 127);
      end;
    $1F:
      if CPU = 0 then
        WriteBus(0, $04000300, C.R[0], 1)
      else
        FHalted[CPU] := True;
  else
    raise ENotSupportedException.CreateFmt('NDS ARM%d BIOS SWI %.2x is not implemented', [9 - CPU * 2, Number]);
  end;
end;

procedure TNDSConsole.SerializeState(State: TStateArchive);
begin
  if State.Loading then
  begin
    FBusPending := 0;
    FBusBudget := 0;
  end
  else
    FlushBus;
  if State.Loading then
    FillChar(FTimerPending, SizeOf(FTimerPending), 0)
  else
  begin
    FlushTimers(0);
    FlushTimers(1);
  end;
  var Version: Cardinal := 2;
  State.Field(Version, SizeOf(Version));
  if not (Version in [1, 2]) then
    raise EReadError.Create('Unsupported NDS snapshot layout');

  State.Field(FMain, SizeOf(FMain));
  State.Field(FShared, SizeOf(FShared));
  State.Field(FPrivate, SizeOf(FPrivate));
  State.Field(FITCM, SizeOf(FITCM));
  State.Field(FDTCM, SizeOf(FDTCM));
  State.Field(FBIOS9, SizeOf(FBIOS9));
  State.Field(FBIOS7, SizeOf(FBIOS7));
  State.Field(FIO, SizeOf(FIO));
  State.Field(FFIFOControl, SizeOf(FFIFOControl));
  State.Field(FFIFOIRQ, SizeOf(FFIFOIRQ));
  State.Field(FIME, SizeOf(FIME));
  State.Field(FIE, SizeOf(FIE));
  State.Field(FIF, SizeOf(FIF));
  State.Field(FWaitMask, SizeOf(FWaitMask));
  State.Field(FHalted, SizeOf(FHalted));
  State.Field(FCodeAccess, SizeOf(FCodeAccess));
  State.Field(FDMABusy, SizeOf(FDMABusy));
  State.Field(FCPUTime, SizeOf(FCPUTime));
  State.Field(FBusTime, SizeOf(FBusTime));
  State.Field(FCPControl, SizeOf(FCPControl));
  State.Field(FDTCMControl, SizeOf(FDTCMControl));
  State.Field(FITCMControl, SizeOf(FITCMControl));
  State.Field(FCPRegs, SizeOf(FCPRegs));
  State.Field(FWRAM, SizeOf(FWRAM));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineClock, SizeOf(FLineClock));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  State.Field(FKeys, SizeOf(FKeys));
  State.Field(FExtKeys, SizeOf(FExtKeys));
  State.Field(FTouchX, SizeOf(FTouchX));
  State.Field(FTouchY, SizeOf(FTouchY));
  State.Field(FPen, SizeOf(FPen));
  State.Field(FSPIPosition, SizeOf(FSPIPosition));
  State.Field(FSPIAddress, SizeOf(FSPIAddress));
  State.Field(FSPICommand, SizeOf(FSPICommand));
  State.Field(FTSCValue, SizeOf(FTSCValue));
  State.Field(FPowerRegisters, SizeOf(FPowerRegisters));
  State.Field(FFirmwareStatus, SizeOf(FFirmwareStatus));
  State.Field(FFirmwareWriting, SizeOf(FFirmwareWriting));
  State.Field(FCardRemaining, SizeOf(FCardRemaining));
  State.Field(FCardAddress, SizeOf(FCardAddress));
  State.Field(FCardCommand, SizeOf(FCardCommand));
  State.Field(FCardOwner, SizeOf(FCardOwner));
  State.Field(FFirmware[0], Length(FFirmware));
  for var C := 0 to 1 do
  begin
    FCPU[C].SerializeState(State);
    for var N := 0 to 3 do
    begin
      State.Field(FTimers[C, N].Reload, SizeOf(FTimers[C, N].Reload));
      State.Field(FTimers[C, N].Counter, SizeOf(FTimers[C, N].Counter));
      State.Field(FTimers[C, N].Control, SizeOf(FTimers[C, N].Control));
      State.Field(FTimers[C, N].Divider, SizeOf(FTimers[C, N].Divider));
      State.Field(FDMA[C, N].Source, SizeOf(FDMA[C, N].Source));
      State.Field(FDMA[C, N].Destination, SizeOf(FDMA[C, N].Destination));
      State.Field(FDMA[C, N].Control, SizeOf(FDMA[C, N].Control));
      State.Field(FDMA[C, N].CurrentSource, SizeOf(FDMA[C, N].CurrentSource));
      State.Field(FDMA[C, N].CurrentDestination, SizeOf(FDMA[C, N].CurrentDestination));
      State.Field(FDMA[C, N].Pending, SizeOf(FDMA[C, N].Pending));
      if State.Loading and ((FTimers[C, N].Divider < 0) or (FTimers[C, N].Divider > 1023)) then
        raise EReadError.Create('Invalid NDS snapshot timer phase');
    end;

    State.Field(FFIFO[C].Words, SizeOf(FFIFO[C].Words));
    State.Field(FFIFO[C].Head, SizeOf(FFIFO[C].Head));
    State.Field(FFIFO[C].Count, SizeOf(FFIFO[C].Count));
    State.Field(FFIFO[C].Last, SizeOf(FFIFO[C].Last));
    if State.Loading and ((FFIFO[C].Head < 0) or (FFIFO[C].Head > 15) or (FFIFO[C].Count < 0) or (FFIFO[C].Count > 16) or
      (FCPUTime[C] < 0) or (FCPUTime[C] > High(Int64) - $100000000) or FDMABusy[C]) then
      raise EReadError.Create('Invalid NDS snapshot scheduler or FIFO');
  end;

  Cartridge.SerializeState(State);
  Video.SerializeState(State, Version);
  Sound.SerializeState(State);
  RTC.SerializeState(State);
  if State.Loading then
  begin
    RefreshEventMasks(0);
    RefreshEventMasks(1);
    TimerDeadline(0);
    TimerDeadline(1);
    if (FWRAM > 3) or (FFrameNumber = High(UInt64)) or (FLine < 0) or (FLine >= 263) or (FLineClock < 0) or (FLineClock >= 2130) or
      (FCardOwner < 0) or (FCardOwner > 1) or (FCardRemaining > $4000) or (FCardRemaining and 3 <> 0) or
      (FCardCommand < 0) or (FCardCommand > 255) or (FSPIPosition < 0) or (FSPIPosition > $1000000) or
      (FSPICommand < 0) or (FSPICommand > 255) or (FSPIAddress < 0) or (FTouchX < 0) or (FTouchX > 255) or
      (FTouchY < 0) or (FTouchY > 191) or (FBusTime < 0) or (FBusTime > SharedClock) then
      raise EReadError.Create('Invalid NDS snapshot hardware state');

    if FCPControl and $2000 <> 0 then
      FCPU[0].VectorBase := $FFFF0000
    else
      FCPU[0].VectorBase := 0;
  end;
end;

end.

