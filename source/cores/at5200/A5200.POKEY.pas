unit A5200.POKEY;

interface

uses
  System.SysUtils, A5200.POKEY.Types, A5200.Controller, Core.Snapshots;

type
  TA5200POKEY = class
  private
    FPair: TPokeyPair;
    FRegs: array[0..15] of Byte;
    FPots: array[0..7] of Byte;
    FCycle, FPotCycle: Integer;
    FLastKey: Byte;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure BeginFrame;
    procedure Clock(Controller: TA5200Controller; SelectedPort: Integer);
    function Read(Index: Byte; Controller: TA5200Controller; SelectedPort: Integer; PotsEnabled: Boolean): Byte;
    procedure Write(Index, Value: Byte; Controller: TA5200Controller);
    procedure EndFrame(out Samples: TArray<SmallInt>);
    function IRQ: Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math, A5200.POKEY.Engine;

constructor TA5200POKEY.Create;
begin
  inherited;
  FPair := TPokeyPair.Create;
  PokeyPair_Construct(FPair);
  Reset;
end;

destructor TA5200POKEY.Destroy;
begin
  FPair.Free;
  inherited;
end;

procedure TA5200POKEY.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FPots, SizeOf(FPots), 228);
  PokeyPair_Initialize(FPair, True, False, 44100);
  FCycle := 0;
  FPotCycle := 0;
  FLastKey := $FF;
end;

procedure TA5200POKEY.BeginFrame;
begin
  PokeyPair_StartFrame(FPair);
  FCycle := 0;
end;

procedure TA5200POKEY.Clock(Controller: TA5200Controller; SelectedPort: Integer);
begin
  Inc(FCycle);
  if FPotCycle < 114 * 228 then
    Inc(FPotCycle);
  Pokey_CheckIrq(FPair.basePokey, FCycle, 8388608);
  if FCycle mod 114 = 0 then
  begin
    var Key := Controller.Keyboard(SelectedPort);
    if (FRegs[15] and 2 <> 0) and (Key <> $FF) and (Key <> FLastKey) and (FRegs[14] and $40 <> 0) then
      FPair.basePokey.irqst := FPair.basePokey.irqst and $BF;
    if Controller.TopButton(SelectedPort) and (FRegs[14] and $80 <> 0) then
      FPair.basePokey.irqst := FPair.basePokey.irqst and $7F;
    FLastKey := Key;
  end;
end;

function TA5200POKEY.Read(Index: Byte; Controller: TA5200Controller; SelectedPort: Integer; PotsEnabled: Boolean): Byte;
begin
  Index := Index and 15;
  Result := $FF;
  if Index < 8 then
  begin
    var Elapsed := FPotCycle div 114;
    if FRegs[15] and 4 <> 0 then
      Elapsed := FPotCycle;
    if PotsEnabled then
      Result := Min(FPots[Index], Min(228, Elapsed))
    else
      Result := 228;
  end
  else
    case Index of
      8:
        begin
          Result := 0;
          for var i := 0 to 7 do
            if (FPotCycle div 114 < FPots[i]) then
              Result := Result or (1 shl i);
        end;
      9:
        Result := FLastKey;
      10, 14:
        Result := PokeyPair_Peek(FPair, Index, FCycle);
      15:
        begin
          Result := $FF;
          if Controller.TopButton(SelectedPort) then
            Result := Result and $F7;
          if Controller.Keyboard(SelectedPort) <> $FF then
            Result := Result and $FB;
        end;
    end;
end;

procedure TA5200POKEY.Write(Index, Value: Byte; Controller: TA5200Controller);
begin
  Index := Index and 15;
  FRegs[Index] := Value;
  if Index = 11 then
  begin
    FPotCycle := 0;
    for var i := 0 to 7 do
      FPots[i] := Controller.Pot(i);
  end;
  PokeyPair_Poke(FPair, Index, Value, FCycle);
end;

function TA5200POKEY.IRQ: Boolean;
begin
  Result := (FPair.basePokey.irqst xor 255) and FRegs[14] <> 0;
end;

procedure TA5200POKEY.EndFrame(out Samples: TArray<SmallInt>);
begin
  var Count := PokeyPair_EndFrame(FPair, FCycle);
  var PCM: TBytes;
  SetLength(PCM, Count * 2);
  PokeyPair_Generate(FPair, PCM, 0, Count, ASAPSampleFormat_S16_L_E);
  SetLength(Samples, Count * 2);
  for var i := 0 to Count - 1 do
  begin
    var V := SmallInt(Word(PCM[i * 2]) or (Word(PCM[i * 2 + 1]) shl 8));
    Samples[i * 2] := V;
    Samples[i * 2 + 1] := V;
  end;
  for var i := 0 to 3 do
    PokeyChannel_EndFrame(FPair.basePokey.channels[i], FCycle);
end;

procedure TA5200POKEY.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FPots, SizeOf(FPots));
  State.Field(FCycle, SizeOf(FCycle));
  State.Field(FPotCycle, SizeOf(FPotCycle));
  State.Field(FLastKey, SizeOf(FLastKey));
  State.Field(FPair.sampleOffset, SizeOf(Integer));
  State.Field(FPair.readySamplesStart, SizeOf(Integer));
  State.Field(FPair.readySamplesEnd, SizeOf(Integer));
  var P := FPair.basePokey;
  State.Field(P.audctl, SizeOf(Integer));
  State.Field(P.skctl, SizeOf(Integer));
  State.Field(P.irqst, SizeOf(Integer));
  State.Field(P.init, SizeOf(Boolean));
  State.Field(P.divCycles, SizeOf(Integer));
  State.Field(P.reloadCycles1, SizeOf(Integer));
  State.Field(P.reloadCycles3, SizeOf(Integer));
  State.Field(P.polyIndex, SizeOf(Integer));
  State.Field(P.sumDACInputs, SizeOf(Integer));
  State.Field(P.sumDACOutputs, SizeOf(Integer));
  State.Field(P.iirAcc, SizeOf(Integer));
  State.Field(P.trailing, SizeOf(Integer));
  State.Field(P.deltaBuffer[0], Length(P.deltaBuffer) * SizeOf(Integer));
  for var i := 0 to 3 do
  begin
    var C := P.channels[i];
    State.Field(C.audf, SizeOf(Integer));
    State.Field(C.audc, SizeOf(Integer));
    State.Field(C.periodCycles, SizeOf(Integer));
    State.Field(C.tickCycle, SizeOf(Integer));
    State.Field(C.timerCycle, SizeOf(Integer));
    State.Field(C.mute, SizeOf(Integer));
    State.Field(C.output, SizeOf(Integer));
    State.Field(C.delta, SizeOf(Integer));
  end;
end;

end.

