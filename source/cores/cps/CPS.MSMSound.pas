unit CPS.MSMSound;

interface

uses
  System.SysUtils, CPS1.Sound, HW.Sound.MSM5205, HW.Z80, Core.Snapshots;

type
  // Two LS157 byte latches, a VCK flip-flop and cascaded MSM5205 clocks.
  TCPSMSMSound = class
  private
    FChip: array[0..1] of TMSM5205;
    FByte: array[0..1] of Byte;
    FPhase, FVCK: Int64;
    FSelect: Boolean;
    FCount, FGain: Integer;
  public
    Samples: TArray<SmallInt>;
    constructor Create(Gain: Integer = 1);
    destructor Destroy; override;
    procedure Reset;
    procedure BeginFrame;
    procedure EndFrame;
    procedure Bank(Value: Byte);
    procedure Data(Chip: Integer; Value: Byte);
    procedure Advance(Cycles: Integer; Sound: TCPS1Sound; var CPU: TZ80State);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor TCPSMSMSound.Create(Gain: Integer);
begin
  inherited Create;
  FGain := Gain;
  for var i := 0 to 1 do
    FChip[i] := TMSM5205.Create;
  Reset;
end;

destructor TCPSMSMSound.Destroy;
begin
  for var i := 0 to 1 do
    FChip[i].Free;
  inherited;
end;

procedure TCPSMSMSound.Reset;
begin
  for var i := 0 to 1 do
    FChip[i].Reset;
  FillChar(FByte, SizeOf(FByte), 0);
  FPhase := 0;
  FVCK := 0;
  FSelect := False;
  BeginFrame;
end;

procedure TCPSMSMSound.BeginFrame;
begin
  FCount := 0;
  SetLength(Samples, 2048);
end;

procedure TCPSMSMSound.EndFrame;
begin
  SetLength(Samples, FCount);
end;

procedure TCPSMSMSound.Bank(Value: Byte);
begin
  FChip[0].SetReset(Value and $20 <> 0);
  FChip[1].SetReset(Value and $10 <> 0);
end;

procedure TCPSMSMSound.Data(Chip: Integer; Value: Byte);
begin
  FByte[Chip] := Value;
end;

procedure TCPSMSMSound.Advance(Cycles: Integer; Sound: TCPS1Sound; var CPU: TZ80State);
begin
  while Cycles > 0 do
  begin
    var N := Min(Int64(Cycles), Min((3750000 - FPhase + 44099) div 44100,
        (Int64(3750000) * 96 - FVCK + 399999) div 400000));
    if N < 1 then
      N := 1;
    Dec(Cycles, N);
    Inc(FPhase, N * 44100);
    Inc(FVCK, N * 400000);
    if FVCK >= Int64(3750000) * 96 then
    begin
      Dec(FVCK, Int64(3750000) * 96);
      FSelect := not FSelect;
      for var i := 0 to 1 do
        FChip[i].Clock((FByte[i] shr (Ord(FSelect) * 4)) and 15);
      if FSelect then
        Z80NonMaskableInterrupt(CPU);
    end;
    if FPhase >= 3750000 then
    begin
      Dec(FPhase, 3750000);
      var V := (Integer(Sound.Samples[FCount]) + Integer(Sound.Samples[FCount + 1])) div 2 +
        (FChip[0].Sample + FChip[1].Sample) * FGain div 4;
      if FCount + 2 > Length(Samples) then
        SetLength(Samples, FCount + 2048);
      Samples[FCount] := EnsureRange(V, -32768, 32767);
      Samples[FCount + 1] := Samples[FCount];
      Inc(FCount, 2);
    end;
  end;
end;

procedure TCPSMSMSound.SerializeState(State: TStateArchive);
begin
  for var i := 0 to 1 do
    FChip[i].SerializeState(State);
  State.Field(FByte, SizeOf(FByte));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FVCK, SizeOf(FVCK));
  State.Field(FSelect, SizeOf(FSelect));

  if (FPhase < 0) or (FPhase >= 3750000) or (FVCK < 0) or (FVCK >= Int64(3750000) * 96) then
    raise EArgumentException.Create('Invalid CPS MSM clock');

  if State.Loading then
    BeginFrame;
end;

end.

