unit CPS.BootlegSound;

interface

uses
  System.SysUtils, HW.Sound.YM2203, HW.Sound.MSM5205, HW.Z80, Core.Snapshots;

type
  TCPSBootlegSound = class
  private
    FOPN: array[0..1] of TYM2203;
    FMSM: array[0..1] of TMSM5205;
    FBuffer, FAddress: array[0..1] of Byte;
    FPhase, FNibblePhase: Int64;
    FToggle: Boolean;
    FCount: Integer;
    FMuted: array[0..1] of Boolean;
    FBusy: array[0..1] of Integer;
  public
    Samples: TArray<SmallInt>;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure BeginFrame;
    procedure EndFrame;
    procedure WriteFM(Chip, Port: Integer; Value: Byte);
    function ReadFM(Chip, Port: Integer): Byte;
    procedure WriteADPCM(Chip: Integer; Value: Byte);
    procedure Bank(Value: Byte);
    procedure Advance(Cycles: Integer; var CPU: TZ80State);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor TCPSBootlegSound.Create;
begin
  inherited Create;
  for var i := 0 to 1 do
  begin
    FOPN[i] := TYM2203.Create(4000000);
    FMSM[i] := TMSM5205.Create;
  end;
  Reset;
end;

destructor TCPSBootlegSound.Destroy;
begin
  for var i := 0 to 1 do
  begin
    FOPN[i].Free;
    FMSM[i].Free;
  end;
  inherited;
end;

procedure TCPSBootlegSound.Reset;
begin
  for var i := 0 to 1 do
  begin
    FOPN[i].Reset;
    FMSM[i].Reset;
  end;
  FillChar(FBuffer, SizeOf(FBuffer), 0);
  FillChar(FAddress, SizeOf(FAddress), 0);
  FillChar(FMuted, SizeOf(FMuted), 0);
  FPhase := 0;
  FNibblePhase := 0;
  FToggle := False;
  BeginFrame;
  FillChar(FBusy, SizeOf(FBusy), 0);
end;

procedure TCPSBootlegSound.BeginFrame;
begin
  FCount := 0;
  SetLength(Samples, 2048);
end;

procedure TCPSBootlegSound.EndFrame;
begin
  SetLength(Samples, FCount);
end;

procedure TCPSBootlegSound.WriteFM(Chip, Port: Integer; Value: Byte);
begin
  if Port = 0 then
    FAddress[Chip] := Value
  else
  begin
    FOPN[Chip].WriteRegister(FAddress[Chip], Value);
    FBusy[Chip] := 192;
  end;
end;

function TCPSBootlegSound.ReadFM(Chip, Port: Integer): Byte;
begin
  if Port = 1 then
    Exit(FOPN[Chip].ReadRegister(FAddress[Chip]));

  Result := FOPN[Chip].ReadStatus;
  if FBusy[Chip] > 0 then
    Result := Result or $80;
end;

procedure TCPSBootlegSound.WriteADPCM(Chip: Integer; Value: Byte);
begin
  FBuffer[Chip] := Value;
end;

procedure TCPSBootlegSound.Bank(Value: Byte);
begin
  FMuted[0] := Value and 8 <> 0;
  FMuted[1] := Value and 16 <> 0;
end;

procedure TCPSBootlegSound.Advance(Cycles: Integer; var CPU: TZ80State);
begin
  for var i := 0 to 1 do
    FBusy[i] := Max(0, FBusy[i] - Cycles);
  while Cycles > 0 do
  begin
    var N := Min(Int64(Cycles), Min((4000000 - FPhase + 44099) div 44100,
        (Int64(4000000) * 96 - FNibblePhase + 374999) div 375000));
    if N < 1 then
      N := 1;
    Dec(Cycles, N);
    Inc(FPhase, N * 44100);
    Inc(FNibblePhase, N * 375000);
    if FNibblePhase >= Int64(4000000) * 96 then
    begin
      Dec(FNibblePhase, Int64(4000000) * 96);
      for var i := 0 to 1 do
      begin
        FMSM[i].Clock(FBuffer[i] and 15);
        FBuffer[i] := FBuffer[i] shr 4;
      end;
      FToggle := not FToggle;
      if not FToggle then
        Z80NonMaskableInterrupt(CPU);
    end;
    if FPhase >= 4000000 then
    begin
      Dec(FPhase, 4000000);
      var Value := (Integer(FOPN[0].Sample) + Integer(FOPN[1].Sample)) div 2;
      for var i := 0 to 1 do
        if not FMuted[i] then
          Inc(Value, FMSM[i].Sample div 4);
      Value := EnsureRange(Value, -32768, 32767);
      if FCount + 2 > Length(Samples) then
        SetLength(Samples, FCount + 2048);
      Samples[FCount] := Value;
      Samples[FCount + 1] := Value;
      Inc(FCount, 2);
    end;
  end;
end;

procedure TCPSBootlegSound.SerializeState(State: TStateArchive);
begin
  for var i := 0 to 1 do
  begin
    FOPN[i].SerializeState(State);
    FMSM[i].SerializeState(State);
  end;
  State.Field(FBuffer, SizeOf(FBuffer));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FMuted, SizeOf(FMuted));
  State.Field(FToggle, SizeOf(FToggle));
  State.Field(FBusy, SizeOf(FBusy));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FNibblePhase, SizeOf(FNibblePhase));

  if (FPhase < 0) or (FPhase >= 4000000) or (FNibblePhase < 0) or (FNibblePhase >= Int64(4000000) * 96) then
    raise EArgumentException.Create('Invalid bootleg sound clock');
end;

end.

