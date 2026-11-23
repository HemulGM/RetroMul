unit HW.Sound.UPD7756;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TUpd7756 = class
  private
    type
      TPlayback = packed record
        Phase, ClocksLeft, Offset, NibblesLeft, Period, RepeatOffset, RepeatCount: Integer;
        Sample, Step: Integer;
        Active, FirstBlock, LowNibble: Boolean;
      end;
  private
    FRom: TBytes;
    FState: TPlayback;
    procedure ReadBlock;
    procedure DecodeNibble;
  public
    constructor Create(const Rom: TBytes);
    procedure Reset;
    procedure Start(Track: Byte);
    procedure Clock(CpuHz: Integer); inline;
    function Playing: Boolean; inline;
    function Output: SmallInt; inline;
    procedure SerializeState(State: TStateArchive; CpuHz: Integer);
  end;

implementation

uses
  System.Classes, System.Math;

const
  ChipHz = 640000;
  // 4-to-9-bit ADPCM step table from the uPD775x analysis in MAME.
  Steps: array[0..15, 0..7] of Byte = (
    (0, 0, 1, 2, 3, 5, 7, 10), (0, 1, 2, 3, 4, 6, 8, 13),
    (0, 1, 2, 4, 5, 7, 10, 15), (0, 1, 3, 4, 6, 9, 13, 19),
    (0, 2, 3, 5, 8, 11, 15, 23), (0, 2, 4, 7, 10, 14, 19, 29),
    (0, 3, 5, 8, 12, 16, 22, 33), (1, 4, 7, 10, 15, 20, 29, 43),
    (1, 4, 8, 13, 18, 25, 35, 53), (1, 6, 10, 16, 22, 31, 43, 64),
    (2, 7, 12, 19, 27, 37, 51, 76), (2, 9, 16, 24, 34, 46, 64, 96),
    (3, 11, 19, 29, 41, 57, 79, 117), (4, 13, 24, 36, 50, 69, 96, 143),
    (4, 16, 29, 44, 62, 85, 118, 175), (6, 20, 36, 54, 76, 104, 144, 214));
  StepChange: array[0..7] of ShortInt = (-1, -1, 0, 0, 1, 2, 2, 3);

constructor TUpd7756.Create(const Rom: TBytes);
begin
  inherited Create;
  FRom := Rom;
end;

procedure TUpd7756.Reset;
begin
  FState := Default(TPlayback);
end;

procedure TUpd7756.Start(Track: Byte);
begin
  if FState.Active then
    Exit;
  var Entry := 5 + 2 * Track;
  if (Entry + 1 >= Length(FRom)) or (Track > FRom[0]) then
    Exit;
  var Offset := ((FRom[Entry] shl 9) or (FRom[Entry + 1] shl 1)) + 1;
  if (Offset < 7 + 2 * FRom[0]) or (Offset >= Length(FRom)) then
    Exit;
  Reset;
  FState.Active := True;
  FState.FirstBlock := True;
  FState.Offset := Offset;
  FState.ClocksLeft := 176;
end;

procedure TUpd7756.ReadBlock;
begin
  while FState.Offset < Length(FRom) do
  begin
    if FState.RepeatCount > 0 then
    begin
      FState.Offset := FState.RepeatOffset;
      Dec(FState.RepeatCount);
    end;
    var Header := FRom[FState.Offset];
    Inc(FState.Offset);
    if (Header = 0) and not FState.FirstBlock then
      Break;
    FState.FirstBlock := False;
    case Header shr 6 of
      0:
        begin
          FState.Sample := 0;
          FState.Step := 0;
          FState.ClocksLeft := 1024 * ((Header and 63) + 1);
          Exit;
        end;
      1, 2:
        begin
          FState.Period := ((Header and 63) + 1) * 4;
          FState.NibblesLeft := 256;
          if (Header and $80) <> 0 then
          begin
            if FState.Offset >= Length(FRom) then
              Break;
            FState.NibblesLeft := FRom[FState.Offset] + 1;
            Inc(FState.Offset);
          end;
          if (FState.NibblesLeft + 1) div 2 > Length(FRom) - FState.Offset then
            Break;
          FState.LowNibble := False;
          DecodeNibble;
          Exit;
        end;
      3:
        begin
          FState.RepeatOffset := FState.Offset;
          FState.RepeatCount := (Header and 7) + 1;
        end;
    end;
  end;
  Reset;
end;

procedure TUpd7756.DecodeNibble;
begin
  var Data := FRom[FState.Offset];
  var Code := Data shr 4;
  if FState.LowNibble then
    Code := Data and 15;
  var Magnitude := Code and 7;
  var Delta: Integer := Steps[FState.Step, Magnitude];
  if (Code and 8) <> 0 then
    Delta := -Delta;
  // The DAC sees the low nine bits of the accumulator.
  FState.Sample := ((FState.Sample + Delta + $100) and $1FF) - $100;
  FState.Step := EnsureRange(FState.Step + StepChange[Magnitude], 0, 15);
  FState.ClocksLeft := FState.Period;
  Dec(FState.NibblesLeft);
  if FState.LowNibble or (FState.NibblesLeft = 0) then
    Inc(FState.Offset);
  FState.LowNibble := not FState.LowNibble;
end;

procedure TUpd7756.Clock(CpuHz: Integer);
begin
  if not FState.Active then
    Exit;
  Inc(FState.Phase, ChipHz);
  if FState.Phase < CpuHz then
    Exit;
  Dec(FState.Phase, CpuHz);
  Dec(FState.ClocksLeft);
  if FState.ClocksLeft = 0 then
    if FState.NibblesLeft = 0 then
      ReadBlock
    else
      DecodeNibble;
end;

function TUpd7756.Playing: Boolean;
begin
  Result := FState.Active;
end;

function TUpd7756.Output: SmallInt;
begin
  Result := SmallInt(FState.Sample * 128);
end;

procedure TUpd7756.SerializeState(State: TStateArchive; CpuHz: Integer);
begin
  State.Field(FState, SizeOf(FState));
  if State.Loading and
    ((Cardinal(FState.Phase) >= Cardinal(CpuHz)) or (Cardinal(FState.ClocksLeft) > 65536) or
    (FState.Active and (FState.ClocksLeft = 0)) or (Cardinal(FState.Offset) > Cardinal(Length(FRom))) or
    (Cardinal(FState.NibblesLeft) > 256) or (Cardinal(FState.Period) > 256) or
    (Cardinal(FState.RepeatOffset) > Cardinal(Length(FRom))) or (Cardinal(FState.RepeatCount) > 8) or
    ((FState.NibblesLeft <> 0) and ((FState.Period < 4) or
    (FState.Offset + (FState.NibblesLeft + 1 + Ord(FState.LowNibble)) div 2 > Length(FRom)))) or
    (FState.Sample < -256) or (FState.Sample > 255) or (Cardinal(FState.Step) > 15)) then
    raise EReadError.Create('Invalid uPD7756 playback state');
end;

end.

