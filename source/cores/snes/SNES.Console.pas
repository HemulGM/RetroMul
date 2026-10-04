unit SNES.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Snapshots,
  SNES.Cartridge, SNES.CPU, SNES.PPU, SNES.SPC;

{$SCOPEDENUMS ON}

type
  TSnesButton = (Up, Down, Left, Right, A, B, Select, Start, X, Y, L, R);

  TSnesButtons = set of TSnesButton;

  TSnesSystemState = packed record
    RAM: array[0..$1FFFF] of Byte;
    IO: array[0..$1F] of Byte;
    DMA: array[0..7, 0..15] of Byte;
    HDMAAddress, HDMAIndirect: array[0..7] of Word;
    HDMALines: array[0..7] of Byte;
    HDMAActive, HDMATransfer: array[0..7] of Boolean;
    Clock: Int64;
    Line, HClock, RefreshPosition, CPUSpeed: Integer;
    FrameNumber: UInt64;
    WRAMAddress: Cardinal;
    OpenBus, NMITIMEN, PendingDMA, HDMAEnable: Byte;
    NMIFlag, IRQFlag, JoyStrobe, HBlank, HDMAPending: Boolean;
    Joy, JoyShift: array[0..1] of Word;
    JoyIndex: array[0..1] of Integer;
    MultiplyResult, DivideResult, Remainder: Word;
    AluShift: Cardinal;
    AluCycle: UInt64;
    MultCounter, DivCounter: Byte;
    AutoJoyNext: Int64;
    AutoJoyStep: Integer;
    AutoJoyActive, AutoJoyDisabled, AutoJoyStrobe: Boolean;
    AutoJoyBit: array[0..1] of Byte;
    NMICounter: Byte;
  end;

  TSnesConsole = class
  private
    FCartridge: TSnesCartridge;
    FCPU: TSnesCPU;
    FPPU: TSnesPPU;
    FSPC: TSnesSPC;
    FState: TSnesSystemState;
    FInDMA: Boolean;
    function MasterRate: Integer;
    function LineCount: Integer;
    function LineClocks: Integer;
    function BusSpeed(Address: Cardinal): Integer;
    function CPURead(Address: Cardinal): Byte;
    procedure CPUWrite(Address: Cardinal; Value: Byte);
    procedure CPUClock(Clocks: Integer);
    procedure PollNMI;
    procedure Advance(Clocks: Integer);
    procedure SyncSPC;
    procedure RunALU(IsRead: Boolean);
    procedure WriteALU(Address: Word; Value: Byte);
    procedure ProcessAutoJoy;
    procedure BeginHDMA;
    procedure RunHDMA;
    procedure RunDMA;
    procedure Transfer(Channel, Index: Integer; AAddress: Cardinal);
    function IsWorkRAM(Address: Cardinal): Boolean;
    function InvalidDMAAddress(Address: Cardinal): Boolean;
    function GetPixels: TArray<TAlphaColor>;
    function GetSamples: TArray<SmallInt>;
    function GetSampleFrames: Integer;
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetFrameNumber: UInt64;
    function GetBatteryDirty: Boolean;
  public
    constructor Create(const Data: TBytes; const Extension: string = ''; const Firmware: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure SetInput(const Buttons: TSnesButtons; const Buttons2: TSnesButtons = []);
    procedure LoadBattery(const Data: TBytes);
    procedure MarkBatteryDirty;
    function BatteryData: TBytes;
    function FramesPerSecond: Double;
    procedure SerializeState(State: TStateArchive);
    property Pixels: TArray<TAlphaColor> read GetPixels;
    property Samples: TArray<SmallInt> read GetSamples;
    property SampleFrames: Integer read GetSampleFrames;
    property Width: Integer read GetWidth;
    property Height: Integer read GetHeight;
    property FrameNumber: UInt64 read GetFrameNumber;
    property BatteryDirty: Boolean read GetBatteryDirty;
    property CPU: TSnesCPU read FCPU;
    property PPU: TSnesPPU read FPPU;
    property SPC: TSnesSPC read FSPC;
  end;

implementation

const
  DMALength: array[0..7] of Integer = (1, 2, 2, 4, 4, 4, 2, 4);
  DMAOffset: array[0..7, 0..3] of Byte = (
    (0, 0, 0, 0),
    (0, 1, 0, 1),
    (0, 0, 0, 0),
    (0, 0, 1, 1),
    (0, 1, 2, 3),
    (0, 1, 0, 1),
    (0, 0, 0, 0),
    (0, 0, 1, 1));

constructor TSnesConsole.Create(const Data: TBytes; const Extension: string; const Firmware: TBytes);
begin
  inherited Create;
  FCartridge := TSnesCartridge.Create(Data, Firmware);
  FPPU := TSnesPPU.Create;
  FSPC := TSnesSPC.Create;
  FCPU := TSnesCPU.Create(CPURead, CPUWrite, CPUClock);
  Reset;
end;

destructor TSnesConsole.Destroy;
begin
  FCPU.Free;
  FSPC.Free;
  FPPU.Free;
  FCartridge.Free;
  inherited;
end;

function TSnesConsole.MasterRate: Integer;
begin
  if FCartridge.Header.PAL then
    Result := 21281370
  else
    Result := 21477272;
end;

function TSnesConsole.LineCount: Integer;
begin
  if FCartridge.Header.PAL then
    Result := 312
  else
    Result := 262;
  if ((FPPU.State.Regs[$33] and 1) <> 0) and ((FState.FrameNumber and 1) = 0) then
    Inc(Result);
end;

function TSnesConsole.FramesPerSecond: Double;
begin
  var Lines := 262;
  if FCartridge.Header.PAL then
    Lines := 312;
  if (FPPU.State.Regs[$33] and 1) <> 0 then
    Result := MasterRate / (1364.0 * (Lines + 0.5))
  else
    Result := MasterRate / (1364.0 * Lines - 2);
end;

function TSnesConsole.LineClocks: Integer;
begin
  Result := 1364;
  if (FState.Line = 240) and ((FState.FrameNumber and 1) <> 0) and ((FPPU.State.Regs[$33] and 1) = 0) then
    Result := 1360;
end;

procedure TSnesConsole.Reset;
begin
  FState := Default(TSnesSystemState);
  FState.IO[1] := $FF;
  FState.IO[2] := $FF;
  FState.IO[4] := $FF;
  FState.IO[5] := $FF;
  FState.AutoJoyDisabled := True;
  FState.RefreshPosition := 538;
  FState.CPUSpeed := 6;
  FCartridge.Reset;
  FPPU.Reset;
  FSPC.Reset;
  FCPU.Reset;
  FInDMA := False;
end;

procedure TSnesConsole.SyncSPC;
begin
  var Rate := MasterRate;
  FSPC.RunUntil((FState.Clock div Rate) * 1024000 + (FState.Clock mod Rate) * 1024000 div Rate);
end;

procedure TSnesConsole.RunALU(IsRead: Boolean);
begin
  var Cycle := FCPU.State.Cycles;
  if IsRead and (Cycle > 0) then
    Dec(Cycle);
  if Cycle < FState.AluCycle then
    Exit;

  var Count := Cycle - FState.AluCycle;
  while (Count > 0) and ((FState.MultCounter > 0) or (FState.DivCounter > 0)) do
  begin
    Dec(Count);
    if FState.MultCounter > 0 then
    begin
      Dec(FState.MultCounter);
      if (FState.DivideResult and 1) <> 0 then
        FState.Remainder := Word(FState.Remainder + FState.AluShift);
      FState.AluShift := FState.AluShift shl 1;
      FState.DivideResult := FState.DivideResult shr 1;
    end;
    if FState.DivCounter > 0 then
    begin
      Dec(FState.DivCounter);
      FState.AluShift := FState.AluShift shr 1;
      FState.DivideResult := Word(FState.DivideResult shl 1);
      if FState.Remainder >= FState.AluShift then
      begin
        FState.Remainder := Word(FState.Remainder - FState.AluShift);
        FState.DivideResult := FState.DivideResult or 1;
      end;
    end;
  end;
  FState.AluCycle := Cycle;
end;

procedure TSnesConsole.WriteALU(Address: Word; Value: Byte);
begin
  RunALU(True);
  var Busy := (FState.MultCounter > 0) or (FState.DivCounter > 0);
  RunALU(False);
  case Address of
    $4203:
      begin
        FState.Remainder := 0;
        if not Busy then
        begin
          FState.MultCounter := 8;
          FState.AluShift := Value;
          FState.DivideResult := (Word(Value) shl 8) or FState.IO[2];
        end
        else if (FState.MultCounter = 0) and (FState.DivCounter = 0) then
          FState.DivideResult := (Word(Value) shl 8) or FState.IO[2];
      end;
    $4206:
      begin
        FState.Remainder := FState.IO[4] or (Word(FState.IO[5]) shl 8);
        if not Busy then
        begin
          FState.DivCounter := 16;
          FState.AluShift := Cardinal(Value) shl 16;
        end;
      end;
  end;
end;

procedure TSnesConsole.ProcessAutoJoy;
begin
  if FState.AutoJoyDisabled then
  begin
    if FState.AutoJoyStrobe and (FState.Clock >= FState.AutoJoyNext) then
      FState.AutoJoyStrobe := False;
    Exit;
  end;
  if FState.Clock < FState.AutoJoyNext then
    Exit;

  var Step := FState.AutoJoyStep;
  Inc(FState.AutoJoyStep);
  Inc(FState.AutoJoyNext, 128);
  case Step of
    0:
      begin
        FState.AutoJoyStrobe := (FState.NMITIMEN and 1) <> 0;
        if FState.AutoJoyStrobe then
          for var Pad := 0 to 1 do
          begin
            FState.JoyShift[Pad] := FState.Joy[Pad];
            FState.JoyIndex[Pad] := 0;
          end;
      end;
    1:
      begin
        FState.AutoJoyActive := (FState.NMITIMEN and 1) <> 0;
        FState.AutoJoyDisabled := not FState.AutoJoyActive;
        if FState.AutoJoyActive then
          FillChar(FState.IO[$18], 8, 0);
      end;
    2:
      FState.AutoJoyStrobe := False;
  else
    if (FState.NMITIMEN and 1) = 0 then
      Step := 34
    else
      for var Pad := 0 to 1 do
        if (Step and 1) <> 0 then
        begin
          if FState.JoyIndex[Pad] >= 16 then
            FState.AutoJoyBit[Pad] := 1
          else
            FState.AutoJoyBit[Pad] := (FState.JoyShift[Pad] shr (15 - FState.JoyIndex[Pad])) and 1;
          if not FState.JoyStrobe and (FState.JoyIndex[Pad] < 16) then
            Inc(FState.JoyIndex[Pad]);
        end
        else
        begin
          var V := Word((FState.IO[$18 + Pad * 2] or (Word(FState.IO[$19 + Pad * 2]) shl 8)) shl 1) or FState.AutoJoyBit[Pad];
          FState.IO[$18 + Pad * 2] := Byte(V);
          FState.IO[$19 + Pad * 2] := V shr 8;
        end;
  end;
  if Step >= 34 then
  begin
    FState.AutoJoyDisabled := True;
    FState.AutoJoyActive := False;
    FState.AutoJoyStrobe := False;
  end;
end;

function TSnesConsole.BusSpeed(Address: Cardinal): Integer;
begin
  Result := 8;
  if (Address and $408000) <> 0 then
  begin
    if (Address >= $800000) and ((FState.IO[$0D] and 1) <> 0) then
      Result := 6;
  end
  else if (Address and $FFFF) < $2000 then
    Result := 8
  else if (Address and $FFFF) < $4000 then
    Result := 6
  else if (Address and $FFFF) < $4200 then
    Result := 12
  else if (Address and $FFFF) < $6000 then
    Result := 6;
end;

function TSnesConsole.CPURead(Address: Cardinal): Byte;
begin
  PollNMI;
  FState.CPUSpeed := BusSpeed(Address);
  Advance(FState.CPUSpeed);
  Result := ReadByte(Address);
end;

procedure TSnesConsole.CPUWrite(Address: Cardinal; Value: Byte);
begin
  PollNMI;
  FState.CPUSpeed := BusSpeed(Address);
  Advance(FState.CPUSpeed);
  WriteByte(Address, Value);
end;

procedure TSnesConsole.CPUClock(Clocks: Integer);
begin
  PollNMI;
  Advance(Clocks);
end;

procedure TSnesConsole.PollNMI;
begin
  // Mesen's edge detector samples at CPU cycle boundaries, including idle cycles.
  // DMA master clocks do not advance this counter.
  if FState.NMICounter > 0 then
  begin
    Dec(FState.NMICounter);
    if FState.NMICounter = 0 then
      FCPU.State.NMI := True;
  end;
end;

procedure TSnesConsole.Advance(Clocks: Integer);
begin
  var Remaining := Clocks;
  while Remaining > 0 do
  begin
    Dec(Remaining);
    Inc(FState.Clock);
    Inc(FState.HClock);
    if FState.HClock = FState.RefreshPosition then
      Inc(Remaining, 40);
    if FState.HClock = 1096 then
    begin
      FState.HBlank := True;
      if (FState.Line > 0) and (FState.Line <= FPPU.Height) then
        FPPU.RenderLine(FState.Line - 1, (FState.FrameNumber and 1) <> 0);
    end;

    // HDMA also runs on the pre-render line0, preparing registers for visible line1.
    if (FState.HClock = 1104) and (FState.Line <= FPPU.Height) then
      FState.HDMAPending := True;
    if FState.HClock >= LineClocks then
    begin
      FState.HClock := 0;
      FState.HBlank := False;
      Inc(FState.Line);
      FState.RefreshPosition := 538 - (FState.Clock and 7);
      if FState.Line = FPPU.Height + 1 then
      begin
        FState.NMIFlag := True;
        if (FState.NMITIMEN and $80) <> 0 then
          FState.NMICounter := 1;
        // Forced blank permits OAM DMA across the start of vblank without a reset.
        if (FPPU.State.Regs[0] and $80) = 0 then
          FPPU.State.OAMAddress := FPPU.State.OAMReload;
        var Start := FState.Clock + 130;
        FState.AutoJoyNext := ((Start + 255) and not Int64(255)) - 128;
        FState.AutoJoyStep := 0;
        FState.AutoJoyDisabled := False;
      end;
      if FState.Line >= LineCount then
      begin
        FState.Line := 0;
        Inc(FState.FrameNumber);
        FState.NMIFlag := False;
        FPPU.State.Status := 0;
        BeginHDMA;
      end;
    end;
    ProcessAutoJoy;
    var IRQMode := (FState.NMITIMEN shr 4) and 3;
    if IRQMode <> 0 then
    begin
      var H := (FState.IO[7] or ((FState.IO[8] and 1) shl 8)) * 4;
      var V := FState.IO[9] or ((FState.IO[10] and 1) shl 8);
      if (((IRQMode and 1) = 0) or (FState.HClock = H)) and
        (((IRQMode and 2) = 0) or (FState.Line = V)) and
        (((IRQMode and 1) <> 0) or (FState.HClock = 0)) then
      begin
        FState.IRQFlag := True;
        FCPU.State.IRQ := True;
      end;
    end;
  end;
end;

function TSnesConsole.ReadByte(Address: Cardinal): Byte;
begin
  FCartridge.HostAccess(Address, BusSpeed(Address) = 6);
  FCartridge.SyncDSP(FState.Clock, MasterRate);
  Address := Address and $FFFFFF;
  var Bank := Address shr 16;
  var A := Address and $FFFF;
  if FCartridge.ActionReplay and (Address >= $100000) and (Address <= $10003F) then
  begin
    FState.OpenBus := FCartridge.Read(Address, FState.OpenBus);
    Exit(FState.OpenBus);
  end;
  if Bank in [$7E, $7F] then
    Result := FState.RAM[Address and $1FFFF]
  else if (Bank and $7F) < $40 then
  begin
    if A < $2000 then
      Result := FState.RAM[A]
    else
      case A of
        $2100..$213F:
          Result := FPPU.Read(Word(A), FState.OpenBus, FState.HClock, FState.Line, FCartridge.Header.PAL,
            (FState.FrameNumber and 1) <> 0, (FState.IO[1] and $80) <> 0);
        $2140..$217F:
          begin
            SyncSPC;
            Result := FSPC.State.PortsOut[A and 3];
          end;
        $2180:
          begin
            Result := FState.RAM[FState.WRAMAddress and $1FFFF];
            FState.WRAMAddress := (FState.WRAMAddress + 1) and $1FFFF;
          end;
        $4016, $4017:
          begin
            var Pad := A and 1;
            if FState.JoyStrobe or FState.AutoJoyStrobe then
            begin
              FState.JoyShift[Pad] := FState.Joy[Pad];
              FState.JoyIndex[Pad] := 0;
            end;
            if FState.JoyIndex[Pad] >= 16 then
              Result := 1
            else
              Result := (FState.JoyShift[Pad] shr (15 - FState.JoyIndex[Pad])) and 1;
            Result := Result or (FState.OpenBus and $FC);
            if not FState.JoyStrobe and not FState.AutoJoyStrobe and (FState.JoyIndex[Pad] < 16) then
              Inc(FState.JoyIndex[Pad]);
          end;
        $4210:
          begin
            Result := 2 or (Ord(FState.NMIFlag) shl 7) or (FState.OpenBus and $70);
            FState.NMIFlag := False;
          end;
        $4211:
          begin
            Result := (Ord(FState.IRQFlag) shl 7) or (FState.OpenBus and $7F);
            FState.IRQFlag := False;
            FCPU.State.IRQ := FCartridge.CoprocessorIRQ;
          end;
        $4212:
          begin
            Result := Ord(FState.Line > FPPU.Height) shl 7 or (Ord(FState.HBlank) shl 6) or (FState.OpenBus and $3E);
            if FState.AutoJoyActive then
              Result := Result or 1;
          end;
        $4213:
          Result := FState.IO[1];
        $4214..$4217:
          begin
            RunALU(True);
            if A < $4216 then
              Result := Byte(FState.DivideResult shr ((A and 1) * 8))
            else
              Result := Byte(FState.Remainder shr ((A and 1) * 8));
          end;
        $4218..$421F:
          Result := FState.IO[A - $4200];
        $4300..$437F:
          Result := FState.DMA[(A shr 4) and 7, A and 15];
      else
        Result := FCartridge.Read(Address, FState.OpenBus);
      end;
  end
  else
    Result := FCartridge.Read(Address, FState.OpenBus);
  FState.OpenBus := Result;
end;

procedure TSnesConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  FCartridge.HostAccess(Address, BusSpeed(Address) = 6);
  FCartridge.SyncDSP(FState.Clock, MasterRate);
  Address := Address and $FFFFFF;
  FState.OpenBus := Value;
  if FCartridge.ActionReplay and (Address >= $100000) and (Address <= $10003F) then
  begin
    FCartridge.Write(Address, Value);
    Exit;
  end;
  var Bank := Address shr 16;
  var A := Address and $FFFF;
  if Bank in [$7E, $7F] then
    FState.RAM[Address and $1FFFF] := Value
  else if (Bank and $7F) < $40 then
  begin
    if A < $2000 then
      FState.RAM[A] := Value
    else
      case A of
        $2100..$2133:
          begin
            // An INIDISP write on the first vblank line resets OAM if blank was active.
            if (A = $2100) and (FState.Line = FPPU.Height + 1) and ((FPPU.State.Regs[0] and $80) <> 0) then
              FPPU.State.OAMAddress := FPPU.State.OAMReload;
            FPPU.Write(Word(A), Value, FState.Line);
          end;
        $2140..$217F:
          begin
            SyncSPC;
            FSPC.State.PortsIn[A and 3] := Value;
          end;
        $2180:
          begin
            FState.RAM[FState.WRAMAddress and $1FFFF] := Value;
            FState.WRAMAddress := (FState.WRAMAddress + 1) and $1FFFF;
          end;
        $2181:
          FState.WRAMAddress := (FState.WRAMAddress and $1FF00) or Value;
        $2182:
          FState.WRAMAddress := (FState.WRAMAddress and $100FF) or (Cardinal(Value) shl 8);
        $2183:
          FState.WRAMAddress := (FState.WRAMAddress and $FFFF) or (Cardinal(Value and 1) shl 16);
        $4016:
          begin
            var Strobe := (Value and 1) <> 0;
            if FState.JoyStrobe or Strobe then
              for var Pad := 0 to 1 do
              begin
                FState.JoyShift[Pad] := FState.Joy[Pad];
                FState.JoyIndex[Pad] := 0;
              end;
            FState.JoyStrobe := Strobe;
          end;
        $4200..$420D:
          begin
            var OldIO := FState.IO[1];
            FState.IO[A - $4200] := Value;
            case A of
              $4200:
                begin
                  if ((FState.NMITIMEN and $80) = 0) and ((Value and $80) <> 0) and FState.NMIFlag then
                    FState.NMICounter := 2;
                  FState.NMITIMEN := Value;
                  if (Value and $30) = 0 then
                  begin
                    FState.IRQFlag := False;
                    FCPU.State.IRQ := FCartridge.CoprocessorIRQ;
                  end;
                end;
              $4201:
                if ((OldIO and $80) <> 0) and ((Value and $80) = 0) then
                  FPPU.LatchCounters(FState.HClock, FState.Line);
              $4202..$4206:
                WriteALU(Word(A), Value);
              $420B:
                if not FInDMA then
                  FState.PendingDMA := Value;
              $420C:
                FState.HDMAEnable := Value;
            end;
          end;
        $4300..$437F:
          begin
            FState.DMA[(A shr 4) and 7, A and 15] := Value;
            FCartridge.Write(Address, Value);
          end;
      else
        FCartridge.Write(Address, Value);
      end;
  end
  else
    FCartridge.Write(Address, Value);
end;

procedure TSnesConsole.Transfer(Channel, Index: Integer; AAddress: Cardinal);
begin
  var Mode := FState.DMA[Channel, 0];
  var BAddress := $2100 or Byte(FState.DMA[Channel, 1] + DMAOffset[Mode and 7, Index and 3]);
  if (BAddress = $2180) and IsWorkRAM(AAddress) then
  begin
    if (Mode and $80) <> 0 then
    begin
      Advance(4);
      Advance(4);
      WriteByte(AAddress, $FF);
    end
    else
      Advance(8);
    Exit;
  end;

  Advance(4);
  var Data: Byte;
  if (Mode and $80) = 0 then
  begin
    if InvalidDMAAddress(AAddress) then
      Data := FState.OpenBus
    else
      Data := ReadByte(AAddress);
    Advance(4);
    WriteByte(BAddress, Data);
  end
  else
  begin
    Data := ReadByte(BAddress);
    Advance(4);
    if not InvalidDMAAddress(AAddress) then
      WriteByte(AAddress, Data)
    else
      FState.OpenBus := Data;
  end;
end;

function TSnesConsole.IsWorkRAM(Address: Cardinal): Boolean;
begin
  Result := ((Address shr 16) in [$7E, $7F]) or (((Address shr 16 and $7F) < $40) and ((Address and $FFFF) < $2000));
end;

function TSnesConsole.InvalidDMAAddress(Address: Cardinal): Boolean;
begin
  var A := Address and $FFFF;
  Result := ((Address shr 16 and $7F) < $40) and (((A and $FF00) = $2100) or (A = $420B) or (A = $420C) or ((A >= $4300) and (A <= $437F)));
end;

procedure TSnesConsole.RunDMA;
begin
  var Mask := FState.PendingDMA;
  FState.PendingDMA := 0;
  FInDMA := True;
  try
    var Cycles := 8 - Integer(FState.Clock and 7);
    Advance(Cycles);
    Advance(8);
    Inc(Cycles, 8);
    for var Channel := 0 to 7 do
      if (Mask and (1 shl Channel)) <> 0 then
      begin
        Advance(8);
        Inc(Cycles, 8);
        var Address: Integer := FState.DMA[Channel, 2] or (Word(FState.DMA[Channel, 3]) shl 8);
        var Bank := Cardinal(FState.DMA[Channel, 4]) shl 16;
        var Count := Integer(FState.DMA[Channel, 5] or (Word(FState.DMA[Channel, 6]) shl 8));
        if Count = 0 then
          Count := 65536;
        for var J := 0 to Count - 1 do
        begin
          Transfer(Channel, J, Bank or Word(Address));
          Inc(Cycles, 8);
          if (FState.DMA[Channel, 0] and 8) = 0 then
            if (FState.DMA[Channel, 0] and $10) = 0 then
              Address := (Address + 1) and $FFFF
            else
              Address := (Address - 1) and $FFFF;
          if FState.HDMAPending then
          begin
            var ActiveMask: Byte := 0;
            for var H := 0 to 7 do
              if FState.HDMAActive[H] and ((FState.HDMAEnable and (1 shl H)) <> 0) then
                ActiveMask := ActiveMask or (1 shl H);
            RunHDMA;
            Mask := Mask and not ActiveMask;
            if (Mask and (1 shl Channel)) = 0 then
              Break;
          end;
        end;
        FState.DMA[Channel, 2] := Byte(Address);
        FState.DMA[Channel, 3] := Byte(Address shr 8);
        FState.DMA[Channel, 5] := 0;
        FState.DMA[Channel, 6] := 0;
      end;
    Advance(FState.CPUSpeed - (Cycles mod FState.CPUSpeed));
  finally
    FInDMA := False;
  end;
end;

procedure TSnesConsole.BeginHDMA;
begin
  for var C := 0 to 7 do
  begin
    FState.HDMAAddress[C] := FState.DMA[C, 2] or (Word(FState.DMA[C, 3]) shl 8);
    FState.HDMAActive[C] := (FState.HDMAEnable and (1 shl C)) <> 0;
    FState.HDMALines[C] := 0;
    FState.HDMATransfer[C] := True;
  end;
end;

procedure TSnesConsole.RunHDMA;
begin
  var WasInDMA := FInDMA;
  FState.HDMAPending := False;
  FInDMA := True;
  try
    for var C := 0 to 7 do
    begin
      if not FState.HDMAActive[C] or ((FState.HDMAEnable and (1 shl C)) = 0) then
        Continue;

      var TableBank := Cardinal(FState.DMA[C, 4]) shl 16;
      if (FState.HDMALines[C] and $7F) = 0 then
      begin
        FState.HDMALines[C] := ReadByte(TableBank or FState.HDMAAddress[C]);
        FState.HDMAAddress[C] := (Integer(FState.HDMAAddress[C]) + 1) and $FFFF;
        Advance(8);
        if FState.HDMALines[C] = 0 then
        begin
          FState.HDMAActive[C] := False;
          Continue;
        end;

        FState.HDMATransfer[C] := True;
        if (FState.DMA[C, 0] and $40) <> 0 then
        begin
          FState.HDMAIndirect[C] := ReadByte(TableBank or FState.HDMAAddress[C]);
          FState.HDMAAddress[C] := (Integer(FState.HDMAAddress[C]) + 1) and $FFFF;
          FState.HDMAIndirect[C] := FState.HDMAIndirect[C] or (Word(ReadByte(TableBank or FState.HDMAAddress[C])) shl 8);
          FState.HDMAAddress[C] := (Integer(FState.HDMAAddress[C]) + 1) and $FFFF;
          Advance(16);
        end;
      end;
      if FState.HDMATransfer[C] then
        for var J := 0 to DMALength[FState.DMA[C, 0] and 7] - 1 do
          if (FState.DMA[C, 0] and $40) <> 0 then
          begin
            Transfer(C, J, (Cardinal(FState.DMA[C, 7]) shl 16) or FState.HDMAIndirect[C]);
            FState.HDMAIndirect[C] := (Integer(FState.HDMAIndirect[C]) + 1) and $FFFF;
          end
          else
          begin
            Transfer(C, J, TableBank or FState.HDMAAddress[C]);
            FState.HDMAAddress[C] := (Integer(FState.HDMAAddress[C]) + 1) and $FFFF;
          end;
      FState.HDMATransfer[C] := (FState.HDMALines[C] and $80) <> 0;
      Dec(FState.HDMALines[C]);
      FState.DMA[C, 8] := Byte(FState.HDMAAddress[C]);
      FState.DMA[C, 9] := FState.HDMAAddress[C] shr 8;
      FState.DMA[C, 10] := FState.HDMALines[C];
    end;
  finally
    FInDMA := WasInDMA;
  end;
end;

procedure TSnesConsole.RunFrame;
begin
  var Frame := FState.FrameNumber;
  FSPC.BeginFrame;
  repeat
    FCartridge.SyncDSP(FState.Clock, MasterRate);
    FCPU.State.IRQ := FState.IRQFlag or FCartridge.CoprocessorIRQ;
    FCPU.Step;
    if FState.PendingDMA <> 0 then
      RunDMA;
    if FState.HDMAPending then
      RunHDMA;
  until FState.FrameNumber <> Frame;
  SyncSPC;
  FCartridge.SyncDSP(FState.Clock, MasterRate, True);
end;

procedure TSnesConsole.SetInput(const Buttons, Buttons2: TSnesButtons);
const
  Bits: array[TSnesButton] of Word = ($0800, $0400, $0200, $0100, $0080, $8000, $2000, $1000, $0040, $4000, $0020, $0010);
begin
  FState.Joy[0] := 0;
  FState.Joy[1] := 0;
  for var B := Low(TSnesButton) to High(TSnesButton) do
  begin
    if B in Buttons then
      FState.Joy[0] := FState.Joy[0] or Bits[B];
    if B in Buttons2 then
      FState.Joy[1] := FState.Joy[1] or Bits[B];
  end;
end;

function TSnesConsole.GetPixels: TArray<TAlphaColor>;
begin
  Result := FPPU.Pixels;
end;

function TSnesConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FSPC.Samples;
end;

function TSnesConsole.GetSampleFrames: Integer;
begin
  Result := FSPC.SampleFrames;
end;

function TSnesConsole.GetWidth: Integer;
begin
  Result := FPPU.Width;
end;

function TSnesConsole.GetHeight: Integer;
begin
  Result := FPPU.OutputHeight;
end;

function TSnesConsole.GetFrameNumber: UInt64;
begin
  Result := FState.FrameNumber;
end;

function TSnesConsole.GetBatteryDirty: Boolean;
begin
  Result := FCartridge.BatteryDirty;
end;

procedure TSnesConsole.LoadBattery(const Data: TBytes);
begin
  FCartridge.LoadBattery(Data);
end;

procedure TSnesConsole.MarkBatteryDirty;
begin
  FCartridge.MarkBatteryDirty;
end;

function TSnesConsole.BatteryData: TBytes;
begin
  Result := FCartridge.BatteryData;
end;

procedure TSnesConsole.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  FCPU.SerializeState(State);
  FPPU.SerializeState(State);
  FSPC.SerializeState(State);
  FCartridge.SerializeState(State);
  if State.Loading then
  begin
    if (FState.Line < 0) or (FState.Line >= LineCount) or (FState.HClock < 0) or (FState.HClock >= 1364) then
      raise EReadError.Create('Invalid SNES snapshot timing');

    FInDMA := False;
    MarkBatteryDirty;
  end;
end;

end.

