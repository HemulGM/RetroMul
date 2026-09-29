unit NES.Mapper.Subor;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  // iNES mapper 167: Subor educational-computer cartridge.
  TMapperSubor = class(TMapperBanked)
  private
    FRegister1, FRegister2, FRegister3, FRegister4: Byte;
    procedure UpdateBanks;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperSubor.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegister1, SizeOf(FRegister1));
  State.Field(FRegister2, SizeOf(FRegister2));
  State.Field(FRegister3, SizeOf(FRegister3));
  State.Field(FRegister4, SizeOf(FRegister4));
end;

constructor TMapperSubor.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  // The SUBOR board has 8 KiB of writable CHR RAM irrespective of legacy
  // header RAM flags.
  inherited Create(Prg, Chr, True, MirrorMode);
  Reset;
end;

procedure TMapperSubor.Reset;
begin
  inherited;
  FRegister1 := 0;
  FRegister2 := 0;
  FRegister3 := 0;
  FRegister4 := 0;
  UpdateBanks;
end;

procedure TMapperSubor.UpdateBanks;
begin
  var Bank := ((FRegister1 xor FRegister2) shr 4 and 1) shl 5;
  Bank := Bank or ((FRegister3 xor FRegister4) and $1F);
  case (FRegister2 shr 2) and 3 of
    0:
      begin
        Prg16(0, Bank);
        Prg16(1, $20);
      end;
    1:
      begin
        Prg16(0, $1F);
        Prg16(1, Bank);
      end;
  else
    begin
      // NROM-256: the lower physical PRG address bit is the inverse of
      // CPU A14, so the two 16 KiB windows form an adjacent bank pair.
      Prg16(0, (Bank and $3E) or 1);
      Prg16(1, Bank and $3E);
    end;
  end;
  FMirror := TMirrorMode.Horizontal;
  if (FRegister1 and 1) <> 0 then
    FMirror := TMirrorMode.Vertical;
  Chr8(0);
end;

function TMapperSubor.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));
  case Address shr 13 of
    4:
      FRegister1 := Value;
    5:
      FRegister2 := Value;
    6:
      FRegister3 := Value;
    7:
      FRegister4 := Value;
  end;
  UpdateBanks;
  Result := True;
end;

end.

