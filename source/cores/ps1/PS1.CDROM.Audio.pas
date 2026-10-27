unit PS1.CDROM.Audio;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types;

const
  // 44100 Hz stereo frames buffered between the drive and the SPU.
  PS1CDAudioCapacity = 16384;

type
  // CD audio output: CD-DA frames, XA-ADPCM decoding with the 37800/18900 Hz
  // to 44100 Hz zigzag resampler, the ATV volume matrix and mute switches.
  // The SPU takes one frame per sample.
  TPS1CDAudio = class
  private
    FLeft, FRight: array[0..PS1CDAudioCapacity - 1] of SmallInt;
    FHead, FCount: Integer;
    // XA decoder: ADPCM history per channel, resampler ring and six-step.
    FOld, FOlder: array[0..1] of Integer;
    FRing: array[0..1, 0..31] of SmallInt;
    FRingPos, FSixStep: Integer;
    // ATV0 L->L, ATV1 L->R, ATV2 R->R, ATV3 R->L.
    FPending, FVolume: array[0..3] of Byte;
    FADPCMMuted, FMuted: Boolean;
    FPeak: Word;
    procedure Changing; inline;
    procedure SetMuted(Value: Boolean);
    procedure Push(Left, Right: Integer);
    procedure Resample(Left, Right: Integer);
    procedure DecodeBlock(const Sector: array of Byte; Offset, Block, Channel: Integer; EightBit: Boolean; var Output: array of SmallInt; Start: Integer);
  public
    // Called before anything that changes the frames Pop returns, so that
    // the consumer can first take the frames due by the current time.
    BeforeChange: TPS1Notify;
    constructor Create;
    procedure Reset;
    // Forgets ADPCM history between unrelated streams.
    procedure ResetXA;
    // Raw 2352-byte Mode 2 Form 2 sector with an XA audio subheader.
    procedure DecodeXA(const Sector: array of Byte);
    // 2352 bytes of 16-bit little-endian stereo samples.
    procedure PushCDDA(const Sector: array of Byte; Offset: Integer = 0);
    // Next 44100 Hz frame after the volume matrix; silence when empty.
    procedure Pop(out Left, Right: Integer);
    procedure WriteVolume(Index: Integer; Value: Byte);
    procedure WriteControl(Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property Count: Integer read FCount;
    // Mute/Demute commands silence CD-DA and XA alike.
    property Muted: Boolean read FMuted write SetMuted;
    // Peak level of the last CD-DA sector (for Play reports).
    property Peak: Word read FPeak;
  end;

implementation

const
  XAPositive: array[0..3] of Integer = (0, 60, 115, 98);
  XANegative: array[0..3] of Integer = (0, 0, -52, -55);

  // psx-spx "25-point Zigzag Interpolation": one table per output sample of
  // each group of seven, applied to the 29 most recent 37800 Hz samples.
  ZigZag: array[0..6, 1..29] of Integer = (
    (0, 0, 0, 0, 0, -$0002, $000A, -$0022, $0041, -$0054, $0034, $0009, -$010A, $0400, -$0A78, $234C,
    $6794, -$1780, $0BCD, -$0623, $0350, -$016D, $006B, $000A, -$0010, $0011, -$0008, $0003, -$0001),
    (0, 0, 0, -$0002, 0, $0003, -$0013, $003C, -$004B, $00A2, -$00E3, $0132, -$0043, -$0267, $0C9D, $74BB,
    -$11B4, $09B8, -$05BF, $0372, -$01A8, $00A6, -$001B, $0005, $0006, -$0008, $0003, -$0001, 0),
    (0, 0, -$0001, $0003, -$0002, -$0005, $001F, -$004A, $00B3, -$0192, $02B1, -$039E, $04F8, -$05A6, $7939,
    -$05A6, $04F8, -$039E, $02B1, -$0192, $00B3, -$004A, $001F, -$0005, -$0002, $0003, -$0001, 0, 0),
    (0, -$0001, $0003, -$0008, $0006, $0005, -$001B, $00A6, -$01A8, $0372, -$05BF, $09B8, -$11B4, $74BB,
    $0C9D, -$0267, -$0043, $0132, -$00E3, $00A2, -$004B, $003C, -$0013, $0003, 0, -$0002, 0, 0, 0),
    (-$0001, $0003, -$0008, $0011, -$0010, $000A, $006B, -$016D, $0350, -$0623, $0BCD, -$1780, $6794, $234C,
    -$0A78, $0400, -$010A, $0009, $0034, -$0054, $0041, -$0022, $000A, -$0001, 0, $0001, 0, 0, 0),
    ($0002, -$0008, $0010, -$0023, $002B, $001A, -$00EB, $027B, -$0548, $0AFA, -$16FA, $53E0, $3C07, -$1249,
    $080E, -$0347, $015B, -$0044, -$0017, $0046, -$0023, $0011, -$0005, 0, 0, 0, 0, 0, 0),
    (-$0005, $0011, -$0023, $0046, -$0017, -$0044, $015B, -$0347, $080E, -$1249, $3C07, $53E0, -$16FA,
    $0AFA, -$0548, $027B, -$00EB, $001A, $002B, -$0023, $0010, -$0008, $0002, 0, 0, 0, 0, 0, 0));

function Sar(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function Clamp16(Value: Int64): Integer; inline;
begin
  if Value < -32768 then
    Result := -32768
  else if Value > 32767 then
    Result := 32767
  else
    Result := Integer(Value);
end;

constructor TPS1CDAudio.Create;
begin
  inherited Create;
  Reset;
end;

procedure TPS1CDAudio.Changing;
begin
  if Assigned(BeforeChange) then
    BeforeChange;
end;

procedure TPS1CDAudio.SetMuted(Value: Boolean);
begin
  Changing;
  FMuted := Value;
end;

procedure TPS1CDAudio.Reset;
begin
  Changing;
  FHead := 0;
  FCount := 0;
  ResetXA;
  FPending[0] := $80;
  FPending[1] := 0;
  FPending[2] := $80;
  FPending[3] := 0;
  FVolume := FPending;
  FADPCMMuted := False;
  FMuted := False;
  FPeak := 0;
end;

procedure TPS1CDAudio.ResetXA;
begin
  FillChar(FOld, SizeOf(FOld), 0);
  FillChar(FOlder, SizeOf(FOlder), 0);
  FillChar(FRing, SizeOf(FRing), 0);
  FRingPos := 0;
  // The hardware counter starts at a random phase; six keeps it fixed.
  FSixStep := 6;
end;

procedure TPS1CDAudio.Push(Left, Right: Integer);
begin
  if FCount >= PS1CDAudioCapacity then
    Exit;

  var Index := (FHead + FCount) and (PS1CDAudioCapacity - 1);
  FLeft[Index] := SmallInt(Left);
  FRight[Index] := SmallInt(Right);
  Inc(FCount);
end;

procedure TPS1CDAudio.Pop(out Left, Right: Integer);
begin
  Left := 0;
  Right := 0;
  if FCount = 0 then
    Exit;

  var L := Integer(FLeft[FHead]);
  var R := Integer(FRight[FHead]);
  FHead := (FHead + 1) and (PS1CDAudioCapacity - 1);
  Dec(FCount);
  if FMuted then
    Exit;

  Left := Clamp16(Sar(Int64(L) * FVolume[0] + Int64(R) * FVolume[3], 7));
  Right := Clamp16(Sar(Int64(R) * FVolume[2] + Int64(L) * FVolume[1], 7));
end;

procedure TPS1CDAudio.Resample(Left, Right: Integer);
begin
  FRing[0, FRingPos and 31] := SmallInt(Left);
  FRing[1, FRingPos and 31] := SmallInt(Right);
  FRingPos := (FRingPos + 1) and 31;
  Dec(FSixStep);
  if FSixStep > 0 then
    Exit;

  FSixStep := 6;
  for var Table := 0 to 6 do
  begin
    var SumL: Int64 := 0;
    var SumR: Int64 := 0;
    for var I := 1 to 29 do
    begin
      var At := (FRingPos - I) and 31;
      Inc(SumL, Int64(FRing[0, At]) * ZigZag[Table, I]);
      Inc(SumR, Int64(FRing[1, At]) * ZigZag[Table, I]);
    end;
    Push(Clamp16(Sar(SumL, 15)), Clamp16(Sar(SumR, 15)));
  end;
end;

// 28 samples of one block of a 128-byte sound group starting at Offset.
procedure TPS1CDAudio.DecodeBlock(const Sector: array of Byte; Offset, Block, Channel: Integer; EightBit: Boolean; var Output: array of SmallInt; Start: Integer);
begin
  var Header := Sector[Offset + 4 + Block];
  var Range := Header and $F;
  if Range > 12 then
    Range := 9;
  var Filter := (Header shr 4) and 3;
  var F0 := XAPositive[Filter];
  var F1 := XANegative[Filter];
  for var J := 0 to 27 do
  begin
    var Sample: Integer;
    if EightBit then
      Sample := Integer(ShortInt(Sector[Offset + 16 + Block + J * 4])) shl 8
    else
    begin
      var Nibble := (Sector[Offset + 16 + Block shr 1 + J * 4] shr ((Block and 1) * 4)) and $F;
      Sample := Integer(Nibble) shl 12;
      if Nibble >= 8 then
        Dec(Sample, $10000);
    end;
    var Value := Clamp16(Sar(Sample, Range) + Sar(Int64(FOld[Channel]) * F0 + Int64(FOlder[Channel]) * F1 + 32, 6));
    FOlder[Channel] := FOld[Channel];
    FOld[Channel] := Value;
    Output[Start + J] := SmallInt(Value);
  end;
end;

procedure TPS1CDAudio.DecodeXA(const Sector: array of Byte);
var
  Left, Right: array[0..223] of SmallInt;
begin
  Changing;
  var Coding := Sector[19];
  var Stereo := (Coding and 3) = 1;
  var HalfRate := ((Coding shr 2) and 3) = 1;
  var EightBit := ((Coding shr 4) and 3) = 1;
  var Blocks := 8;
  if EightBit then
    Blocks := 4;
  for var Group := 0 to 17 do
  begin
    var Offset := 24 + Group * 128;
    var Count := 0;
    if Stereo then
    begin
      for var Block := 0 to Blocks div 2 - 1 do
      begin
        DecodeBlock(Sector, Offset, Block * 2, 0, EightBit, Left, Count);
        DecodeBlock(Sector, Offset, Block * 2 + 1, 1, EightBit, Right, Count);
        Inc(Count, 28);
      end;
    end
    else
    begin
      for var Block := 0 to Blocks - 1 do
      begin
        DecodeBlock(Sector, Offset, Block, 0, EightBit, Left, Count);
        Inc(Count, 28);
      end;
      Move(Left, Right, Count * SizeOf(SmallInt));
    end;
    for var I := 0 to Count - 1 do
    begin
      var L := Integer(Left[I]);
      var R := Integer(Right[I]);
      if FADPCMMuted then
      begin
        L := 0;
        R := 0;
      end;
      Resample(L, R);
      // 18900 Hz streams enter the 37800 Hz resampler twice per sample.
      if HalfRate then
        Resample(L, R);
    end;
  end;
end;

procedure TPS1CDAudio.PushCDDA(const Sector: array of Byte; Offset: Integer);
begin
  Changing;
  var Peak := 0;
  for var I := 0 to 587 do
  begin
    var At := Offset + I * 4;
    var L := Integer(SmallInt(Word(Sector[At]) or (Word(Sector[At + 1]) shl 8)));
    var R := Integer(SmallInt(Word(Sector[At + 2]) or (Word(Sector[At + 3]) shl 8)));
    if Abs(L) > Peak then
      Peak := Abs(L);
    Push(L, R);
  end;
  if Peak > $7FFF then
    Peak := $7FFF;
  FPeak := Peak;
end;

procedure TPS1CDAudio.WriteVolume(Index: Integer; Value: Byte);
begin
  FPending[Index and 3] := Value;
end;

procedure TPS1CDAudio.WriteControl(Value: Byte);
begin
  Changing;
  FADPCMMuted := (Value and 1) <> 0;
  if (Value and $20) <> 0 then
    FVolume := FPending;
end;

procedure TPS1CDAudio.SerializeState(State: TStateArchive);
begin
  State.Field(FLeft, SizeOf(FLeft));
  State.Field(FRight, SizeOf(FRight));
  State.Field(FHead, SizeOf(FHead));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FOld, SizeOf(FOld));
  State.Field(FOlder, SizeOf(FOlder));
  State.Field(FRing, SizeOf(FRing));
  State.Field(FRingPos, SizeOf(FRingPos));
  State.Field(FSixStep, SizeOf(FSixStep));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FADPCMMuted, SizeOf(FADPCMMuted));
  State.Field(FMuted, SizeOf(FMuted));
  State.Field(FPeak, SizeOf(FPeak));
  if State.Loading and ((FHead < 0) or (FHead >= PS1CDAudioCapacity) or (FCount < 0) or
    (FCount > PS1CDAudioCapacity) or (FSixStep < 1) or (FSixStep > 6)) then
    raise EReadError.Create('PS1 snapshot CD audio');
end;

end.

