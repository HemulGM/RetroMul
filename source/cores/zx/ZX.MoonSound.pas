unit ZX.MoonSound;

interface

uses
  System.SysUtils, Yamaha.Sound.OPL4, ZX.AM29F040, Core.Snapshots;

type
  // Mick ZXM-MoonSound revision 01: OPL4 + AM29F016D + 2 x 512K SRAM.
  TZXMoonSound = class
  private
    FChip: TOPL4;
    FFlash: TZXAM29F040;
    FRAM: TBytes;
    FClock, FSamplePhase, FChipPhase, FFlashPhase: Integer;
    FLeft, FRight: Double;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset(Clock: Integer);
    class function Decodes(Address: Word): Boolean; static;
    function ReadPort(Address: Word): Byte;
    procedure WritePort(Address: Word; Value: Byte);
    function ReadMemory(Address: Cardinal; MemoryMode: Boolean): Byte;
    procedure WriteMemory(Address: Cardinal; Value: Byte; MemoryMode: Boolean);
    procedure Tick;
    procedure Levels(out Left, Right: Double);
    function Interrupt: Boolean;
    procedure SerializeState(State: TStateArchive);
    function FlashImage: TBytes;
    function FlashDirty: Boolean;
    procedure LoadFlash(const Data: TBytes);
    property Chip: TOPL4 read FChip;
  end;

implementation

uses
  System.Classes;

function ReadPCM(Context: Pointer; Address: Cardinal; MemoryMode: Boolean): Byte;
begin
  Result := TZXMoonSound(Context).ReadMemory(Address, MemoryMode);
end;

procedure WritePCM(Context: Pointer; Address: Cardinal; Value: Byte; MemoryMode: Boolean);
begin
  TZXMoonSound(Context).WriteMemory(Address, Value, MemoryMode);
end;

constructor TZXMoonSound.Create;
begin
  inherited;
  var S := TResourceStream.Create(HInstance, 'ZX_MOON_WAVE', PChar(10));
  var D: TBytes;
  try
    if S.Size <> $200000 then
      raise EReadError.Create('Invalid MoonSound wavetable ROM size');
    SetLength(D, S.Size);
    S.ReadBuffer(D[0], Length(D));
  finally
    S.Free;
  end;
  FFlash := TZXAM29F040.Create(D);
  SetLength(FRAM, $100000);
  FChip := TOPL4.Create(Self, ReadPCM, WritePCM);
  Reset(3500000);
end;

destructor TZXMoonSound.Destroy;
begin
  FChip.Free;
  FFlash.Free;
  inherited;
end;

procedure TZXMoonSound.Reset(Clock: Integer);
begin
  if (Clock < 1000000) or (Clock > 8000000) then
    raise EArgumentException.Create('Invalid MoonSound motherboard clock');
  FClock := Clock;
  FSamplePhase := 0;
  FChipPhase := 0;
  FFlashPhase := 0;
  FLeft := 0;
  FRight := 0;
  // Reset does not erase the external SRAM or programmed flash.
  FChip.Reset;
  FFlash.PowerReset;
end;

class function TZXMoonSound.Decodes(Address: Word): Boolean;
begin
  Result := ((Address and $FE) = $7E) or ((Address and $FC) = $C4);
end;

function TZXMoonSound.ReadPort(Address: Word): Byte;
begin
  var Port := Address and 255;
  if Port < $80 then
    Port := Port - $7E + 4
  else
    Port := Port - $C4;
  Result := FChip.ReadPort(Port);
end;

procedure TZXMoonSound.WritePort(Address: Word; Value: Byte);
begin
  var Port := Address and 255;
  if Port < $80 then
    Port := Port - $7E + 4
  else
    Port := Port - $C4;
  FChip.WritePort(Port, Value);
end;

function TZXMoonSound.ReadMemory(Address: Cardinal; MemoryMode: Boolean): Byte;
begin
  Address := Address and $3FFFFF;
  if Address < $200000 then
    Exit(FFlash.Read(Address));
  if not MemoryMode then
  begin
    if Address < $300000 then
      Exit(FRAM[Address - $200000]);
  end
  else
  begin
    // MCS6/MCS7 narrow to 128K windows in memory mode 1. The same nineteen
    // address lines remain connected to each 512K SRAM (not a linear remap).
    if (Address >= $380000) and (Address < $3A0000) then
      Exit(FRAM[Address and $7FFFF]);
    if (Address >= $3A0000) and (Address < $3C0000) then
      Exit(FRAM[$80000 + (Address and $7FFFF)]);
  end;
  Result := $FF;
end;

procedure TZXMoonSound.WriteMemory(Address: Cardinal; Value: Byte; MemoryMode: Boolean);
begin
  Address := Address and $3FFFFF;
  if Address < $200000 then
  begin
    FFlash.Write(Address, Value);
    Exit;
  end;
  if not MemoryMode then
  begin
    if Address < $300000 then
      FRAM[Address - $200000] := Value;
  end
  else
  begin
    if (Address >= $380000) and (Address < $3A0000) then
      FRAM[Address and $7FFFF] := Value;
    if (Address >= $3A0000) and (Address < $3C0000) then
      FRAM[$80000 + (Address and $7FFFF)] := Value;
  end;
end;

procedure TZXMoonSound.Tick;
begin
  Inc(FChipPhase, 33868800);
  var Clocks := FChipPhase div FClock;
  FChipPhase := FChipPhase mod FClock;
  FChip.AdvanceClocks(Clocks);
  Inc(FFlashPhase, 24000000);
  Clocks := FFlashPhase div FClock;
  FFlashPhase := FFlashPhase mod FClock;
  FFlash.Advance(Clocks);
  Inc(FSamplePhase, 44100);
  if FSamplePhase >= FClock then
  begin
    FSamplePhase := FSamplePhase - FClock;
    FChip.Sample(FLeft, FRight);
  end;
end;

procedure TZXMoonSound.Levels(out Left, Right: Double);
begin
  Left := FLeft;
  Right := FRight;
end;

function TZXMoonSound.Interrupt: Boolean;
begin
  Result := FChip.Interrupt;
end;

function TZXMoonSound.FlashImage: TBytes;
begin
  Result := FFlash.Image;
end;

function TZXMoonSound.FlashDirty: Boolean;
begin
  Result := FFlash.Dirty;
end;

procedure TZXMoonSound.LoadFlash(const Data: TBytes);
begin
  FFlash.LoadImage(Data);
end;

procedure TZXMoonSound.SerializeState(State: TStateArchive);
begin
  State.Field(FClock, 4);
  State.Field(FSamplePhase, 4);
  State.Field(FChipPhase, 4);
  State.Field(FFlashPhase, 4);
  State.Field(FLeft, 8);
  State.Field(FRight, 8);
  State.Field(FRAM[0], Length(FRAM));
  FFlash.SerializeState(State);
  FChip.SerializeState(State);
  if (FClock < 1000000) or (FClock > 8000000) or (FSamplePhase < 0) or (FSamplePhase >= FClock) or
    (FChipPhase < 0) or (FChipPhase >= FClock) or (FFlashPhase < 0) or (FFlashPhase >= FClock) then
    raise EReadError.Create('Invalid ZXM-MoonSound clock state');
end;

end.

