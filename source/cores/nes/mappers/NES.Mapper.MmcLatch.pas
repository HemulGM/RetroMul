unit NES.Mapper.MmcLatch;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperMmcLatch = class(TMapperBanked)
  private
    FMmc4: Boolean;
    FLatches: array[0..1] of Integer;
    FRegisters: array[0..3] of Byte;
    procedure UpdateChr;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Mmc4: Boolean; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperMmcLatch.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FMmc4, SizeOf(FMmc4));
  State.Field(FLatches, SizeOf(FLatches));
  State.Field(FRegisters, SizeOf(FRegisters));
end;

constructor TMapperMmcLatch.Create(Mmc4: Boolean; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FMmc4 := Mmc4;
  Reset;
end;

procedure TMapperMmcLatch.UpdateChr;
begin
  for var i := 0 to 1 do
    Chr4(i, FRegisters[i * 2 + FLatches[i]]);
end;

procedure TMapperMmcLatch.Reset;
begin
  inherited;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FLatches[0] := 1;
  FLatches[1] := 1;
  if not FMmc4 then
  begin
    Prg8(0, 0);
    Prg8(1, -3);
  end;
  UpdateChr;
end;

function TMapperMmcLatch.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $A000 then
    Exit(inherited CpuWrite(Address, Value));
  Result := True;
  case Address shr 12 of
    $A:
      if FMmc4 then
        Prg16(0, Value and $0F)
      else
        Prg8(0, Value and $0F);
    $B..$E:
      begin
        FRegisters[(Address shr 12) - $B] := Value and $1F;
        UpdateChr;
      end;
    $F:
      Mirror(Value and 1);
  end;
end;

function TMapperMmcLatch.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := inherited PpuRead(Address, Value);
  if not Result then
    Exit;
  // The triggering read still returns the old bank; the next read sees the latch.
  var Trigger := Address;
  if FMmc4 or (Address >= $1000) then
    Trigger := Trigger and $FFF8;
  case Trigger of
    $0FD8:
      FLatches[0] := 0;
    $0FE8:
      FLatches[0] := 1;
    $1FD8:
      FLatches[1] := 0;
    $1FE8:
      FLatches[1] := 1;
  else
    Exit;
  end;
  UpdateChr;
end;

end.

