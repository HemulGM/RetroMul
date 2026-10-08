unit Amiga.ProTracker;

interface

uses
  System.SysUtils, System.Generics.Collections, Core.AudioFilter;

type
  TMODSample = record
    Name: string;
    Data, Original: TArray<ShortInt>;
    Volume, Finetune, LoopStart, LoopLength: Integer;
  end;

  TMODNote = record
    Period, Instrument, FX, Param: Integer;
  end;

  TMODVoice = record
    Instrument, PlayingSample, Volume, MixVolume, Period, MixPeriod, Target, Finetune: Integer;
    FX, Param, Offset, PortaSpeed, VibratoSpeed, VibratoDepth, VibratoPhase, VibratoWave: Integer;
    TremoloSpeed, TremoloDepth, TremoloPhase, TremoloWave, Pan, LoopRow, LoopCount: Integer;
    FunkSpeed, FunkAccum, FunkPosition, Glissando, DelayNote, DelayPeriod: Integer;
    Position: Double;
    Active, Looped: Boolean;
  end;

  TMOD = class
  private
    FSamples: TArray<TMODSample>;
    FNotes: TArray<TMODNote>;
    FOrders: TArray<Integer>;
    FVoices: TArray<TMODVoice>;
    FVisited: TDictionary<string, Boolean>;
    FChannels, FOrder, FRow, FTick, FSpeed, FBPM, FDelay, FNextOrder, FNextRow, FSamplesLeft: Integer;
    FTicks: Integer;
    FSampleFraction: Double;
    FEnded, FFilterOn: Boolean;
    FTitle: string;
    FFilter: array[0..1] of TPCMLowPass;
    FDC: array[0..1] of TPCMDCBlocker;
    function NoteAt(Channel: Integer): TMODNote;
    function TunedPeriod(Period, Finetune: Integer): Integer;
    procedure Trigger(var Voice: TMODVoice; Period: Integer);
    procedure BeginRow;
    procedure Effects(Channel: Integer; Tick: Integer);
    function NextTick: Boolean;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset;
    function FrameCount: Int64;
    function Sample(out Left, Right: SmallInt): Boolean;
    property Title: string read FTitle;
    property Channels: Integer read FChannels;
  end;

implementation

uses
  System.Math;

const
  // Exact 16 x 37 ProTracker finetune periods, including section terminators.
  PeriodTable: array[0..591] of Integer = (
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453, 428, 404, 381, 360,
    339, 320, 302, 285, 269, 254, 240, 226, 214, 202, 190, 180, 170, 160, 151, 143,
    135, 127, 120, 113, 0, 850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477,
    450, 425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 239, 225, 213, 201, 189,
    179, 169, 159, 150, 142, 134, 126, 119, 113, 0, 844, 796, 752, 709, 670, 632,
    597, 563, 532, 502, 474, 447, 422, 398, 376, 355, 335, 316, 298, 282, 266, 251,
    237, 224, 211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118, 112, 0, 838,
    791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444, 419, 395, 373, 352, 332,
    314, 296, 280, 264, 249, 235, 222, 209, 198, 187, 176, 166, 157, 148, 140, 132,
    125, 118, 111, 0, 832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, 441,
    416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233, 220, 208, 196, 185, 175,
    165, 156, 147, 139, 131, 124, 117, 110, 0, 826, 779, 736, 694, 655, 619, 584,
    551, 520, 491, 463, 437, 413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232,
    219, 206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116, 109, 0, 820, 774,
    730, 689, 651, 614, 580, 547, 516, 487, 460, 434, 410, 387, 365, 345, 325, 307,
    290, 274, 258, 244, 230, 217, 205, 193, 183, 172, 163, 154, 145, 137, 129, 122,
    115, 109, 0, 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431, 407,
    384, 363, 342, 323, 305, 288, 272, 256, 242, 228, 216, 204, 192, 181, 171, 161,
    152, 144, 136, 128, 121, 114, 108, 0, 907, 856, 808, 762, 720, 678, 640, 604,
    570, 538, 508, 480, 453, 428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240,
    226, 214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 0, 900, 850, 802,
    757, 715, 675, 636, 601, 567, 535, 505, 477, 450, 425, 401, 379, 357, 337, 318,
    300, 284, 268, 253, 238, 225, 212, 200, 189, 179, 169, 159, 150, 142, 134, 126,
    119, 0, 894, 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447, 422,
    398, 376, 355, 335, 316, 298, 282, 266, 251, 237, 223, 211, 199, 188, 177, 167,
    158, 149, 141, 133, 125, 118, 0, 887, 838, 791, 746, 704, 665, 628, 592, 559,
    528, 498, 470, 444, 419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235, 222,
    209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118, 0, 881, 832, 785, 741,
    699, 660, 623, 588, 555, 524, 494, 467, 441, 416, 392, 370, 350, 330, 312, 294,
    278, 262, 247, 233, 220, 208, 196, 185, 175, 165, 156, 147, 139, 131, 123, 117,
    0, 875, 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437, 413, 390,
    368, 347, 328, 309, 292, 276, 260, 245, 232, 219, 206, 195, 184, 174, 164, 155,
    146, 138, 130, 123, 116, 0, 868, 820, 774, 730, 689, 651, 614, 580, 547, 516,
    487, 460, 434, 410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230, 217, 205,
    193, 183, 172, 163, 154, 145, 137, 129, 122, 115, 0, 862, 814, 768, 725, 684,
    646, 610, 575, 543, 513, 484, 457, 431, 407, 384, 363, 342, 323, 305, 288, 272,
    256, 242, 228, 216, 203, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114, 0);
  Sine: array[0..31] of Integer = (0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24);
  Funk: array[0..15] of Integer = (0, 5, 6, 7, 8, 10, 11, 13, 16, 19, 22, 26, 32, 43, 64, 128);

constructor TMOD.Create(const Data: TBytes);

  procedure Require(Offset, Count: Integer);
  begin
    if (Offset < 0) or (Count < 0) or (Offset > Length(Data)) or (Count > Length(Data) - Offset) then
      raise EArgumentException.Create('Truncated MOD');
  end;

  function BE16(Offset: Integer): Integer;
  begin
    Require(Offset, 2);
    Result := Integer(Data[Offset]) * 256 + Data[Offset + 1];
  end;

  function Text(Offset, Count: Integer): string;
  begin
    Require(Offset, Count);
    var N := 0;
    while (N < Count) and (Data[Offset + N] <> 0) do
      Inc(N);
    Result := TEncoding.ASCII.GetString(Data, Offset, N).Trim;
  end;

begin
  inherited Create;
  FVisited := TDictionary<string, Boolean>.Create;
  Require(0, 600);
  FTitle := Text(0, 20);
  FChannels := 4;
  var Instruments := 15;
  var Header := 600;
  if Length(Data) >= 1084 then
  begin
    var Signature := Text(1080, 4);
    if (Signature = 'M.K.') or (Signature = 'M!K!') or (Signature = 'M&K!') or
      (Signature = 'N.T.') or (Signature = 'FLT4') then
      Instruments := 31
    else if (Length(Signature) = 4) and (Copy(Signature, 2, 3) = 'CHN') then
    begin
      FChannels := StrToIntDef(Signature[1], 0);
      Instruments := 31;
    end
    else if (Length(Signature) = 4) and (Copy(Signature, 3, 2) = 'CH') then
    begin
      FChannels := StrToIntDef(Copy(Signature, 1, 2), 0);
      Instruments := 31;
    end
    else if (Signature = 'FLT8') or (Signature = 'CD81') or (Signature = 'OKTA') then
      raise EArgumentException.Create('Unsupported MOD layout');
    if Instruments = 31 then
      Header := 1084;
  end;
  if (FChannels < 1) or (FChannels > 32) then
    raise EArgumentException.Create('Invalid MOD channel count');
  var SongOffset := 20 + Instruments * 30;
  var SongLength := Integer(Data[SongOffset]);
  if (SongLength < 1) or (SongLength > 128) then
    raise EArgumentException.Create('Invalid MOD order count');
  SetLength(FOrders, SongLength);
  var Patterns := 0;
  for var I := 0 to 127 do
  begin
    var Pattern := Integer(Data[SongOffset + 2 + I]);
    if I < SongLength then
    begin
      if Pattern > 127 then
        raise EArgumentException.Create('Invalid MOD pattern');
      FOrders[I] := Pattern;
      Patterns := Max(Patterns, Pattern + 1);
    end;
  end;
  Require(Header, Patterns * 64 * FChannels * 4);
  SetLength(FNotes, Patterns * 64 * FChannels);
  for var I := 0 to High(FNotes) do
  begin
    var P := Header + I * 4;
    var N: TMODNote;
    N.Instrument := (Data[P] and $F0) or (Data[P + 2] shr 4);
    N.Period := ((Integer(Data[P]) and 15) shl 8) or Data[P + 1];
    N.FX := Data[P + 2] and 15;
    N.Param := Data[P + 3];
    if (N.Instrument > Instruments) or ((N.Period <> 0) and (N.Period < 28)) then
      raise EArgumentException.Create('Invalid MOD note/instrument');
    FNotes[I] := N;
  end;
  var Offset := Header + Length(FNotes) * 4;
  SetLength(FSamples, Instruments + 1);
  for var I := 1 to Instruments do
  begin
    var P := 20 + (I - 1) * 30;
    var Size := BE16(P + 22) * 2;
    FSamples[I].Name := Text(P, 22);
    FSamples[I].Finetune := Data[P + 24] and 15;
    FSamples[I].Volume := Data[P + 25];
    if (Data[P + 24] > 15) or (FSamples[I].Volume > 64) then
      raise EArgumentException.Create('Invalid MOD sample parameters');
    FSamples[I].LoopStart := BE16(P + 26) * 2;
    FSamples[I].LoopLength := BE16(P + 28) * 2;
    if FSamples[I].LoopLength <= 2 then
    begin
      FSamples[I].LoopStart := 0;
      FSamples[I].LoopLength := 0;
    end
    else if (FSamples[I].LoopStart > Size) or (FSamples[I].LoopLength > Size - FSamples[I].LoopStart) then
      raise EArgumentException.Create('Invalid MOD sample loop');
    Require(Offset, Size);
    SetLength(FSamples[I].Original, Size);
    for var J := 0 to Size - 1 do
    begin
      var V := Integer(Data[Offset + J]);
      if V >= 128 then
        Dec(V, 256);
      FSamples[I].Original[J] := V;
    end;
    Inc(Offset, Size);
  end;
  SetLength(FVoices, FChannels);
  Reset;
end;

destructor TMOD.Destroy;
begin
  FVisited.Free;
  inherited;
end;

procedure TMOD.Reset;
begin
  for var I := 0 to High(FSamples) do
    FSamples[I].Data := Copy(FSamples[I].Original);
  for var C := 0 to FChannels - 1 do
  begin
    FVoices[C] := Default(TMODVoice);
    FVoices[C].Pan := 0;
    if C mod 4 in [1, 2] then
      FVoices[C].Pan := 255;
  end;
  FVisited.Clear;
  FOrder := 0;
  FRow := 0;
  FTick := 0;
  FTicks := 0;
  FSpeed := 6;
  FBPM := 125;
  FDelay := 0;
  FNextOrder := -1;
  FNextRow := 0;
  FSamplesLeft := 0;
  FSampleFraction := 0;
  FEnded := False;
  FFilterOn := False;
  for var J := 0 to 1 do
  begin
    FFilter[J].Configure(44100, 3275);
    FFilter[J].Reset;
    FDC[J].Configure(44100, 5);
    FDC[J].Reset;
  end;
end;

function TMOD.NoteAt(Channel: Integer): TMODNote;
begin
  Result := FNotes[(FOrders[FOrder] * 64 + FRow) * FChannels + Channel];
end;

function TMOD.TunedPeriod(Period, Finetune: Integer): Integer;
begin
  var Note := 0;
  while (Note < 35) and (Period < PeriodTable[Note]) do
    Inc(Note);
  Result := PeriodTable[(Finetune and 15) * 37 + Note];
end;

procedure TMOD.Trigger(var Voice: TMODVoice; Period: Integer);
begin
  Voice.Period := Period;
  Voice.Position := 0;
  Voice.Looped := False;
  if Voice.FX = 9 then
    Voice.Position := Voice.Offset * 256;
  Voice.PlayingSample := Voice.Instrument;
  Voice.Active := (Voice.PlayingSample > 0) and (Length(FSamples[Voice.PlayingSample].Data) > Voice.Position);
  if Voice.VibratoWave and 4 = 0 then
    Voice.VibratoPhase := 0;
  if Voice.TremoloWave and 4 = 0 then
    Voice.TremoloPhase := 0;
end;

procedure TMOD.BeginRow;
begin
  if FOrder >= Length(FOrders) then
  begin
    FEnded := True;
    Exit;
  end;
  var Key := Format('%d:%d:%d:%d', [FOrder, FRow, FSpeed, FBPM]);
  for var V in FVoices do
    Key := Key + Format(':%d:%d', [V.LoopRow, V.LoopCount]);
  if FVisited.ContainsKey(Key) then
  begin
    FEnded := True;
    Exit;
  end;
  FVisited.Add(Key, True);
  FNextOrder := -1;
  FNextRow := 0;
  FDelay := 0;
  for var C := 0 to FChannels - 1 do
  begin
    var N := NoteAt(C);
    var V := FVoices[C];
    V.FX := N.FX;
    V.Param := N.Param;
    V.DelayNote := 0;
    if N.Instrument <> 0 then
    begin
      V.Instrument := N.Instrument;
      V.Volume := FSamples[N.Instrument].Volume;
      V.Finetune := FSamples[N.Instrument].Finetune;
    end;
    if (N.FX = 14) and (N.Param shr 4 = 5) then
      V.Finetune := N.Param and 15;
    if (N.FX = 9) and (N.Param <> 0) then
      V.Offset := N.Param;
    if (N.FX = 3) and (N.Param <> 0) then
      V.PortaSpeed := N.Param;
    if N.FX in [4, 7] then
    begin
      if N.FX = 4 then
      begin
        if N.Param shr 4 <> 0 then
          V.VibratoSpeed := N.Param shr 4;
        if N.Param and 15 <> 0 then
          V.VibratoDepth := N.Param and 15;
      end
      else
      begin
        if N.Param shr 4 <> 0 then
          V.TremoloSpeed := N.Param shr 4;
        if N.Param and 15 <> 0 then
          V.TremoloDepth := N.Param and 15;
      end;
    end;
    if N.Period <> 0 then
    begin
      var Period := TunedPeriod(N.Period, V.Finetune);
      if N.FX in [3, 5] then
        V.Target := Period
      else if (N.FX = 14) and (N.Param shr 4 = 13) and (N.Param and 15 <> 0) then
      begin
        V.DelayNote := N.Param and 15;
        V.DelayPeriod := Period;
      end
      else
        Trigger(V, Period);
    end;
    case N.FX of
      8:
        V.Pan := N.Param;
      11:
        begin
          FNextOrder := N.Param;
          FNextRow := 0;
        end;
      12:
        V.Volume := Min(64, N.Param);
      13:
        begin
          if FNextOrder < 0 then
            FNextOrder := FOrder + 1;
          FNextRow := (N.Param shr 4) * 10 + (N.Param and 15);
          if FNextRow > 63 then
            FNextRow := 0;
        end;
      15:
        if N.Param = 0 then
          FEnded := True
        else if N.Param < 32 then
          FSpeed := N.Param
        else
          FBPM := N.Param;
      14:
        case N.Param shr 4 of
          0:
            FFilterOn := N.Param and 1 = 0;
          1:
            V.Period := Max(113, V.Period - (N.Param and 15));
          2:
            V.Period := Min(856, V.Period + (N.Param and 15));
          3:
            V.Glissando := N.Param and 15;
          4:
            V.VibratoWave := N.Param and 7;
          6:
            if N.Param and 15 = 0 then
              V.LoopRow := FRow
            else
            begin
              if V.LoopCount = 0 then
                V.LoopCount := N.Param and 15
              else
                Dec(V.LoopCount);
              if V.LoopCount > 0 then
              begin
                FNextOrder := FOrder;
                FNextRow := V.LoopRow;
              end;
            end;
          7:
            V.TremoloWave := N.Param and 7;
          8:
            if V.PlayingSample > 0 then
            begin
              var S := V.PlayingSample;
              var Start := FSamples[S].LoopStart;
              var Size := FSamples[S].LoopLength;
              if Size > 0 then
                for var J := 0 to Size - 1 do
                  FSamples[S].Data[Start + J] := (Integer(FSamples[S].Data[Start + J]) + FSamples[S].Data[Start + (J + 1) mod Size]) div 2;
            end;
          10:
            V.Volume := Min(64, V.Volume + (N.Param and 15));
          11:
            V.Volume := Max(0, V.Volume - (N.Param and 15));
          12:
            if N.Param and 15 = 0 then
              V.Volume := 0;
          14:
            FDelay := N.Param and 15;
          15:
            V.FunkSpeed := N.Param and 15;
        end;
    end;
    V.MixPeriod := V.Period;
    V.MixVolume := V.Volume;
    FVoices[C] := V;
  end;
end;

procedure TMOD.Effects(Channel: Integer; Tick: Integer);
var
  V: TMODVoice;

  procedure SlideVolume;
  begin
    if V.Param shr 4 <> 0 then
      V.Volume := Min(64, V.Volume + (V.Param shr 4))
    else
      V.Volume := Max(0, V.Volume - (V.Param and 15));
    V.MixVolume := V.Volume;
  end;

  function Wave(Phase, Kind: Integer): Integer;
  begin
    Phase := Phase and 63;
    case Kind and 3 of
      0:
        Result := Sine[Phase and 31];
      1:
        begin
          Result := (Phase and 31) * 8;
          if Phase >= 32 then
            Result := 255 - Result;
        end;
    else
      Result := 255;
    end;
    if Phase >= 32 then
      Result := -Result;
  end;

  procedure Vibrato;
  begin
    V.MixPeriod := V.Period + Wave(V.VibratoPhase, V.VibratoWave) * V.VibratoDepth div 128;
    V.VibratoPhase := (V.VibratoPhase + V.VibratoSpeed) and 63;
  end;

  procedure Porta;
  begin
    if V.Target > 0 then
    begin
      if V.Period < V.Target then
        V.Period := Min(V.Target, V.Period + V.PortaSpeed)
      else
        V.Period := Max(V.Target, V.Period - V.PortaSpeed);
      V.MixPeriod := V.Period;
      if V.Glissando <> 0 then
        V.MixPeriod := TunedPeriod(V.Period, V.Finetune);
    end;
  end;

begin
  V := FVoices[Channel];
  V.MixPeriod := V.Period;
  V.MixVolume := V.Volume;
  if Tick > 0 then
    case V.FX of
      0:
        if V.Param <> 0 then
        begin
          var Shift := 0;
          if Tick mod 3 = 1 then
            Shift := V.Param shr 4;
          if Tick mod 3 = 2 then
            Shift := V.Param and 15;
          var Note := 0;
          while (Note < 35) and (V.Period < PeriodTable[V.Finetune * 37 + Note]) do
            Inc(Note);
          V.MixPeriod := PeriodTable[V.Finetune * 37 + Min(35, Note + Shift)];
        end;
      1:
        begin
          V.Period := Max(113, V.Period - V.Param);
          V.MixPeriod := V.Period;
        end;
      2:
        begin
          V.Period := Min(856, V.Period + V.Param);
          V.MixPeriod := V.Period;
        end;
      3:
        Porta;
      4:
        Vibrato;
      5:
        begin
          Porta;
          SlideVolume;
        end;
      6:
        begin
          Vibrato;
          SlideVolume;
        end;
      7:
        begin
          V.MixVolume := EnsureRange(V.Volume + Wave(V.TremoloPhase, V.TremoloWave) * V.TremoloDepth div 64, 0, 64);
          V.TremoloPhase := (V.TremoloPhase + V.TremoloSpeed) and 63;
        end;
      10:
        SlideVolume;
    end;
  if V.FX = 14 then
    case V.Param shr 4 of
      9:
        if (V.Param and 15 <> 0) and (Tick > 0) and (Tick mod (V.Param and 15) = 0) then
          Trigger(V, V.Period);
      12:
        if Tick = V.Param and 15 then
        begin
          V.Volume := 0;
          V.MixVolume := 0;
        end;
      13:
        if (V.DelayNote > 0) and (Tick = V.DelayNote) then
        begin
          Trigger(V, V.DelayPeriod);
          V.MixPeriod := V.Period;
          V.DelayNote := 0;
        end;
    end;
  if (V.FunkSpeed > 0) and (V.PlayingSample > 0) then
  begin
    Inc(V.FunkAccum, Funk[V.FunkSpeed]);
    var S := V.PlayingSample;
    if (V.FunkAccum >= 128) and (FSamples[S].LoopLength > 0) then
    begin
      V.FunkAccum := 0;
      V.FunkPosition := (V.FunkPosition + 1) mod FSamples[S].LoopLength;
      var P := FSamples[S].LoopStart + V.FunkPosition;
      FSamples[S].Data[P] := -1 - Integer(FSamples[S].Data[P]);
    end;
  end;
  FVoices[Channel] := V;
end;

function TMOD.NextTick: Boolean;
begin
  Result := False;
  if FEnded then
    Exit;
  if FTicks >= 900000 then
    raise EArgumentException.Create('MOD exceeds 900,000 ticks');
  if FTick = 0 then
    BeginRow;
  if FEnded then
    Exit;
  for var C := 0 to FChannels - 1 do
    Effects(C, FTick mod FSpeed);
  FSampleFraction := FSampleFraction + 44100 * 2.5 / FBPM;
  FSamplesLeft := Trunc(FSampleFraction);
  FSampleFraction := FSampleFraction - FSamplesLeft;
  Inc(FTick);
  Inc(FTicks);
  if FTick >= FSpeed * (FDelay + 1) then
  begin
    FTick := 0;
    if FNextOrder >= 0 then
    begin
      FOrder := FNextOrder;
      FRow := FNextRow;
    end
    else
    begin
      Inc(FRow);
      if FRow = 64 then
      begin
        FRow := 0;
        Inc(FOrder);
      end;
    end;
  end;
  Result := True;
end;

function TMOD.FrameCount: Int64;
begin
  Reset;
  Result := 0;
  while NextTick do
    Inc(Result, FSamplesLeft);
  Reset;
end;

function TMOD.Sample(out Left, Right: SmallInt): Boolean;
begin
  Result := False;
  if (FSamplesLeft = 0) and not NextTick then
    Exit;
  var L := 0.0;
  var R := 0.0;
  for var C := 0 to FChannels - 1 do
  begin
    var V := FVoices[C];
    if V.Active and (V.MixPeriod > 0) then
    begin
      var S := V.PlayingSample;
      var Size := Length(FSamples[S].Data);
      var LoopStart := FSamples[S].LoopStart;
      var LoopSize := FSamples[S].LoopLength;
      var EndPos := Size;
      // A nonzero repeat start shortens the initial DMA length. With a
      // zero repeat start Paula plays the full sample once before looping.
      if (LoopSize > 0) and ((LoopStart > 0) or V.Looped) then
        EndPos := LoopStart + LoopSize;
      if V.Position >= EndPos then
        if LoopSize > 0 then
        begin
          V.Position := LoopStart + Frac((V.Position - EndPos) / LoopSize) * LoopSize;
          V.Looped := True;
          EndPos := LoopStart + LoopSize;
        end
        else
          V.Active := False;
      if V.Active then
      begin
        var At := Trunc(V.Position);
        var Next := At + 1;
        if Next >= EndPos then
          if LoopSize > 0 then
            Next := LoopStart
          else
            Next := At;
        var A := Integer(FSamples[S].Data[At]);
        var B := Integer(FSamples[S].Data[Next]);
        var Value := (A + (B - A) * Frac(V.Position)) * V.MixVolume * 4;
        L := L + Value * (255 - V.Pan) / 255;
        R := R + Value * V.Pan / 255;
        V.Position := V.Position + 3546895 / (Double(V.MixPeriod) * 44100);
      end;
    end;
    FVoices[C] := V;
  end;
  var FilterL := FFilter[0].Process(L);
  var FilterR := FFilter[1].Process(R);
  if FFilterOn then
  begin
    L := FilterL;
    R := FilterR;
  end;
  Left := EnsureRange(Round(FDC[0].Process(L)), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(R)), -32768, 32767);
  Dec(FSamplesLeft);
  Result := True;
end;

end.

