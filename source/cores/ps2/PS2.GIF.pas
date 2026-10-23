unit PS2.GIF;

// GS interface: GIF tags in PACKED, REGLIST and IMAGE modes for the three
// paths (PATH1 from VU1 XGKICK, PATH2 from VIF1 DIRECT, PATH3 from DMA
// channel 2 or the FIFO), each with its own tag state so that packets of
// different paths may alternate between whole packets; the GIF registers
// (CTRL, MODE, STAT, TAG0-3, CNT, P3CNT, P3TAG) and PATH3 masking.
// References: EE User's Manual (GIF chapter), GS User's Manual, ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, Core.Snapshots, PS2.Types, PS2.EE.Bus, PS2.DMAC, PS2.GS;

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
  public
    Path: array[1..3] of TPS2GIFPathState;
    CTRL, MODE: Cardinal;
    // Set while PATH3 is masked by VIF1 MSKPATH3.
    MaskedPath3: Boolean;
    constructor Create(GS: TPS2GS);
    property GS: TPS2GS read FGS;
    procedure Reset;
    // Feeds quadwords to a path; returns how many were taken (PATH3 stops
    // at the end of a packet while it is masked).
    function Transfer(PathIndex: Integer; Data: PByte; Count: Integer): Integer;
    function PathIdle(PathIndex: Integer): Boolean;
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
    FPixels: Int64;
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

function TPS2GIF.Transfer(PathIndex: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := 0;
  var Q := PPS2Reg128(Data);
  while Result < Count do
  begin
    var P: PPS2GIFPathState := @Path[PathIndex];
    if not P.Active then
    begin
      // PATH3 masked: stop between packets.
      if (PathIndex = 3) and (MaskedPath3 or ((MODE and 1) <> 0)) then
        Exit;
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
      Inc(Result);
      Inc(Q);
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
      P.Active := False;
  end;
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
        for var K := 1 to 3 do
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
    $010: MODE := Cardinal(Value) and 5;
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
end;

{ TPS2GIFPort }

constructor TPS2GIFPort.Create(GIF: TPS2GIF);
begin
  inherited Create;
  FGIF := GIF;
end;

function TPS2GIFPort.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := FGIF.Transfer(3, Data, Count);
end;

function TPS2GIFPort.TakeBusyCycles: Int64;
begin
  // About four pixels per EE cycle (the GS fills 8..16 per 147 MHz clock).
  var Pixels := FGIF.GS.Raster.PixelsDrawn;
  Result := (Pixels - FPixels) div 4;
  FPixels := Pixels;
end;

end.
