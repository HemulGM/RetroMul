unit DC.Holly;

// Holly system block (005F6800..005F7FFF): interrupt registers, TA paths in
// area 4 and the DMA engines: SH-4 channel 2 (DDT) to the TA, sort DMA, PVR
// DMA, G1 GD-ROM DMA, the four G2 channels and Maple DMA. Transfers move data
// when started; completion interrupts follow after a nominal bus time.
// References: Marcus Comstedt's Dreamcast pages, KallistiOS asic/g2/maple.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, HW.SH4.Periph, DC.Types, DC.Memory, DC.Scheduler,
  DC.Interrupts, DC.PVR, DC.GDROM, DC.AICA, DC.Maple;

type
  TDCHollyState = record
    Regs: array[0..$5FF] of Cardinal; // 005F6800..005F7FFF
    // G2 channel completion times (DCNever: idle).
    G2Due: array[0..3] of Int64;
    MapleBusy, PVRDMABusy, Ch2Busy, SortBusy, GDBusy: Boolean;
  end;

  TDCHolly = class
  private
    FMemory: TDCMemory;
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
    FPeriph: TSH4Periph;
    FPVR: TDCPVR;
    FGDROM: TDCGDROM;
    FAICA: TDCAICA;
    FMaple: TDCMaple;
    function Reg(Address: Cardinal): Cardinal;
    procedure SetReg(Address, Value: Cardinal);
    procedure StartCh2;
    procedure StartSort;
    procedure StartPVRDMA;
    procedure StartGDDMA;
    procedure StartG2(Channel: Integer);
    procedure StartMaple;
    procedure ScheduleG2;
    function RAMPointer(Address: Cardinal): PByte; inline;
  public
    S: TDCHollyState;
    // SB_SFRES written with 7611h.
    OnSoftReset: procedure of object;
    constructor Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts; Periph: TSH4Periph;
      PVR: TDCPVR; GDROM: TDCGDROM; AICA: TDCAICA; Maple: TDCMaple);
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    // Area 4 (10000000..13FFFFFF) writes from the SH-4, store queues or DMA.
    procedure WriteArea4(Address: Cardinal; Data: PCardinal; Count: Integer);
    function ReadArea4(Address: Cardinal; Size: Integer): Cardinal;
    procedure VBlank;
    procedure Event(Kind: TDCEvent);
    // The registers a finished GD-ROM DMA leaves (the boot ROM's loads).
    procedure SetGDDMAEnd(Address, Length: Cardinal);
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  SBBase = $005F6800;
  SB_C2DSTAT = $005F6800;
  SB_C2DLEN = $005F6804;
  SB_C2DST = $005F6808;
  SB_SDSTAW = $005F6810;
  SB_SDBAAW = $005F6814;
  SB_SDWLT = $005F6818;
  SB_SDLAS = $005F681C;
  SB_SDST = $005F6820;
  SB_SDDIV = $005F6824;
  SB_TFREM = $005F6880;
  SB_LMMODE0 = $005F6884;
  SB_LMMODE1 = $005F6888;
  SB_FFST = $005F688C;
  SB_SFRES = $005F6890;
  SB_SBREV = $005F689C;
  SB_ISTNRM = $005F6900;
  SB_ISTEXT = $005F6904;
  SB_ISTERR = $005F6908;
  SB_IML2NRM = $005F6910;
  SB_MDSTAR = $005F6C04;
  SB_MDTSEL = $005F6C10;
  SB_MDEN = $005F6C14;
  SB_MDST = $005F6C18;
  SB_GDSTAR = $005F7404;
  SB_GDLEN = $005F7408;
  SB_GDDIR = $005F740C;
  SB_GDEN = $005F7414;
  SB_GDST = $005F7418;
  SB_GDSTARD = $005F74F4;
  SB_GDLEND = $005F74F8;
  SB_ADSTAG = $005F7800;
  SB_ADSTAGD = $005F78C0;
  SB_PDSTAP = $005F7C00;
  SB_PDSTAR = $005F7C04;
  SB_PDLEN = $005F7C08;
  SB_PDDIR = $005F7C0C;
  SB_PDEN = $005F7C14;
  SB_PDST = $005F7C18;

constructor TDCHolly.Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts;
  Periph: TSH4Periph; PVR: TDCPVR; GDROM: TDCGDROM; AICA: TDCAICA; Maple: TDCMaple);
begin
  inherited Create;
  FMemory := Memory;
  FScheduler := Scheduler;
  FInterrupts := Interrupts;
  FPeriph := Periph;
  FPVR := PVR;
  FGDROM := GDROM;
  FAICA := AICA;
  FMaple := Maple;
  Reset;
end;

procedure TDCHolly.Reset;
begin
  S := Default(TDCHollyState);
  for var I := 0 to 3 do
    S.G2Due[I] := DCNever;
end;

function TDCHolly.Reg(Address: Cardinal): Cardinal;
begin
  Result := S.Regs[((Address - SBBase) shr 2) and $5FF];
end;

procedure TDCHolly.SetReg(Address, Value: Cardinal);
begin
  S.Regs[((Address - SBBase) shr 2) and $5FF] := Value;
end;

function TDCHolly.RAMPointer(Address: Cardinal): PByte;
begin
  Result := FMemory.RAM + (Address and (DCRAMSize - 1));
end;

{ Area 4 }

procedure TDCHolly.WriteArea4(Address: Cardinal; Data: PCardinal; Count: Integer);
begin
  Address := Address and $03FFFFFF;
  if Address < $01000000 then
  begin
    // 10000000: polygon FIFO; 10800000: YUV converter (both mirrored at 12000000).
    if (Address and $00800000) = 0 then
      FPVR.WriteFIFOBurst(Data, Count)
    else
      FPVR.WriteYUV(Data, Count);
    Exit;
  end;
  if (Address and $02000000) <> 0 then
    Exit;
  // 11000000/13000000: direct texture path, 64- or 32-bit by LMMODE0/1.
  var Mode := Reg(SB_LMMODE0);
  if (Address and $01000000) <> 0 then
    if (Address shr 25) and 1 <> 0 then
      Mode := Reg(SB_LMMODE1);
  var Offset := Address and $00FFFFFF;
  for var I := 0 to Count - 1 do
  begin
    if (Mode and 1) = 0 then
      FMemory.VRAMWrite64Path(Offset, Data[I], 4)
    else
      FMemory.VRAMWrite32(Offset, Data[I]);
    Inc(Offset, 4);
  end;
end;

function TDCHolly.ReadArea4(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
end;

{ DMA }

procedure TDCHolly.StartCh2;
begin
  // SH-4 DMAC channel 2 in DDT mode supplies the source and enable bits.
  var Channel := FPeriph.S.DMA[2];
  var Dest := Reg(SB_C2DSTAT);
  var Length := Reg(SB_C2DLEN);
  if (FPeriph.S.DMAOR and 1) = 0 then
    Exit;
  var Source := Channel.SAR and $1FFFFFE0;
  if Length = 0 then
    Length := $1000000;
  Length := Length and $FFFFE0;
  // Source must be system RAM.
  var Remaining := Length;
  var Address := Source;
  var Buffer: array[0..7] of Cardinal;
  while Remaining > 0 do
  begin
    Move(RAMPointer(Address)^, Buffer[0], 32);
    WriteArea4(Dest, @Buffer[0], 8);
    Inc(Address, 32);
    // The TA FIFO address stays; the texture path advances.
    if (Dest and $01000000) <> 0 then
      Inc(Dest, 32);
    Dec(Remaining, 32);
  end;
  FPeriph.S.DMA[2].SAR := Channel.SAR + Length;
  SetReg(SB_C2DSTAT, Dest);
  SetReg(SB_C2DLEN, 0);
  S.Ch2Busy := True;
  SetReg(SB_C2DST, 1);
  FScheduler.Schedule(TDCEvent.Ch2DMA, FScheduler.Now + Int64(Length) div 2 + 64);
end;

procedure TDCHolly.StartSort;
begin
  // Start-link table entries select chains of TA parameter blocks: a block's
  // word 6 counts its 32-byte units (0: 256) and word 7 links the next one.
  // Link 2 ends a chain, start link 1 ends the table.
  var Table := Reg(SB_SDSTAW);
  var BaseAddress := Reg(SB_SDBAAW);
  var Wide := (Reg(SB_SDWLT) and 1) <> 0;
  var Shift := (Reg(SB_SDLAS) and 1) <> 0;
  var Divider := 0;
  var Units: Int64 := 0;
  for var Guard := 0 to 65535 do
  begin
    var Link: Cardinal;
    if Wide then
      Link := PCardinal(RAMPointer(Table + Cardinal(Divider) * 4))^
    else
      Link := PWord(RAMPointer(Table + Cardinal(Divider) * 2))^;
    Inc(Divider);
    if Link = 1 then
      Break;
    var Steps := 0;
    while (Link <> 2) and (Steps < 65536) do
    begin
      Inc(Steps);
      if Shift then
        Link := Link * 32;
      var Block := (BaseAddress + Link) and (DCRAMSize - 1) and $FFFFE0;
      var Count := PCardinal(RAMPointer(Block + $18))^ and $FF;
      if Count = 0 then
        Count := 256;
      Link := PCardinal(RAMPointer(Block + $1C))^;
      for var U := 0 to Integer(Count) - 1 do
      begin
        var Data: array[0..7] of Cardinal;
        Move(RAMPointer(Block + Cardinal(U) * 32)^, Data[0], 32);
        FPVR.WriteFIFOBurst(@Data[0], 8);
      end;
      Inc(Units, Count);
    end;
  end;
  SetReg(SB_SDDIV, Divider);
  S.SortBusy := True;
  SetReg(SB_SDST, 1);
  FScheduler.Schedule(TDCEvent.SortDMA, FScheduler.Now + Units * 16 + 64);
end;

procedure TDCHolly.StartPVRDMA;
begin
  if (Reg(SB_PDEN) and 1) = 0 then
    Exit;
  var PVRAddress := Reg(SB_PDSTAP) and $01FFFFE0;
  var RAMAddress := Reg(SB_PDSTAR) and $1FFFFFE0;
  var Length := Reg(SB_PDLEN) and $FFFFE0;
  var ToRAM := (Reg(SB_PDDIR) and 1) <> 0;
  var Offset := PVRAddress and $00FFFFFF;
  var Path32 := (PVRAddress and $01000000) <> 0;
  var Remaining := Length;
  while Remaining > 0 do
  begin
    var P := PCardinal(RAMPointer(RAMAddress));
    if ToRAM then
    begin
      if Path32 then
        P^ := FMemory.VRAMRead32(Offset)
      else
        P^ := Cardinal(FMemory.VRAMRead64Path(Offset, 4));
    end
    else if Path32 then
      FMemory.VRAMWrite32(Offset, P^)
    else
      FMemory.VRAMWrite64Path(Offset, P^, 4);
    Inc(RAMAddress, 4);
    Inc(Offset, 4);
    Dec(Remaining, 4);
  end;
  if ToRAM then
    FMemory.TouchRAM(Reg(SB_PDSTAR), Length);
  SetReg(SB_PDSTAP, Reg(SB_PDSTAP) + Length);
  SetReg(SB_PDSTAR, Reg(SB_PDSTAR) + Length);
  SetReg(SB_PDLEN, 0);
  S.PVRDMABusy := True;
  SetReg(SB_PDST, 1);
  FScheduler.Schedule(TDCEvent.PVRDMA, FScheduler.Now + Int64(Length) div 2 + 64);
end;

procedure TDCHolly.StartGDDMA;
begin
  if (Reg(SB_GDEN) and 1) = 0 then
    Exit;
  var Address := Reg(SB_GDSTAR) and $1FFFFFE0;
  var Length := Reg(SB_GDLEN);
  var Moved := 0;
  if (Reg(SB_GDDIR) and 1) <> 0 then
  begin
    var Buffer: TBytes;
    SetLength(Buffer, Length);
    if Length > 0 then
      Moved := FGDROM.DMARead(@Buffer[0], Length);
    // Programs also load sound data straight into the AICA's wave RAM.
    if (Address >= $00800000) and (Address < $00A00000) then
    begin
      for var I := 0 to Moved div 4 - 1 do
        FAICA.WriteRAM(Address - $00800000 + Cardinal(I) * 4, PCardinal(@Buffer[I * 4])^, 4);
    end
    else
    begin
      for var I := 0 to Moved - 1 do
        RAMPointer(Address + Cardinal(I))^ := Buffer[I];
      FMemory.TouchRAM(Address, Moved);
    end;
  end;
  SetReg(SB_GDSTARD, Address + Cardinal(Moved));
  SetReg(SB_GDLEND, Moved);
  S.GDBusy := True;
  SetReg(SB_GDST, 1);
  FScheduler.Schedule(TDCEvent.GDDMA, FScheduler.Now + Int64(Moved) * 12 + 256);
end;

procedure TDCHolly.StartG2(Channel: Integer);
begin
  var Base := SB_ADSTAG + Cardinal(Channel) * $20;
  if (Reg(Base + $14) and 1) = 0 then
    Exit;
  var G2Address := Reg(Base) and $1FFFFFE0;
  var RAMAddress := Reg(Base + 4) and $1FFFFFE0;
  var Length := Reg(Base + 8) and $7FFFFFE0;
  var ToRAM := (Reg(Base + $C) and 1) <> 0;
  var Remaining := Length;
  while Remaining > 0 do
  begin
    var P := PCardinal(RAMPointer(RAMAddress));
    // AICA wave RAM at 00800000, registers at 00700000; other G2 targets are absent.
    if (G2Address >= $00800000) and (G2Address < $00A00000) then
    begin
      if ToRAM then
        P^ := FAICA.ReadRAM(G2Address - $00800000, 4)
      else
        FAICA.WriteRAM(G2Address - $00800000, P^, 4);
    end
    else if (G2Address >= $00700000) and (G2Address < $00708000) then
    begin
      if ToRAM then
        P^ := FAICA.ReadRegister(G2Address - $00700000, 4)
      else
        FAICA.WriteRegister(G2Address - $00700000, P^, 4);
    end
    else if ToRAM then
      P^ := 0;
    Inc(G2Address, 4);
    Inc(RAMAddress, 4);
    Dec(Remaining, 4);
  end;
  if ToRAM then
    FMemory.TouchRAM(Reg(Base + 4), Length);
  SetReg(SB_ADSTAGD + Cardinal(Channel) * $10, G2Address);
  SetReg(SB_ADSTAGD + Cardinal(Channel) * $10 + 4, RAMAddress);
  SetReg(SB_ADSTAGD + Cardinal(Channel) * $10 + 8, 0);
  SetReg(Base + $18, 1);
  // DMA end mode (length bit 31) clears the enable bit.
  if (Reg(Base + 8) and $80000000) <> 0 then
    SetReg(Base + $14, 0);
  S.G2Due[Channel] := FScheduler.Now + Int64(Length) * 4 + 256;
  ScheduleG2;
end;

procedure TDCHolly.ScheduleG2;
begin
  var Next := DCNever;
  for var I := 0 to 3 do
    if S.G2Due[I] < Next then
      Next := S.G2Due[I];
  if Next = DCNever then
    FScheduler.Cancel(TDCEvent.G2DMA)
  else
    FScheduler.Schedule(TDCEvent.G2DMA, Next);
end;

procedure TDCHolly.StartMaple;
begin
  if (Reg(SB_MDEN) and 1) = 0 then
    Exit;
  var Words := FMaple.RunDMA(Reg(SB_MDSTAR) and $1FFFFFE0);
  S.MapleBusy := True;
  SetReg(SB_MDST, 1);
  // About 2 Mbit/s on the Maple bus.
  FScheduler.Schedule(TDCEvent.MapleDMA, FScheduler.Now + Int64(Words) * 3200 + 2000);
end;

procedure TDCHolly.VBlank;
begin
  // Hardware-triggered Maple DMA (SB_MDTSEL=1) starts at vertical blank.
  if ((Reg(SB_MDTSEL) and 1) <> 0) and ((Reg(SB_MDEN) and 1) <> 0) and not S.MapleBusy then
    StartMaple;
end;

procedure TDCHolly.Event(Kind: TDCEvent);
begin
  case Kind of
    TDCEvent.Ch2DMA:
      begin
        S.Ch2Busy := False;
        SetReg(SB_C2DST, 0);
        FPeriph.CompleteDMA(2);
        FInterrupts.RaiseNormal(HollyCh2DMA);
      end;
    TDCEvent.SortDMA:
      begin
        S.SortBusy := False;
        SetReg(SB_SDST, 0);
        FInterrupts.RaiseNormal(HollySortDMA);
      end;
    TDCEvent.PVRDMA:
      begin
        S.PVRDMABusy := False;
        SetReg(SB_PDST, 0);
        FInterrupts.RaiseNormal(HollyPVRDMA);
      end;
    TDCEvent.GDDMA:
      begin
        S.GDBusy := False;
        SetReg(SB_GDST, 0);
        SetReg(SB_GDLEN, 0);
        FInterrupts.RaiseNormal(HollyGDDMA);
      end;
    TDCEvent.MapleDMA:
      begin
        S.MapleBusy := False;
        SetReg(SB_MDST, 0);
        FInterrupts.RaiseNormal(HollyMapleDMA);
      end;
    TDCEvent.G2DMA:
      begin
        for var I := 0 to 3 do
          if S.G2Due[I] <= FScheduler.Now then
          begin
            S.G2Due[I] := DCNever;
            SetReg(SB_ADSTAG + Cardinal(I) * $20 + $18, 0);
            FInterrupts.RaiseNormal(HollyAICADMA + I);
          end;
        ScheduleG2;
      end;
  end;
end;

{ Registers }

function TDCHolly.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  case Address and $FFFFFFFC of
    SB_ISTNRM: Result := FInterrupts.NormalStatus;
    SB_ISTEXT: Result := FInterrupts.S.External;
    SB_ISTERR: Result := FInterrupts.S.Error;
    SB_FFST: Result := 0;
    // Free TA FIFO entries: the FIFO is always drained (8 = empty).
    SB_TFREM: Result := 8;
    SB_SBREV: Result := $0B;
    SB_IML2NRM..SB_IML2NRM + $28:
      begin
        var Index := (Address - SB_IML2NRM) shr 2;
        if (Index and 3) = 3 then
          Result := 0
        else
          Result := FInterrupts.S.Masks[Index shr 2, Index and 3];
      end;
  else
    Result := Reg(Address);
  end;
  if Size < 4 then
    Result := (Result shr ((Address and 3) * 8)) and ((Cardinal(1) shl (Size * 8)) - 1);
end;

procedure TDCHolly.Write(Address, Value: Cardinal; Size: Integer);
begin
  var Aligned := Address and $FFFFFFFC;
  if Size < 4 then
  begin
    var Shift := (Address and 3) * 8;
    var Mask := ((Cardinal(1) shl (Size * 8)) - 1) shl Shift;
    Value := (Reg(Aligned) and not Mask) or ((Value shl Shift) and Mask);
  end;
  case Aligned of
    SB_ISTNRM:
      FInterrupts.AcknowledgeNormal(Value);
    SB_ISTEXT:
      ;
    SB_ISTERR:
      FInterrupts.AcknowledgeError(Value);
    SB_IML2NRM..SB_IML2NRM + $28:
      begin
        var Index := (Aligned - SB_IML2NRM) shr 2;
        if (Index and 3) <> 3 then
          FInterrupts.SetMask(Index shr 2, Index and 3, Value);
      end;
    SB_C2DST:
      if (Value and 1) <> 0 then
        StartCh2;
    SB_SDST:
      if (Value and 1) <> 0 then
        StartSort;
    SB_PDST:
      if (Value and 1) <> 0 then
        StartPVRDMA;
    SB_GDST:
      if (Value and 1) <> 0 then
        StartGDDMA;
    SB_MDST:
      if ((Value and 1) <> 0) and not S.MapleBusy then
        StartMaple;
    SB_ADSTAG + $18, SB_ADSTAG + $38, SB_ADSTAG + $58, SB_ADSTAG + $78:
      if (Value and 1) <> 0 then
        StartG2((Aligned - SB_ADSTAG) div $20);
    SB_TFREM, SB_FFST, SB_SBREV, SB_GDSTARD, SB_GDLEND:
      ;
    SB_SFRES:
      begin
        SetReg(Aligned, Value);
        // 7611h resets the SH-4 (the boot ROM starts a disc this way).
        if ((Value and $FFFF) = $7611) and Assigned(OnSoftReset) then
          OnSoftReset;
      end;
  else
    SetReg(Aligned, Value);
  end;
end;

procedure TDCHolly.SetGDDMAEnd(Address, Length: Cardinal);
begin
  SetReg(SB_GDSTARD, Address);
  SetReg(SB_GDLEND, Length);
end;

procedure TDCHolly.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading then
    for var I := 0 to 3 do
      if S.G2Due[I] < 0 then
        raise EReadError.Create('Dreamcast snapshot G2 DMA');
end;

end.
