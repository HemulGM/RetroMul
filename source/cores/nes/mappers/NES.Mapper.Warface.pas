unit NES.Mapper.Warface;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperWarface = class(TMapperBanked)
  private
    FChrRegister, FChrLatch, FScanline, FNametableReads, FIdleCycles: Byte;
    FPpuAddress: UInt16;
    FTimer: UInt16;
    FIrqPending: Boolean;
    procedure UpdateChr;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockPpuRead; override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    function IrqPending: Boolean; override;
  end;

implementation

// Board wiring and PPU read detector:
// https://github.com/ClusterM/nes-warface/blob/master/Mapper/WarfaceMapper.v

constructor TMapperWarface.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  Reset;
end;

procedure TMapperWarface.Reset;
begin
  inherited;
  FRamEnabled := False;
  FRamWritable := False;
  FMirror := TMirrorMode.Horizontal;
  FChrRegister := 0;
  FChrLatch := 0;
  FScanline := 0;
  FNametableReads := 0;
  FIdleCycles := 16;
  FPpuAddress := 0;
  FTimer := 0;
  FIrqPending := False;
  UpdateChr;
end;

procedure TMapperWarface.UpdateChr;
begin
  if (FChrRegister and $80) <> 0 then
    Chr4(0, (FChrRegister and $1C) or FChrLatch)
  else
    Chr4(0, FChrRegister and $1F);
  Chr4(1, (Length(FChrMemory) div $1000) - 1);
end;

function TMapperWarface.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address >= $6000) and (Address < $8000);
  if not Result then
    Exit;

  if (Address and 1) = 0 then
  begin
    Prg16(0, Value and 7);
    if (Value and $80) <> 0 then
      FTimer := 4095;
    // Acknowledging does not stop a timer that is still counting.
    FIrqPending := False;
  end
  else
  begin
    FChrRegister := Value;
    UpdateChr;
  end;
end;

procedure TMapperWarface.ClockCpu;
begin
  if FTimer > 0 then
  begin
    Dec(FTimer);
    if FTimer = 0 then
      FIrqPending := True;
  end;
  if FIdleCycles < 16 then
    Inc(FIdleCycles);
end;

procedure TMapperWarface.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  FPpuAddress := Address;
end;

procedure TMapperWarface.ClockPpuRead;
begin
  // Four consecutive nametable reads identify the end-of-line dummy fetches
  // followed by the next line's tile/attribute fetches. Use timed reads rather
  // than a visible-line hook, so rendering pauses reset the detector as well.
  if FIdleCycles = 16 then
  begin
    FScanline := 0;
    FChrLatch := 0;
    UpdateChr;
  end
  else if (FPpuAddress and $3000) = $2000 then
  begin
    if FNametableReads < 3 then
      Inc(FNametableReads)
    else
    begin
      case FScanline of
        64:
          FChrLatch := 1;
        128:
          FChrLatch := 2;
        192:
          FChrLatch := 3;
      end;
      FScanline := (Integer(FScanline) + 1) and $FF;
      UpdateChr;
    end;
  end
  else
    FNametableReads := 0;
  FIdleCycles := 0;
end;

function TMapperWarface.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

procedure TMapperWarface.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  // RetroMul draws the complete row at dot 1. The fourth nametable read
  // arrives at dot 3, before its pattern fetches, but after that software
  // render. Project the imminent CHR bank for the row without advancing
  // the hardware detector (which still clocks on the real read at dot 3).
  if Rendering and (Line < 240) and (FNametableReads = 3) and ((FChrRegister and $80) <> 0) then
    case FScanline of
      64:
        Chr4(0, (FChrRegister and $1C) or 1);
      128:
        Chr4(0, (FChrRegister and $1C) or 2);
      192:
        Chr4(0, (FChrRegister and $1C) or 3);
    end;
end;

procedure TMapperWarface.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FChrRegister, SizeOf(FChrRegister));
  State.Field(FChrLatch, SizeOf(FChrLatch));
  State.Field(FScanline, SizeOf(FScanline));
  State.Field(FNametableReads, SizeOf(FNametableReads));
  State.Field(FIdleCycles, SizeOf(FIdleCycles));
  State.Field(FPpuAddress, SizeOf(FPpuAddress));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FIrqPending, SizeOf(FIrqPending));
end;

end.

