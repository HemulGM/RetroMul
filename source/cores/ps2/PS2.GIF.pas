unit PS2.GIF;

// GS interface: GIF tags in PACKED, REGLIST and IMAGE modes for the three
// paths (PATH1 from VU1 XGKICK, PATH2 from VIF1 DIRECT, PATH3 from DMA
// channel 2 or the FIFO), each with its own tag state so that packets of
// different paths may alternate between whole packets; the GIF registers
// (CTRL, MODE, STAT, TAG0-3, CNT, P3CNT, P3TAG) and PATH3 masking. Masking
// takes effect between packets: once unmasked, PATH3 DMA moves to the end of
// a packet and only goes on after that packet's transfer time, so a mask set
// again right away (VIF1 MSKPATH3 1 after MSKPATH3 0) lets exactly one packet
// through, as programs that interleave texture uploads with drawing expect.
// References: EE User's Manual (GIF chapter), GS User's Manual, ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS2.Types, PS2.EE.Bus, PS2.DMAC, PS2.GS;

type
  TPS2GIFPathState = record
    Tag: TPS2Reg128;
    Active: Boolean;
    NLoop, NReg, Flg, Reg, Loop: Integer;
    Regs: UInt64;
    Q: Cardinal;
    // REGLIST: the second 64 bits of a quadword are pending.
    EOP: Boolean;
  end;
  PPS2GIFPathState = ^TPS2GIFPathState;

  TPS2GIF = class(TPS2Device)
  private
    FGS: TPS2GS;
    procedure PackedWrite(var P: TPS2GIFPathState; Reg: Integer; const D: TPS2Reg128);
    procedure ReglistWrite(var P: TPS2GIFPathState; Value: UInt64);
    procedure StartPath3Burst;
  public
    Path: array[1..3] of TPS2GIFPathState;
    CTRL, MODE: Cardinal;
    // Set while PATH3 is masked by VIF1 MSKPATH3.
    MaskedPath3: Boolean;
    // After an unmask: PATH3 DMA stops at the next packet end (Burst), then
    // waits (Held) until ReleasePath3; BurstQuads counts its quadwords.
    Path3Burst, Path3Held: Boolean;
    Path3BurstQuads: Integer;
    // PATH3 may move again (unmasked): the GIF DMA channel goes on.
    OnPath3Resume: TProc;
    // A PATH3 DMA burst ended after Cycles (EE cycles): ReleasePath3 then.
    OnPath3Held: TProc<Int64>;
    // Diagnostics: tags started when assigned.
    TagLog: TStrings;
    constructor Create(GS: TPS2GS);
    property GS: TPS2GS read FGS;
    procedure Reset;
    // Feeds quadwords to a path; returns how many were taken (PATH3 stops
    // at the end of a packet while it is masked).
    function Transfer(PathIndex: Integer; Data: PByte; Count: Integer; FromDMA: Boolean = False): Integer;
    function PathIdle(PathIndex: Integer): Boolean;
    // MSKPATH3 or MODE.M3R: PATH3 masked or unmasked.
    procedure SetPath3Mask(Masked: Boolean);
    // The end of a burst's transfer time: PATH3 DMA goes on unless masked.
    procedure ReleasePath3;
    // XGKICK: GIF packets from VU1 data memory at Address until one ends
    // with EOP.
    procedure Kick(Memory: PByte; Address, Mask: Cardinal);
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); override;
    procedure SerializeState(State: TStateArchive);
  end;

  // DMA channel 2 into PATH3.
  TPS2GIFPort = class(TPS2DMAPort)
  private
    FGIF: TPS2GIF;
    // Pixels the GS drew from data this channel moved (not yet taken).
    FBusyPixels: Int64;
  public
    constructor Create(GIF: TPS2GIF);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    function TakeBusyCycles: Int64; override;
  end;

implementation

constructor TPS2GIF.Create(GS: TPS2GS);
begin
  inherited Create;
  FGS := GS;
  Reset;
end;

procedure TPS2GIF.Reset;
begin
  for var K := 1 to 3 do
    Path[K] := Default(TPS2GIFPathState);
  CTRL := 0;
  MODE := 0;
  MaskedPath3 := False;
  Path3Burst := False;
  Path3Held := False;
  Path3BurstQuads := 0;
end;

procedure TPS2GIF.StartPath3Burst;
begin
  Path3Burst := True;
  Path3Held := False;
  Path3BurstQuads := 0;
  if Assigned(OnPath3Resume) then
    OnPath3Resume();
end;

procedure TPS2GIF.SetPath3Mask(Masked: Boolean);
begin
  var Was := MaskedPath3;
  MaskedPath3 := Masked;
  if Was and not Masked and ((MODE and 1) = 0) then
    StartPath3Burst;
end;

procedure TPS2GIF.ReleasePath3;
begin
  if not Path3Held then
    Exit;
  Path3Held := False;
  if not MaskedPath3 and ((MODE and 1) = 0) and Assigned(OnPath3Resume) then
    OnPath3Resume();
end;

function TPS2GIF.PathIdle(PathIndex: Integer): Boolean;
begin
  Result := not Path[PathIndex].Active;
end;

procedure TPS2GIF.PackedWrite(var P: TPS2GIFPathState; Reg: Integer; const D: TPS2Reg128);
begin
  case Reg of
    $0: FGS.WriteRegister($00, D.Lo and $7FF);
    $1:
      FGS.WriteRegister($01, (D.UW[0] and $FF) or ((D.UW[1] and $FF) shl 8) or ((D.UW[2] and $FF) shl 16) or
        (UInt64(D.UW[3] and $FF) shl 24) or (UInt64(P.Q) shl 32));
    $2:
      begin
        P.Q := D.UW[2];
        FGS.WriteRegister($02, D.Lo);
      end;
    $3: FGS.WriteRegister($03, (D.UW[0] and $3FFF) or ((D.UW[1] and $3FFF) shl 16));
    $4:
      begin
        var V := UInt64(D.UW[0] and $FFFF) or (UInt64(D.UW[1] and $FFFF) shl 16) or
          (UInt64((D.UW[2] shr 4) and $FFFFFF) shl 32) or (UInt64((D.UW[3] shr 4) and $FF) shl 56);
        if (D.UW[3] and $8000) <> 0 then
          FGS.WriteRegister($0C, V)
        else
          FGS.WriteRegister($04, V);
      end;
    $5:
      begin
        var V := UInt64(D.UW[0] and $FFFF) or (UInt64(D.UW[1] and $FFFF) shl 16) or (UInt64(D.UW[2]) shl 32);
        if (D.UW[3] and $8000) <> 0 then
          FGS.WriteRegister($0D, V)
        else
          FGS.WriteRegister($05, V);
      end;
    $6, $7, $8, $9:
      FGS.WriteRegister(Reg, D.Lo);
    $A: FGS.WriteRegister($0A, UInt64((D.UW[3] shr 4) and $FF) shl 56);
    $C: FGS.WriteRegister($0C, D.Lo);
    $D: FGS.WriteRegister($0D, D.Lo);
    $E: FGS.WriteRegister(Integer(D.Hi and $FF), D.Lo);
    $F: ;
  end;
end;

procedure TPS2GIF.ReglistWrite(var P: TPS2GIFPathState; Value: UInt64);
begin
  var Reg := Integer((P.Regs shr (P.Reg * 4)) and $F);
  // In REGLIST mode registers take their 64-bit form; A+D is not allowed.
  if Reg < $E then
    FGS.WriteRegister(Reg, Value);
  Inc(P.Reg);
  if P.Reg >= P.NReg then
  begin
    P.Reg := 0;
    Inc(P.Loop);
  end;
end;

function TPS2GIF.Transfer(PathIndex: Integer; Data: PByte; Count: Integer; FromDMA: Boolean): Integer;

  procedure PacketEnd(Done: Integer);
  begin
    if FromDMA and Path3Burst then
    begin
      Path3Burst := False;
      Path3Held := True;
      // The GS takes about a quadword per bus clock (two EE cycles).
      if Assigned(OnPath3Held) then
        OnPath3Held(Int64(Path3BurstQuads + Done) * 2 + 64);
    end;
  end;

begin
  Result := 0;
  var Q := PPS2Reg128(Data);
  while Result < Count do
  begin
    var P: PPS2GIFPathState := @Path[PathIndex];
    if not P.Active then
    begin
      // PATH3 masked or held after a burst: stop between packets.
      if (PathIndex = 3) and (MaskedPath3 or ((MODE and 1) <> 0) or FromDMA and Path3Held) then
      begin
        if FromDMA then
          Inc(Path3BurstQuads, Result);
        Exit;
      end;
      // A new tag.
      P.Tag := Q^;
      P.NLoop := Integer(P.Tag.Lo and $7FFF);
      P.EOP := (P.Tag.Lo and $8000) <> 0;
      P.Flg := Integer((P.Tag.Lo shr 58) and 3);
      P.NReg := Integer((P.Tag.Lo shr 60) and $F);
      if P.NReg = 0 then
        P.NReg := 16;
      P.Regs := P.Tag.Hi;
      P.Reg := 0;
      P.Loop := 0;
      P.Q := $3F800000;
      if (P.Tag.Lo and (UInt64(1) shl 46)) <> 0 then
        FGS.WriteRegister($00, (P.Tag.Lo shr 47) and $7FF);
      P.Active := P.NLoop > 0;
      if (TagLog <> nil) and (TagLog.Count < 200000) then
        TagLog.Add(Format('tag path%d nloop=%d eop=%d flg=%d nreg=%d regs=%x pre=%d prim=%x', [PathIndex, P.NLoop, Ord(P.EOP), P.Flg,
          P.NReg, P.Regs, (P.Tag.Lo shr 46) and 1, (P.Tag.Lo shr 47) and $7FF]));
      Inc(Result);
      Inc(Q);
      if not P.Active and P.EOP and (PathIndex = 3) then
        PacketEnd(Result);
      Continue;
    end;
    case P.Flg of
      0:
        begin
          var Reg := Integer((P.Regs shr (P.Reg * 4)) and $F);
          PackedWrite(P^, Reg, Q^);
          Inc(P.Reg);
          if P.Reg >= P.NReg then
          begin
            P.Reg := 0;
            Inc(P.Loop);
          end;
        end;
      1:
        begin
          ReglistWrite(P^, Q.Lo);
          if P.Loop < P.NLoop then
            ReglistWrite(P^, Q.Hi);
        end;
    else
      begin
        FGS.WriteImage(Q^);
        Inc(P.Loop);
      end;
    end;
    Inc(Result);
    Inc(Q);
    if P.Loop >= P.NLoop then
    begin
      P.Active := False;
      if P.EOP and (PathIndex = 3) then
        PacketEnd(Result);
    end;
  end;
  if FromDMA then
    Inc(Path3BurstQuads, Result);
end;

procedure TPS2GIF.Kick(Memory: PByte; Address, Mask: Cardinal);
begin
  // At most the whole memory; stops after the packet with EOP is done.
  for var K := 0 to Integer((Mask + 1) div 16) - 1 do
  begin
    var Q := PPS2Reg128(Memory + (Address and Mask))^;
    Transfer(1, @Q, 1);
    Address := Address + 16;
    if not Path[1].Active and Path[1].EOP then
      Break;
  end;
end;

function TPS2GIF.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  case Address and $FF0 of
    $000: Result := CTRL;
    $010: Result := MODE;
    $020:
      begin
        // STAT: M3R, M3P, IMT, OPH and APATH while a path is active.
        Result := (MODE and 1) or (Cardinal(Ord(MaskedPath3)) shl 1) or (MODE and 4);
        // PATH1 (XGKICK) runs to completion at once: never reported busy (an
        // unterminated VU packet left it 'active' and sceGsSyncPath timed out).
        for var K := 2 to 3 do
          if Path[K].Active then
          begin
            Result := Result or $200 or (Cardinal(K) shl 10);
            Break;
          end;
      end;
    $040: Result := Cardinal(Path[3].Tag.UW[0]);
    $050: Result := Cardinal(Path[3].Tag.UW[1]);
    $060: Result := Cardinal(Path[3].Tag.UW[2]);
    $070: Result := Cardinal(Path[3].Tag.UW[3]);
    $080: Result := Cardinal(Path[3].NLoop - Path[3].Loop) or (Cardinal(Path[3].Reg) shl 16);
    $090: Result := Cardinal(Path[3].NLoop - Path[3].Loop);
    $0A0: Result := Cardinal(Path[3].Tag.UW[0]);
  else
    Result := 0;
  end;
end;

procedure TPS2GIF.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  case Address and $FF0 of
    $000:
      begin
        CTRL := Cardinal(Value) and 8;
        if (Value and 1) <> 0 then
        begin
          for var K := 1 to 3 do
            Path[K] := Default(TPS2GIFPathState);
        end;
      end;
    $010:
      begin
        var WasMasked := (MODE and 1) <> 0;
        MODE := Cardinal(Value) and 5;
        if WasMasked and ((MODE and 1) = 0) and not MaskedPath3 then
          StartPath3Burst
        else if ((MODE and 1) = 0) and Assigned(OnPath3Resume) then
          OnPath3Resume();
      end;
  end;
end;

procedure TPS2GIF.WriteFIFO(Address: Cardinal; const Value: TPS2Reg128);
begin
  var V := Value;
  Transfer(3, @V, 1);
end;

procedure TPS2GIF.SerializeState(State: TStateArchive);
begin
  State.Field(Path, SizeOf(Path));
  State.Field(CTRL, SizeOf(CTRL));
  State.Field(MODE, SizeOf(MODE));
  State.Field(MaskedPath3, SizeOf(MaskedPath3));
  State.Field(Path3Burst, SizeOf(Path3Burst));
  State.Field(Path3Held, SizeOf(Path3Held));
  State.Field(Path3BurstQuads, SizeOf(Path3BurstQuads));
end;

{ TPS2GIFPort }

constructor TPS2GIFPort.Create(GIF: TPS2GIF);
begin
  inherited Create;
  FGIF := GIF;
end;

function TPS2GIFPort.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  var Pixels := FGIF.GS.Raster.PixelsDrawn;
  Result := FGIF.Transfer(3, Data, Count, True);
  Inc(FBusyPixels, FGIF.GS.Raster.PixelsDrawn - Pixels);
end;

// The GS time of what this channel's data drew: about four pixels per EE
// cycle (the GS fills 8..16 per 147 MHz clock). Drawing from the other paths
// does not hold the channel.
function TPS2GIFPort.TakeBusyCycles: Int64;
begin
  Result := FBusyPixels div 4;
  FBusyPixels := 0;
end;

end.
